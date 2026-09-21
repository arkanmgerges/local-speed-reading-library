// Quality gate after a batch `lsr build`: removes editions that did not
// build or are too short to be worth a download, then keeps at most
// `--per-language` editions per language in discovery order (the order in
// the report written by bin/discover.dart). Editions that are not in the
// report (hand-added or already published) are always kept and count
// towards the limit.
//
//   dart run bin/prune.dart --report ../build/discover-report.json \
//       [--min-words 6000] [--per-language 20] [--dry-run]
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:lsr_library_tools/lsr_library_tools.dart';
import 'package:path/path.dart' as p;

/// Stage plays are dialogue, not prose: most paragraphs open with a speaker
/// name in capitals. Wikidata rarely classes them, so the text decides.
String? _looksLikeAPlay(LibraryRepo repo, BookMetadata m) {
  final String? path = m.assetPathValue;
  if (path == null) return null;
  final File json = File(localAssetFile(repo, path.substring(0, path.length - 3)));
  if (!json.existsSync()) return null;
  final Map<String, Object?> book = jsonDecode(json.readAsStringSync()) as Map<String, Object?>;
  final List<Object?> chapters = (book['chapters'] as List<Object?>?) ?? const <Object?>[];
  int total = 0, speaker = 0;
  final RegExp cue = RegExp(
      r'^[A-ZÀ-ÖØ-ÞĂÂÎȘȚŞŢČŠŽĆĐŁŃŚŹŻ][A-ZÀ-ÖØ-ÞĂÂÎȘȚŞŢČŠŽĆĐŁŃŚŹŻ\s.\-]{1,40}[:(.,]\s',
      unicode: true);
  final RegExp cyrillicCue = RegExp(r'^[А-ЯЁЂЈЉЊЋЏІЇЄҐ][А-ЯЁЂЈЉЊЋЏІЇЄҐ\s.\-]{1,40}[:(.,]\s', unicode: true);
  for (final Object? c in chapters) {
    for (final Object? p in ((c as Map<String, Object?>)['paragraphs'] as List<Object?>)) {
      final String t = p as String;
      total++;
      if (cue.hasMatch(t) || cyrillicCue.hasMatch(t)) speaker++;
    }
  }
  if (total < 40) return null;
  final double share = speaker / total;
  return share >= 0.3 ? 'reads like a play (${(share * 100).round()}% of paragraphs open with a speaker cue)' : null;
}

const Set<String> _unspaced = <String>{'zh-Hant', 'zh-Hans', 'ja', 'th', 'km', 'my', 'lo'};

void main(List<String> argv) {
  final ArgParser parser = ArgParser()
    ..addOption('report', mandatory: true)
    ..addOption('min-words', defaultsTo: '6000')
    ..addOption('min-chapters', defaultsTo: '1')
    ..addOption('max-words', defaultsTo: '400000', help: 'Multi-volume compendia are not one download.')
    ..addOption('per-language', defaultsTo: '20')
    ..addFlag('dry-run');
  final ArgResults args = parser.parse(argv);
  final LibraryRepo repo = LibraryRepo.locate();
  final int minWords = int.parse(args['min-words'] as String);
  final int minChapters = int.parse(args['min-chapters'] as String);
  final int maxWords = int.parse(args['max-words'] as String);
  final int perLanguage = int.parse(args['per-language'] as String);
  final bool dryRun = args['dry-run'] as bool;

  final Map<String, Object?> report =
      jsonDecode(File(args['report'] as String).readAsStringSync()) as Map<String, Object?>;
  final Map<String, List<String>> order = <String, List<String>>{};
  for (final MapEntry<String, Object?> e in report.entries) {
    final List<Object?> chosen = ((e.value as Map<String, Object?>)['chosen'] as List<Object?>?) ?? const <Object?>[];
    order[e.key] = chosen.map((Object? c) => (c as Map<String, Object?>)['workId'] as String).toList();
  }

  final Map<String, List<BookMetadata>> byLanguage = <String, List<BookMetadata>>{};
  for (final File f in repo.metadataFiles()) {
    final BookMetadata m = BookMetadata.read(f);
    byLanguage.putIfAbsent(m.language, () => <BookMetadata>[]).add(m);
  }

  // Safety: a batch where nothing built at all means the build step failed,
  // not that every book is bad.
  final bool anyBuilt = byLanguage.values
      .expand((List<BookMetadata> l) => l)
      .any((BookMetadata m) => m.asset != null && (order[m.language] ?? const <String>[]).contains(m.workId));
  if (!anyBuilt) {
    stderr.writeln('no discovered edition has an asset block; refusing to prune');
    exit(1);
  }
  int removed = 0, kept = 0;
  final Map<String, int> keptPerLanguage = <String, int>{};
  // Rejected editions are remembered so a later discovery round does not
  // offer them again (build/rejected-editions.txt, one editionId per line).
  final File rejected = File(p.join(repo.buildDir, 'rejected-editions.txt'));
  void remove(BookMetadata m, String why) {
    removed++;
    stdout.writeln('remove ${m.editionId}: $why');
    if (dryRun) return;
    rejected.writeAsStringSync('${m.editionId}\n', mode: FileMode.append);
    final File f = File(repo.metadataFile(m.language, m.editionId));
    if (f.existsSync()) f.deleteSync();
    for (final String dir in <String>[
      p.join(repo.buildSourcesDir, m.editionId),
      p.join(repo.buildBooksDir, languagePathSegment(m.language), m.editionId),
    ]) {
      final Directory d = Directory(dir);
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  }

  for (final MapEntry<String, List<BookMetadata>> e in byLanguage.entries) {
    final String lang = e.key;
    final List<String> discovered = order[lang] ?? const <String>[];
    final List<BookMetadata> protected = e.value.where((BookMetadata m) => !discovered.contains(m.workId)).toList();
    final List<BookMetadata> candidates = e.value.where((BookMetadata m) => discovered.contains(m.workId)).toList()
      ..sort((BookMetadata a, BookMetadata b) => discovered.indexOf(a.workId).compareTo(discovered.indexOf(b.workId)));
    int slots = perLanguage - protected.length;
    kept += protected.length;
    keptPerLanguage[lang] = protected.length;
    for (final BookMetadata m in candidates) {
      final Map<String, Object?>? asset = m.asset;
      if (asset == null) {
        remove(m, 'no asset (build failed)');
        continue;
      }
      // Scripts without word spacing count as one "word" per run, so the gate
      // falls back to the text size for them (about six bytes per word).
      final int words = _unspaced.contains(m.language)
          ? ((asset['uncompressedSizeBytes'] as int? ?? 0) ~/ 6)
          : (asset['wordCount'] as int? ?? 0);
      final int chapters = asset['chapterCount'] as int? ?? 0;
      if (words < minWords) {
        remove(m, 'only $words words');
        continue;
      }
      if (words > maxWords) {
        remove(m, '$words words: too large for one download');
        continue;
      }
        final String? why = _looksLikeAPlay(repo, m);
        if (why != null) {
          remove(m, why);
          continue;
        }
      if (chapters < minChapters) {
        remove(m, 'only $chapters chapter(s)');
        continue;
      }
      if (slots <= 0) {
        remove(m, 'over the per-language limit');
        continue;
      }
      slots--;
      kept++;
      keptPerLanguage[lang] = keptPerLanguage[lang]! + 1;
    }
  }
  final List<String> langs = keptPerLanguage.keys.toList()..sort();
  for (final String l in langs) {
    stdout.writeln('$l: ${keptPerLanguage[l]}');
  }
  stdout.writeln('${dryRun ? 'would keep' : 'kept'} $kept, ${dryRun ? 'would remove' : 'removed'} $removed');
}

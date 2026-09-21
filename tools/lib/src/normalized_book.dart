import 'package:lsr_library_tools/src/canonical_json.dart';
import 'package:lsr_library_tools/src/text_normalize.dart';

/// Name/version stamped into every generated asset. Bump the version when
/// the normaliser's output for the same source could change.
const String normalizerName = 'lsr-library-tools';
const String normalizerVersion = '0.2.0';

/// Schema version of the normalized book this tool writes.
const int normalizedBookSchemaVersion = 1;

class Chapter {
  const Chapter({required this.index, required this.title, required this.paragraphs});

  final int index;
  final String? title;
  final List<String> paragraphs;

  int get wordCount => paragraphs.fold<int>(0, (int n, String p) => n + countWords(p));

  Map<String, Object?> toJson() => <String, Object?>{
        'index': index,
        'title': title,
        'paragraphs': paragraphs,
      };

  static Chapter fromJson(Map<String, Object?> json) => Chapter(
        index: json['index'] as int,
        title: json['title'] as String?,
        paragraphs: (json['paragraphs'] as List<Object?>).cast<String>(),
      );
}

class Provenance {
  const Provenance({
    required this.provider,
    required this.url,
    required this.identifier,
    required this.revision,
    required this.pages,
    required this.retrievedAt,
  });

  final String provider;
  final String url;
  final String identifier;
  final String? revision;
  final List<({String title, int revision})> pages;
  final String retrievedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'provider': provider,
        'url': url,
        'identifier': identifier,
        'revision': revision,
        if (pages.isNotEmpty)
          'pages': <Object?>[
            for (final p in pages)
              <String, Object?>{'title': p.title, 'revision': p.revision},
          ],
        'retrievedAt': retrievedAt,
      };

  static Provenance fromJson(Map<String, Object?> json) => Provenance(
        provider: json['provider'] as String,
        url: json['url'] as String,
        identifier: json['identifier'] as String,
        revision: json['revision'] as String?,
        pages: ((json['pages'] as List<Object?>?) ?? const <Object?>[])
            .map((Object? e) {
          final Map<String, Object?> m = e as Map<String, Object?>;
          return (title: m['title'] as String, revision: m['revision'] as int);
        }).toList(),
        retrievedAt: json['retrievedAt'] as String,
      );
}

/// The canonical text of one edition. See schemas/normalized-book.schema.json.
class NormalizedBook {
  const NormalizedBook({
    this.schemaVersion = normalizedBookSchemaVersion,
    required this.workId,
    required this.editionId,
    required this.assetVersion,
    required this.language,
    required this.direction,
    required this.title,
    required this.author,
    required this.translator,
    required this.chapters,
    required this.provenance,
    required this.rightsStatement,
    this.normalizer = (name: normalizerName, version: normalizerVersion),
  });

  final int schemaVersion;
  final String workId;
  final String editionId;
  final int assetVersion;
  final String language;
  final String direction;
  final String title;
  final String author;
  final String? translator;
  final List<Chapter> chapters;
  final Provenance provenance;
  final String rightsStatement;
  final ({String name, String version}) normalizer;

  int get wordCount => chapters.fold<int>(0, (int n, Chapter c) => n + c.wordCount);

  Map<String, Object?> toJson() => <String, Object?>{
        'schemaVersion': schemaVersion,
        'workId': workId,
        'editionId': editionId,
        'assetVersion': assetVersion,
        'language': language,
        'direction': direction,
        'title': title,
        'author': author,
        'translator': translator,
        'chapters': chapters.map((Chapter c) => c.toJson()).toList(),
        'provenance': provenance.toJson(),
        'rights': <String, Object?>{
          'status': 'public-domain',
          'statement': rightsStatement,
        },
        'normalizer': <String, Object?>{
          'name': normalizer.name,
          'version': normalizer.version,
        },
      };

  /// Canonical bytes of the asset before compression.
  String toCanonicalJson() => canonicalJson(toJson());

  static NormalizedBook fromJson(Map<String, Object?> json) {
    final Map<String, Object?> normalizer =
        json['normalizer'] as Map<String, Object?>;
    return NormalizedBook(
      schemaVersion: json['schemaVersion'] as int,
      workId: json['workId'] as String,
      editionId: json['editionId'] as String,
      assetVersion: json['assetVersion'] as int,
      language: json['language'] as String,
      direction: json['direction'] as String,
      title: json['title'] as String,
      author: json['author'] as String,
      translator: json['translator'] as String?,
      chapters: (json['chapters'] as List<Object?>)
          .map((Object? c) => Chapter.fromJson(c as Map<String, Object?>))
          .toList(),
      provenance:
          Provenance.fromJson(json['provenance'] as Map<String, Object?>),
      rightsStatement:
          (json['rights'] as Map<String, Object?>)['statement'] as String,
      normalizer: (
        name: normalizer['name'] as String,
        version: normalizer['version'] as String
      ),
    );
  }

  /// The single plain-text rendering the speed reader consumes: chapter
  /// titles on their own line, paragraphs separated by blank lines.
  String toPlainText() {
    final StringBuffer out = StringBuffer();
    for (final Chapter c in chapters) {
      if (out.isNotEmpty) out.write('\n\n');
      final String? t = c.title;
      if (t != null && t.isNotEmpty) out.write('$t\n\n');
      out.write(c.paragraphs.join('\n\n'));
    }
    return out.toString();
  }
}

/// Structural rules the JSON schema cannot express. Returns human-readable
/// problems; an empty list means the book is sound.
List<String> validateBookStructure(NormalizedBook book) {
  final List<String> problems = <String>[];
  if (book.chapters.isEmpty) problems.add('book has no chapters');
  for (int i = 0; i < book.chapters.length; i++) {
    final Chapter c = book.chapters[i];
    if (c.index != i) {
      problems.add('chapter at position $i has index ${c.index}');
    }
    if (c.paragraphs.isEmpty) {
      problems.add('chapter $i has no paragraphs');
    }
    for (int j = 0; j < c.paragraphs.length; j++) {
      final String p = c.paragraphs[j];
      if (p.trim().isEmpty) problems.add('chapter $i paragraph $j is blank');
      if (p != normalizeParagraph(p)) {
        problems.add('chapter $i paragraph $j is not normalised');
      }
      if (p.contains('<') && RegExp(r'<[a-zA-Z/][^>]*>').hasMatch(p)) {
        problems.add('chapter $i paragraph $j contains markup');
      }
    }
  }
  if (book.wordCount == 0) problems.add('book has no words');
  if (book.title.trim().isEmpty) problems.add('title is empty');
  if (book.author.trim().isEmpty) problems.add('author is empty');
  if (book.direction != 'ltr' && book.direction != 'rtl') {
    problems.add('direction must be ltr or rtl');
  }
  return problems;
}

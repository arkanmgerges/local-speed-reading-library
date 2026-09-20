import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:lsr_library_tools/lsr_library_tools.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final CommandRunner<int> runner = CommandRunner<int>(
      'lsr', 'Local Speed Reading library tools: pin, build, validate, catalog, publish-check.')
    ..argParser.addOption('repo', help: 'Repository root (default: found from the working directory).')
    ..argParser.addOption('year', help: 'Current year for the rights policy (default: today).')
    ..addCommand(_PinCommand())
    ..addCommand(_BuildCommand())
    ..addCommand(_ValidateCommand())
    ..addCommand(_CatalogCommand())
    ..addCommand(_PublishCheckCommand())
    ..addCommand(_ShowCommand());
  try {
    exitCode = await runner.run(args) ?? 0;
  } on UsageException catch (e) {
    stderr.writeln(e);
    exitCode = 64;
  }
}

abstract class _LsrCommand extends Command<int> {
  LibraryRepo get repo => LibraryRepo.locate(globalResults?['repo'] as String?);

  RightsPolicy get policy {
    final String? y = globalResults?['year'] as String?;
    return RightsPolicy(currentYear: y == null ? DateTime.now().year : int.parse(y));
  }

  /// Editions named on the command line, or every edition with `--all`.
  List<BookMetadata> selectEditions(LibraryRepo repo, List<String> ids, bool all) {
    final List<BookMetadata> every = repo.metadataFiles().map(BookMetadata.read).toList();
    if (all) return every;
    if (ids.isEmpty) throw UsageException('name at least one editionId or pass --all', usage);
    final List<BookMetadata> out = <BookMetadata>[];
    for (final String id in ids) {
      final BookMetadata? m = every.where((BookMetadata m) => m.editionId == id).firstOrNull;
      if (m == null) throw UsageException('no metadata file for editionId "$id"', usage);
      out.add(m);
    }
    return out;
  }

  void writeMetadata(LibraryRepo repo, BookMetadata m) {
    final File f = File(repo.metadataFile(m.language, m.editionId));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(m.toCanonicalJson());
  }

  int report(List<Problem> problems) {
    for (final Problem pr in problems) {
      stdout.writeln(pr);
    }
    final int errors = problems.where((Problem pr) => pr.isError).length;
    stdout.writeln(errors == 0 ? 'OK: no errors' : 'FAILED: $errors error(s)');
    return errors == 0 ? 0 : 1;
  }
}

class _PinCommand extends _LsrCommand {
  _PinCommand() {
    argParser.addFlag('all', help: 'Pin every edition.');
  }
  @override
  String get name => 'pin';
  @override
  String get description => 'Record the current provider revision(s) of an edition in its metadata file.';

  @override
  Future<int> run() async {
    final LibraryRepo r = repo;
    final SourceImporter importer = SourceImporter(r);
    for (final BookMetadata m in selectEditions(r, argResults!.rest, argResults!['all'] as bool)) {
      final Map<String, Object?> source = await importer.pin(m);
      writeMetadata(r, m.withSection('source', source));
      stdout.writeln('pinned ${m.editionId}: revision ${source['revision']}'
          '${source['pages'] is List ? ' (${(source['pages'] as List).length} page(s))' : ''}');
    }
    return 0;
  }
}

class _BuildCommand extends _LsrCommand {
  _BuildCommand() {
    argParser
      ..addFlag('all', help: 'Build every publishable edition.')
      ..addFlag('offline', help: 'Use the snapshot under build/sources; never fetch.')
      ..addFlag('check', help: 'Fail instead of updating metadata when the asset block would change.')
      ..addFlag('allow-rewrite',
          help: 'Accept changed content for the current version. Only for versions that were never uploaded; publish-check refuses to overwrite a CDN copy.');
  }
  @override
  String get name => 'build';
  @override
  String get description => 'Fetch (pinned), normalise, package and record the asset of an edition.';

  @override
  Future<int> run() async {
    final LibraryRepo r = repo;
    final LanguageRegistry languages = LanguageRegistry.load(r.languagesRegistryFile);
    final Schemas schemas = Schemas.load(r);
    final SourceImporter importer = SourceImporter(r);
    final bool check = argResults!['check'] as bool;
    int failures = 0;
    for (final BookMetadata m in selectEditions(r, argResults!.rest, argResults!['all'] as bool)) {
      final RightsVerdict verdict = policy.evaluate(m);
      if (!verdict.publishable) {
        stdout.writeln('skip ${m.editionId}: ${verdict.reasons.join('; ')}');
        continue;
      }
      try {
        final ImportedSource src = await importer.import(m, offline: argResults!['offline'] as bool);
        final NormalizedBook book = normalizeBook(m, src, languages);
        final List<String> errors = schemaErrors(schemas.normalizedBook, book.toJson());
        if (errors.isNotEmpty) throw BuildException('${m.editionId}: normalized book fails its schema: ${errors.join('; ')}');
        final Map<String, Object?> fresh = writeAsset(r, m, book, builtAt: DateTime.now());
        final String? drift = assetDrift(m.asset, fresh);
        if (drift != null && !(argResults!['allow-rewrite'] as bool)) throw BuildException('${m.editionId}: $drift');
        final bool unchanged = m.asset != null &&
            m.asset!['assetVersion'] == fresh['assetVersion'] &&
            m.asset!['sha256'] == fresh['sha256'];
        final Map<String, Object?> source = <String, Object?>{...m.source, 'retrievedAt': src.provenance.retrievedAt};
        final bool sourceChanged = m.retrievedAt != src.provenance.retrievedAt;
        if (!unchanged || sourceChanged) {
          if (check) throw BuildException('${m.editionId}: asset block is not up to date (run `lsr build` and commit)');
          writeMetadata(r, m.withSection('asset', fresh).withSection('source', source));
        }
        stdout.writeln('built ${m.editionId}: v${fresh['assetVersion']} ${fresh['chapterCount']} chapters, '
            '${fresh['wordCount']} words, ${fresh['sizeBytes']} bytes gz (${fresh['uncompressedSizeBytes']} raw)'
            '${unchanged ? ' [unchanged]' : ''}');
      } catch (e) {
        failures++;
        stderr.writeln('FAILED ${m.editionId}: $e');
      }
    }
    return failures == 0 ? 0 : 1;
  }
}

class _ValidateCommand extends _LsrCommand {
  _ValidateCommand() {
    argParser.addFlag('catalog', defaultsTo: true, help: 'Also check the committed catalogue.');
  }
  @override
  String get name => 'validate';
  @override
  String get description => 'Validate metadata (schema, ids, languages, sources, rights policy, assets) and the catalogue.';

  @override
  Future<int> run() async {
    final LibraryRepo r = repo;
    final RepoValidator v = RepoValidator(r, policy: policy);
    final ({List<Problem> problems, List<BookMetadata> editions}) result = v.validateMetadata();
    final List<Problem> problems = <Problem>[...result.problems];
    if (argResults!['catalog'] as bool) problems.addAll(v.validateCatalog(result.editions));
    return report(problems);
  }
}

class _CatalogCommand extends _LsrCommand {
  _CatalogCommand() {
    argParser
      ..addFlag('check', help: 'Compare with the committed files instead of writing.')
      ..addOption('base-url', defaultsTo: defaultBaseUrl);
  }
  @override
  String get name => 'catalog';
  @override
  String get description => 'Generate catalog/catalog.json and catalog/languages/*.json from the metadata.';

  @override
  Future<int> run() async {
    final LibraryRepo r = repo;
    final RepoValidator v = RepoValidator(r, policy: policy);
    final ({List<Problem> problems, List<BookMetadata> editions}) result = v.validateMetadata();
    if (result.problems.any((Problem pr) => pr.isError)) return report(result.problems);
    final String baseUrl = argResults!['base-url'] as String;
    if (argResults!['check'] as bool) return report(v.validateCatalog(result.editions, baseUrl: baseUrl));
    final GeneratedCatalog generated = buildCatalog(result.editions, v.languages, policy: policy, baseUrl: baseUrl);
    final Directory langDir = Directory(r.languagesDir)..createSync(recursive: true);
    for (final File old in langDir.listSync().whereType<File>()) {
      if (!generated.files.containsKey('catalog/languages/${p.basename(old.path)}')) {
        old.deleteSync();
        stdout.writeln('removed stale ${p.basename(old.path)}');
      }
    }
    for (final MapEntry<String, String> e in generated.files.entries) {
      File(p.join(r.root, p.joinAll(e.key.split('/'))))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(e.value);
      stdout.writeln('wrote ${e.key}');
    }
    return 0;
  }
}

class _PublishCheckCommand extends _LsrCommand {
  _PublishCheckCommand() {
    argParser
      ..addOption('base-url', defaultsTo: defaultBaseUrl)
      ..addOption('plan', help: 'Write the list of assets to upload (JSON) to this file.');
  }
  @override
  String get name => 'publish-check';
  @override
  String get description => 'Compare local assets with the CDN: what is missing, what is identical, what must never be overwritten.';

  @override
  Future<int> run() async {
    final LibraryRepo r = repo;
    final RepoValidator v = RepoValidator(r, policy: policy);
    final ({List<Problem> problems, List<BookMetadata> editions}) result = v.validateMetadata();
    if (result.problems.any((Problem pr) => pr.isError)) return report(result.problems);
    final PublishCheck check = PublishCheck(baseUrl: argResults!['base-url'] as String);
    final List<AssetRemoteStatus> statuses = await check.checkAssets(result.editions, policy);
    for (final AssetRemoteStatus s in statuses) {
      stdout.writeln(s);
    }
    final String? plan = argResults!['plan'] as String?;
    if (plan != null) {
      File(plan).writeAsStringSync(canonicalJson(<String, Object?>{
        'baseUrl': check.baseUrl,
        'upload': <String>[
          for (final AssetRemoteStatus s in statuses)
            if (s.state == RemoteState.missing) s.path,
        ],
      }));
    }
    final bool conflict = statuses.any((AssetRemoteStatus s) => s.state == RemoteState.different);
    final bool unreachable = statuses.any((AssetRemoteStatus s) => s.state == RemoteState.unreachable);
    if (conflict) stderr.writeln('FAILED: an immutable asset differs from the CDN copy; bump its version instead');
    if (unreachable) stderr.writeln('FAILED: some assets could not be checked');
    return conflict || unreachable ? 1 : 0;
  }
}

class _ShowCommand extends _LsrCommand {
  @override
  String get name => 'show';
  @override
  String get description => 'Print the chapter outline of a built edition (from build/).';

  @override
  Future<int> run() async {
    final LibraryRepo r = repo;
    for (final BookMetadata m in selectEditions(r, argResults!.rest, false)) {
      final String? path = m.assetPathValue;
      if (path == null) {
        stderr.writeln('${m.editionId} is not built');
        continue;
      }
      final File json = File(localAssetFile(r, path).replaceFirst(RegExp(r'\.gz$'), ''));
      final NormalizedBook book = NormalizedBook.fromJson(jsonDecode(json.readAsStringSync()) as Map<String, Object?>);
      stdout.writeln('${book.title} — ${book.author} (${book.language}, ${book.wordCount} words)');
      for (final Chapter c in book.chapters) {
        final String first = c.paragraphs.first;
        stdout.writeln('  ${c.index.toString().padLeft(3)}. ${c.title ?? '(untitled)'}  [${c.paragraphs.length} ¶, ${c.wordCount} w]  '
            '${first.length > 70 ? '${first.substring(0, 70)}…' : first}');
      }
    }
    return 0;
  }
}

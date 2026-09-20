import 'dart:convert';
import 'dart:io';

import 'package:json_schema/json_schema.dart';
import 'package:lsr_library_tools/src/catalog_builder.dart';
import 'package:lsr_library_tools/src/ids.dart';
import 'package:lsr_library_tools/src/languages.dart';
import 'package:lsr_library_tools/src/metadata.dart';
import 'package:lsr_library_tools/src/normalized_book.dart';
import 'package:lsr_library_tools/src/providers/gutenberg.dart';
import 'package:lsr_library_tools/src/packaging.dart';
import 'package:lsr_library_tools/src/repo.dart';
import 'package:lsr_library_tools/src/rights_policy.dart';
import 'package:path/path.dart' as p;

enum Severity { error, warning, info }

class Problem {
  const Problem(this.severity, this.where, this.message);

  final Severity severity;
  final String where;
  final String message;

  bool get isError => severity == Severity.error;

  @override
  String toString() => '${severity.name.toUpperCase()} $where: $message';
}

/// Compiled schemas of this checkout.
class Schemas {
  Schemas._(this.bookMetadata, this.normalizedBook, this.languageManifest, this.catalog);

  static Schemas load(LibraryRepo repo) {
    JsonSchema read(String name) =>
        JsonSchema.create(json.decode(File(repo.schema(name)).readAsStringSync()));
    return Schemas._(
      read('book-metadata'),
      read('normalized-book'),
      read('language-manifest'),
      read('catalog'),
    );
  }

  final JsonSchema bookMetadata;
  final JsonSchema normalizedBook;
  final JsonSchema languageManifest;
  final JsonSchema catalog;
}

List<String> schemaErrors(JsonSchema schema, Object? instance) {
  final ValidationResults r = schema.validate(instance);
  return r.errors.map((ValidationError e) => '${e.instancePath}: ${e.message}').toList();
}

const Set<String> _providerHosts = <String>{
  'wikisource.org',
  'gutenberg.org',
  'europeana.eu',
};

/// All static checks over `metadata/` and, when [catalogFiles] is given,
/// over the committed catalogue. Errors block publishing; warnings and
/// infos are reported only.
class RepoValidator {
  RepoValidator(this.repo, {required this.policy, Schemas? schemas, LanguageRegistry? languages})
      : schemas = schemas ?? Schemas.load(repo),
        languages = languages ?? LanguageRegistry.load(repo.languagesRegistryFile);

  final LibraryRepo repo;
  final RightsPolicy policy;
  final Schemas schemas;
  final LanguageRegistry languages;

  /// Validates every metadata file; returns the problems and the parsed
  /// editions that passed the schema (so later stages can use them).
  ({List<Problem> problems, List<BookMetadata> editions}) validateMetadata() {
    final List<Problem> problems = <Problem>[];
    final List<BookMetadata> editions = <BookMetadata>[];
    for (final File file in repo.metadataFiles()) {
      final String where = p.relative(file.path, from: repo.root).replaceAll('\\', '/');
      final Object? decoded;
      try {
        decoded = json.decode(file.readAsStringSync());
      } on FormatException catch (e) {
        problems.add(Problem(Severity.error, where, 'not valid JSON: ${e.message}'));
        continue;
      }
      if (decoded is! Map<String, Object?>) {
        problems.add(Problem(Severity.error, where, 'top level must be an object'));
        continue;
      }
      final int? version = decoded['schemaVersion'] as int?;
      if (version != 1) {
        problems.add(Problem(Severity.error, where, 'unsupported schemaVersion $version (this tool supports 1)'));
        continue;
      }
      final List<String> errors = schemaErrors(schemas.bookMetadata, decoded);
      if (errors.isNotEmpty) {
        for (final String e in errors) {
          problems.add(Problem(Severity.error, where, 'schema: $e'));
        }
        continue;
      }
      final BookMetadata m = BookMetadata(decoded);
      problems.addAll(validateEdition(m, where: where));
      editions.add(m);
    }
    problems.addAll(validateAcrossEditions(editions));
    return (problems: problems, editions: editions);
  }

  /// Checks on one schema-valid edition.
  List<Problem> validateEdition(BookMetadata m, {required String where}) {
    final List<Problem> out = <Problem>[];
    void error(String msg) => out.add(Problem(Severity.error, where, msg));
    void warn(String msg) => out.add(Problem(Severity.warning, where, msg));
    void info(String msg) => out.add(Problem(Severity.info, where, msg));

    // Identifiers.
    if (!isValidWorkId(m.workId)) error('work.workId "${m.workId}" is malformed');
    final ({String workId, String language, String slug})? parts = parseEditionId(m.editionId);
    if (parts == null) {
      error('edition.editionId "${m.editionId}" is malformed');
    } else {
      if (parts.workId != m.workId) {
        error('editionId starts with "${parts.workId}" but workId is "${m.workId}"');
      }
      if (parts.language != languagePathSegment(m.language)) {
        error('editionId language segment "${parts.language}" does not match edition.language "${m.language}"');
      }
    }
    final String expectedFile = 'metadata/${m.language}/${m.editionId}.json';
    if (where != expectedFile) error('file should be at $expectedFile');

    // Languages.
    for (final MapEntry<String, String> e in <String, String>{
      'edition.language': m.language,
      'work.originalLanguage': m.originalLanguage,
    }.entries) {
      if (!isWellFormedLanguageTag(e.value)) {
        error('${e.key} "${e.value}" is not a well-formed BCP 47 tag');
      } else if (e.key == 'edition.language' && !languages.contains(e.value)) {
        error('${e.key} "${e.value}" is not in sources/languages.json (the app cannot label it)');
      }
    }
    if (m.kind == 'original' && m.language.toLowerCase() != m.originalLanguage.toLowerCase()) {
      warn('kind is "original" but edition.language differs from work.originalLanguage');
    }
    if (m.kind == 'translation' && m.language.toLowerCase() == m.originalLanguage.toLowerCase()) {
      warn('kind is "translation" but edition.language equals work.originalLanguage');
    }

    // Source.
    final Uri? url = Uri.tryParse(m.sourceUrl);
    if (url == null || url.scheme != 'https' || url.host.isEmpty) {
      error('source.url must be an https URL');
    } else if (m.provider != 'other') {
      final bool hostOk = _providerHosts.any((String h) => url.host == h || url.host.endsWith('.$h'));
      final bool providerOk = url.host.contains(m.provider) || (m.provider == 'gutenberg' && url.host.endsWith('gutenberg.org'));
      if (!hostOk || !providerOk) {
        error('source.url host "${url.host}" does not belong to provider "${m.provider}"');
      }
    }
    if (m.provider == 'wikisource' && m.sourceFormat != 'html') {
      error('wikisource sources are imported as rendered html; set source.format to "html"');
    }
    if (m.provider == 'gutenberg') {
      if (!RegExp(r'^[0-9]+$').hasMatch(m.sourceIdentifier)) {
        error('gutenberg source.identifier must be the ebook number');
      }
      if (m.sourceFormat != 'epub') error('gutenberg sources are imported from the EPUB; set source.format to "epub"');
    }

    // Rights.
    final RightsVerdict verdict = policy.evaluate(m);
    if (m.rightsStatus == 'public-domain' && !verdict.publishable) {
      error('marked public-domain but fails the publishing policy: ${verdict.reasons.join('; ')} '
          '(set rights.status to "uncertain" until evidence is added)');
    } else if (m.rightsStatus != 'public-domain') {
      info('rights.status is "${m.rightsStatus}": kept out of the catalogue');
    }

    // Asset block.
    final Map<String, Object?>? asset = m.asset;
    if (asset != null) {
      final String expectedPath = assetPath(m.language, m.editionId, asset['assetVersion'] as int);
      if (asset['path'] != expectedPath) {
        error('asset.path "${asset['path']}" should be "$expectedPath"');
      }
      if (asset['assetVersion'] != m.publishAssetVersion) {
        warn('asset is version ${asset['assetVersion']} but publish.assetVersion is ${m.publishAssetVersion}: '
            'run `lsr build ${m.editionId}` (kept out of the catalogue until then)');
      }
      final File local = File(p.join(repo.buildDir, p.joinAll((asset['path'] as String).split('/'))));
      if (local.existsSync()) {
        final List<int> bytes = local.readAsBytesSync();
        try {
          final Map<String, Object?> decoded = verifyAsset(
            bytes,
            expectedSizeBytes: asset['sizeBytes'] as int,
            expectedSha256: asset['sha256'] as String,
            expectedContentSha256: asset['contentSha256'] as String,
          );
          for (final String e in schemaErrors(schemas.normalizedBook, decoded)) {
            error('build/${asset['path']}: schema: $e');
          }
          final NormalizedBook book = NormalizedBook.fromJson(decoded);
          for (final String e in validateBookStructure(book)) {
            error('build/${asset['path']}: $e');
          }
          if (book.editionId != m.editionId || book.assetVersion != asset['assetVersion']) {
            error('build/${asset['path']}: identifies itself as ${book.editionId} v${book.assetVersion}');
          }
          if (m.provider == 'gutenberg') {
            for (final Chapter c in book.chapters) {
              for (final String para in c.paragraphs) {
                if (gutenbergBoilerplate.hasMatch(para)) {
                  error('build/${asset['path']}: chapter ${c.index} still contains Gutenberg boilerplate: "${para.length > 60 ? para.substring(0, 60) : para}"');
                  break;
                }
              }
            }
          }
        } on AssetVerificationException catch (e) {
          error('build/${asset['path']} does not match its asset block: ${e.problem.name} (${e.detail})');
        }
      }
    } else if (verdict.publishable) {
      info('not built yet: run `lsr build ${m.editionId}`');
    }
    return out;
  }

  /// Uniqueness and consistency across files.
  List<Problem> validateAcrossEditions(List<BookMetadata> editions) {
    final List<Problem> out = <Problem>[];
    final Map<String, String> editionIds = <String, String>{};
    final Map<String, String> assetPaths = <String, String>{};
    final Map<String, BookMetadata> works = <String, BookMetadata>{};
    final Map<String, String> workLanguage = <String, String>{};
    for (final BookMetadata m in editions) {
      final String where = 'metadata/${m.language}/${m.editionId}.json';
      final String? dupEdition = editionIds[m.editionId];
      if (dupEdition != null) {
        out.add(Problem(Severity.error, where, 'duplicate editionId "${m.editionId}" (also in $dupEdition)'));
      }
      editionIds[m.editionId] = where;
      final String? path = m.assetPathValue;
      if (path != null) {
        final String? dupAsset = assetPaths[path];
        if (dupAsset != null) {
          out.add(Problem(Severity.error, where, 'duplicate asset path "$path" (also in $dupAsset)'));
        }
        assetPaths[path] = where;
      }
      final BookMetadata? first = works[m.workId];
      if (first == null) {
        works[m.workId] = m;
      } else if (first.originalTitle != m.originalTitle || first.authorName != m.authorName) {
        out.add(Problem(Severity.error, where,
            'workId "${m.workId}" is defined differently in metadata/${first.language}/${first.editionId}.json '
            '(originalTitle/author must match; use a different workId for a different work)'));
      }
      final String key = '${m.workId}|${m.language.toLowerCase()}';
      final String? dupWork = workLanguage[key];
      if (dupWork != null) {
        out.add(Problem(Severity.warning, where,
            'second edition of work "${m.workId}" in ${m.language} (also $dupWork); keep both only on purpose'));
      }
      workLanguage[key] = where;
    }
    return out;
  }

  /// The committed catalogue must equal a fresh generation and reference
  /// only current assets.
  List<Problem> validateCatalog(List<BookMetadata> editions, {String baseUrl = defaultBaseUrl}) {
    final List<Problem> out = <Problem>[];
    final GeneratedCatalog fresh = buildCatalog(editions, languages, policy: policy, baseUrl: baseUrl);
    final Map<String, BookMetadata> byEdition = <String, BookMetadata>{
      for (final BookMetadata m in editions) m.editionId: m,
    };
    for (final MapEntry<String, String> e in fresh.files.entries) {
      final File f = File(p.join(repo.root, p.joinAll(e.key.split('/'))));
      if (!f.existsSync()) {
        out.add(Problem(Severity.error, e.key, 'missing; run `lsr catalog`'));
      } else if (f.readAsStringSync().replaceAll('\r\n', '\n') != e.value) {
        out.add(Problem(Severity.error, e.key, 'out of date; run `lsr catalog`'));
      }
    }
    final Directory langDir = Directory(repo.languagesDir);
    if (langDir.existsSync()) {
      for (final File f in langDir.listSync().whereType<File>()) {
        final String rel = 'catalog/languages/${p.basename(f.path)}';
        if (!fresh.files.containsKey(rel)) {
          out.add(Problem(Severity.error, rel, 'stale manifest: no publishable edition in this language; delete it'));
        }
        final Object? decoded = json.decode(f.readAsStringSync());
        for (final String err in schemaErrors(schemas.languageManifest, decoded)) {
          out.add(Problem(Severity.error, rel, 'schema: $err'));
        }
        final List<Object?> books = ((decoded as Map<String, Object?>)['books'] as List<Object?>?) ?? const <Object?>[];
        for (final Object? b in books) {
          final Map<String, Object?> book = b as Map<String, Object?>;
          final Map<String, Object?> asset = book['asset'] as Map<String, Object?>;
          final BookMetadata? m = byEdition[book['editionId']];
          if (m == null) {
            out.add(Problem(Severity.error, rel, 'references edition "${book['editionId']}" that has no metadata file'));
          } else if (m.asset == null || m.asset!['path'] != asset['path'] || m.asset!['sha256'] != asset['sha256']) {
            out.add(Problem(Severity.error, rel, 'stale reference for "${book['editionId']}": asset ${asset['path']} is not the current build'));
          }
        }
      }
    }
    final File catalogFile = File(repo.catalogFile);
    if (catalogFile.existsSync()) {
      for (final String err in schemaErrors(schemas.catalog, json.decode(catalogFile.readAsStringSync()))) {
        out.add(Problem(Severity.error, 'catalog/catalog.json', 'schema: $err'));
      }
    }
    return out;
  }
}

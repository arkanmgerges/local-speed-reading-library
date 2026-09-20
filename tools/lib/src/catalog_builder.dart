import 'dart:convert';

import 'package:lsr_library_tools/src/canonical_json.dart';
import 'package:lsr_library_tools/src/languages.dart';
import 'package:lsr_library_tools/src/metadata.dart';
import 'package:lsr_library_tools/src/normalized_book.dart';
import 'package:lsr_library_tools/src/packaging.dart';
import 'package:lsr_library_tools/src/rights_policy.dart';

/// Production base URL; every relative path in the catalogue resolves
/// against it. Override with `--base-url` for staging.
const String defaultBaseUrl = 'https://books.localspeedreading.com/';

/// Generated catalogue files, as text, keyed by repository-relative path.
class GeneratedCatalog {
  const GeneratedCatalog(this.files);

  /// `catalog/catalog.json`, `catalog/languages/<lang>.json`, ...
  final Map<String, String> files;
}

/// Editions that may appear in production: public-domain per policy and
/// built at the requested version.
bool isPublishable(BookMetadata m, RightsPolicy policy) =>
    policy.evaluate(m).publishable &&
    m.asset != null &&
    m.assetVersion == m.publishAssetVersion;

/// Builds the manifests and the catalog from [editions]. Deterministic:
/// versions are content hashes, not timestamps, so `--check` can compare
/// bytes.
GeneratedCatalog buildCatalog(
  List<BookMetadata> editions,
  LanguageRegistry languages, {
  required RightsPolicy policy,
  String baseUrl = defaultBaseUrl,
}) {
  final Map<String, List<BookMetadata>> byLanguage = <String, List<BookMetadata>>{};
  for (final BookMetadata m in editions) {
    if (!isPublishable(m, policy)) continue;
    byLanguage.putIfAbsent(m.language, () => <BookMetadata>[]).add(m);
  }
  final Map<String, String> files = <String, String>{};
  final List<Map<String, Object?>> languageEntries = <Map<String, Object?>>[];
  final List<String> codes = byLanguage.keys.toList()..sort();
  for (final String code in codes) {
    final LanguageInfo? info = languages[code];
    if (info == null) throw StateError('language $code is not in sources/languages.json');
    final List<BookMetadata> books = byLanguage[code]!
      ..sort((BookMetadata a, BookMetadata b) => a.editionId.compareTo(b.editionId));
    final Map<String, Object?> manifestBody = <String, Object?>{
      'schemaVersion': 1,
      'language': code,
      'englishName': info.englishName,
      'nativeName': info.nativeName,
      'direction': info.direction,
      'books': books.map(_bookEntry).toList(),
    };
    final String manifestVersion = _shortHash(compactJson(manifestBody));
    final String manifestText = canonicalJson(<String, Object?>{
      ...manifestBody,
      'manifestVersion': manifestVersion,
    });
    final String manifestPath = 'catalog/languages/$code.json';
    files[manifestPath] = manifestText;
    languageEntries.add(<String, Object?>{
      'language': code,
      'englishName': info.englishName,
      'nativeName': info.nativeName,
      'direction': info.direction,
      'bookCount': books.length,
      'manifest': manifestPath,
      'manifestVersion': manifestVersion,
      'manifestSha256': sha256Hex(utf8.encode(manifestText)),
    });
  }
  final Map<String, Object?> catalogBody = <String, Object?>{
    'schemaVersion': 1,
    'generatedBy': '$normalizerName $normalizerVersion',
    'assets': <String, Object?>{'baseUrl': baseUrl},
    'languages': languageEntries,
  };
  files['catalog/catalog.json'] = canonicalJson(<String, Object?>{
    ...catalogBody,
    'catalogVersion': _shortHash(compactJson(catalogBody)),
  });
  return GeneratedCatalog(files);
}

Map<String, Object?> _bookEntry(BookMetadata m) {
  final Map<String, Object?> asset = m.asset!;
  return <String, Object?>{
    'workId': m.workId,
    'editionId': m.editionId,
    'language': m.language,
    'title': m.title,
    'originalTitle': m.originalTitle,
    'originalLanguage': m.originalLanguage,
    'author': m.authorName,
    'authorDeathYear': m.authorDeathYear,
    'translator': m.translatorName,
    'translatorDeathYear': m.translatorDeathYear,
    'kind': m.kind,
    'originalPublicationYear': m.originalPublicationYear,
    'editionPublicationYear': m.editionPublicationYear,
    'translationPublicationYear': m.translationPublicationYear,
    'genres': m.genres,
    'rights': <String, Object?>{
      'status': m.rightsStatus,
      'statement': m.rightsStatement,
      'verifiedAt': m.rightsVerifiedAt,
    },
    'source': <String, Object?>{
      'provider': m.provider,
      'url': m.sourceUrl,
      'identifier': m.sourceIdentifier,
      'revision': m.sourceRevision,
      'retrievedAt': m.retrievedAt,
    },
    'asset': <String, Object?>{
      'assetVersion': asset['assetVersion'],
      'path': asset['path'],
      'sizeBytes': asset['sizeBytes'],
      'sha256': asset['sha256'],
      'uncompressedSizeBytes': asset['uncompressedSizeBytes'],
      'contentSha256': asset['contentSha256'],
      'wordCount': asset['wordCount'],
      'chapterCount': asset['chapterCount'],
      'schemaVersion': normalizedBookSchemaVersion,
      'encoding': 'gzip',
    },
  };
}

String _shortHash(String text) => sha256Hex(utf8.encode(text)).substring(0, 16);

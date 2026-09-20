import 'dart:io';

import 'package:lsr_library_tools/src/html_sections.dart';
import 'package:lsr_library_tools/src/ids.dart';
import 'package:lsr_library_tools/src/importer.dart';
import 'package:lsr_library_tools/src/languages.dart';
import 'package:lsr_library_tools/src/metadata.dart';
import 'package:lsr_library_tools/src/normalized_book.dart';
import 'package:lsr_library_tools/src/packaging.dart';
import 'package:lsr_library_tools/src/providers/gutenberg.dart';
import 'package:lsr_library_tools/src/repo.dart';
import 'package:lsr_library_tools/src/text_normalize.dart';
import 'package:path/path.dart' as p;

class BuildException implements Exception {
  const BuildException(this.message);
  final String message;
  @override
  String toString() => 'BuildException: $message';
}

/// Paragraph patterns dropped for [m] on top of the per-edition list:
/// Gutenberg licence/trademark text, transcriber remarks and the
/// title-page "by &lt;author&gt;" line.
List<RegExp> dropPatternsFor(BookMetadata m) => <RegExp>[
      if (m.provider == 'gutenberg') ...<RegExp>[
        gutenbergBoilerplate,
        gutenbergTranscriberNotes,
        RegExp('^by ${RegExp.escape(m.authorName)}[.]?\$', caseSensitive: false),
      ],
      for (final String pattern in m.dropParagraphsMatching) RegExp(pattern, unicode: true),
    ];

/// Turns fetched sections into a [NormalizedBook] for [m] at
/// `publish.assetVersion`. Pure: no I/O, so tests can feed it sections.
NormalizedBook normalizeBook(BookMetadata m, ImportedSource src, LanguageRegistry languages) {
  final List<RawSection> merged = mergeSections(
    src.sections,
    skipHeadings: m.skipHeadings,
    title: m.title,
    author: m.authorName,
  );
  final List<RegExp> drop = dropPatternsFor(m);
  final List<Chapter> chapters = <Chapter>[];
  for (final RawSection s in merged) {
    final List<String> paragraphs = s.paragraphs
        .map(normalizeParagraph)
        .where((String t) => t.isNotEmpty && !drop.any((RegExp r) => r.hasMatch(t)))
        .toList();
    if (paragraphs.isEmpty) continue;
    final String? title = s.heading == null ? null : normalizeParagraph(s.heading!);
    chapters.add(Chapter(index: chapters.length, title: title, paragraphs: paragraphs));
  }
  if (chapters.isEmpty) {
    throw BuildException('${m.editionId}: no text left after normalisation');
  }
  final LanguageInfo? lang = languages[m.language];
  final NormalizedBook book = NormalizedBook(
    workId: m.workId,
    editionId: m.editionId,
    assetVersion: m.publishAssetVersion,
    language: m.language,
    direction: lang?.direction ?? 'ltr',
    title: m.title,
    author: m.authorName,
    translator: m.translatorName,
    chapters: chapters,
    provenance: src.provenance,
    rightsStatement: m.rightsStatement,
  );
  final List<String> problems = validateBookStructure(book);
  if (problems.isNotEmpty) {
    throw BuildException('${m.editionId}: ${problems.join('; ')}');
  }
  return book;
}

/// Where a built asset lives locally (mirrors the R2 key).
String localAssetFile(LibraryRepo repo, String assetPath) =>
    p.join(repo.buildDir, p.joinAll(assetPath.split('/')));

/// Packages [book], writes `build/<assetPath>` (+ the readable `.json`
/// next to it) and returns the `asset` block for the metadata file.
Map<String, Object?> writeAsset(LibraryRepo repo, BookMetadata m, NormalizedBook book, {required DateTime builtAt}) {
  final String path = assetPath(m.language, m.editionId, book.assetVersion);
  final PackagedAsset packaged = packageJson(book.toCanonicalJson());
  final File gz = File(localAssetFile(repo, path))..parent.createSync(recursive: true);
  gz.writeAsBytesSync(packaged.gzipBytes);
  File(gz.path.substring(0, gz.path.length - 3)).writeAsBytesSync(packaged.jsonBytes);
  return <String, Object?>{
    'assetVersion': book.assetVersion,
    'path': path,
    'sizeBytes': packaged.sizeBytes,
    'sha256': packaged.sha256,
    'uncompressedSizeBytes': packaged.uncompressedSizeBytes,
    'contentSha256': packaged.contentSha256,
    'wordCount': book.wordCount,
    'chapterCount': book.chapters.length,
    'normalizerVersion': normalizerVersion,
    'builtAt': builtAt.toUtc().toIso8601String(),
  };
}

/// The already-recorded asset block, compared with a fresh build: the
/// content hash and version must match for an existing version, otherwise
/// the source drifted and `publish.assetVersion` has to be bumped.
String? assetDrift(Map<String, Object?>? recorded, Map<String, Object?> fresh) {
  if (recorded == null) return null;
  if (recorded['assetVersion'] != fresh['assetVersion']) return null;
  if (recorded['contentSha256'] != fresh['contentSha256']) {
    return 'content changed for version ${fresh['assetVersion']} (contentSha256 ${recorded['contentSha256']} -> ${fresh['contentSha256']}); bump publish.assetVersion';
  }
  if (recorded['sha256'] != fresh['sha256']) {
    return 'compressed bytes differ for identical content (sha256 ${recorded['sha256']} -> ${fresh['sha256']}); the packaging is not deterministic';
  }
  return null;
}

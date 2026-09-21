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
/// Page-number markers left by proofread transcriptions: `[s. 3]`,
/// `[Page 12`, `[ 45 ]`, `p. 7`.
final RegExp pageMarker = RegExp(
    r'^\[?\s*(s\.|p\.|pp\.|pag\.|page|pagina|pág\.|стр\.|стор\.|seite|bl\.|sivu)?\s*[0-9ivxlcdm]{1,6}\s*\]?$',
    caseSensitive: false,
    unicode: true);

/// Licence boxes that some Wikisources render inside the text: a short
/// paragraph naming the public domain together with rights vocabulary.
final RegExp licenceNotice = RegExp(
    r'(domeniul public|public domain|domaine public|dominio p[úu]blico|pubblico dominio|gemeinfrei|publiek domein|'
    r'общественном достоянии|суспільним надбанням|domínio público|domini públic|domena publiczna|volné dílo|'
    r'közkincs|julkista omaisuutta|offentlig ejendom|allmän egendom|δημόσιο τομέα|パブリックドメイン|公有领域|公共領域)',
    caseSensitive: false,
    unicode: true);
final RegExp licenceContext = RegExp(
    r'(author|autor|auteur|autore|copyright|drept|diritt|droit|recht|©|died|decedat|morto|mort|starb|years|\bani\b|anni|\bans\b|jahre|'
    r'умер|помер|expir|licen|wikisource|creative commons|cc-by)',
    caseSensitive: false,
    unicode: true);

bool isLicenceNotice(String paragraph) =>
    licenceNotice.hasMatch(paragraph) && licenceContext.hasMatch(paragraph) && countWords(paragraph) < 120;

List<RegExp> dropPatternsFor(BookMetadata m) => <RegExp>[
      if (m.provider == 'wikisource') pageMarker,
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
  // The main page of a multi-page Wikisource work is a title page with a
  // table of contents and illustration captions; its short sections are not
  // chapters. (A long section there is real text: some works put the first
  // chapter on the main page.)
  final Set<RawSection> mainPage = <RawSection>{
    for (int i = 0; i < src.mainPageSectionCount && i < src.sections.length; i++) src.sections[i],
  };
  for (final RawSection s in merged) {
    if (mainPage.contains(s) && countWords(s.paragraphs.join(' ')) < 400) continue;
    final List<String> paragraphs = s.paragraphs
        .map(normalizeParagraph)
        .where((String t) => t.isNotEmpty && !drop.any((RegExp r) => r.hasMatch(t)))
        .where((String t) => m.provider != 'wikisource' || !isLicenceNotice(t))
        .toList();
    if (paragraphs.isEmpty) continue;
    final String? title = s.heading == null ? null : normalizeParagraph(s.heading!);
    chapters.add(Chapter(index: chapters.length, title: title, paragraphs: paragraphs));
  }
  // On Wikisource, tables of contents, navigation crumbs and page markers
  // come through as headings with a few words under them; in a book with
  // real chapters they are dropped. (EPUB chapters are trusted: reference
  // books have legitimately short ones.)
  if (m.provider == 'wikisource' &&
      chapters.length > 3 &&
      chapters.fold<int>(0, (int n, Chapter c) => n + c.wordCount) > 2000) {
    final List<Chapter> kept = chapters.where((Chapter c) => c.wordCount >= 40).toList();
    chapters
      ..clear()
      ..addAll(<Chapter>[
        for (int i = 0; i < kept.length; i++) Chapter(index: i, title: kept[i].title, paragraphs: kept[i].paragraphs),
      ]);
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

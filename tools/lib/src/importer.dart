import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:lsr_library_tools/src/epub_reader.dart';
import 'package:lsr_library_tools/src/html_sections.dart';
import 'package:lsr_library_tools/src/metadata.dart';
import 'package:lsr_library_tools/src/normalized_book.dart';
import 'package:lsr_library_tools/src/providers/fetch.dart';
import 'package:lsr_library_tools/src/providers/gutenberg.dart';
import 'package:lsr_library_tools/src/providers/wikisource.dart';
import 'package:lsr_library_tools/src/repo.dart';
import 'package:path/path.dart' as p;

/// A Wikisource work with more subpages than this is a multi-volume
/// compendium (dictionaries, chronicles, hadith collections) rather than a
/// book someone reads end to end; fetching it would also take hours.
const int maxWikisourcePages = 160;

/// Text fetched from a provider for one edition, before it becomes a book.
class ImportedSource {
  const ImportedSource({
    required this.sections,
    required this.provenance,
    this.title,
    this.author,
    this.language,
    this.mainPageSectionCount = 0,
  });

  final List<RawSection> sections;
  final Provenance provenance;
  final String? title;
  final String? author;
  final String? language;

  /// How many leading [sections] come from the main page of a multi-page
  /// Wikisource work (a title page or table of contents, usually); zero for
  /// single-page and EPUB sources.
  final int mainPageSectionCount;
}

/// Fetches the pinned source of an edition and keeps a raw copy under
/// `build/sources/<editionId>/` so a build can be repeated offline
/// (`--offline`) and a reviewer can diff what the provider served.
class SourceImporter {
  SourceImporter(this.repo, {http.Client? client, DateTime Function()? now})
      : _client = client ?? http.Client(),
        _now = now ?? DateTime.now;

  final LibraryRepo repo;
  final http.Client _client;
  final DateTime Function() _now;

  String snapshotDir(BookMetadata m) => p.join(repo.buildSourcesDir, m.editionId);

  Future<ImportedSource> import(BookMetadata m, {bool offline = false}) {
    switch (m.provider) {
      case 'wikisource':
        return _importWikisource(m, offline: offline);
      case 'gutenberg':
        return _importGutenberg(m, offline: offline);
      default:
        throw UnsupportedError('provider "${m.provider}" has no importer yet');
    }
  }

  /// Resolves the current provider revision(s) for [m] and returns the
  /// `source` block to write back (`lsr pin`).
  Future<Map<String, Object?>> pin(BookMetadata m) async {
    final Map<String, Object?> source = Map<String, Object?>.of(m.source);
    switch (m.provider) {
      case 'wikisource':
        final WikisourceClient ws = WikisourceClient(_site(m), client: _client);
        final ({String html, int revid, String title}) main = await ws.parse(m.sourceIdentifier);
        final List<String> explicit = m.sourcePageTitles;
        final List<String> titles = explicit.isNotEmpty
            ? explicit
            : <String>[m.sourceIdentifier, ...WikisourceClient.discoverSubpages(main.html, m.sourceIdentifier)];
        final Map<String, int> revs = await ws.latestRevisions(titles);
        final List<Map<String, Object?>> pages = <Map<String, Object?>>[];
        for (final String t in titles) {
          final int? rev = revs[t];
          if (rev == null) throw FetchException('page "$t" does not exist on ${_site(m)}');
          pages.add(<String, Object?>{'title': t, 'revision': rev});
        }
        source['site'] = _site(m);
        source['revision'] = '${main.revid}';
        source['pages'] = pages;
      case 'gutenberg':
        final String? lm = await GutenbergClient(client: _client).lastModified(m.sourceIdentifier);
        if (lm != null) source['revision'] = lm;
      default:
        throw UnsupportedError('provider "${m.provider}" cannot be pinned');
    }
    return source;
  }

  String _site(BookMetadata m) {
    final String? site = m.sourceSite;
    if (site != null && site.isNotEmpty) return site;
    return Uri.parse(m.sourceUrl).host;
  }

  Future<ImportedSource> _importWikisource(BookMetadata m, {required bool offline}) async {
    final List<({String title, int revision})> pages = m.sourcePages;
    if (pages.isEmpty) {
      throw StateError('${m.editionId}: source.pages is empty; run `lsr pin ${m.editionId}` first');
    }
    if (pages.length > maxWikisourcePages) {
      throw StateError('${m.editionId}: ${pages.length} pages; more than $maxWikisourcePages is a multi-volume '
          'compendium, not one download (set source.pages by hand to import a part)');
    }
    final WikisourceClient ws = WikisourceClient(_site(m), client: _client);
    final Directory dir = Directory(snapshotDir(m))..createSync(recursive: true);
    final List<RawSection> sections = <RawSection>[];
    int mainPageSections = 0;
    for (int i = 0; i < pages.length; i++) {
      final ({String title, int revision}) page = pages[i];
      final File snap = File(p.join(dir.path, 'page-${i.toString().padLeft(3, '0')}-${page.revision}.html'));
      String html;
      if (snap.existsSync()) {
        html = snap.readAsStringSync();
      } else {
        if (offline) throw StateError('offline build but ${snap.path} is missing');
        html = (await ws.parse(page.title, oldid: page.revision)).html;
        snap.writeAsStringSync(html);
      }
      final String? subtitle = i == 0 ? m.firstChapterTitle : _subpageTitle(page.title, m.sourceIdentifier);
      sections.addAll(sectionsFromHtml(
        html,
        removeSelectors: m.removeSelectors,
        headingLevels: m.chapterHeadingLevels,
        initialHeading: subtitle,
      ));
      if (i == 0) mainPageSections = sections.length;
    }
    return ImportedSource(
      sections: sections,
      mainPageSectionCount: pages.length > 1 ? mainPageSections : 0,
      provenance: Provenance(
        provider: 'wikisource',
        url: m.sourceUrl,
        identifier: m.sourceIdentifier,
        revision: m.sourceRevision,
        pages: pages,
        retrievedAt: _retrievedAt(dir, m.retrievedAt),
      ),
    );
  }

  Future<ImportedSource> _importGutenberg(BookMetadata m, {required bool offline}) async {
    final Directory dir = Directory(snapshotDir(m))..createSync(recursive: true);
    final File snap = File(p.join(dir.path, 'pg${m.sourceIdentifier}.epub'));
    final File meta = File(p.join(dir.path, 'fetch.json'));
    Uint8List bytes;
    String? lastModified;
    if (snap.existsSync()) {
      bytes = snap.readAsBytesSync();
      if (meta.existsSync()) {
        lastModified = (jsonDecode(meta.readAsStringSync()) as Map<String, Object?>)['lastModified'] as String?;
      }
    } else {
      if (offline) throw StateError('offline build but ${snap.path} is missing');
      final GutenbergClient pg = GutenbergClient(client: _client);
      final ({Uint8List bytes, String? lastModified, Uri finalUrl}) r = await pg.fetchEpub(m.sourceIdentifier);
      bytes = r.bytes;
      lastModified = r.lastModified;
      snap.writeAsBytesSync(bytes);
      meta.writeAsStringSync(jsonEncode(<String, Object?>{
        'lastModified': lastModified,
        'finalUrl': r.finalUrl.toString(),
        'retrievedAt': _now().toUtc().toIso8601String(),
      }));
    }
    final String? pinned = m.sourceRevision;
    if (pinned != null && lastModified != null && pinned != lastModified) {
      throw StateError('${m.editionId}: Gutenberg file changed (Last-Modified "$lastModified", pinned "$pinned"); '
          'run `lsr pin` and bump publish.assetVersion if the text differs');
    }
    final EpubContent epub = readEpub(bytes,
        removeSelectors: m.removeSelectors,
        headingLevels: m.chapterHeadingLevels,
        skipHeadings: m.skipHeadings);
    return ImportedSource(
      sections: epub.sections,
      title: epub.title,
      author: epub.author,
      language: epub.language,
      provenance: Provenance(
        provider: 'gutenberg',
        url: m.sourceUrl,
        identifier: m.sourceIdentifier,
        revision: pinned ?? lastModified,
        pages: const [],
        retrievedAt: _retrievedAt(dir, m.retrievedAt),
      ),
    );
  }

  /// Retrieval time of the pinned source. It is part of the asset's
  /// provenance, so it must be stable: the value recorded in the metadata
  /// file wins (CI rebuilds reproduce the same bytes), then the snapshot
  /// stamp, and only a first-ever fetch uses the clock.
  String _retrievedAt(Directory dir, String? pinned) {
    if (pinned != null && pinned.isNotEmpty) return pinned;
    final File stamp = File(p.join(dir.path, 'retrieved-at.txt'));
    if (stamp.existsSync()) return stamp.readAsStringSync().trim();
    final String now = _now().toUtc().toIso8601String();
    stamp.writeAsStringSync('$now\n');
    return now;
  }

  /// The chapter title a subpage contributes: what follows the work's title,
  /// or the last path segment when the pages hang off a different prefix
  /// (an index page named after the author, say).
  static String? _subpageTitle(String pageTitle, String mainTitle) {
    final String rest = pageTitle.startsWith('$mainTitle/')
        ? pageTitle.substring(mainTitle.length + 1).trim()
        : pageTitle.substring(pageTitle.lastIndexOf('/') + 1).trim();
    return rest.isEmpty || rest == pageTitle ? null : rest;
  }
}

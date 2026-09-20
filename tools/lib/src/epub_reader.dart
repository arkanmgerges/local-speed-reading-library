import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:lsr_library_tools/src/html_sections.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

/// What an EPUB contributes: Dublin Core metadata and the spine documents
/// in reading order, already split into sections.
class EpubContent {
  const EpubContent({
    required this.title,
    required this.author,
    required this.language,
    required this.sections,
    required this.spineCount,
  });

  final String title;
  final String author;
  final String? language;
  final List<RawSection> sections;
  final int spineCount;
}

class EpubFormatException implements Exception {
  const EpubFormatException(this.message);
  final String message;
  @override
  String toString() => 'EpubFormatException: $message';
}

/// Reads an EPUB 2/3 container: `META-INF/container.xml` -> OPF ->
/// manifest + spine -> each XHTML document through [sectionsFromHtml].
EpubContent readEpub(
  Uint8List bytes, {
  List<String> removeSelectors = const <String>[],
  List<int> headingLevels = const <int>[1, 2, 3],
  List<String> skipHeadings = const <String>[],
}) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes, verify: false);
  } catch (e) {
    throw EpubFormatException('not a zip archive: $e');
  }
  final Map<String, ArchiveFile> entries = <String, ArchiveFile>{
    for (final ArchiveFile f in archive.files)
      if (f.isFile) _norm(f.name): f,
  };
  String? readText(String path) {
    final ArchiveFile? f = entries[_norm(path)];
    if (f == null) return null;
    return utf8.decode(f.readBytes()!, allowMalformed: true);
  }

  final String? container = readText('META-INF/container.xml');
  if (container == null) throw const EpubFormatException('missing META-INF/container.xml');
  String? opfPath;
  try {
    for (final XmlElement rootfile
        in XmlDocument.parse(container).findAllElements('rootfile')) {
      final String? full = rootfile.getAttribute('full-path');
      if (full != null && full.isNotEmpty) {
        opfPath = full;
        break;
      }
    }
  } on XmlException catch (e) {
    throw EpubFormatException('container.xml is not XML: $e');
  }
  if (opfPath == null) throw const EpubFormatException('container.xml names no rootfile');
  final String? opfText = readText(opfPath);
  if (opfText == null) throw EpubFormatException('OPF $opfPath missing');
  final XmlDocument opf;
  try {
    opf = XmlDocument.parse(opfText);
  } on XmlException catch (e) {
    throw EpubFormatException('OPF is not XML: $e');
  }
  final String opfDir = p.posix.dirname(_norm(opfPath));

  String dc(String name) {
    for (final XmlElement e in opf.findAllElements(name, namespaceUri: '*')) {
      final String t = e.innerText.trim();
      if (t.isNotEmpty) return t;
    }
    return '';
  }

  final Map<String, ({String href, String type})> manifest = <String, ({String href, String type})>{};
  for (final XmlElement item in opf.findAllElements('item', namespaceUri: '*')) {
    final String? id = item.getAttribute('id');
    final String? href = item.getAttribute('href');
    if (id == null || href == null) continue;
    manifest[id] = (href: href, type: item.getAttribute('media-type') ?? '');
  }
  final List<List<RawSection>> documents = <List<RawSection>>[];
  int spineCount = 0;
  for (final XmlElement ref in opf.findAllElements('itemref', namespaceUri: '*')) {
    final String? idref = ref.getAttribute('idref');
    final ({String href, String type})? item = idref == null ? null : manifest[idref];
    if (item == null) continue;
    if (!item.type.contains('html') && !item.type.contains('xml')) continue;
    final String path = opfDir == '.' ? item.href : p.posix.join(opfDir, item.href);
    final String? html = readText(Uri.decodeComponent(path));
    if (html == null) continue;
    spineCount++;
    documents.add(sectionsFromHtml(html,
        removeSelectors: removeSelectors, headingLevels: headingLevels, fallbackHeadings: false));
  }
  final String lang = dc('language');
  return EpubContent(
    title: dc('title'),
    author: dc('creator'),
    language: lang.isEmpty ? null : lang,
    sections: joinDocuments(documents, skipHeadings: skipHeadings),
    spineCount: spineCount,
  );
}

String _norm(String path) =>
    p.posix.normalize(path.replaceAll('\\', '/')).replaceFirst(RegExp(r'^\./'), '');

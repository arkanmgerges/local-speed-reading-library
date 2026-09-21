import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:lsr_library_tools/src/text_normalize.dart';

/// Elements never carrying book text, plus the navigation/boilerplate
/// blocks of the two pilot providers. Per-edition `import.removeSelectors`
/// are added on top.
const List<String> defaultRemoveSelectors = <String>[
  'script', 'style', 'nav', 'noscript', 'template', 'head', 'img', 'svg',
  // Wikisource
  '.ws-noexport', '.noprint', '.mw-editsection', '#toc', '.toc',
  '.references', '.mw-references-wrap', 'sup.reference', '.mw-cite-backlink',
  '.ws-header', '.wst-header', '#headertemplate', '.headertemplate',
  '.navbox', '.mw-empty-elt', '.thumb', 'figure', '.ws-summary',
  '.mw-indicators', '.catlinks', '.printfooter', '.ws-pagenum', '.pagenum',
  '.wst-tpl-pagenum', '.pagenum-inner', '.pagenumber', '.wst-page-number',
  'a.prp-pagequality-0', 'a.prp-pagequality-1', 'a.prp-pagequality-2',
  'a.prp-pagequality-3', 'a.prp-pagequality-4', '.prp-page-qualityheader',
  '.wst-header-mainblock', '.wst-header-notes', '.wst-header-forward',
  '.wst-header-backward', '.wst-header-title', '.header_notes', '#header_notes',
  '.licenseContainer', '.licensetpl', '.licence', '.license', '.licensetable',
  '.reunahuomautus-paikka', '.reunahuomautus-vasen', '.reunahuomautus-oikea',
  '.sidenote', '.sidenotes', '.marginnote', '.authority-control', '.gallery',
  '.wst-sidenote-left', '.wst-sidenote-right', '.mw-halign-center img',
  // Project Gutenberg EPUBs
  '#pg-header', '#pg-footer', '#pg-machine-header', '.pg-boilerplate',
  '#pg-start-separator', '#pg-end-separator', '#project-gutenberg-license',
  '.trnote', '.transnote', '.x-ebookmaker-pageno', '.pgmonospaced',
  '.figcenter', '.figleft', '.figright', '.fig', '.caption', '.illus',
  '.footnote', '.footnotes', '.fnanchor',
];

/// Headings (compared case-insensitively after trimming) whose whole
/// section is dropped: tables of contents, reference lists, transcriber
/// notes. Per-edition `import.skipHeadings` are added on top.
/// Class-name fragments of Wikisource header/licence/navigation templates,
/// matched case-insensitively as substrings of an element's class list.
const List<String> defaultRemoveClassSubstrings = <String>[
  'headertemplate', 'header_notes', 'wst-header', 'otsikkomalline', 'encabezado', 'intestazione',
  'cabeçalho', 'cabecalho', 'cabecera', 'nagłówek', 'naglowek', 'zaglavlje', 'hlavička', 'hlavicka',
  'fejléc', 'fejlec', 'titelbalk', 'en-tete', 'entete', 'kopfzeile', 'заголовок', 'шапка',
  'licensecontainer', 'licensetpl', 'licence-box', 'license-box', 'licensetable', 'pd-box',
  'ws-noexport', 'noprint', 'pagenum', 'reunahuomautus', 'sidenote', 'marginnote', 'navigation-box',
  'navbox', 'wst-nav', 'authority-control', 'ws-summary', 'ws-header', 'ws-license', 'ws-licence',
];

const List<String> defaultSkipHeadings = <String>[
  'contents', 'table of contents', 'cuprins', 'index',
  'sisällys', 'sisällys:', 'sisältö', 'innehåll', 'indhold', 'innhold', 'inhalt', 'inhoud',
  'sommaire', 'table des matières', 'índice', 'indice', 'índex', 'содержание', 'оглавление',
  'зміст', 'змест', 'съдържание', 'sadržaj', 'kazalo', 'spis treści', 'spis rzeczy', 'obsah',
  'tartalom', 'tartalomjegyzék', 'περιεχόμενα', 'sisukord', 'saturs', 'turinys', 'içindekiler',
  'فهرست', 'فهرس', 'תוכן', 'תוכן עניינים', 'सूची', 'অনুক্রমণিকা', 'সূচী', 'સૂચિ', 'അനുക്രമണിക',
  'अनुक्रमणिका', 'విషయసూచిక', '目次', '目录', '目錄', 'mục lục', 'daftar isi',
  'illustrations', 'list of illustrations',
  'note', 'notes', 'references', 'footnotes', 'referințe', 'referinţe',
  "transcriber's note", "transcriber's notes", 'transcriber’s note',
  'transcriber’s notes',
];

const Set<String> _blockTags = <String>{
  'p', 'div', 'blockquote', 'li', 'pre', 'dd', 'dt', 'dl',
  'section', 'article', 'main', 'body', 'html', 'ul', 'ol', 'table',
  'tbody', 'thead', 'tfoot', 'tr', 'center', 'aside', 'header', 'footer',
  'figcaption', 'hr', 'address', 'details', 'summary', 'poem',
};

final RegExp _headingTag = RegExp(r'^h([1-6])$');
final RegExp _footnoteMarker = RegExp(r'^\s*[\[(]?\s*(\d{1,3}|[a-z]|\*+|†+)\s*[\])]?\s*$');

/// A run of text under one heading, before it becomes a chapter.
class RawSection {
  RawSection({this.heading, this.level = 0});

  String? heading;
  final int level;
  final List<String> paragraphs = <String>[];

  bool get isEmpty => paragraphs.isEmpty;
}

/// Turns a rendered HTML document (Wikisource page, EPUB spine item) into
/// ordered sections: a new section starts at every heading whose level is
/// in [headingLevels]; block elements become paragraphs; `<br>` becomes a
/// line break inside a paragraph; table cells of a row are joined; lists
/// that are mostly links (tables of contents) and footnote markers are
/// dropped.
///
/// Documents without any heading (text-derived EPUBs) fall back to
/// [detectHeadingParagraphs] when [fallbackHeadings] is true.
List<RawSection> sectionsFromHtml(
  String html, {
  List<String> removeSelectors = const <String>[],
  List<int> headingLevels = const <int>[1, 2, 3],
  String? initialHeading,
  bool fallbackHeadings = true,
}) {
  final dom.Document doc = html_parser.parse(_expandSelfClosing(html));
  for (final String selector
      in <String>[...defaultRemoveSelectors, ...removeSelectors]) {
    for (final dom.Element e in doc.querySelectorAll(selector)) {
      e.remove();
    }
  }
  // Header, licence and navigation templates are named differently on every
  // Wikisource ("otsikkomalline", "encabezado", ...); a class-name substring
  // catches them without a per-language list of selectors.
  for (final dom.Element e in doc.querySelectorAll('[class]').toList()) {
    final String cls = e.className.toLowerCase();
    if (defaultRemoveClassSubstrings.any(cls.contains)) e.remove();
  }
  final _Walker walker = _Walker(headingLevels, initialHeading);
  final dom.Element? body = doc.body;
  if (body != null) walker.walk(body);
  walker.flush();
  List<RawSection> sections =
      walker.sections.where((RawSection s) => !s.isEmpty || s.heading != null).toList();
  final bool noHeadings = sections.every((RawSection s) => s.heading == null || s.heading == initialHeading);
  if (fallbackHeadings && noHeadings) {
    sections = detectHeadingParagraphs(sections);
  }
  return sections;
}

final RegExp _selfClosing = RegExp(r'<(div|span|p|a|section|article|li|td|th|i|b|em|strong)(\s[^<>]*?)?\s*/>', caseSensitive: false);

/// XHTML allows `<div class="x"/>`; an HTML5 parser reads that as an
/// *opening* tag and swallows the rest of the document into it. Expand such
/// tags into an explicit open/close pair before parsing.
String _expandSelfClosing(String html) =>
    html.replaceAllMapped(_selfClosing, (Match m) => '<${m[1]}${m[2] ?? ''}></${m[1]}>');

class _Walker {
  _Walker(this.headingLevels, String? initialHeading)
      : _initialHeading = initialHeading;

  final List<int> headingLevels;
  final String? _initialHeading;
  final List<RawSection> sections = <RawSection>[];
  final StringBuffer _inline = StringBuffer();
  int _preDepth = 0;

  RawSection get _current {
    if (sections.isEmpty) {
      sections.add(RawSection(heading: _initialHeading));
    }
    return sections.last;
  }

  void flush() {
    final String text = _inline.toString();
    _inline.clear();
    final List<String> paragraphs = paragraphsFromText(text);
    if (paragraphs.isEmpty) return;
    _current.paragraphs.addAll(paragraphs);
  }

  void walk(dom.Node node) {
    if (node is dom.Text) {
      final String t = node.text;
      _inline.write(_preDepth > 0
          ? t.replaceAll('\r\n', '\n')
          : t.replaceAll(RegExp(r'[ \t\r\n\f]+'), ' '));
      return;
    }
    if (node is! dom.Element) return;
    final String tag = node.localName ?? '';
    final RegExpMatch? h = _headingTag.firstMatch(tag);
    if (h != null) {
      final int level = int.parse(h.group(1)!);
      final String text = _headingText(node);
      if (headingLevels.contains(level)) {
        flush();
        sections.add(RawSection(heading: text.isEmpty ? null : text, level: level));
      } else if (text.isNotEmpty) {
        flush();
        _inline.write(text);
        flush();
      }
      return;
    }
    switch (tag) {
      case 'br':
        _inline.write('\n');
        return;
      case 'sup':
        if (_footnoteMarker.hasMatch(node.text)) return;
      case 'a':
        final String href = node.attributes['href'] ?? '';
        if (href.startsWith('#') && _footnoteMarker.hasMatch(node.text)) return;
      case 'td':
      case 'th':
        final String sofar = _inline.toString();
        if (sofar.isNotEmpty && !sofar.endsWith('\n') && sofar.trim().isNotEmpty) {
          _inline.write(' · ');
        }
        for (final dom.Node child in node.nodes) {
          walk(child);
        }
        return;
    }
    if (_blockTags.contains(tag)) {
      if ((tag == 'ul' || tag == 'ol') && _looksLikeLinkList(node)) return;
      flush();
      if (tag == 'pre') _preDepth++;
      for (final dom.Node child in node.nodes) {
        walk(child);
      }
      if (tag == 'pre') _preDepth--;
      flush();
      return;
    }
    for (final dom.Node child in node.nodes) {
      walk(child);
    }
  }

  String _headingText(dom.Element e) =>
      e.text.replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Lists where links carry most of the text are navigation, not prose.
  bool _looksLikeLinkList(dom.Element list) {
    final List<dom.Element> items = list.querySelectorAll('li');
    if (items.length < 2) return false;
    final int total = list.text.replaceAll(RegExp(r'\s+'), '').length;
    if (total == 0) return true;
    int linked = 0;
    for (final dom.Element a in list.querySelectorAll('a')) {
      linked += a.text.replaceAll(RegExp(r'\s+'), '').length;
    }
    return linked / total >= 0.8;
  }
}

final RegExp _romanNumeral = RegExp(r'^[IVXLCDM]{1,8}\.?$');
final RegExp _chapterWord = RegExp(
    r'^(chapter|part|book|section|canto|capitolul|partea|cartea|chapitre|partie|livre|kapitel|teil|capítulo|parte|libro|глава|часть|книга)\b',
    caseSensitive: false);
final RegExp _endsLikeSentence = RegExp(r'''[.!?,;:…»"”’']$''');
final RegExp _letters = RegExp(r'\p{L}', unicode: true);

/// Whether a paragraph reads like a heading in a text-only source: short,
/// not sentence-like, and either all capitals, a roman numeral, a
/// chapter/part label or Title Case.
bool looksLikeHeading(String paragraph) {
  final String t = paragraph.trim();
  if (t.isEmpty || t.length > 70 || t.contains('\n')) return false;
  if (_romanNumeral.hasMatch(t)) return true;
  if (_chapterWord.hasMatch(t) && t.split(' ').length <= 10) return true;
  // Quoted lines and signatures ('EMMA RYLE.') are prose, not headings.
  if (RegExp(r'''^["'“‘«„]''').hasMatch(t) || _endsLikeSentence.hasMatch(t)) return false;
  if (t.contains('·') || RegExp(r'\d').hasMatch(t)) return false;
  final int letters = _letters.allMatches(t).length;
  if (letters < 3) return false;
  final List<String> words = t.split(RegExp(r'\s+'));
  final bool allCaps = t == t.toUpperCase() && t != t.toLowerCase();
  if (allCaps) return words.length <= 8;
  if (words.length > 6) return false;
  // Title Case: every word capitalised, except short function words
  // ("The End of General Gordon", "Moara cu noroc") in the middle.
  bool capitalised(String w) {
    final String first = w.replaceAll(RegExp(r'^[^\p{L}]+', unicode: true), '');
    return first.isEmpty || first[0] != first[0].toLowerCase();
  }
  if (!capitalised(words.first) || !capitalised(words.last)) return false;
  return words.every((String w) => capitalised(w) || _letters.allMatches(w).length <= 3);
}

/// Concatenates the sections of consecutive documents (EPUB spine items,
/// Wikisource subpages). A document that starts without a heading continues
/// the previous section instead of opening an untitled chapter. When no
/// document had a heading element at all, the heading fallback runs over
/// the whole book.
List<RawSection> joinDocuments(
  List<List<RawSection>> documents, {
  bool fallbackHeadings = true,
  List<String> skipHeadings = const <String>[],
}) {
  final Set<String> skip = <String>{
    for (final String s in <String>[...defaultSkipHeadings, ...skipHeadings]) _fold(s),
  };
  final List<RawSection> out = <RawSection>[];
  for (final List<RawSection> doc in documents) {
    for (int i = 0; i < doc.length; i++) {
      final RawSection s = doc[i];
      // Continue the previous chapter only if it is real prose, not a
      // table of contents or a title-page heading that will be dropped.
      final bool continues = i == 0 &&
          s.heading == null &&
          out.isNotEmpty &&
          out.last.paragraphs.isNotEmpty &&
          !skip.contains(_fold(out.last.heading ?? ''));
      if (continues) {
        out.last.paragraphs.addAll(s.paragraphs);
      } else {
        out.add(s);
      }
    }
  }
  final bool noHeadings = out.every((RawSection s) => s.heading == null);
  return fallbackHeadings && noHeadings ? detectHeadingParagraphs(out) : out;
}

/// Fallback for documents without heading elements: paragraphs that
/// [looksLikeHeading] open a new section, provided the document has at
/// least two such candidates (one alone is more likely a subtitle).
List<RawSection> detectHeadingParagraphs(List<RawSection> sections) {
  final int candidates = sections
      .expand((RawSection s) => s.paragraphs)
      .where(looksLikeHeading)
      .length;
  if (candidates < 2) return sections;
  final List<RawSection> out = <RawSection>[];
  for (final RawSection s in sections) {
    RawSection current = RawSection(heading: s.heading, level: s.level);
    out.add(current);
    for (final String p in s.paragraphs) {
      if (looksLikeHeading(p)) {
        current = RawSection(heading: p.trim(), level: 9);
        out.add(current);
      } else {
        current.paragraphs.add(p);
      }
    }
  }
  return out.where((RawSection s) => !s.isEmpty || s.heading != null).toList();
}

String _fold(String s) => s
    .toLowerCase()
    .replaceAll(RegExp('[’‘`´]'), "'")
    .replaceAll(RegExp('[“”]'), '"')
    .replaceAll(RegExp(r'[\s.]+$'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Merges raw sections into chapter candidates:
/// * sections whose heading is in [skipHeadings] are dropped entirely;
/// * heading-only sections equal to [title]/[author]/"by [author]" are
///   dropped (title pages);
/// * other heading-only sections (part titles) are prefixed to the next
///   section's heading;
/// * sections with no text are dropped.
List<RawSection> mergeSections(
  List<RawSection> sections, {
  List<String> skipHeadings = const <String>[],
  String? title,
  String? author,
}) {
  final Set<String> skip = <String>{
    for (final String s in <String>[...defaultSkipHeadings, ...skipHeadings]) _fold(s),
  };
  final Set<String> selfNames = <String>{
    'by',
    if (title != null) _fold(title),
    if (author != null) ...<String>[_fold(author), _fold('by $author')],
  };
  final List<RawSection> out = <RawSection>[];
  String? pendingPrefix;
  for (final RawSection s in sections) {
    final String key = _fold(s.heading ?? '');
    if (key.isNotEmpty && skip.contains(key)) continue;
    // A title page: the only text is the title / author / "by author".
    s.paragraphs.removeWhere((String p) => selfNames.contains(_fold(p)));
    if (s.isEmpty) {
      if (key.isEmpty || selfNames.contains(key)) continue;
      pendingPrefix = pendingPrefix == null ? s.heading : '$pendingPrefix — ${s.heading}';
      continue;
    }
    if (pendingPrefix != null) {
      s.heading = s.heading == null ? pendingPrefix : '$pendingPrefix — ${s.heading}';
      pendingPrefix = null;
    }
    out.add(s);
  }
  return out;
}

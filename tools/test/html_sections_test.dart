import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:lsr_library_tools/lsr_library_tools.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('sectionsFromHtml', () {
    test('headings start sections, blocks become paragraphs, br breaks lines', () {
      const String html = '''
<body>
<p>Motto before any heading.</p>
<h2>I</h2>
<p>First <i>paragraph</i> of one.</p>
<div>Second paragraph<br/>with a line break.</div>
<h2>II</h2>
<p>Only paragraph of two.</p>
</body>''';
      final List<RawSection> s = sectionsFromHtml(html);
      expect(s.map((RawSection x) => x.heading), <String?>[null, 'I', 'II']);
      expect(s[0].paragraphs, <String>['Motto before any heading.']);
      expect(s[1].paragraphs, <String>['First paragraph of one.', 'Second paragraph\nwith a line break.']);
      expect(s[2].paragraphs, <String>['Only paragraph of two.']);
    });

    test('Wikisource header, edit links, references and footnote markers are removed', () {
      const String html = '''
<div class="mw-parser-output">
<div class="ws-header wst-header ws-noexport noprint">Amintiri din copilărie de Ion Creangă</div>
<div class="mw-heading mw-heading2"><h2 id="I">I</h2><span class="mw-editsection">[modificare]</span></div>
<p>Stau câteodată și-mi aduc aminte<sup class="reference"><a href="#cite_note-1">[1]</a></sup> ce vremi.</p>
<div class="mw-heading mw-heading2"><h2>Note</h2></div>
<div class="references"><ol><li id="cite_note-1"><span class="mw-cite-backlink">↑</span> footnote text</li></ol></div>
</div>''';
      final List<RawSection> merged = mergeSections(sectionsFromHtml(html));
      expect(merged, hasLength(1));
      expect(merged.single.heading, 'I');
      expect(merged.single.paragraphs, <String>['Stau câteodată și-mi aduc aminte ce vremi.']);
    });

    test('Gutenberg boilerplate blocks, transcriber notes, figures and link lists are removed', () {
      const String html = '''
<body>
<div class="pg-boilerplate pgheader" id="pg-header"><h2>The Project Gutenberg eBook of X</h2><p>Licence text</p></div>
<div id="pg-start-separator"><span>*** START OF THE PROJECT GUTENBERG EBOOK X ***</span></div>
<p class="trnote">Several symbols are used throughout this e-text.</p>
<h1>KING SOLOMON’S MINES</h1>
<h2>by H. Rider Haggard</h2>
<h2>CONTENTS</h2>
<ul><li><a href="#c1">Chapter I</a></li><li><a href="#c2">Chapter II</a></li></ul>
<div class="figcenter"><p>CANIS MINOR</p></div>
<h2 id="c1">CHAPTER I</h2>
<p>It is a curious thing<a href="#fn1">[1]</a> that at my age.</p>
<p class="footnote">[1] A footnote.</p>
<div class="pg-boilerplate pgheader" id="pg-footer"><p>*** END OF THE PROJECT GUTENBERG EBOOK X ***</p></div>
</body>''';
      final List<RawSection> merged = mergeSections(sectionsFromHtml(html), title: "King Solomon's Mines", author: 'H. Rider Haggard');
      expect(merged.map((RawSection s) => s.heading), <String?>['CHAPTER I']);
      expect(merged.single.paragraphs, <String>['It is a curious thing that at my age.']);
    });

    test('part headings without text are prefixed to the next chapter', () {
      const String html = '<h1>PART ONE</h1><h2>CHAPTER I</h2><p>Text.</p><h2>CHAPTER II</h2><p>More.</p>';
      final List<RawSection> merged = mergeSections(sectionsFromHtml(html));
      expect(merged.map((RawSection s) => s.heading), <String?>['PART ONE — CHAPTER I', 'CHAPTER II']);
    });

    test('table cells of one row are joined into one paragraph', () {
      const String html = '<table><tr><td>Name</td><td>Date</td></tr><tr><td>Lyrids</td><td>April 20</td></tr></table>';
      final List<RawSection> s = sectionsFromHtml(html);
      expect(s.single.paragraphs, <String>['Name · Date', 'Lyrids · April 20']);
    });

    test('documents without heading elements fall back to heading-like paragraphs', () {
      const String html = '''
<p>EMINENT VICTORIANS</p>
<p>by Lytton Strachey</p>
<p>Preface</p>
<p>The history of the Victorian Age will never be written; we know too much about it.</p>
<p>CARDINAL MANNING</p>
<p>I</p>
<p>Henry Edward Manning was born in 1807.</p>
<p>II</p>
<p>Yes.</p>
<p>The rest of the chapter.</p>''';
      final List<RawSection> merged = mergeSections(sectionsFromHtml(html), title: 'Eminent Victorians', author: 'Lytton Strachey');
      expect(merged.map((RawSection s) => s.heading), <String?>['Preface', 'CARDINAL MANNING — I', 'II']);
      expect(merged[0].paragraphs, <String>['The history of the Victorian Age will never be written; we know too much about it.']);
      expect(merged[2].paragraphs, <String>['Yes.', 'The rest of the chapter.']);
    });

    test('a single heading-like paragraph is treated as text, not a chapter', () {
      const String html = '<p>Nuvelă</p><p>...și tot astfel, dacă închid un ochi.</p><p>Al doilea paragraf.</p>';
      final List<RawSection> s = sectionsFromHtml(html);
      expect(s.single.heading, isNull);
      expect(s.single.paragraphs, hasLength(3));
    });

    test('looksLikeHeading', () {
      expect(looksLikeHeading('CHAPTER I'), isTrue);
      expect(looksLikeHeading('XIV'), isTrue);
      expect(looksLikeHeading('Capitolul al doilea'), isTrue);
      expect(looksLikeHeading('The Witch-Hunt'), isTrue);
      expect(looksLikeHeading('ALLAN QUATERMAIN.'), isFalse);
      expect(looksLikeHeading("'EMMA RYLE."), isFalse);
      expect(looksLikeHeading('Name · Date'), isFalse);
      expect(looksLikeHeading('Florence Nightingale'), isTrue);
      expect(looksLikeHeading('“Yes.”'), isFalse);
      expect(looksLikeHeading('L.S.'), isFalse);
      expect(looksLikeHeading('It is a curious thing that at my age I should be writing.'), isFalse);
      expect(looksLikeHeading('So we started.'), isFalse);
    });
  });

  group('readEpub', () {
    Uint8List makeEpub(Map<String, String> files) {
      final Archive a = Archive();
      files.forEach((String name, String content) {
        final List<int> bytes = utf8.encode(content);
        a.addFile(ArchiveFile(name, bytes.length, bytes));
      });
      return Uint8List.fromList(ZipEncoder().encode(a));
    }

    test('reads metadata and spine documents in order', () {
      final Uint8List epub = makeEpub(<String, String>{
        'mimetype': 'application/epub+zip',
        'META-INF/container.xml': '<?xml version="1.0"?><container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>',
        'OEBPS/content.opf': '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/">
<metadata><dc:title>Moara cu noroc</dc:title><dc:creator>Ioan Slavici</dc:creator><dc:language>ro</dc:language></metadata>
<manifest>
<item id="b" href="b.xhtml" media-type="application/xhtml+xml"/>
<item id="a" href="a.xhtml" media-type="application/xhtml+xml"/>
<item id="css" href="s.css" media-type="text/css"/>
</manifest>
<spine><itemref idref="a"/><itemref idref="b"/></spine>
</package>''',
        'OEBPS/a.xhtml': '<html><body><h2>I</h2><p>Omul să fie mulțumit.</p></body></html>',
        'OEBPS/b.xhtml': '<html><body><h2>II</h2><p>De la Ineu drumul de țară.</p></body></html>',
        'OEBPS/s.css': 'p {}',
      });
      final EpubContent c = readEpub(epub);
      expect(c.title, 'Moara cu noroc');
      expect(c.author, 'Ioan Slavici');
      expect(c.language, 'ro');
      expect(c.spineCount, 2);
      expect(c.sections.map((RawSection s) => s.heading), <String?>['I', 'II']);
    });

    test('rejects non-EPUB input', () {
      expect(() => readEpub(Uint8List.fromList(<int>[1, 2, 3])), throwsA(isA<EpubFormatException>()));
      expect(() => readEpub(makeEpub(<String, String>{'mimetype': 'x'})), throwsA(isA<EpubFormatException>()));
    });
  });

  group('normalizeBook', () {
    test('builds chapters from sections, drops Gutenberg residue and title lines', () {
      final BookMetadata m = BookMetadata(sampleMetadata(patch: <String, Object?>{
        'source': <String, Object?>{
          'provider': 'gutenberg',
          'url': 'https://www.gutenberg.org/ebooks/2166',
          'identifier': '2166',
          'format': 'epub',
        },
      }));
      final ImportedSource src = ImportedSource(
        sections: <RawSection>[
          RawSection(heading: 'I')..paragraphs.addAll(<String>['by Ion Creangă', 'Real  text here.', 'Produced by Project Gutenberg volunteers.']),
          RawSection(heading: 'Note')..paragraphs.add('dropped'),
          RawSection(heading: 'II')..paragraphs.add('More.'),
        ],
        provenance: sampleBook().provenance,
      );
      final NormalizedBook b = normalizeBook(m, src, testLanguages);
      expect(b.chapters.map((Chapter c) => c.title), <String?>['I', 'II']);
      expect(b.chapters[0].paragraphs, <String>['Real text here.']);
      expect(b.direction, 'ltr');
    });

    test('fails when nothing is left', () {
      final BookMetadata m = BookMetadata(sampleMetadata());
      final ImportedSource src = ImportedSource(sections: <RawSection>[RawSection(heading: 'Contents')..paragraphs.add('x')], provenance: sampleBook().provenance);
      expect(() => normalizeBook(m, src, testLanguages), throwsA(isA<BuildException>()));
    });
  });
}

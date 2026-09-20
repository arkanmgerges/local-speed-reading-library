import 'dart:convert';

import 'package:lsr_library_tools/lsr_library_tools.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  final Schemas schemas = Schemas.load(realRepo);

  test('a sound book passes structure and schema checks', () {
    final NormalizedBook b = sampleBook();
    expect(validateBookStructure(b), isEmpty);
    expect(schemaErrors(schemas.normalizedBook, b.toJson()), isEmpty);
    expect(b.wordCount, 18);
  });

  test('an empty book is rejected', () {
    expect(validateBookStructure(sampleBook(chapters: <Chapter>[])), contains('book has no chapters'));
    expect(schemaErrors(schemas.normalizedBook, sampleBook(chapters: <Chapter>[]).toJson()), isNotEmpty);
    final Chapter blank = const Chapter(index: 0, title: null, paragraphs: <String>[]);
    expect(validateBookStructure(sampleBook(chapters: <Chapter>[blank])), contains('chapter 0 has no paragraphs'));
  });

  test('a malformed normalized book fails the schema and the parser', () {
    final Map<String, Object?> json = sampleBook().toJson()..remove('chapters');
    expect(schemaErrors(schemas.normalizedBook, json), isNotEmpty);
    expect(() => NormalizedBook.fromJson(json), throwsA(isA<TypeError>()));
    final Map<String, Object?> wrongVersion = sampleBook().toJson()..['schemaVersion'] = 99;
    expect(schemaErrors(schemas.normalizedBook, wrongVersion), isNotEmpty);
  });

  test('invalid chapter ordering is rejected', () {
    final NormalizedBook b = sampleBook(chapters: <Chapter>[
      const Chapter(index: 1, title: 'II', paragraphs: <String>['b']),
      const Chapter(index: 0, title: 'I', paragraphs: <String>['a']),
    ]);
    expect(validateBookStructure(b), containsAll(<String>['chapter at position 0 has index 1', 'chapter at position 1 has index 0']));
  });

  test('markup and unnormalised text are rejected', () {
    final NormalizedBook b = sampleBook(chapters: <Chapter>[
      const Chapter(index: 0, title: null, paragraphs: <String>['<p>hello</p>', '  two  spaces ']),
    ]);
    final List<String> problems = validateBookStructure(b);
    expect(problems, contains('chapter 0 paragraph 0 contains markup'));
    expect(problems, contains('chapter 0 paragraph 1 is not normalised'));
  });

  test('Unicode is preserved through normalisation, JSON and gzip (NFC applied)', () {
    const String decomposed = 'Sărmanul Dionis'; // a + combining breve
    const String composed = 'Sărmanul Dionis';
    expect(normalizeParagraph(decomposed), composed);
    const String mixed = 'Ținutul Moldovei — „ghilimele” ș ț â î; 日本語のテキスト; emoji 🙂';
    expect(normalizeParagraph(mixed), mixed);
    final NormalizedBook b = sampleBook(chapters: <Chapter>[
      const Chapter(index: 0, title: 'Capitolul Ⅰ', paragraphs: <String>[mixed]),
    ]);
    final PackagedAsset a = packageJson(b.toCanonicalJson());
    final Map<String, Object?> back = verifyAsset(a.gzipBytes,
        expectedSizeBytes: a.sizeBytes, expectedSha256: a.sha256, expectedContentSha256: a.contentSha256);
    expect(NormalizedBook.fromJson(back).chapters.single.paragraphs.single, mixed);
    expect(NormalizedBook.fromJson(back).chapters.single.title, 'Capitolul Ⅰ');
  });

  test('RTL text, bidi marks and joiners survive; zero-width spaces do not', () {
    const String arabic = 'قال الملك: ‏«ادخل»‏؛ ثم صمت.';
    expect(normalizeParagraph(arabic), arabic);
    const String persian = 'می‌خواهم'; // ZWNJ must stay
    expect(normalizeParagraph(persian), persian);
    expect(normalizeParagraph('a​b﻿c­d'), 'abcd');
    expect(normalizeParagraph('a b c　d'), 'a b c d');
    final NormalizedBook b = NormalizedBook(
      workId: 'x-y',
      editionId: 'x-y.ar.z',
      assetVersion: 1,
      language: 'ar',
      direction: 'rtl',
      title: 'كتاب',
      author: 'مؤلف',
      translator: null,
      chapters: const <Chapter>[Chapter(index: 0, title: null, paragraphs: <String>[arabic])],
      provenance: sampleBook().provenance,
      rightsStatement: 'pd',
    );
    expect(validateBookStructure(b), isEmpty);
    final String json = b.toCanonicalJson();
    expect((jsonDecode(json) as Map<String, Object?>)['direction'], 'rtl');
    expect(NormalizedBook.fromJson(jsonDecode(json) as Map<String, Object?>).chapters.single.paragraphs.single, arabic);
  });

  test('canonical JSON sorts keys and ends with a newline', () {
    final String json = sampleBook().toCanonicalJson();
    expect(json, startsWith('{\n  "assetVersion": 1,\n  "author": "Ion Creangă",\n  "chapters": ['));
    expect(json, endsWith('}\n'));
    expect(canonicalJson(<String, Object?>{'b': 1, 'a': <String, Object?>{'z': 1, 'y': 2}}),
        '{\n  "a": {\n    "y": 2,\n    "z": 1\n  },\n  "b": 1\n}\n');
  });

  test('plain text rendering keeps chapter titles and paragraph breaks', () {
    expect(sampleBook().toPlainText(),
        'I\n\nStau câteodată și-mi aduc aminte.\n\nNu știu alții cum sunt.\n\nII\n\nCum nu se dă scos ursul din bârlog.');
  });

  test('word counting matches whitespace splitting', () {
    expect(countWords('one two  three\nfour'), 4);
    expect(countWords('日本語のテキスト'), 1);
    expect(countWords(''), 0);
  });
}

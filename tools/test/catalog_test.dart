import 'package:lsr_library_tools/lsr_library_tools.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  late TempRepo t;
  setUp(() => t = TempRepo.create());
  tearDown(() => t.dispose());

  BookMetadata builtEdition() {
    final BookMetadata m = BookMetadata(sampleMetadata());
    final Map<String, Object?> asset = t.writeBuiltAsset(m, sampleBook());
    final Map<String, Object?> full = sampleMetadata(patch: <String, Object?>{'asset': asset});
    t.writeMetadata(full);
    return BookMetadata(full);
  }

  test('catalog and manifest are generated, schema-valid and deterministic', () {
    final BookMetadata m = builtEdition();
    final GeneratedCatalog a = buildCatalog(<BookMetadata>[m], testLanguages, policy: testPolicy);
    final GeneratedCatalog b = buildCatalog(<BookMetadata>[m], testLanguages, policy: testPolicy);
    expect(a.files, equals(b.files));
    expect(a.files.keys, containsAll(<String>['catalog/catalog.json', 'catalog/languages/ro.json']));
    t.writeCatalog(a);
    final Schemas s = Schemas.load(t.repo);
    expect(schemaErrors(s.catalog, t.readJson('catalog/catalog.json')), isEmpty);
    expect(schemaErrors(s.languageManifest, t.readJson('catalog/languages/ro.json')), isEmpty);
    final Map<String, Object?> catalog = t.readJson('catalog/catalog.json');
    expect((catalog['assets'] as Map<String, Object?>)['baseUrl'], 'https://books.localspeedreading.com/');
    final Map<String, Object?> lang = (catalog['languages'] as List<Object?>).single as Map<String, Object?>;
    expect(lang['bookCount'], 1);
    expect(lang['manifest'], 'catalog/languages/ro.json');
    expect(lang['nativeName'], 'Română');
  });

  test('manifest entries carry no text, only metadata and the asset record', () {
    final BookMetadata m = builtEdition();
    t.writeCatalog(buildCatalog(<BookMetadata>[m], testLanguages, policy: testPolicy));
    final Map<String, Object?> manifest = t.readJson('catalog/languages/ro.json');
    final Map<String, Object?> book = (manifest['books'] as List<Object?>).single as Map<String, Object?>;
    expect(book.keys, isNot(contains('chapters')));
    final Map<String, Object?> asset = book['asset'] as Map<String, Object?>;
    expect(asset['path'], 'books/ro/creanga-amintiri-din-copilarie.ro.wikisource/v1/book.json.gz');
    expect(asset['sha256'], matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(asset['encoding'], 'gzip');
    expect(t.readFile('catalog/languages/ro.json'), isNot(contains('Stau câteodată')));
  });

  test('the committed catalogue is validated against a fresh generation', () {
    final BookMetadata m = builtEdition();
    t.writeCatalog(buildCatalog(<BookMetadata>[m], testLanguages, policy: testPolicy));
    expect(errorsOf(t.validator().validateCatalog(<BookMetadata>[m])), isEmpty);
  });

  test('a stale manifest reference (old asset version) is an error', () {
    final BookMetadata v1 = builtEdition();
    t.writeCatalog(buildCatalog(<BookMetadata>[v1], testLanguages, policy: testPolicy));
    // The edition moves to v2 but the committed manifest still points at v1.
    final Map<String, Object?> v2meta = sampleMetadata(patch: <String, Object?>{'publish': <String, Object?>{'assetVersion': 2}});
    final Map<String, Object?> asset2 = t.writeBuiltAsset(BookMetadata(v2meta), sampleBook(assetVersion: 2));
    final BookMetadata v2 = BookMetadata(sampleMetadata(patch: <String, Object?>{
      'publish': <String, Object?>{'assetVersion': 2},
      'asset': asset2,
    }));
    final List<String> errors = errorsOf(t.validator().validateCatalog(<BookMetadata>[v2]));
    expect(errors, contains(contains('stale reference')));
    expect(errors, contains(contains('out of date')));
  });

  test('a manifest that references a nonexistent edition is an error', () {
    final BookMetadata m = builtEdition();
    t.writeCatalog(buildCatalog(<BookMetadata>[m], testLanguages, policy: testPolicy));
    expect(errorsOf(t.validator().validateCatalog(<BookMetadata>[])), contains(contains('no metadata file')));
  });

  test('immutable version paths are generated from language, edition and version', () {
    expect(assetPath('ro', 'creanga-amintiri-din-copilarie.ro.wikisource', 1),
        'books/ro/creanga-amintiri-din-copilarie.ro.wikisource/v1/book.json.gz');
    expect(assetPath('pt-BR', 'x-y.pt-br.z', 12), 'books/pt-br/x-y.pt-br.z/v12/book.json.gz');
    expect(() => assetPath('ro', 'bad id', 1), throwsArgumentError);
    expect(() => assetPath('ro', 'a.ro.b', 0), throwsArgumentError);
    expect(parseAssetPath('books/ro/a.ro.b/v3/book.json.gz'), (language: 'ro', editionId: 'a.ro.b', assetVersion: 3));
    expect(parseAssetPath('books/ro/a.ro.b/3/book.json.gz'), isNull);
  });

  test('edition ids embed the work id and the language', () {
    expect(isValidEditionId('creanga-amintiri-din-copilarie.ro.wikisource'), isTrue);
    expect(isValidEditionId('Creanga.ro.x'), isFalse);
    expect(isValidEditionId('a.ro'), isFalse);
    expect(parseEditionId('a-b.zh-hans.c')!.language, 'zh-hans');
    expect(slugify('Sărmanul Dionis — O nuvelă!'), 'sarmanul-dionis-o-nuvela');
  });
}

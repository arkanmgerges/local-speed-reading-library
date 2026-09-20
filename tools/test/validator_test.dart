import 'package:lsr_library_tools/lsr_library_tools.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  late TempRepo t;
  setUp(() => t = TempRepo.create());
  tearDown(() => t.dispose());

  ({List<Problem> problems, List<BookMetadata> editions}) run() => t.validator().validateMetadata();

  test('a well-formed edition passes with only infos', () {
    t.writeMetadata(sampleMetadata());
    final result = run();
    expect(errorsOf(result.problems), isEmpty);
    expect(result.editions, hasLength(1));
  });

  test('invalid metadata schema (missing rights) is an error', () {
    final Map<String, Object?> m = sampleMetadata()..remove('rights');
    t.writeMetadata(m);
    expect(errorsOf(run().problems), contains(contains('schema')));
  });

  test('unsupported schema version is rejected before anything else', () {
    t.writeMetadata(sampleMetadata(patch: <String, Object?>{'schemaVersion': 2}));
    final result = run();
    expect(errorsOf(result.problems).single, contains('unsupported schemaVersion 2'));
    expect(result.editions, isEmpty);
  });

  test('duplicate edition ids across files are an error', () {
    t.writeMetadata(sampleMetadata());
    t.writeMetadata(sampleMetadata(), at: 'metadata/ro/other-file.json');
    expect(errorsOf(run().problems), contains(contains('duplicate editionId')));
  });

  test('the same work id with a different definition is an error', () {
    t.writeMetadata(sampleMetadata());
    final Map<String, Object?> other = sampleMetadata();
    other['work'] = <String, Object?>{
      ...other['work'] as Map<String, Object?>,
      'originalTitle': 'Alt titlu',
    };
    other['edition'] = <String, Object?>{
      ...other['edition'] as Map<String, Object?>,
      'editionId': 'creanga-amintiri-din-copilarie.ro.alt',
    };
    t.writeMetadata(other);
    expect(errorsOf(run().problems), contains(contains('defined differently')));
  });

  test('duplicate asset paths are an error', () {
    final Map<String, Object?> asset = t.writeBuiltAsset(BookMetadata(sampleMetadata()), sampleBook());
    t.writeMetadata(sampleMetadata(patch: <String, Object?>{'asset': asset}));
    final Map<String, Object?> other = sampleMetadata(patch: <String, Object?>{'asset': asset});
    other['edition'] = <String, Object?>{
      ...other['edition'] as Map<String, Object?>,
      'editionId': 'creanga-amintiri-din-copilarie.ro.alt',
    };
    t.writeMetadata(other);
    expect(errorsOf(run().problems), contains(contains('duplicate asset path')));
  });

  test('invalid BCP 47 tags are rejected', () {
    for (final String bad in <String>['romanian', 'ro_RO', 'r', 'ro-']) {
      final Map<String, Object?> m = sampleMetadata();
      m['work'] = <String, Object?>{...m['work'] as Map<String, Object?>, 'originalLanguage': bad};
      t.writeMetadata(m);
      expect(errorsOf(run().problems), isNotEmpty, reason: bad);
    }
  });

  test('a language the app does not know is rejected', () {
    final Map<String, Object?> m = sampleMetadata();
    m['edition'] = <String, Object?>{...m['edition'] as Map<String, Object?>, 'language': 'tlh', 'editionId': 'creanga-amintiri-din-copilarie.tlh.wikisource'};
    t.writeMetadata(m);
    expect(errorsOf(run().problems), contains(contains('not in sources/languages.json')));
  });

  test('missing rights information fails the schema', () {
    final Map<String, Object?> m = sampleMetadata();
    m['rights'] = <String, Object?>{'status': 'public-domain'};
    t.writeMetadata(m);
    expect(errorsOf(run().problems), contains(contains('schema')));
  });

  test('an uncertain-rights item is kept out of the catalogue but is not an error', () {
    final Map<String, Object?> m = sampleMetadata();
    m['rights'] = <String, Object?>{...m['rights'] as Map<String, Object?>, 'status': 'uncertain'};
    t.writeMetadata(m);
    final result = run();
    expect(errorsOf(result.problems), isEmpty);
    expect(isPublishable(result.editions.single, testPolicy), isFalse);
    final GeneratedCatalog c = buildCatalog(result.editions, testLanguages, policy: testPolicy);
    expect(c.files.keys, <String>['catalog/catalog.json']);
  });

  test('a non-public-domain item marked public-domain is an error', () {
    final Map<String, Object?> m = sampleMetadata();
    m['work'] = <String, Object?>{
      ...m['work'] as Map<String, Object?>,
      'author': <String, Object?>{'name': 'Someone Recent', 'deathYear': 1990},
    };
    t.writeMetadata(m);
    expect(errorsOf(run().problems), contains(contains('fails the publishing policy')));
  });

  test('a translation needs the translator to be public domain too', () {
    final Map<String, Object?> m = sampleMetadata();
    m['edition'] = <String, Object?>{
      ...m['edition'] as Map<String, Object?>,
      'kind': 'translation',
      'language': 'en',
      'editionId': 'creanga-amintiri-din-copilarie.en.recent',
      'translator': <String, Object?>{'name': 'Recent Translator', 'deathYear': 2001},
      'translationPublicationYear': 1990,
    };
    t.writeMetadata(m);
    final List<String> errors = errorsOf(run().problems);
    expect(errors, contains(contains('translator died in 2001')));
    expect(errors, contains(contains('first published in 1990')));
  });

  test('invalid or missing source information is rejected', () {
    for (final Map<String, Object?> bad in <Map<String, Object?>>[
      <String, Object?>{'url': 'http://ro.wikisource.org/wiki/X'},
      <String, Object?>{'url': 'https://example.com/book'},
      <String, Object?>{'identifier': ''},
      <String, Object?>{'format': 'epub'},
    ]) {
      final Map<String, Object?> m = sampleMetadata();
      m['source'] = <String, Object?>{...m['source'] as Map<String, Object?>, ...bad};
      t.writeMetadata(m);
      expect(errorsOf(run().problems), isNotEmpty, reason: '$bad');
    }
  });

  test('a file in the wrong folder or with the wrong name is an error', () {
    t.writeMetadata(sampleMetadata(), at: 'metadata/en/creanga-amintiri-din-copilarie.ro.wikisource.json');
    expect(errorsOf(run().problems), contains(contains('file should be at metadata/ro/')));
  });

  test('a built asset that does not match its asset block is an error', () {
    final BookMetadata m = BookMetadata(sampleMetadata());
    final Map<String, Object?> asset = t.writeBuiltAsset(m, sampleBook());
    t.writeMetadata(sampleMetadata(patch: <String, Object?>{
      'asset': <String, Object?>{...asset, 'sha256': 'a' * 64},
    }));
    expect(errorsOf(run().problems), contains(contains('checksumMismatch')));
  });

  test('a built asset that matches passes', () {
    final BookMetadata m = BookMetadata(sampleMetadata());
    final Map<String, Object?> asset = t.writeBuiltAsset(m, sampleBook());
    t.writeMetadata(sampleMetadata(patch: <String, Object?>{'asset': asset}));
    expect(errorsOf(run().problems), isEmpty);
  });

  test('an asset built for an older version than publish.assetVersion is a warning and unpublishable', () {
    final BookMetadata m = BookMetadata(sampleMetadata());
    final Map<String, Object?> asset = t.writeBuiltAsset(m, sampleBook());
    t.writeMetadata(sampleMetadata(patch: <String, Object?>{
      'asset': asset,
      'publish': <String, Object?>{'assetVersion': 2},
    }));
    final result = run();
    expect(errorsOf(result.problems), isEmpty);
    expect(result.problems.where((Problem p) => p.severity == Severity.warning), isNotEmpty);
    expect(isPublishable(result.editions.single, testPolicy), isFalse);
  });
}

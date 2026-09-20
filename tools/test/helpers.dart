import 'dart:convert';
import 'dart:io';

import 'package:lsr_library_tools/lsr_library_tools.dart';
import 'package:path/path.dart' as p;

/// The real repository checkout (schemas, languages) this test suite runs in.
final LibraryRepo realRepo = LibraryRepo.locate(Directory.current.path);

final LanguageRegistry testLanguages = LanguageRegistry.load(realRepo.languagesRegistryFile);

const RightsPolicy testPolicy = RightsPolicy(currentYear: 2026);

/// A schema-valid, publishable Romanian edition. Override parts with
/// [patch] (top-level keys are replaced whole).
Map<String, Object?> sampleMetadata({Map<String, Object?> patch = const <String, Object?>{}}) {
  final Map<String, Object?> m = <String, Object?>{
    'schemaVersion': 1,
    'work': <String, Object?>{
      'workId': 'creanga-amintiri-din-copilarie',
      'originalTitle': 'Amintiri din copilărie',
      'originalLanguage': 'ro',
      'author': <String, Object?>{'name': 'Ion Creangă', 'birthYear': 1837, 'deathYear': 1889},
      'originalPublicationYear': 1881,
    },
    'edition': <String, Object?>{
      'editionId': 'creanga-amintiri-din-copilarie.ro.wikisource',
      'language': 'ro',
      'title': 'Amintiri din copilărie',
      'kind': 'original',
    },
    'source': <String, Object?>{
      'provider': 'wikisource',
      'site': 'ro.wikisource.org',
      'url': 'https://ro.wikisource.org/wiki/Amintiri_din_copil%C4%83rie',
      'identifier': 'Amintiri din copilărie',
      'format': 'html',
      'revision': '106333',
      'pages': <Object?>[
        <String, Object?>{'title': 'Amintiri din copilărie', 'revision': 106333},
      ],
      'retrievedAt': '2026-09-20T18:00:00.000Z',
    },
    'rights': <String, Object?>{
      'status': 'public-domain',
      'basis': <String>['author died 1889'],
      'jurisdictions': <String>['worldwide-conservative'],
      'statement': 'Public domain worldwide.',
      'evidence': <String>['https://ro.wikipedia.org/wiki/Ion_Creang%C4%83'],
      'verifiedBy': 'tests',
      'verifiedAt': '2026-09-20',
    },
    'genres': <String>['Fiction'],
    'publish': <String, Object?>{'assetVersion': 1},
  };
  m.addAll(patch);
  return m;
}

/// A tiny two-chapter book for [sampleMetadata].
NormalizedBook sampleBook({int assetVersion = 1, List<Chapter>? chapters}) => NormalizedBook(
      workId: 'creanga-amintiri-din-copilarie',
      editionId: 'creanga-amintiri-din-copilarie.ro.wikisource',
      assetVersion: assetVersion,
      language: 'ro',
      direction: 'ltr',
      title: 'Amintiri din copilărie',
      author: 'Ion Creangă',
      translator: null,
      chapters: chapters ??
          <Chapter>[
            const Chapter(index: 0, title: 'I', paragraphs: <String>['Stau câteodată și-mi aduc aminte.', 'Nu știu alții cum sunt.']),
            const Chapter(index: 1, title: 'II', paragraphs: <String>['Cum nu se dă scos ursul din bârlog.']),
          ],
      provenance: const Provenance(
        provider: 'wikisource',
        url: 'https://ro.wikisource.org/wiki/Amintiri_din_copil%C4%83rie',
        identifier: 'Amintiri din copilărie',
        revision: '106333',
        pages: [(title: 'Amintiri din copilărie', revision: 106333)],
        retrievedAt: '2026-09-20T18:00:00.000Z',
      ),
      rightsStatement: 'Public domain worldwide.',
    );

/// A throw-away repository with the real schemas and language registry,
/// and whatever metadata files the test writes.
class TempRepo {
  TempRepo._(this.dir, this.repo);

  static TempRepo create() {
    final Directory dir = Directory.systemTemp.createTempSync('lsr_test_');
    Directory(p.join(dir.path, 'schemas')).createSync();
    for (final String name in <String>['book-metadata', 'normalized-book', 'language-manifest', 'catalog']) {
      File(realRepo.schema(name)).copySync(p.join(dir.path, 'schemas', '$name.schema.json'));
    }
    Directory(p.join(dir.path, 'sources')).createSync();
    File(realRepo.languagesRegistryFile).copySync(p.join(dir.path, 'sources', 'languages.json'));
    return TempRepo._(dir, LibraryRepo(dir.path));
  }

  final Directory dir;
  final LibraryRepo repo;

  /// Writes a metadata file at its canonical location (or [at]).
  void writeMetadata(Map<String, Object?> metadata, {String? at}) {
    final BookMetadata m = BookMetadata(metadata);
    final File f = File(at == null ? repo.metadataFile(m.language, m.editionId) : p.join(dir.path, at));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(canonicalJson(metadata));
  }

  /// Builds [book] into build/ and returns the asset block.
  Map<String, Object?> writeBuiltAsset(BookMetadata m, NormalizedBook book) =>
      writeAsset(repo, m, book, builtAt: DateTime.utc(2026, 9, 20));

  void writeCatalog(GeneratedCatalog generated) {
    for (final MapEntry<String, String> e in generated.files.entries) {
      File(p.join(dir.path, p.joinAll(e.key.split('/'))))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(e.value);
    }
  }

  RepoValidator validator() => RepoValidator(repo, policy: testPolicy);

  String readFile(String rel) => File(p.join(dir.path, p.joinAll(rel.split('/')))).readAsStringSync();

  Map<String, Object?> readJson(String rel) => json.decode(readFile(rel)) as Map<String, Object?>;

  void dispose() => dir.deleteSync(recursive: true);
}

List<String> errorsOf(List<Problem> problems) =>
    problems.where((Problem p) => p.isError).map((Problem p) => p.message).toList();

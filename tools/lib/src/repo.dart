import 'dart:io';

import 'package:path/path.dart' as p;

/// Locations inside a checkout of local-speed-reading-library.
class LibraryRepo {
  LibraryRepo(this.root);

  final String root;

  String get schemasDir => p.join(root, 'schemas');
  String get metadataDir => p.join(root, 'metadata');
  String get catalogDir => p.join(root, 'catalog');
  String get languagesDir => p.join(catalogDir, 'languages');
  String get sourcesDir => p.join(root, 'sources');
  String get buildDir => p.join(root, 'build');
  String get buildBooksDir => p.join(buildDir, 'books');
  String get buildSourcesDir => p.join(buildDir, 'sources');

  String get catalogFile => p.join(catalogDir, 'catalog.json');
  String get languagesRegistryFile => p.join(sourcesDir, 'languages.json');
  String get providersFile => p.join(sourcesDir, 'providers.json');

  String schema(String name) => p.join(schemasDir, '$name.schema.json');

  String manifestFile(String language) =>
      p.join(languagesDir, '$language.json');

  /// Path of the metadata file for [editionId] in [language].
  String metadataFile(String language, String editionId) =>
      p.join(metadataDir, language, '$editionId.json');

  /// Every metadata file, sorted for deterministic processing.
  List<File> metadataFiles() {
    final Directory dir = Directory(metadataDir);
    if (!dir.existsSync()) return const <File>[];
    final List<File> files = dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => f.path.endsWith('.json'))
        .toList()
      ..sort((File a, File b) => a.path.compareTo(b.path));
    return files;
  }

  /// Walks up from [start] (default: the working directory) until it finds
  /// the repository root, identified by `schemas/book-metadata.schema.json`.
  static LibraryRepo locate([String? start]) {
    Directory dir = Directory(start ?? Directory.current.path).absolute;
    while (true) {
      final File marker =
          File(p.join(dir.path, 'schemas', 'book-metadata.schema.json'));
      if (marker.existsSync()) return LibraryRepo(dir.path);
      final Directory parent = dir.parent;
      if (parent.path == dir.path) {
        throw StateError(
            'Not inside local-speed-reading-library (no schemas/ found above ${Directory.current.path}).');
      }
      dir = parent;
    }
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:lsr_library_tools/src/canonical_json.dart';

/// Typed view over one `metadata/<lang>/<editionId>.json` file. The raw map
/// is kept so unknown-but-schema-valid fields survive a round trip.
class BookMetadata {
  BookMetadata(this.raw);

  factory BookMetadata.parse(String text) =>
      BookMetadata(json.decode(text) as Map<String, Object?>);

  static BookMetadata read(File file) =>
      BookMetadata.parse(file.readAsStringSync());

  final Map<String, Object?> raw;

  Map<String, Object?> _section(String key) =>
      (raw[key] as Map<String, Object?>?) ?? const <String, Object?>{};

  int get schemaVersion => raw['schemaVersion'] as int? ?? 0;

  // Work ------------------------------------------------------------------
  Map<String, Object?> get work => _section('work');
  String get workId => work['workId'] as String? ?? '';
  String get originalTitle => work['originalTitle'] as String? ?? '';
  String get originalLanguage => work['originalLanguage'] as String? ?? '';
  Map<String, Object?> get author =>
      (work['author'] as Map<String, Object?>?) ?? const <String, Object?>{};
  String get authorName => author['name'] as String? ?? '';
  int? get authorDeathYear => author['deathYear'] as int?;
  int? get originalPublicationYear => work['originalPublicationYear'] as int?;

  // Edition ---------------------------------------------------------------
  Map<String, Object?> get edition => _section('edition');
  String get editionId => edition['editionId'] as String? ?? '';
  String get language => edition['language'] as String? ?? '';
  String get title => edition['title'] as String? ?? '';
  String get kind => edition['kind'] as String? ?? '';
  bool get isTranslation => kind == 'translation';
  Map<String, Object?>? get translator =>
      edition['translator'] as Map<String, Object?>?;
  String? get translatorName => translator?['name'] as String?;
  int? get translatorDeathYear => translator?['deathYear'] as int?;
  int? get editionPublicationYear => edition['editionPublicationYear'] as int?;
  int? get translationPublicationYear =>
      edition['translationPublicationYear'] as int?;

  // Source ----------------------------------------------------------------
  Map<String, Object?> get source => _section('source');
  String get provider => source['provider'] as String? ?? '';
  String get sourceUrl => source['url'] as String? ?? '';
  String get sourceIdentifier => source['identifier'] as String? ?? '';
  String get sourceFormat => source['format'] as String? ?? '';
  String? get sourceSite => source['site'] as String?;
  String? get sourceRevision => source['revision'] as String?;
  String? get retrievedAt => source['retrievedAt'] as String?;
  List<({String title, int revision})> get sourcePages {
    final List<Object?>? pages = source['pages'] as List<Object?>?;
    if (pages == null) return const [];
    return pages.map((Object? e) {
      final Map<String, Object?> m = e as Map<String, Object?>;
      return (title: m['title'] as String, revision: m['revision'] as int);
    }).toList();
  }

  // Rights ----------------------------------------------------------------
  Map<String, Object?> get rights => _section('rights');
  String get rightsStatus => rights['status'] as String? ?? '';
  String get rightsStatement => rights['statement'] as String? ?? '';
  String? get rightsVerifiedAt => rights['verifiedAt'] as String?;
  List<String> get rightsEvidence =>
      ((rights['evidence'] as List<Object?>?) ?? const <Object?>[])
          .cast<String>();

  List<String> get genres =>
      ((raw['genres'] as List<Object?>?) ?? const <Object?>[]).cast<String>();

  // Publish / asset -------------------------------------------------------
  int get publishAssetVersion =>
      (_section('publish')['assetVersion'] as int?) ?? 0;

  Map<String, Object?>? get asset => raw['asset'] as Map<String, Object?>?;
  int? get assetVersion => asset?['assetVersion'] as int?;
  String? get assetPathValue => asset?['path'] as String?;
  String? get assetSha256 => asset?['sha256'] as String?;

  // Import hints ----------------------------------------------------------
  Map<String, Object?> get importHints => _section('import');
  List<int> get chapterHeadingLevels =>
      ((importHints['chapterHeadingLevels'] as List<Object?>?) ??
              const <Object?>[1, 2, 3])
          .cast<int>();
  List<String> get skipHeadings =>
      ((importHints['skipHeadings'] as List<Object?>?) ?? const <Object?>[])
          .cast<String>();
  List<String> get removeSelectors =>
      ((importHints['removeSelectors'] as List<Object?>?) ?? const <Object?>[])
          .cast<String>();
  List<String> get dropParagraphsMatching =>
      ((importHints['dropParagraphsMatching'] as List<Object?>?) ??
              const <Object?>[])
          .cast<String>();
  String? get firstChapterTitle => importHints['firstChapterTitle'] as String?;

  /// A copy with [section] replaced (or removed when [value] is null).
  BookMetadata withSection(String section, Map<String, Object?>? value) {
    final Map<String, Object?> copy = Map<String, Object?>.of(raw);
    if (value == null) {
      copy.remove(section);
    } else {
      copy[section] = value;
    }
    return BookMetadata(copy);
  }

  String toCanonicalJson() => canonicalJson(raw);
}

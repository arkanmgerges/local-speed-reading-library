/// Identifier rules shared by the validator, the builder and the app.
///
/// * workId    `creanga-amintiri-din-copilarie`      `[a-z0-9-]`
/// * editionId `<workId>.<lang>.<edition-slug>`      `[a-z0-9.-]`
/// * asset     `books/<lang>/<editionId>/v<N>/book.json.gz`
library;

final RegExp workIdPattern = RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$');
final RegExp editionIdPattern = RegExp(
    r'^[a-z0-9]+(-[a-z0-9]+)*\.[a-z0-9]+(-[a-z0-9]+)*\.[a-z0-9]+(-[a-z0-9]+)*$');
final RegExp assetPathPattern =
    RegExp(r'^books/([a-z0-9-]+)/([a-z0-9.-]+)/v([0-9]+)/book\.json\.gz$');
final RegExp sha256Pattern = RegExp(r'^[a-f0-9]{64}$');

bool isValidWorkId(String id) => workIdPattern.hasMatch(id);
bool isValidEditionId(String id) => editionIdPattern.hasMatch(id);

/// The language segment used inside identifiers and object paths: the BCP 47
/// tag lower-cased (`pt-BR` -> `pt-br`, `zh-Hans` -> `zh-hans`).
String languagePathSegment(String languageTag) => languageTag.toLowerCase();

/// Splits `<workId>.<lang>.<slug>`; null when the id is malformed.
({String workId, String language, String slug})? parseEditionId(String id) {
  if (!isValidEditionId(id)) return null;
  final List<String> parts = id.split('.');
  return (workId: parts[0], language: parts[1], slug: parts[2]);
}

/// Immutable object path of one asset version.
String assetPath(String languageTag, String editionId, int assetVersion) {
  if (assetVersion < 1) {
    throw ArgumentError.value(assetVersion, 'assetVersion', 'must be >= 1');
  }
  if (!isValidEditionId(editionId)) {
    throw ArgumentError.value(editionId, 'editionId', 'malformed');
  }
  return 'books/${languagePathSegment(languageTag)}/$editionId/v$assetVersion/book.json.gz';
}

({String language, String editionId, int assetVersion})? parseAssetPath(
    String path) {
  final RegExpMatch? m = assetPathPattern.firstMatch(path);
  if (m == null) return null;
  return (
    language: m.group(1)!,
    editionId: m.group(2)!,
    assetVersion: int.parse(m.group(3)!),
  );
}

/// Lower-cases, strips diacritics for the Latin range and replaces runs of
/// non-alphanumerics with `-`. Good enough for ids of Latin-script titles;
/// other scripts should be transliterated by hand.
String slugify(String text) {
  const String from = 'àáâãäåăāçćčďđèéêëěēğìíîïīłñńňòóôõöøōřśšşșťţțùúûüūůýÿžźż';
  const String to = 'aaaaaaaacccddeeeeeegiiiiilnnnoooooooorsssssttuuuuuuyyzzz';
  final StringBuffer out = StringBuffer();
  for (final int rune in text.toLowerCase().runes) {
    final String ch = String.fromCharCode(rune);
    final int i = from.indexOf(ch);
    out.write(i >= 0 ? to[i] : ch);
  }
  return out
      .toString()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
}

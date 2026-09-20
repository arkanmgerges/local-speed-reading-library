import 'dart:convert';
import 'dart:io';

/// Syntax check for a BCP 47 language tag: language, optional script,
/// optional region, optional variants. Extensions and private-use subtags
/// are rejected on purpose (they never identify a book language).
final RegExp languageTagPattern = RegExp(
    r'^[A-Za-z]{2,3}(-[A-Za-z]{4})?(-([A-Za-z]{2}|[0-9]{3}))?(-[A-Za-z0-9]{5,8}|-[0-9][A-Za-z0-9]{3})*$');

bool isWellFormedLanguageTag(String tag) => languageTagPattern.hasMatch(tag);

class LanguageInfo {
  const LanguageInfo({
    required this.code,
    required this.englishName,
    required this.nativeName,
    required this.direction,
  });

  final String code;
  final String englishName;
  final String nativeName;

  /// `ltr` or `rtl`.
  final String direction;

  Map<String, Object?> toJson() => <String, Object?>{
        'code': code,
        'englishName': englishName,
        'nativeName': nativeName,
        'direction': direction,
      };
}

/// The languages the catalogue may use (`sources/languages.json`), kept in
/// sync with the app's own registry so every catalogue language has a
/// localised name and a text direction on the device.
class LanguageRegistry {
  LanguageRegistry(Iterable<LanguageInfo> languages)
      : _byCode = <String, LanguageInfo>{
          for (final LanguageInfo l in languages) l.code.toLowerCase(): l,
        };

  factory LanguageRegistry.fromJson(Map<String, Object?> json) {
    final List<Object?> list = json['languages'] as List<Object?>;
    return LanguageRegistry(list.map((Object? e) {
      final Map<String, Object?> m = e as Map<String, Object?>;
      return LanguageInfo(
        code: m['code'] as String,
        englishName: m['englishName'] as String,
        nativeName: m['nativeName'] as String,
        direction: m['direction'] as String,
      );
    }));
  }

  static LanguageRegistry load(String file) => LanguageRegistry.fromJson(
      json.decode(File(file).readAsStringSync()) as Map<String, Object?>);

  final Map<String, LanguageInfo> _byCode;

  int get length => _byCode.length;

  LanguageInfo? operator [](String tag) => _byCode[tag.toLowerCase()];

  bool contains(String tag) => _byCode.containsKey(tag.toLowerCase());

  Iterable<LanguageInfo> get all => _byCode.values;
}

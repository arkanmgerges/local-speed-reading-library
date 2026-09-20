import 'dart:collection';
import 'dart:convert';

/// Encodes [value] as JSON with object keys sorted recursively, two-space
/// indentation, `\n` line endings and a trailing newline. Two runs on equal
/// data produce identical bytes, so file hashes are reproducible.
String canonicalJson(Object? value) =>
    '${const JsonEncoder.withIndent('  ').convert(sortJson(value))}\n';

/// Compact variant (no whitespace) used for hashing derived versions.
String compactJson(Object? value) => json.encode(sortJson(value));

/// Returns a copy of [value] where every map is a key-sorted map.
Object? sortJson(Object? value) {
  if (value is Map) {
    final SplayTreeMap<String, Object?> sorted = SplayTreeMap<String, Object?>();
    value.forEach((Object? k, Object? v) => sorted[k.toString()] = sortJson(v));
    return sorted;
  }
  if (value is List) return value.map(sortJson).toList();
  return value;
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

/// Result of compressing one canonical book JSON.
class PackagedAsset {
  const PackagedAsset({
    required this.jsonBytes,
    required this.gzipBytes,
    required this.contentSha256,
    required this.sha256,
  });

  final Uint8List jsonBytes;
  final Uint8List gzipBytes;

  /// SHA-256 of [jsonBytes] (the content identity).
  final String contentSha256;

  /// SHA-256 of [gzipBytes] (what the app verifies before decompressing).
  final String sha256;

  int get uncompressedSizeBytes => jsonBytes.length;
  int get sizeBytes => gzipBytes.length;
}

String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// gzip with a fixed header (no name, mtime 0, OS "unknown") over the
/// pure-Dart deflate, so the same input yields the same bytes on every
/// machine and platform. The stock encoders stamp the current time.
Uint8List deterministicGzip(List<int> input, {int level = 9}) {
  final Deflate deflate = Deflate(input, level: level);
  final Uint8List body = deflate.getBytes();
  final int crc = getCrc32(input);
  final BytesBuilder out = BytesBuilder(copy: false);
  out.add(<int>[0x1f, 0x8b, 0x08, 0x00]); // magic, deflate, no flags
  out.add(<int>[0, 0, 0, 0]); // mtime = 0
  out.add(<int>[0x02, 0xff]); // xfl = max compression, OS = unknown
  out.add(body);
  out.add(_le32(crc));
  out.add(_le32(input.length & 0xffffffff));
  return out.toBytes();
}

Uint8List gunzip(List<int> bytes) =>
    Uint8List.fromList(const GZipDecoder().decodeBytes(bytes, verify: true));

List<int> _le32(int v) =>
    <int>[v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];

PackagedAsset packageJson(String canonicalJson) {
  final Uint8List jsonBytes = Uint8List.fromList(utf8.encode(canonicalJson));
  final Uint8List gz = deterministicGzip(jsonBytes);
  return PackagedAsset(
    jsonBytes: jsonBytes,
    gzipBytes: gz,
    contentSha256: sha256Hex(jsonBytes),
    sha256: sha256Hex(gz),
  );
}

/// What went wrong when a downloaded asset was checked.
enum AssetProblem { sizeMismatch, checksumMismatch, notGzip, contentChecksumMismatch, notJson }

/// The app-side verification sequence, mirrored here so the pipeline and
/// its tests exercise exactly the same rules:
/// size -> sha256(compressed) -> gunzip -> sha256(content) -> JSON parse.
/// Returns the decoded JSON, or throws [AssetVerificationException].
Map<String, Object?> verifyAsset(
  List<int> downloaded, {
  required int expectedSizeBytes,
  required String expectedSha256,
  required String expectedContentSha256,
}) {
  if (downloaded.length != expectedSizeBytes) {
    throw AssetVerificationException(AssetProblem.sizeMismatch,
        'expected $expectedSizeBytes bytes, got ${downloaded.length}');
  }
  final String actual = sha256Hex(downloaded);
  if (actual != expectedSha256) {
    throw AssetVerificationException(AssetProblem.checksumMismatch,
        'expected $expectedSha256, got $actual');
  }
  final Uint8List content;
  try {
    content = gunzip(downloaded);
  } catch (e) {
    throw AssetVerificationException(AssetProblem.notGzip, '$e');
  }
  final String contentActual = sha256Hex(content);
  if (contentActual != expectedContentSha256) {
    throw AssetVerificationException(AssetProblem.contentChecksumMismatch,
        'expected $expectedContentSha256, got $contentActual');
  }
  try {
    return json.decode(utf8.decode(content)) as Map<String, Object?>;
  } catch (e) {
    throw AssetVerificationException(AssetProblem.notJson, '$e');
  }
}

class AssetVerificationException implements Exception {
  const AssetVerificationException(this.problem, this.detail);

  final AssetProblem problem;
  final String detail;

  @override
  String toString() => 'AssetVerificationException(${problem.name}: $detail)';
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:lsr_library_tools/lsr_library_tools.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  test('gzip round trip restores the canonical JSON byte for byte', () {
    final String json = sampleBook().toCanonicalJson();
    final PackagedAsset a = packageJson(json);
    expect(utf8.decode(gunzip(a.gzipBytes)), json);
    expect(a.gzipBytes.length, lessThan(a.jsonBytes.length));
  });

  test('packaging is deterministic across runs', () {
    final String json = sampleBook().toCanonicalJson();
    final PackagedAsset a = packageJson(json);
    final PackagedAsset b = packageJson(json);
    expect(a.gzipBytes, equals(b.gzipBytes));
    expect(a.sha256, b.sha256);
    expect(a.contentSha256, b.contentSha256);
    // Fixed gzip header: no mtime, no name, OS unknown.
    expect(a.gzipBytes.sublist(0, 10), <int>[0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x02, 0xff]);
  });

  test('sha256 values are lower-case hex of the right input', () {
    final PackagedAsset a = packageJson(sampleBook().toCanonicalJson());
    expect(a.sha256, matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(a.contentSha256, matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(a.sha256, isNot(a.contentSha256));
    expect(sha256Hex(utf8.encode('abc')), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  });

  test('verifyAsset accepts a good download and returns the book', () {
    final PackagedAsset a = packageJson(sampleBook().toCanonicalJson());
    final Map<String, Object?> decoded = verifyAsset(a.gzipBytes,
        expectedSizeBytes: a.sizeBytes, expectedSha256: a.sha256, expectedContentSha256: a.contentSha256);
    expect(NormalizedBook.fromJson(decoded).title, 'Amintiri din copilărie');
  });

  test('checksum mismatch is rejected before decompression', () {
    final PackagedAsset a = packageJson(sampleBook().toCanonicalJson());
    final Uint8List tampered = Uint8List.fromList(a.gzipBytes)..[a.gzipBytes.length - 1] ^= 0xff;
    expect(
      () => verifyAsset(tampered, expectedSizeBytes: a.sizeBytes, expectedSha256: a.sha256, expectedContentSha256: a.contentSha256),
      throwsA(isA<AssetVerificationException>().having((e) => e.problem, 'problem', AssetProblem.checksumMismatch)),
    );
  });

  test('a truncated download is rejected by size', () {
    final PackagedAsset a = packageJson(sampleBook().toCanonicalJson());
    expect(
      () => verifyAsset(a.gzipBytes.sublist(0, a.sizeBytes ~/ 2),
          expectedSizeBytes: a.sizeBytes, expectedSha256: a.sha256, expectedContentSha256: a.contentSha256),
      throwsA(isA<AssetVerificationException>().having((e) => e.problem, 'problem', AssetProblem.sizeMismatch)),
    );
  });

  test('a corrupted archive with a matching checksum is rejected as not gzip', () {
    final Uint8List garbage = Uint8List.fromList(List<int>.generate(100, (int i) => (i * 7) & 0xff));
    expect(
      () => verifyAsset(garbage, expectedSizeBytes: 100, expectedSha256: sha256Hex(garbage), expectedContentSha256: 'a' * 64),
      throwsA(isA<AssetVerificationException>().having((e) => e.problem, 'problem', AssetProblem.notGzip)),
    );
  });

  test('content checksum mismatch after decompression is rejected', () {
    final PackagedAsset a = packageJson(sampleBook().toCanonicalJson());
    expect(
      () => verifyAsset(a.gzipBytes, expectedSizeBytes: a.sizeBytes, expectedSha256: a.sha256, expectedContentSha256: 'b' * 64),
      throwsA(isA<AssetVerificationException>().having((e) => e.problem, 'problem', AssetProblem.contentChecksumMismatch)),
    );
  });

  test('assetDrift flags content changes for the same version and nothing for a new version', () {
    final Map<String, Object?> v1 = <String, Object?>{'assetVersion': 1, 'contentSha256': 'x', 'sha256': 'y'};
    expect(assetDrift(null, v1), isNull);
    expect(assetDrift(v1, v1), isNull);
    expect(assetDrift(v1, <String, Object?>{'assetVersion': 1, 'contentSha256': 'z', 'sha256': 'w'}), contains('bump publish.assetVersion'));
    expect(assetDrift(v1, <String, Object?>{'assetVersion': 2, 'contentSha256': 'z', 'sha256': 'w'}), isNull);
  });
}

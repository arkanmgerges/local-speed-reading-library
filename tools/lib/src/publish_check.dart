import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:lsr_library_tools/src/catalog_builder.dart';
import 'package:lsr_library_tools/src/metadata.dart';
import 'package:lsr_library_tools/src/packaging.dart';
import 'package:lsr_library_tools/src/rights_policy.dart';

enum RemoteState { missing, identical, different, unreachable }

class AssetRemoteStatus {
  const AssetRemoteStatus(this.editionId, this.path, this.state, [this.detail = '']);

  final String editionId;
  final String path;
  final RemoteState state;
  final String detail;

  @override
  String toString() => '${state.name.padRight(11)} $path${detail.isEmpty ? '' : '  ($detail)'}';
}

/// Compares the local build with what the CDN serves. Immutable assets
/// that already exist must be byte-identical; a difference is a hard
/// failure because `v<N>` is never overwritten.
class PublishCheck {
  PublishCheck({required this.baseUrl, http.Client? client}) : _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  Future<List<AssetRemoteStatus>> checkAssets(List<BookMetadata> editions, RightsPolicy policy) async {
    final List<AssetRemoteStatus> out = <AssetRemoteStatus>[];
    for (final BookMetadata m in editions) {
      if (!isPublishable(m, policy)) continue;
      final String path = m.assetPathValue!;
      final Uri uri = Uri.parse('$baseUrl$path');
      try {
        final http.Response head = await _client.head(uri);
        if (head.statusCode == 404) {
          out.add(AssetRemoteStatus(m.editionId, path, RemoteState.missing));
          continue;
        }
        if (head.statusCode != 200) {
          out.add(AssetRemoteStatus(m.editionId, path, RemoteState.unreachable, 'HTTP ${head.statusCode}'));
          continue;
        }
        final http.Response body = await _client.get(uri);
        final String remote = sha256Hex(body.bodyBytes);
        out.add(remote == m.assetSha256
            ? AssetRemoteStatus(m.editionId, path, RemoteState.identical)
            : AssetRemoteStatus(m.editionId, path, RemoteState.different, 'remote sha256 $remote, local ${m.assetSha256}'));
      } catch (e) {
        out.add(AssetRemoteStatus(m.editionId, path, RemoteState.unreachable, '$e'));
      }
    }
    return out;
  }

  /// `catalogVersion` served right now, or null when absent/unreachable.
  Future<String?> remoteCatalogVersion() async {
    try {
      final http.Response r = await _client.get(Uri.parse('${baseUrl}catalog/catalog.json'));
      if (r.statusCode != 200) return null;
      return (json.decode(r.body) as Map<String, Object?>)['catalogVersion'] as String?;
    } catch (_) {
      return null;
    }
  }
}

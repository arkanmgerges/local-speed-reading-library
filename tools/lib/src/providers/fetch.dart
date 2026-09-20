import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

const String userAgent =
    'lsr-library-tools/0.1 (+https://github.com/arkanmgerges/local-speed-reading-library)';

const Duration fetchTimeout = Duration(seconds: 60);

class FetchException implements Exception {
  const FetchException(this.message);
  final String message;
  @override
  String toString() => 'FetchException: $message';
}

/// GET/HEAD with an identifying User-Agent, redirects, a timeout and three
/// attempts with back-off for 5xx/429/network errors. Providers are shared
/// public services; the tool never hammers them.
Future<http.Response> fetchWithRetry(http.Client client, Uri uri,
    {String method = 'GET', int attempts = 3}) async {
  Object? last;
  for (int i = 1; i <= attempts; i++) {
    try {
      final http.Request req = http.Request(method, uri)
        ..headers['user-agent'] = userAgent
        ..followRedirects = true
        ..maxRedirects = 5;
      final http.StreamedResponse s = await client.send(req).timeout(fetchTimeout);
      final http.Response r = await http.Response.fromStream(s).timeout(fetchTimeout);
      if (r.statusCode == 200) return r;
      if (r.statusCode == 429 || r.statusCode >= 500) {
        last = FetchException('HTTP ${r.statusCode} for $uri');
      } else {
        throw FetchException('HTTP ${r.statusCode} for $uri');
      }
    } on TimeoutException catch (e) {
      last = e;
    } on SocketException catch (e) {
      last = e;
    } on http.ClientException catch (e) {
      last = e;
    }
    if (i < attempts) await Future<void>.delayed(Duration(seconds: 2 * i));
  }
  throw FetchException('giving up on $uri after $attempts attempts: $last');
}

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:lsr_library_tools/src/providers/fetch.dart';

/// MediaWiki API client for one Wikisource site (e.g. `ro.wikisource.org`).
///
/// Text is taken from `action=parse` with an explicit `oldid`, so a pinned
/// revision always renders the same wikitext; the live page is only used
/// to *discover* revisions and subpages (`lsr pin`).
class WikisourceClient {
  WikisourceClient(this.site, {http.Client? client})
      : _client = client ?? http.Client();

  final String site;
  final http.Client _client;

  Uri get _api => Uri.https(site, '/w/api.php');

  /// Current revision ids of [titles]; missing pages are absent from the map.
  Future<Map<String, int>> latestRevisions(List<String> titles) async {
    final Map<String, int> out = <String, int>{};
    // Ten titles per request: non-Latin titles percent-encode to long URLs
    // and fifty of them exceed the API's URL limit (HTTP 414).
    const int per = 10;
    for (int i = 0; i < titles.length; i += per) {
      final List<String> batch = titles.sublist(i, i + per > titles.length ? titles.length : i + per);
      final Map<String, Object?> json = await _get(<String, String>{
        'action': 'query',
        'prop': 'info',
        'titles': batch.join('|'),
      });
      final Map<String, Object?> query = json['query'] as Map<String, Object?>;
      for (final Object? page in query['pages'] as List<Object?>) {
        final Map<String, Object?> m = page as Map<String, Object?>;
        final int? rev = m['lastrevid'] as int?;
        if (rev != null) out[m['title'] as String] = rev;
      }
    }
    return out;
  }

  /// Rendered HTML of one page, at [oldid] when given.
  Future<({String html, int revid, String title})> parse(String title, {int? oldid}) async {
    final Map<String, Object?> json = await _get(<String, String>{
      'action': 'parse',
      'prop': 'text|revid|displaytitle',
      'disabletoc': '1',
      'disableeditsection': '1',
      'disablelimitreport': '1',
      if (oldid != null) 'oldid': '$oldid' else 'page': title,
    });
    final Map<String, Object?> parse = json['parse'] as Map<String, Object?>;
    return (
      html: parse['text'] as String,
      revid: parse['revid'] as int,
      title: parse['title'] as String,
    );
  }

  /// Subpages of [title] linked from [mainHtml], in document order
  /// (`Title/Chapter 1`, `Title/Chapter 2`, ...).
  static List<String> discoverSubpages(String mainHtml, String title) {
    final String prefix = '/wiki/${Uri.encodeComponent(title.replaceAll(' ', '_'))}/';
    final RegExp href = RegExp('href="(/wiki/[^"#?]+)"');
    final List<String> out = <String>[];
    for (final RegExpMatch m in href.allMatches(mainHtml)) {
      final String raw = m.group(1)!;
      if (!raw.startsWith(prefix) && !Uri.decodeComponent(raw).startsWith('/wiki/$title/'.replaceAll(' ', '_'))) continue;
      final String page = Uri.decodeComponent(raw.substring('/wiki/'.length)).replaceAll('_', ' ');
      if (!out.contains(page)) out.add(page);
    }
    return out;
  }

  Future<Map<String, Object?>> _get(Map<String, String> params) async {
    final Uri uri = _api.replace(queryParameters: <String, String>{
      ...params,
      'format': 'json',
      'formatversion': '2',
    });
    final http.Response r = await fetchWithRetry(_client, uri);
    final Map<String, Object?> json = jsonDecode(r.body) as Map<String, Object?>;
    if (json.containsKey('error')) {
      throw FetchException('MediaWiki error for $uri: ${json['error']}');
    }
    return json;
  }
}

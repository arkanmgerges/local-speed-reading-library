import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:lsr_library_tools/src/providers/fetch.dart';

/// Project Gutenberg: one EPUB (no images) per ebook number. Gutenberg asks
/// robots not to crawl; this client fetches single, explicitly listed books
/// and identifies itself.
class GutenbergClient {
  GutenbergClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static Uri epubUrl(String ebookNumber) =>
      Uri.https('www.gutenberg.org', '/ebooks/$ebookNumber.epub.noimages');

  static Uri landingUrl(String ebookNumber) =>
      Uri.https('www.gutenberg.org', '/ebooks/$ebookNumber');

  /// The EPUB bytes and the `Last-Modified` header, which is the closest
  /// thing Gutenberg offers to a revision id.
  Future<({Uint8List bytes, String? lastModified, Uri finalUrl})> fetchEpub(
      String ebookNumber) async {
    final http.Response r = await fetchWithRetry(_client, epubUrl(ebookNumber));
    final String? type = r.headers['content-type'];
    if (type != null && type.contains('text/html')) {
      throw FetchException('Gutenberg returned HTML instead of an EPUB for #$ebookNumber');
    }
    return (
      bytes: r.bodyBytes,
      lastModified: r.headers['last-modified'],
      finalUrl: r.request?.url ?? epubUrl(ebookNumber),
    );
  }

  /// Only the headers: used by `lsr pin`.
  Future<String?> lastModified(String ebookNumber) async {
    final http.Response r = await fetchWithRetry(_client, epubUrl(ebookNumber), method: 'HEAD');
    return r.headers['last-modified'];
  }
}

/// Text that must never survive normalisation of a Gutenberg book: the
/// licence boilerplate and trademark mentions are stripped, attribution
/// lives in the provenance record instead.
final RegExp gutenbergBoilerplate = RegExp(
  r'project gutenberg|\*\*\* ?(start|end) of th(e|is)|www\.gutenberg\.org|gutenberg literary archive|pglaf\.org',
  caseSensitive: false,
);

/// Transcriber remarks that belong to the e-text, not to the work.
final RegExp gutenbergTranscriberNotes = RegExp(
  r'(e-?text|transcriber|this ebook|hovering the mouse|clicking the thumbnail)|^corrections made',
  caseSensitive: false,
);

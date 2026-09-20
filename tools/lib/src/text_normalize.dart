import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// Characters that carry no meaning for a reader and would otherwise leak
/// into words: zero-width space, BOM/ZWNBSP, soft hyphen, word joiner.
/// ZWNJ (U+200C) and ZWJ (U+200D) are kept: they are part of correct
/// Persian, Arabic and Indic spelling.
final RegExp _invisible = RegExp('[​﻿­⁠]');

/// Space-like characters folded to a plain space so word splitting on
/// whitespace behaves the same everywhere.
final RegExp _oddSpaces = RegExp('[    - 　\t]+');

final RegExp _spaceRuns = RegExp(' {2,}');
final RegExp _lineEdges = RegExp(r'^ +| +$', multiLine: true);
final RegExp _blankRuns = RegExp(r'\n{2,}');

/// Canonical form of one paragraph: Unicode NFC, plain spaces, single
/// spaces between words, no leading/trailing space on any line, at most one
/// line break in a row (verse keeps its line breaks). Direction marks and
/// bidi controls are left untouched.
String normalizeParagraph(String text) {
  String t = unorm.nfc(text);
  t = t.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  t = t.replaceAll(_invisible, '');
  t = t.replaceAll(_oddSpaces, ' ');
  t = t.replaceAll(_spaceRuns, ' ');
  t = t.replaceAll(_lineEdges, '');
  t = t.replaceAll(_blankRuns, '\n');
  return t.trim();
}

/// Splits a block of text into paragraphs at blank lines and normalises
/// each one; empty results are dropped.
List<String> paragraphsFromText(String text) {
  final String unix = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  return unix
      .split(RegExp(r'\n[ \t]*\n'))
      .map(normalizeParagraph)
      .where((String p) => p.isNotEmpty)
      .toList();
}

/// Words as the app counts them: runs of non-whitespace.
int countWords(String text) =>
    RegExp(r'\S+', unicode: true).allMatches(text).length;

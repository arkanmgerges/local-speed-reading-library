// Discovers public-domain candidates for every catalogue language and writes
// their metadata files, ready for `lsr pin`, `lsr build` and review.
//
//   dart run bin/discover.dart --rdf <dir with cache/epub/*/pg*.rdf> \
//       [--languages fi,ro] [--per-language 20] [--overshoot 12] \
//       [--report build/discover-report.json] [--write]
//
// Two sources:
//
// * Project Gutenberg, from the offline RDF catalogue (rdf-files.tar.bz2):
//   creators, translators and other contributors with their death years,
//   download counts (the ranking), subjects and bookshelves (genres and
//   exclusions). The first-publication year of an original comes from the
//   Wikidata item behind the "Wikipedia page about this book" link; a
//   translation needs an imprint year in the MARC 260 field.
// * Wikisource, from Wikidata: works written in the language whose author died
//   early enough and whose first publication is recorded, ranked by the
//   number of sitelinks (a fame proxy); translations only when the
//   translator and the translation year are recorded.
//
// Everything the rights policy needs is taken from the provider or Wikidata
// and cited in `rights.evidence`; nothing is guessed. Editions the policy
// cannot prove are simply not written. Quality gates (word count, chapters)
// are applied after `lsr build` by scripts/prune-short.sh.
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:http/http.dart' as http;
import 'package:lsr_library_tools/lsr_library_tools.dart';
import 'package:path/path.dart' as p;

const String _today = '2026-09-21';
const String _verifiedBy = 'arkanmgerges';
const String _discoveryNote =
    'Batch import: death years from the provider agent records and Wikidata, '
    'publication year from the cited Wikidata item or the imprint recorded by the provider; '
    'checked by the rights policy in tools/lib/src/rights_policy.dart.';

Future<void> main(List<String> argv) async {
  final ArgParser parser = ArgParser()
    ..addOption('rdf', help: 'Directory holding the extracted Gutenberg RDF catalogue.')
    ..addOption('languages', help: 'Comma-separated catalogue languages (default: all).')
    ..addOption('per-language', defaultsTo: '20')
    ..addOption('overshoot', defaultsTo: '12', help: 'Extra candidates per language for build failures.')
    ..addOption('report', help: 'Write a JSON report here.')
    ..addOption('cache', help: 'Directory for cached Wikidata responses.')
    ..addOption('year', defaultsTo: '${DateTime.now().year}')
    ..addFlag('write', help: 'Write metadata files (otherwise only report).')
    ..addFlag('gutenberg', defaultsTo: true)
    ..addFlag('wikisource', defaultsTo: true);
  final ArgResults args = parser.parse(argv);

  final LibraryRepo repo = LibraryRepo.locate();
  final LanguageRegistry registry = LanguageRegistry.load(repo.languagesRegistryFile);
  final RightsPolicy policy = RightsPolicy(currentYear: int.parse(args['year'] as String));
  final int perLanguage = int.parse(args['per-language'] as String);
  final int overshoot = int.parse(args['overshoot'] as String);
  final int target = perLanguage + overshoot;
  final List<String> languages = (args['languages'] as String?)?.split(',') ??
      registry.all.map((LanguageInfo l) => l.code).toList();
  final String cacheDir = (args['cache'] as String?) ?? p.join(repo.buildDir, 'discover-cache');
  Directory(cacheDir).createSync(recursive: true);

  final Wikidata wd = Wikidata(cacheDir);
  final Existing existing = Existing.load(repo);
  final File rejectedFile = File(p.join(repo.buildDir, 'rejected-editions.txt'));
  if (rejectedFile.existsSync()) {
    int n = 0;
    for (final String line in rejectedFile.readAsLinesSync()) {
      final ({String workId, String language, String slug})? parts = parseEditionId(line.trim());
      if (parts == null) continue;
      existing.reject(parts.workId, parts.language);
      n++;
    }
    stdout.writeln('skipping $n edition(s) rejected by earlier rounds');
  }

  GutenbergCatalog? pg;
  if (args['gutenberg'] as bool) {
    final String? rdfDir = args['rdf'] as String?;
    if (rdfDir == null) {
      stderr.writeln('--rdf is required unless --no-gutenberg');
      exit(64);
    }
    stdout.writeln('reading RDF catalogue from $rdfDir ...');
    pg = GutenbergCatalog.load(rdfDir, cacheFile: p.join(cacheDir, 'pg-books.json'));
    stdout.writeln('  ${pg.books.length} text ebooks');
  }

  final Map<String, Object?> report = <String, Object?>{};
  int writtenTotal = 0;
  for (final String lang in languages) {
    final LanguageInfo? info = registry[lang];
    if (info == null) {
      stderr.writeln('unknown language $lang');
      continue;
    }
    stdout.writeln('== $lang (${info.englishName})');
    final List<Candidate> chosen = <Candidate>[];
    final Map<String, Object?> langReport = <String, Object?>{};
    List<Candidate>? wsCandidates;

    if (args['wikisource'] as bool) {
      try {
        final List<Candidate> ws = await discoverWikisource(lang, wd, policy);
        wsCandidates = ws;
        langReport['wikisourceFound'] = ws.length;
        // Wikisource takes at most half the slots when Gutenberg can fill the
        // rest: EPUBs are the more reliable import and carry the popular titles.
        final int wsCap = pg != null && gutenbergCodes(lang).isNotEmpty ? (target + 1) ~/ 2 : target;
        for (final Candidate c in ws) {
          if (chosen.length >= wsCap) break;
          if (existing.has(c.workId, lang) || existing.isBundledTitle(c.title, c.authorName)) continue;
          if (chosen.any((Candidate o) => o.workId == c.workId)) continue;
          chosen.add(c);
        }
        stdout.writeln('  wikisource: ${ws.length} candidates, ${chosen.length} taken');
      } catch (e) {
        stderr.writeln('  wikisource discovery failed for $lang: $e');
        langReport['wikisourceError'] = '$e';
      }
    }

    if (pg != null && chosen.length < target) {
      final int before = chosen.length;
      final GutenbergDiscovery g = await discoverGutenberg(lang, pg, wd, policy, existing, chosen, target);
      langReport['gutenbergInLanguage'] = g.inLanguage;
      langReport['gutenbergAfterFilters'] = g.afterFilters;
      langReport['gutenbergExamined'] = g.examined;
      langReport['gutenbergNoYear'] = g.noYear;
      stdout.writeln('  gutenberg: ${g.inLanguage} in language, ${g.afterFilters} pass the agent/genre filters, '
          '${g.examined} examined, ${chosen.length - before} taken (${g.noYear} without a publication year)');
    }

    // Top up from Wikisource when Gutenberg could not fill the remaining slots.
    if (wsCandidates != null && chosen.length < target) {
      for (final Candidate c in wsCandidates) {
        if (chosen.length >= target) break;
        if (existing.has(c.workId, lang) || existing.isBundledTitle(c.title, c.authorName)) continue;
        if (chosen.any((Candidate o) => o.workId == c.workId)) continue;
        chosen.add(c);
      }
    }

    langReport['chosen'] = chosen.map((Candidate c) => c.summary()).toList();
    langReport['chosenCount'] = chosen.length;
    report[lang] = langReport;
    if (args['write'] as bool) {
      for (final Candidate c in chosen) {
        final BookMetadata m = c.toMetadata(lang, policy);
        final RightsVerdict v = policy.evaluate(m);
        if (!v.publishable) {
          stderr.writeln('  BUG: ${m.editionId} fails the policy after discovery: ${v.reasons.join('; ')}');
          continue;
        }
        final File f = File(repo.metadataFile(lang, m.editionId));
        if (f.existsSync()) continue;
        f.parent.createSync(recursive: true);
        f.writeAsStringSync(m.toCanonicalJson());
        existing.add(m.workId, lang, m.editionId);
        writtenTotal++;
      }
    }
  }
  if (args['report'] != null) {
    File(args['report'] as String)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(canonicalJson(report));
  }
  stdout.writeln('done: $writtenTotal metadata files written');
  wd.close();
}

// ---------------------------------------------------------------------------
// Candidates

class Person {
  Person({required this.name, this.birthYear, this.deathYear, this.wikidata});
  final String name;
  final int? birthYear;
  final int? deathYear;
  String? wikidata;

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        if (birthYear != null) 'birthYear': birthYear,
        if (deathYear != null) 'deathYear': deathYear,
        if (wikidata != null) 'wikidata': wikidata,
      };
}

class Candidate {
  Candidate({
    required this.provider,
    required this.workId,
    required this.editionSlug,
    required this.title,
    required this.originalTitle,
    required this.originalLanguage,
    required this.author,
    required this.translator,
    required this.originalPublicationYear,
    required this.editionPublicationYear,
    required this.translationPublicationYear,
    required this.source,
    required this.genres,
    required this.evidence,
    required this.basis,
    required this.statement,
    required this.rank,
    this.notes,
  });

  final String provider;
  final String workId;
  final String editionSlug;
  final String title;
  final String originalTitle;
  final String originalLanguage;
  final Person author;
  final Person? translator;
  final int? originalPublicationYear;
  final int? editionPublicationYear;
  final int? translationPublicationYear;
  final Map<String, Object?> source;
  final List<String> genres;
  final List<String> evidence;
  final List<String> basis;
  final String statement;
  final num rank;
  final String? notes;

  String get authorName => author.name;
  bool get isTranslation => translator != null;

  Map<String, Object?> summary() => <String, Object?>{
        'provider': provider,
        'workId': workId,
        'title': title,
        'author': author.name,
        if (translator != null) 'translator': translator!.name,
        'rank': rank,
        'year': isTranslation ? translationPublicationYear : (originalPublicationYear ?? editionPublicationYear),
        'source': source['url'],
      };

  BookMetadata toMetadata(String lang, RightsPolicy policy) {
    final String editionId = '$workId.${languagePathSegment(lang)}.$editionSlug';
    final Map<String, Object?> raw = <String, Object?>{
      'schemaVersion': 1,
      'work': <String, Object?>{
        'workId': workId,
        'originalTitle': originalTitle,
        'originalLanguage': originalLanguage,
        'author': author.toJson(),
        if (originalPublicationYear != null) 'originalPublicationYear': originalPublicationYear,
      },
      'edition': <String, Object?>{
        'editionId': editionId,
        'language': lang,
        'title': title,
        'kind': isTranslation ? 'translation' : 'original',
        if (translator != null) 'translator': translator!.toJson(),
        if (editionPublicationYear != null) 'editionPublicationYear': editionPublicationYear,
        if (translationPublicationYear != null) 'translationPublicationYear': translationPublicationYear,
        if (notes != null) 'notes': notes,
      },
      'source': source,
      'rights': <String, Object?>{
        'status': 'public-domain',
        'basis': basis,
        'jurisdictions': <String>['worldwide-conservative'],
        'statement': statement,
        'evidence': evidence,
        'verifiedBy': _verifiedBy,
        'verifiedAt': _today,
        'notes': _discoveryNote,
      },
      'genres': genres,
      'publish': <String, Object?>{'assetVersion': 1},
    };
    return BookMetadata(raw);
  }
}

/// Editions already in the repository and titles bundled with the app, so
/// the catalogue does not offer the same book twice.
class Existing {
  Existing(this._workIds, this._bundled);

  final Set<String> _workIds; // "<workId>@<lang>"
  final List<({String title, String author})> _bundled;

  static Existing load(LibraryRepo repo) {
    final Set<String> ids = <String>{};
    for (final File f in repo.metadataFiles()) {
      final BookMetadata m = BookMetadata.read(f);
      ids.add('${m.workId}@${m.language}');
    }
    return Existing(ids, _bundledTitles);
  }

  bool has(String workId, String lang) => _workIds.contains('$workId@$lang') || _rejected.contains('$workId@${languagePathSegment(lang)}');
  final Set<String> _rejected = <String>{};
  void reject(String workId, String langSegment) => _rejected.add('$workId@$langSegment');
  void add(String workId, String lang, String editionId) => _workIds.add('$workId@$lang');

  bool isBundledTitle(String title, String author) {
    final String t = _fold(title);
    final String a = _fold(author);
    for (final ({String title, String author}) b in _bundled) {
      if (_fold(b.title) == t && a.contains(_fold(b.author).split(' ').last)) return true;
    }
    return false;
  }

  static String _fold(String s) => slugify(s).replaceAll('-', ' ');
}

/// Books the app ships in its assets (lib/model/book_catalogue.dart).
const List<({String title, String author})> _bundledTitles = <({String title, String author})>[
  (title: 'Craii de Curtea Veche', author: 'Mateiu Caragiale'),
  (title: 'O Moarte care nu Dovedeşte Nimic', author: 'Anton Holban'),
  (title: 'Ioana', author: 'Anton Holban'),
  (title: 'Moara cu Noroc', author: 'Ioan Slavici'),
  (title: 'Mara', author: 'Ioan Slavici'),
  (title: 'Cezara', author: 'Mihai Eminescu'),
  (title: 'Adela', author: 'Garabet Ibrăileanu'),
  (title: 'La Aniversară', author: 'Mihai Eminescu'),
  (title: 'Sărmanul Dionis', author: 'Mihai Eminescu'),
  (title: 'Amintiri din Copilărie', author: 'Ion Creangă'),
  (title: 'Viața la Țară', author: 'Duiliu Zamfirescu'),
  (title: 'Inimi Cicatrizate', author: 'Max Blecher'),
  (title: 'Jocurile Daniei', author: 'Anton Holban'),
  (title: 'Un Român în Lună', author: 'Henri Stahl'),
  (title: 'Birds and Man', author: 'W. H. Hudson'),
  (title: 'Child of Storm', author: 'H. Rider Haggard'),
  (title: "King Solomon's Mines", author: 'H. Rider Haggard'),
  (title: 'Winds of the World', author: 'Talbot Mundy'),
  (title: 'Bacon', author: 'R. W. Church'),
  (title: 'Queen Victoria', author: 'Lytton Strachey'),
  (title: 'Eminent Victorians', author: 'Lytton Strachey'),
  (title: 'Real Soldiers of Fortune', author: 'Richard Harding Davis'),
  (title: 'The Life of Froude', author: 'Herbert Paul'),
  (title: 'Ancient Man', author: 'Hendrik Willem van Loon'),
  (title: 'Ten Great Events in History', author: 'James Johonnot'),
  (title: 'Ancient Egypt', author: 'George Rawlinson'),
  (title: 'The Story of the Greeks', author: 'H. A. Guerber'),
  (title: 'The Story of Ireland', author: 'Emily Lawless'),
  (title: 'Days of the Discoverers', author: 'L. Lamprey'),
  (title: 'A Field Book of the Stars', author: 'William Tyler Olcott'),
  (title: 'In New England Fields and Woods', author: 'Rowland E. Robinson'),
];

// ---------------------------------------------------------------------------
// Identifiers

/// `<surname>-<title words>`; falls back to [fallback] when the text has no
/// Latin letters (other scripts are not transliterated).
String makeWorkId(String authorSurname, String title, String fallback) {
  String titleSlug = slugify(_stripSubtitle(title));
  final List<String> words = titleSlug.split('-').where((String w) => w.isNotEmpty).toList();
  if (words.length > 7) titleSlug = words.sublist(0, 7).join('-');
  final String surname = slugify(authorSurname);
  final String id = <String>[if (surname.isNotEmpty) surname, if (titleSlug.isNotEmpty) titleSlug].join('-');
  if (id.isEmpty || !isValidWorkId(id) || titleSlug.isEmpty) {
    final String fb = slugify(fallback);
    final String alt = <String>[if (surname.isNotEmpty) surname, fb].join('-');
    return isValidWorkId(alt) ? alt : fb;
  }
  return id;
}

String _stripSubtitle(String title) {
  final int i = title.indexOf(RegExp(r'[:;]|\s[-–—]\s|\sor,\s'));
  return (i > 0 ? title.substring(0, i) : title).trim();
}

/// "Surname, Given, extra" -> "Surname".
String surnameOf(String name) => name.split(',').first.trim();

/// "Surname, Given (Extra)" -> "Given Surname".
String displayName(String name) {
  final List<String> parts = name.split(',').map((String s) => s.trim()).toList();
  if (parts.length < 2) return name.trim();
  String given = parts[1].replaceAll(RegExp(r'\s*\([^)]*\)'), '').trim();
  if (given.isEmpty) return parts[0];
  return '$given ${parts[0]}';
}

// ---------------------------------------------------------------------------
// Genres and exclusions

final RegExp _excludedSubject = RegExp(
    r'poetry|poems|drama|plays|periodicals|dictionar|encyclopedi|songs|hymns|verse|opera|libretto|'
    r'sheet music|catalogs|bibliograph|almanac|comic books|pictorial works|readers|textbooks|'
    r'grammar|phrase books|vocabular|directories|indexes|handbooks, manuals|'
    r'religio|theolog|sermons|devotion|liturg|prayer|catechism|scripture|bible|gospel|testament|'
    r'koran|quran|hadith|torah|talmud|kabbala|christian life|church|clergy|saints|hagiograph|'
    r'vedas|upanishad|purana|bhagavad|buddhis|sutra|hindu|islam|judaism|missions|spiritual',
    caseSensitive: false);

final RegExp _excludedTitle = RegExp(
    r'\b(poems?|poetry|poesie|poésies?|poesías?|poesias|gedichte|gedichten|runoja|runot|runoelmia|dikter|digte|'
    r'wiersze|versos?|versuri|sonnets?|drama|tragedy|comedy|libretto|index|dictionary|glossary|'
    r'vol\.?\s*(ii|iii|iv|v|vi|[2-9]|1[0-9])|volume\s+(ii|iii|iv|v|vi|[2-9]|1[0-9])|'
    r'part\s+(ii|iii|iv|v|vi|[2-9])|tome\s+(ii|iii|iv|v|vi|[2-9])|band\s+[2-9]|'
    r'deel\s+[2-9]|tomo\s+(ii|iii|iv|[2-9])|osa\s+[2-9]|del\s+[2-9]|zweiter band|dritter band|'
    r'(nide|bind|teil|tom|tomul|volumul|partea|kniha|kotet|libro|livre)\.?\s*(ii|iii|iv|v|vi|vii|viii|ix|[2-9]|1[0-9])|'
    r'\s(ii|iii|iv|[2-9])$|\s\((ii|iii|iv|[2-9])\)$|\bv\.\s*([2-9]|\d\d)/\d+|'
    r'catalogue|catalog|bibliography|magazine|gazette|journal|bulletin|proceedings|'
    r'the bible|bible|new testament|old testament|koran|quran|'
    r'complete works|collected works|works of|selected works|sämtliche werke)\b',
    caseSensitive: false);

/// Wikidata classes never offered (verse, stage, songs, documents, lists).
const Set<String> _excludedWikidataTypes = <String>{
  'Q179461', // religious text
  'Q60797', // sermon
  'Q208628', // hagiography
  'Q31191135', // manaqib
  'Q335414', // tafsir
  'Q5185279', // poem
  'Q482', // poetry
  'Q12106333', // poetry collection
  'Q37484', // epic poem
  'Q80056', // sonnet
  'Q25379', // play
  'Q7366', // song
  'Q484692', // hymn
  'Q23691', // national anthem
  'Q861911', // speech
  'Q133492', // letter
  'Q40953', // prayer
  'Q7755', // constitution
  'Q131569', // treaty
  'Q7748', // law
  'Q2571972', // declaration
  'Q1266946', // thesis
  'Q13442814', // scholarly article
  'Q41298', // magazine
  'Q1002697', // periodical
  'Q11032', // newspaper
  'Q23833686', // list
  'Q4167410', // disambiguation page
  'Q20202269', // music score
  'Q207628', // musical composition
  'Q2088357', // musical ensemble (junk guard)
  'Q1004', // comics
  'Q35760', // essay (usually short)
  'Q49084', // short story (too short on its own)
  'Q40831', // comedy
  'Q80930', // tragedy
  'Q25372', // drama
  'Q182357', // lyric poetry
  'Q116476516', // dramatic work
  'Q1760610', // comic book
};

const Set<String> _allowedDespiteExclusion = <String>{};

const Set<String> _narrativeTypes = <String>{
  'Q8261', // novel
  'Q149537', // novella
  'Q1279564', // short story collection
  'Q1667921', // novel series
  'Q12132683', // novel sequence
  'Q1318295', // narrative
  'Q35127', // fairy tale (collections)
};

List<String> genresFromGutenberg(List<String> subjects, List<String> bookshelves, List<String> lcc) {
  final Set<String> out = <String>{};
  final String all = <String>[...subjects, ...bookshelves].join(' | ').toLowerCase();
  if (all.contains('fiction') || all.contains('novels') || all.contains('romance') || all.contains('tales')) {
    out.add('Fiction');
  }
  if (all.contains('juvenile') || all.contains("children's")) out.add('Children');
  if (all.contains('biography') || all.contains('autobiography') || all.contains('memoir') ||
      all.contains('diaries') || lcc.any((String c) => c.startsWith('CT'))) {
    out.add('Biography');
  }
  if (all.contains('history') || lcc.any((String c) => RegExp(r'^[DEF]').hasMatch(c))) out.add('History');
  if (lcc.any((String c) => RegExp(r'^(Q|R|S|T)').hasMatch(c)) || all.contains('science')) out.add('Science');
  if (lcc.any((String c) => RegExp(r'^(B|BC|BD|BH|BJ)$').hasMatch(c)) || all.contains('philosophy') ||
      all.contains('ethics')) {
    out.add('Philosophy');
  }
  if (out.isEmpty || (!out.contains('Fiction') && !out.contains('Children'))) {
    if (!out.contains('Fiction')) out.add('Non-fiction');
  }
  if (out.contains('Non-fiction') && out.length > 1 && !out.contains('Fiction')) {
    // keep Non-fiction plus the specific label
  }
  return out.toList();
}

List<String> genresFromWikidata(Set<String> types, Set<String> genres) {
  final Set<String> out = <String>{};
  if (types.any(_narrativeTypes.contains) || genres.any(_fictionGenres.contains)) {
    out.add('Fiction');
  }
  if (types.contains('Q4184') || types.contains('Q112983') || genres.contains('Q4184') ||
      genres.contains('Q112983')) {
    out.add('Biography');
  }
  if (genres.contains('Q131539') || types.contains('Q131539')) out.add('Children');
  if (genres.contains('Q5891') || genres.contains('Q1791899')) out.add('Philosophy');
  if (genres.contains('Q309') || types.contains('Q1367163') || types.contains('Q185363')) out.add('History');
  if (out.isEmpty) out.add('Other'); // unknown kind of prose: the app can still shelve it
  return out.toList();
}

const Set<String> _fictionGenres = <String>{
  'Q8261', 'Q149537', 'Q1279564', 'Q1233720', 'Q3374956', 'Q52369', 'Q2358', 'Q192239', 'Q24925', 'Q8253', 'Q1194480',
  'Q1544710', 'Q3230612', 'Q1420115', 'Q1362222', 'Q182015', 'Q166936', 'Q188473', 'Q5937792', 'Q186424', 'Q1345788',
};

// ---------------------------------------------------------------------------
// Project Gutenberg (offline RDF catalogue)

class PgAgent {
  PgAgent({required this.name, this.birth, this.death, required this.webpages});
  final String name;
  final int? birth;
  final int? death;
  final List<String> webpages;

  Map<String, Object?> toJson() => <String, Object?>{'n': name, 'b': birth, 'd': death, 'w': webpages};
  static PgAgent fromJson(Map<String, Object?> m) => PgAgent(
      name: m['n'] as String,
      birth: m['b'] as int?,
      death: m['d'] as int?,
      webpages: (m['w'] as List<Object?>).cast<String>());
}

class PgBook {
  PgBook({
    required this.number,
    required this.title,
    required this.language,
    required this.downloads,
    required this.authors,
    required this.translators,
    required this.others,
    required this.subjects,
    required this.lcc,
    required this.bookshelves,
    required this.aboutLinks,
    required this.alternative,
    required this.marc260,
  });
  final int number;
  final String title;
  final String language;
  final int downloads;
  final List<PgAgent> authors;
  final List<PgAgent> translators;
  final List<PgAgent> others;
  final List<String> subjects;
  final List<String> lcc;
  final List<String> bookshelves;
  final List<String> aboutLinks;
  final String? alternative;
  final String? marc260;

  Map<String, Object?> toJson() => <String, Object?>{
        'n': number,
        't': title,
        'l': language,
        'dl': downloads,
        'a': authors.map((PgAgent a) => a.toJson()).toList(),
        'tr': translators.map((PgAgent a) => a.toJson()).toList(),
        'o': others.map((PgAgent a) => a.toJson()).toList(),
        's': subjects,
        'c': lcc,
        'sh': bookshelves,
        'ab': aboutLinks,
        'alt': alternative,
        'm': marc260,
      };

  static PgBook fromJson(Map<String, Object?> m) {
    List<PgAgent> agents(String k) =>
        (m[k] as List<Object?>).map((Object? e) => PgAgent.fromJson(e as Map<String, Object?>)).toList();
    List<String> strings(String k) => (m[k] as List<Object?>).cast<String>();
    return PgBook(
      number: m['n'] as int,
      title: m['t'] as String,
      language: m['l'] as String,
      downloads: m['dl'] as int,
      authors: agents('a'),
      translators: agents('tr'),
      others: agents('o'),
      subjects: strings('s'),
      lcc: strings('c'),
      bookshelves: strings('sh'),
      aboutLinks: strings('ab'),
      alternative: m['alt'] as String?,
      marc260: m['m'] as String?,
    );
  }
}

class GutenbergCatalog {
  GutenbergCatalog(this.books);
  final List<PgBook> books;

  static final RegExp _agentBlock = RegExp(
      r'<(dcterms:creator|marcrel:[a-z]{3})>\s*<pgterms:agent rdf:about="([^"]+)">(.*?)</pgterms:agent>\s*</\1>',
      dotAll: true);
  static final RegExp _agentRef = RegExp(r'<(dcterms:creator|marcrel:[a-z]{3}) rdf:resource="([^"]+)"/>');
  static final RegExp _langValue = RegExp(r'RFC4646">([^<]+)</rdf:value>');
  static final RegExp _title = RegExp(r'<dcterms:title>([^<]*)</dcterms:title>');
  static final RegExp _alt = RegExp(r'<dcterms:alternative>([^<]*)</dcterms:alternative>');
  static final RegExp _downloads = RegExp(r'<pgterms:downloads[^>]*>(\d+)<');
  static final RegExp _subject = RegExp(
      r'<dcterms:subject>\s*<rdf:Description[^>]*>\s*<dcam:memberOf rdf:resource="([^"]+)"/>\s*<rdf:value>([^<]*)</rdf:value>',
      dotAll: true);
  static final RegExp _shelf = RegExp(r'2009/pgterms/Bookshelf"/>\s*<rdf:value>([^<]*)</rdf:value>', dotAll: true);
  static final RegExp _about = RegExp(r'Wikipedia page about this book: (https?://[^\s<]+)');
  static final RegExp _marc260 = RegExp(r'<pgterms:marc260>([^<]*)</pgterms:marc260>');
  static final RegExp _name = RegExp(r'<pgterms:name>([^<]*)</pgterms:name>');
  static final RegExp _birth = RegExp(r'<pgterms:birthdate[^>]*>(-?\d+)<');
  static final RegExp _death = RegExp(r'<pgterms:deathdate[^>]*>(-?\d+)<');
  static final RegExp _webpage = RegExp(r'<pgterms:webpage rdf:resource="([^"]+)"/>');

  static GutenbergCatalog load(String dir, {String? cacheFile}) {
    if (cacheFile != null && File(cacheFile).existsSync()) {
      final List<Object?> list = jsonDecode(File(cacheFile).readAsStringSync()) as List<Object?>;
      return GutenbergCatalog(list.map((Object? e) => PgBook.fromJson(e as Map<String, Object?>)).toList());
    }
    final Directory root = Directory(p.join(dir, 'cache', 'epub'));
    final List<PgBook> books = <PgBook>[];
    for (final FileSystemEntity e in root.listSync()) {
      if (e is! Directory) continue;
      final String n = p.basename(e.path);
      final File f = File(p.join(e.path, 'pg$n.rdf'));
      if (!f.existsSync()) continue;
      final String text = f.readAsStringSync();
      if (!text.contains('<rdf:value>Text</rdf:value>')) continue;
      final PgBook? b = _parse(int.parse(n), text);
      if (b != null) books.add(b);
    }
    books.sort((PgBook a, PgBook b) => b.downloads.compareTo(a.downloads));
    if (cacheFile != null) {
      File(cacheFile).writeAsStringSync(jsonEncode(books.map((PgBook b) => b.toJson()).toList()));
    }
    return GutenbergCatalog(books);
  }

  static PgBook? _parse(int number, String text) {
    final List<String> langs = _langValue.allMatches(text).map((RegExpMatch m) => m.group(1)!).toList();
    if (langs.length != 1) return null;
    final RegExpMatch? t = _title.firstMatch(text);
    if (t == null) return null;
    final Map<String, PgAgent> byId = <String, PgAgent>{};
    final List<PgAgent> authors = <PgAgent>[], translators = <PgAgent>[], others = <PgAgent>[];
    void place(String role, PgAgent a) {
      switch (role) {
        case 'dcterms:creator':
          authors.add(a);
        case 'marcrel:trl':
          translators.add(a);
        case 'marcrel:ill':
        case 'marcrel:pht':
        case 'marcrel:art':
        case 'marcrel:prt':
        case 'marcrel:pbl':
        case 'marcrel:egr':
        case 'marcrel:dub':
        case 'marcrel:unk':
          break; // images are dropped; publishers and printers own nothing in the text
        default:
          others.add(a);
      }
    }

    for (final RegExpMatch m in _agentBlock.allMatches(text)) {
      final String body = m.group(3)!;
      final PgAgent a = PgAgent(
        name: _unescape(_name.firstMatch(body)?.group(1) ?? ''),
        birth: int.tryParse(_birth.firstMatch(body)?.group(1) ?? ''),
        death: int.tryParse(_death.firstMatch(body)?.group(1) ?? ''),
        webpages: _webpage.allMatches(body).map((RegExpMatch w) => w.group(1)!).toList(),
      );
      byId[m.group(2)!] = a;
      place(m.group(1)!, a);
    }
    for (final RegExpMatch m in _agentRef.allMatches(text)) {
      final PgAgent? a = byId[m.group(2)!];
      if (a != null) place(m.group(1)!, a);
    }
    final List<String> subjects = <String>[], lcc = <String>[];
    for (final RegExpMatch m in _subject.allMatches(text)) {
      final String value = _unescape(m.group(2)!);
      if (m.group(1)!.endsWith('/LCC')) {
        lcc.add(value);
      } else {
        subjects.add(value);
      }
    }
    return PgBook(
      number: number,
      title: _unescape(t.group(1)!).replaceAll(RegExp(r'\s+'), ' ').trim(),
      language: langs.single,
      downloads: int.tryParse(_downloads.firstMatch(text)?.group(1) ?? '') ?? 0,
      authors: authors,
      translators: translators,
      others: others,
      subjects: subjects,
      lcc: lcc,
      bookshelves: _shelf.allMatches(text).map((RegExpMatch m) => _unescape(m.group(1)!)).toList(),
      aboutLinks: _about.allMatches(text).map((RegExpMatch m) => m.group(1)!).toList(),
      alternative: _alt.firstMatch(text) == null ? null : _unescape(_alt.firstMatch(text)!.group(1)!),
      marc260: _marc260.firstMatch(text) == null ? null : _unescape(_marc260.firstMatch(text)!.group(1)!),
    );
  }

  static String _unescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&#39;', "'")
      .replaceAll('&#13;', '')
      .replaceAll('\r', '');
}

/// Strips MARC subfield markers (`Title : $b Subtitle`) and collapses whitespace.
String cleanTitle(String raw) => raw
    .replaceAll(RegExp(r'\s*:\s*\$b\s*'), ': ')
    .replaceAll(RegExp(r'\$[a-z]\s*'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAllMapped(RegExp(r'\s+([:;,.])'), (Match m) => m.group(1)!)
    .trim();

/// Catalogue language -> Gutenberg language code(s).
List<String> gutenbergCodes(String lang) {
  switch (lang) {
    case 'fil':
      return <String>['tl'];
    case 'zh-Hant':
      return <String>['zh'];
    case 'zh-Hans':
      return <String>[];
    case 'pt':
    case 'pt-BR':
      return <String>['pt'];
    case 'no':
      return <String>['no', 'nb'];
    default:
      return <String>[lang];
  }
}

class GutenbergDiscovery {
  int inLanguage = 0, afterFilters = 0, examined = 0, noYear = 0;
}

Future<GutenbergDiscovery> discoverGutenberg(String lang, GutenbergCatalog pg, Wikidata wd, RightsPolicy policy,
    Existing existing, List<Candidate> chosen, int target) async {
  final GutenbergDiscovery stats = GutenbergDiscovery();
  final List<String> codes = gutenbergCodes(lang);
  if (codes.isEmpty) return stats;
  final List<PgBook> pool = <PgBook>[];
  for (final PgBook b in pg.books) {
    if (!codes.contains(b.language)) continue;
    stats.inLanguage++;
    if (!_passesAgentFilters(b, policy)) continue;
    if (_excludedTitle.hasMatch(b.title)) continue;
    if (b.subjects.any(_excludedSubject.hasMatch) || b.bookshelves.any(_excludedSubject.hasMatch)) continue;
    if (b.translators.isEmpty && _looksTranslated(b, lang)) continue;
    pool.add(b);
  }
  stats.afterFilters = pool.length;

  const int batch = 40;
  for (int i = 0; i < pool.length && chosen.length < target && stats.examined < 600; i += batch) {
    final List<PgBook> slice = pool.sublist(i, i + batch > pool.length ? pool.length : i + batch);
    stats.examined += slice.length;
    // Resolve the work items (publication year, types, original language) and
    // the author items (Wikidata id, citizenship for pt/pt-BR) in bulk.
    final Map<String, WdEntity> works = await wd.entitiesForLinks(
        slice.expand((PgBook b) => b.aboutLinks).toList());
    final Map<String, WdEntity> people = await wd.entitiesForLinks(
        slice.expand((PgBook b) => <PgAgent>[...b.authors, ...b.translators]).expand((PgAgent a) => a.webpages).toList());
    for (final PgBook b in slice) {
      if (chosen.length >= target) break;
      final Candidate? c = await _gutenbergCandidate(b, lang, works, people, wd, policy);
      if (c == null) {
        stats.noYear++;
        continue;
      }
      if (existing.has(c.workId, lang) || existing.isBundledTitle(c.title, c.authorName)) continue;
      if (chosen.any((Candidate o) => o.workId == c.workId)) continue;
      chosen.add(c);
    }
  }
  return stats;
}

bool _passesAgentFilters(PgBook b, RightsPolicy policy) {
  if (b.authors.isEmpty) return false;
  for (final PgAgent a in <PgAgent>[...b.authors, ...b.translators, ...b.others]) {
    if (a.death == null || a.death! > policy.latestDeathYear) return false;
    if (a.name.isEmpty) return false;
  }
  return true;
}

/// A book in language L by an author whose Wikipedia pages are all in other
/// languages, or whose Gutenberg "alternative" title ends in the language
/// name, is a translation; without a named translator it cannot be cleared.
bool _looksTranslated(PgBook b, String lang) {
  final String? alt = b.alternative;
  if (alt != null && RegExp(r'\.\s*[A-Z][a-z]+$').hasMatch(alt)) return true;
  if (b.subjects.any((String s) => RegExp(r'Translations into', caseSensitive: false).hasMatch(s))) return true;
  return false;
}

/// True when two codes name the same language for cataloguing purposes.
bool sameLanguage(String a, String b) => _baseLanguage(a) == _baseLanguage(b);

String _baseLanguage(String code) {
  switch (code.toLowerCase()) {
    case 'pt-br':
      return 'pt';
    case 'zh-hans':
    case 'zh-hant':
    case 'lzh':
    case 'zh-classical':
      return 'zh';
    case 'nb':
    case 'nn':
      return 'no';
    case 'tl':
      return 'fil';
    default:
      return code.toLowerCase();
  }
}

String _wikiLang(String lang) {
  switch (lang) {
    case 'zh-Hant':
    case 'zh-Hans':
      return 'zh';
    case 'pt-BR':
      return 'pt';
    case 'fil':
      return 'tl';
    default:
      return lang;
  }
}

Future<Candidate?> _gutenbergCandidate(PgBook b, String lang, Map<String, WdEntity> works,
    Map<String, WdEntity> people, Wikidata wd, RightsPolicy policy) async {
  final PgAgent a0 = b.authors.first;
  final WdEntity? authorItem = _firstEntity(a0.webpages, people);
  // Portuguese is split by the author's citizenship.
  if (lang == 'pt' || lang == 'pt-BR') {
    final bool brazilian = authorItem?.citizenship.contains('Q155') ?? false;
    if (brazilian != (lang == 'pt-BR')) return null;
  }
  final WdEntity? work = _firstEntity(b.aboutLinks, works);
  if (work != null && work.types.any((String t) => _excludedWikidataTypes.contains(t) && !_allowedDespiteExclusion.contains(t))) {
    return null;
  }
  final bool translation = b.translators.isNotEmpty;
  // A work whose original language, or whose author's writing languages, are
  // not this language is a translation; without a named translator it
  // cannot be cleared.
  if (!translation) {
    final String? workLang = wd.codeFor(work?.originalLanguage);
    if (workLang != null && !sameLanguage(workLang, lang)) return null;
    final Set<String> authorLangs =
        (authorItem?.writingLanguages ?? const <String>{}).map(wd.codeFor).whereType<String>().toSet();
    if (authorLangs.isNotEmpty && !authorLangs.any((String c) => sameLanguage(c, lang))) return null;
  }
  final int? imprintYear = _yearFromImprint(b.marc260);
  int? originalYear = work?.earliestPublicationYear;
  int? translationYear;
  final List<String> evidence = <String>[GutenbergClient.landingUrl('${b.number}').toString()];
  final List<String> basis = <String>[];
  evidence.addAll(a0.webpages.map(_https));
  if (work != null) evidence.add('https://www.wikidata.org/wiki/${work.id}');
  final String authorDisplay = displayName(a0.name);
  basis.add('author ${a0.death! < 0 ? 'died' : 'died'} ${a0.death}: more than 70 years ago in every life-plus-70 jurisdiction'
      '${b.authors.length > 1 ? ' (all ${b.authors.length} authors died ${b.authors.map((PgAgent x) => x.death).join('/')})' : ''}');
  String statement;
  if (translation) {
    final PgAgent t = b.translators.first;
    if (b.translators.length > 1) return null; // one translator per edition in the schema
    translationYear = imprintYear;
    if (translationYear == null || translationYear > policy.latestPublicationYear) return null;
    evidence.addAll(t.webpages.map(_https));
    basis.add('translator died ${t.death}: more than 70 years ago in every life-plus-70 jurisdiction');
    basis.add('translation printed $translationYear (imprint recorded by Project Gutenberg): more than 95 years ago (US term expired)');
    statement = 'Public domain worldwide. $authorDisplay died in ${a0.death}; the translator ${displayName(t.name)} '
        'died in ${t.death} and this translation was printed in $translationYear. Project Gutenberg boilerplate removed; '
        'the Project Gutenberg edition is the source.';
  } else {
    if (originalYear == null || originalYear > policy.latestPublicationYear) {
      // No first-publication year on Wikidata; the imprint of the digitised
      // edition is an upper bound and is recorded as editionPublicationYear.
      if (imprintYear == null || imprintYear > policy.latestPublicationYear) return null;
      originalYear = null;
      basis.add('edition printed $imprintYear (imprint recorded by Project Gutenberg): more than 95 years ago (US term expired)');
      statement = 'Public domain worldwide. $authorDisplay died in ${a0.death} and the edition digitised by Project Gutenberg '
          'was printed in $imprintYear. Project Gutenberg boilerplate removed; the Project Gutenberg edition is the source.';
    } else {
      basis.add('first published $originalYear: more than 95 years ago (US term expired)');
      statement = 'Public domain worldwide. $authorDisplay died in ${a0.death} and the work was first published in $originalYear. '
          'Project Gutenberg boilerplate removed; the Project Gutenberg edition is the source.';
    }
  }
  final String originalTitle = translation
      ? (work?.label(wd.codeFor(work.originalLanguage) ?? 'en') ?? work?.label('en') ?? _originalFromAlternative(b) ?? b.title)
      : b.title;
  final String originalLanguage = translation
      ? (wd.codeFor(work?.originalLanguage) ?? _languageFromAlternative(b) ?? 'und')
      : lang;
  if (translation && originalLanguage == 'und') return null;
  final String workId = makeWorkId(surnameOf(a0.name), originalTitle, 'pg${b.number}');
  final Person author = Person(
      name: authorDisplay, birthYear: a0.birth, deathYear: a0.death, wikidata: authorItem?.id);
  Person? translator;
  if (translation) {
    final PgAgent t = b.translators.first;
    translator = Person(
        name: displayName(t.name), birthYear: t.birth, deathYear: t.death, wikidata: _firstEntity(t.webpages, people)?.id);
  }
  return Candidate(
    provider: 'gutenberg',
    workId: workId,
    editionSlug: 'gutenberg',
    title: b.title,
    originalTitle: originalTitle,
    originalLanguage: originalLanguage,
    author: author,
    translator: translator,
    originalPublicationYear: originalYear,
    editionPublicationYear: translation ? null : (originalYear == null ? imprintYear : null),
    translationPublicationYear: translationYear,
    source: <String, Object?>{
      'provider': 'gutenberg',
      'url': GutenbergClient.landingUrl('${b.number}').toString(),
      'identifier': '${b.number}',
      'format': 'epub',
    },
    genres: genresFromGutenberg(b.subjects, b.bookshelves, b.lcc),
    evidence: evidence.toSet().toList(),
    basis: basis,
    statement: statement,
    rank: b.downloads,
    notes: b.authors.length > 1 ? 'Co-authors: ${b.authors.map((PgAgent x) => displayName(x.name)).join(', ')}' : null,
  );
}

WdEntity? _firstEntity(List<String> links, Map<String, WdEntity> map) {
  for (final String l in links) {
    final WdEntity? e = map[Wikidata.linkKey(l)];
    if (e != null) return e;
  }
  return null;
}

String _https(String url) => url.replaceFirst('http://', 'https://');

int? _yearFromImprint(String? imprint) {
  if (imprint == null) return null;
  final Iterable<RegExpMatch> years = RegExp(r'(?<!\d)(1[5-9]\d\d)(?!\d)').allMatches(imprint);
  if (years.isEmpty) return null;
  return years.map((RegExpMatch m) => int.parse(m.group(1)!)).reduce((int a, int b) => a < b ? a : b);
}

String? _originalFromAlternative(PgBook b) {
  final String? alt = b.alternative;
  if (alt == null) return null;
  final RegExpMatch? m = RegExp(r'^(.*?)\.\s*[A-Z][a-z]+$').firstMatch(alt);
  return m?.group(1)?.trim();
}

String? _languageFromAlternative(PgBook b) => null; // the alternative names the target language only

// ---------------------------------------------------------------------------
// Wikisource (via Wikidata)

/// Catalogue language -> Wikisource subdomain and Wikidata language codes.
({String site, List<String> codes})? wikisourceSite(String lang) {
  switch (lang) {
    case 'zh-Hant':
      return (site: 'zh', codes: <String>['zh', 'lzh', 'zh-classical', 'zh-hant']);
    case 'zh-Hans':
      return null;
    case 'pt':
    case 'pt-BR':
      return (site: 'pt', codes: <String>['pt', 'pt-br']);
    case 'fil':
      return null;
    case 'no':
      return (site: 'no', codes: <String>['no', 'nb', 'nn']);
    default:
      return (site: lang, codes: <String>[lang]);
  }
}

Future<List<Candidate>> discoverWikisource(String lang, Wikidata wd, RightsPolicy policy) async {
  final ({String site, List<String> codes})? cfg = wikisourceSite(lang);
  if (cfg == null) return const <Candidate>[];
  final String site = 'https://${cfg.site}.wikisource.org/';
  final String codes = cfg.codes.map((String c) => '"$c"').join(' ');
  final String labelLang = _wikiLang(lang);
  final int maxDeath = policy.latestDeathYear, maxPub = policy.latestPublicationYear;
  final String excluded = _excludedWikidataTypes
      .where((String t) => !_allowedDespiteExclusion.contains(t))
      .map((String t) => 'wd:$t')
      .join(' ');

  final String originals = '''
SELECT ?work ?wsTitle ?author ?born ?died ?pub ?sl ?cit
       ?labelL ?labelEn ?authorL ?authorEn
       (GROUP_CONCAT(DISTINCT ?type; separator=",") AS ?types)
       (GROUP_CONCAT(DISTINCT ?genre; separator=",") AS ?genres) WHERE {
  ?ws schema:isPartOf <$site> ; schema:about ?work ; schema:name ?wsTitle .
  ?work wdt:P407 ?lang . ?lang wdt:P424 ?code . VALUES ?code { $codes }
  ?work wdt:P50 ?author .
  ?author wdt:P570 ?d . BIND(YEAR(?d) AS ?died) FILTER(?died <= $maxDeath)
  ?work wdt:P577 ?p . BIND(YEAR(?p) AS ?pub) FILTER(?pub <= $maxPub)
  FILTER NOT EXISTS { ?work wdt:P50 ?a2 . FILTER NOT EXISTS { ?a2 wdt:P570 ?d2 . FILTER(YEAR(?d2) <= $maxDeath) } }
  FILTER NOT EXISTS { ?work wdt:P655 ?anyTranslator }
  MINUS { ?work wdt:P31 ?bad . VALUES ?bad { $excluded } }
  MINUS { ?work wdt:P136 ?badGenre . VALUES ?badGenre { $excluded } }
  ?work wikibase:sitelinks ?sl .
  OPTIONAL { ?author wdt:P569 ?b . BIND(YEAR(?b) AS ?born) }
  OPTIONAL { ?author wdt:P27 ?cit }
  OPTIONAL { ?work wdt:P31 ?type }
  OPTIONAL { ?work wdt:P136 ?genre }
  OPTIONAL { ?work rdfs:label ?labelL FILTER(LANG(?labelL) = "$labelLang") }
  OPTIONAL { ?work rdfs:label ?labelEn FILTER(LANG(?labelEn) = "en") }
  OPTIONAL { ?author rdfs:label ?authorL FILTER(LANG(?authorL) = "$labelLang") }
  OPTIONAL { ?author rdfs:label ?authorEn FILTER(LANG(?authorEn) = "en") }
} GROUP BY ?work ?wsTitle ?author ?born ?died ?pub ?sl ?cit ?labelL ?labelEn ?authorL ?authorEn
ORDER BY DESC(?sl) LIMIT 200
''';
  // The same selection without the aggregated types/genres and with fewer
  // labels: what the query service can answer for the biggest corpora.
  final String originalsLite = '''
SELECT ?work ?wsTitle ?author ?born ?died ?pub ?sl ?cit ?labelL ?labelEn ?authorL ?authorEn
       ("" AS ?types) ("" AS ?genres) WHERE {
  ?ws schema:isPartOf <$site> ; schema:about ?work ; schema:name ?wsTitle .
  ?work wdt:P407 ?lang . ?lang wdt:P424 ?code . VALUES ?code { $codes }
  ?work wdt:P31 wd:Q8261 .
  ?work wdt:P50 ?author .
  ?author wdt:P570 ?d . BIND(YEAR(?d) AS ?died) FILTER(?died <= $maxDeath)
  ?work wdt:P577 ?p . BIND(YEAR(?p) AS ?pub) FILTER(?pub <= $maxPub)
  FILTER NOT EXISTS { ?work wdt:P50 ?a2 . FILTER NOT EXISTS { ?a2 wdt:P570 ?d2 . FILTER(YEAR(?d2) <= $maxDeath) } }
  FILTER NOT EXISTS { ?work wdt:P655 ?anyTranslator }
  ?work wikibase:sitelinks ?sl .
  OPTIONAL { ?author wdt:P569 ?b . BIND(YEAR(?b) AS ?born) }
  OPTIONAL { ?author wdt:P27 ?cit }
  OPTIONAL { ?work rdfs:label ?labelL FILTER(LANG(?labelL) = "$labelLang") }
  OPTIONAL { ?work rdfs:label ?labelEn FILTER(LANG(?labelEn) = "en") }
  OPTIONAL { ?author rdfs:label ?authorL FILTER(LANG(?authorL) = "$labelLang") }
  OPTIONAL { ?author rdfs:label ?authorEn FILTER(LANG(?authorEn) = "en") }
} ORDER BY DESC(?sl) LIMIT 120
''';

  final String translations = '''
SELECT ?ed ?wsTitle ?work ?author ?born ?died ?tr ?trBorn ?trDied ?pub ?origPub ?origCode ?sl ?cit
       ?labelL ?labelEn ?origLabel ?authorL ?authorEn ?trL ?trEn
       (GROUP_CONCAT(DISTINCT ?type; separator=",") AS ?types)
       (GROUP_CONCAT(DISTINCT ?genre; separator=",") AS ?genres) WHERE {
  ?ws schema:isPartOf <$site> ; schema:about ?ed ; schema:name ?wsTitle .
  ?ed wdt:P407 ?lang . ?lang wdt:P424 ?code . VALUES ?code { $codes }
  ?ed wdt:P655 ?tr . ?tr wdt:P570 ?td . BIND(YEAR(?td) AS ?trDied) FILTER(?trDied <= $maxDeath)
  FILTER NOT EXISTS { ?ed wdt:P655 ?tr2 . FILTER(?tr2 != ?tr) }
  ?ed wdt:P577 ?p . BIND(YEAR(?p) AS ?pub) FILTER(?pub <= $maxPub)
  ?ed wdt:P629 ?work . ?work wdt:P50 ?author .
  ?author wdt:P570 ?d . BIND(YEAR(?d) AS ?died) FILTER(?died <= $maxDeath)
  FILTER NOT EXISTS { ?work wdt:P50 ?a2 . FILTER NOT EXISTS { ?a2 wdt:P570 ?d2 . FILTER(YEAR(?d2) <= $maxDeath) } }
  MINUS { ?work wdt:P31 ?bad . VALUES ?bad { $excluded } }
  MINUS { ?ed wdt:P31 ?bad2 . VALUES ?bad2 { $excluded } }
  MINUS { ?work wdt:P136 ?badGenre . VALUES ?badGenre { $excluded } }
  ?work wikibase:sitelinks ?sl .
  OPTIONAL { ?work wdt:P577 ?op . BIND(YEAR(?op) AS ?origPub) }
  OPTIONAL { ?work wdt:P407 ?ol . ?ol wdt:P424 ?origCode }
  OPTIONAL { ?author wdt:P569 ?b . BIND(YEAR(?b) AS ?born) }
  OPTIONAL { ?tr wdt:P569 ?tb . BIND(YEAR(?tb) AS ?trBorn) }
  OPTIONAL { ?author wdt:P27 ?cit }
  OPTIONAL { ?work wdt:P31 ?type }
  OPTIONAL { ?work wdt:P136 ?genre }
  OPTIONAL { ?ed rdfs:label ?labelL FILTER(LANG(?labelL) = "$labelLang") }
  OPTIONAL { ?ed rdfs:label ?labelEn FILTER(LANG(?labelEn) = "en") }
  OPTIONAL { ?work rdfs:label ?origLabel FILTER(LANG(?origLabel) = ?origCode) }
  OPTIONAL { ?author rdfs:label ?authorL FILTER(LANG(?authorL) = "$labelLang") }
  OPTIONAL { ?author rdfs:label ?authorEn FILTER(LANG(?authorEn) = "en") }
  OPTIONAL { ?tr rdfs:label ?trL FILTER(LANG(?trL) = "$labelLang") }
  OPTIONAL { ?tr rdfs:label ?trEn FILTER(LANG(?trEn) = "en") }
} GROUP BY ?ed ?wsTitle ?work ?author ?born ?died ?tr ?trBorn ?trDied ?pub ?origPub ?origCode ?sl ?cit
  ?labelL ?labelEn ?origLabel ?authorL ?authorEn ?trL ?trEn
ORDER BY DESC(?sl) LIMIT 60
''';

  List<Map<String, String>> rowsO;
  try {
    rowsO = await wd.sparql(originals, 'ws-orig-$lang');
  } on FetchException catch (e) {
    stderr.writeln('  full Wikisource query failed for $lang ($e); retrying with novels only');
    rowsO = await wd.sparql(originalsLite, 'ws-orig-lite-$lang');
    for (final Map<String, String> r in rowsO) {
      r['types'] = 'http://www.wikidata.org/entity/Q8261';
    }
  }
  final List<Map<String, String>> rowsT = await wd.sparql(translations, 'ws-trans-$lang');
  final List<Candidate> out = <Candidate>[];
  final Set<String> seenWorks = <String>{};

  Candidate? build(Map<String, String> r, {required bool translation}) {
    final String wsTitle = r['wsTitle'] ?? '';
    if (wsTitle.isEmpty || RegExp(r'^[^/]*:').hasMatch(wsTitle)) return null; // other namespaces
    final String workQ = _qid(r['work']);
    if (!seenWorks.add(workQ)) return null;
    if (lang == 'pt' || lang == 'pt-BR') {
      final bool brazilian = _qid(r['cit']) == 'Q155';
      if (brazilian != (lang == 'pt-BR')) return null;
    }
    final Set<String> types = (r['types'] ?? '').split(',').where((String s) => s.isNotEmpty).map(_qid).toSet();
    final Set<String> genres = (r['genres'] ?? '').split(',').where((String s) => s.isNotEmpty).map(_qid).toSet();
    final int? died = int.tryParse(r['died'] ?? '');
    final int? born = int.tryParse(r['born'] ?? '');
    final int? pub = int.tryParse(r['pub'] ?? '');
    if (died == null || pub == null) return null;
    // Originals carry the author's name in their own language; translations use
    // the English name so one workId reads the same in every language.
    final String authorName = translation
        ? _pick(r['authorEn'], r['authorL'], 'Q')
        : _pick(r['authorL'], r['authorEn'], 'Q');
    if (authorName.startsWith('Q')) return null;
    final String title = _pick(r['labelL'], null, _stripDisambiguation(wsTitle));
    final String authorQ = _qid(r['author']);
    final List<String> evidence = <String>[
      'https://www.wikidata.org/wiki/$workQ',
      'https://www.wikidata.org/wiki/$authorQ',
      '$site' 'wiki/${Uri.encodeComponent(wsTitle.replaceAll(' ', '_'))}',
    ];
    final List<String> basis = <String>[
      'author died $died: more than 70 years ago in every life-plus-70 jurisdiction',
    ];
    final String surname = slugify(_surnameFromDisplay(authorName)).isNotEmpty
        ? _surnameFromDisplay(authorName)
        : _surnameFromDisplay(r['authorEn'] ?? '');
    if (!translation) {
      basis.add('first published $pub: more than 95 years ago (US term expired)');
      final String workId = makeWorkId(surname, title, _latinFallback(r['labelEn'], workQ));
      return Candidate(
        provider: 'wikisource',
        workId: workId,
        editionSlug: 'wikisource',
        title: title,
        originalTitle: title,
        originalLanguage: lang,
        author: Person(name: authorName, birthYear: born, deathYear: died, wikidata: authorQ),
        translator: null,
        originalPublicationYear: pub,
        editionPublicationYear: null,
        translationPublicationYear: null,
        source: _wikisourceSource(cfg.site, wsTitle),
        genres: genresFromWikidata(types, genres),
        evidence: evidence,
        basis: basis,
        statement: 'Public domain worldwide. $authorName died in $died and the work was first published in $pub. '
            'Source: ${cfg.site}.wikisource.org transcription of the public-domain text.',
        rank: int.tryParse(r['sl'] ?? '0') ?? 0,
      );
    }
    final int? trDied = int.tryParse(r['trDied'] ?? '');
    final int? trBorn = int.tryParse(r['trBorn'] ?? '');
    final String trName = _pick(r['trL'], r['trEn'], 'Q');
    if (trDied == null || trName.startsWith('Q')) return null;
    final String origCode = r['origCode'] ?? '';
    if (origCode.isEmpty || !isWellFormedLanguageTag(origCode)) return null;
    if (sameLanguage(origCode, lang)) return null; // a "translation" into its own language is a data error
    final String originalTitle = _pick(r['origLabel'], r['labelEn'], title);
    final int? origPub = int.tryParse(r['origPub'] ?? '');
    final String trQ = _qid(r['tr']);
    evidence.insert(2, 'https://www.wikidata.org/wiki/$trQ');
    evidence.insert(1, 'https://www.wikidata.org/wiki/${_qid(r['ed'])}');
    basis.add('translator died $trDied: more than 70 years ago in every life-plus-70 jurisdiction');
    basis.add('translation first published $pub: more than 95 years ago (US term expired)');
    final String workId = makeWorkId(surname, originalTitle, _latinFallback(r['labelEn'], workQ));
    return Candidate(
      provider: 'wikisource',
      workId: workId,
      editionSlug: 'wikisource',
      title: title,
      originalTitle: originalTitle,
      originalLanguage: origCode,
      author: Person(name: authorName, birthYear: born, deathYear: died, wikidata: authorQ),
      translator: Person(name: trName, birthYear: trBorn, deathYear: trDied, wikidata: trQ),
      originalPublicationYear: origPub,
      editionPublicationYear: null,
      translationPublicationYear: pub,
      source: _wikisourceSource(cfg.site, wsTitle),
      genres: genresFromWikidata(types, genres),
      evidence: evidence,
      basis: basis,
      statement: 'Public domain worldwide. $authorName died in $died; the translator $trName died in $trDied and '
          'this translation was first published in $pub. Source: ${cfg.site}.wikisource.org transcription.',
      rank: int.tryParse(r['sl'] ?? '0') ?? 0,
    );
  }

  for (final Map<String, String> r in rowsO) {
    final Candidate? c = build(r, translation: false);
    if (c != null) out.add(c);
  }
  for (final Map<String, String> r in rowsT) {
    final Candidate? c = build(r, translation: true);
    if (c != null) out.add(c);
  }
  out.sort((Candidate a, Candidate b) => b.rank.compareTo(a.rank));
  return out;
}

Map<String, Object?> _wikisourceSource(String site, String title) => <String, Object?>{
      'provider': 'wikisource',
      'site': '$site.wikisource.org',
      'url': 'https://$site.wikisource.org/wiki/${Uri.encodeComponent(title.replaceAll(' ', '_')).replaceAll('%2F', '/')}',
      'identifier': title,
      'format': 'html',
    };

String _qid(String? uri) => uri == null ? '' : uri.substring(uri.lastIndexOf('/') + 1);

String _pick(String? a, String? b, String fallback) {
  if (a != null && a.isNotEmpty) return a;
  if (b != null && b.isNotEmpty) return b;
  return fallback;
}

/// An English label when it has Latin letters, else the item id.
String _latinFallback(String? labelEn, String qid) =>
    labelEn != null && slugify(_stripSubtitle(labelEn)).isNotEmpty ? _stripSubtitle(labelEn) : qid.toLowerCase();

String _stripDisambiguation(String title) => title.replaceAll(RegExp(r'\s*\([^)]*\)\s*$'), '').trim();

String _surnameFromDisplay(String name) {
  final List<String> parts = name.trim().split(RegExp(r'\s+'));
  return parts.isEmpty ? name : parts.last;
}

// ---------------------------------------------------------------------------
// Wikidata client with an on-disk cache

class WdEntity {
  WdEntity(this.id, this._json);
  final String id;
  final Map<String, Object?> _json;

  Map<String, Object?> get _claims => (_json['claims'] as Map<String, Object?>?) ?? const <String, Object?>{};

  List<Map<String, Object?>> _statements(String prop) =>
      ((_claims[prop] as List<Object?>?) ?? const <Object?>[]).cast<Map<String, Object?>>();

  Set<String> _itemValues(String prop) {
    final Set<String> out = <String>{};
    for (final Map<String, Object?> s in _statements(prop)) {
      final Map<String, Object?>? v = ((s['mainsnak'] as Map<String, Object?>?)?['datavalue'] as Map<String, Object?>?)?['value']
          as Map<String, Object?>?;
      final String? id = v?['id'] as String?;
      if (id != null) out.add(id);
    }
    return out;
  }

  Set<String> get types => _itemValues('P31');
  Set<String> get citizenship => _itemValues('P27');
  Set<String> get writingLanguages => <String>{..._itemValues('P6886'), ..._itemValues('P1412')};
  String? get originalLanguage => _itemValues('P407').firstOrNull;

  int? get earliestPublicationYear {
    int? best;
    for (final Map<String, Object?> s in _statements('P577')) {
      if (s['rank'] == 'deprecated') continue;
      final Map<String, Object?>? v = ((s['mainsnak'] as Map<String, Object?>?)?['datavalue'] as Map<String, Object?>?)?['value']
          as Map<String, Object?>?;
      final String? time = v?['time'] as String?;
      if (time == null) continue;
      final RegExpMatch? m = RegExp(r'^([+-])(\d{4,})').firstMatch(time);
      if (m == null) continue;
      final int year = int.parse(m.group(2)!) * (m.group(1) == '-' ? -1 : 1);
      if (best == null || year < best) best = year;
    }
    return best;
  }

  String? label(String lang) {
    final Map<String, Object?>? labels = _json['labels'] as Map<String, Object?>?;
    final Map<String, Object?>? l = labels?[lang] as Map<String, Object?>?;
    return l?['value'] as String?;
  }
}

class Wikidata {
  Wikidata(this.cacheDir);
  final String cacheDir;
  final http.Client _client = http.Client();
  final Map<String, WdEntity> _entities = <String, WdEntity>{};
  final Map<String, String?> _langCodes = <String, String?>{};

  void close() => _client.close();

  /// `https://fi.wikipedia.org/wiki/Juhani_Aho` -> `fiwiki|Juhani Aho`.
  static String? linkKey(String url) {
    final RegExpMatch? m = RegExp(r'^https?://([a-z\-]+)\.wikipedia\.org/wiki/(.+)$').firstMatch(url.trim());
    if (m == null) return null;
    String title;
    try {
      title = Uri.decodeComponent(m.group(2)!);
    } catch (_) {
      title = m.group(2)!;
    }
    title = title.replaceAll('_', ' ');
    final int hash = title.indexOf('#');
    if (hash >= 0) title = title.substring(0, hash);
    return '${m.group(1)!.replaceAll('-', '_')}wiki|$title';
  }

  /// Entities behind Wikipedia links, keyed by [linkKey]. Missing pages are absent.
  Future<Map<String, WdEntity>> entitiesForLinks(List<String> links) async {
    final Map<String, WdEntity> out = <String, WdEntity>{};
    final Map<String, List<String>> bySite = <String, List<String>>{};
    for (final String l in links) {
      final String? key = linkKey(l);
      if (key == null) continue;
      final WdEntity? cached = _entities[key];
      if (cached != null) {
        out[key] = cached;
        continue;
      }
      final List<String> kv = key.split('|');
      bySite.putIfAbsent(kv[0], () => <String>[]).add(kv[1]);
    }
    for (final MapEntry<String, List<String>> e in bySite.entries) {
      final List<String> titles = e.value.toSet().toList();
      for (int i = 0; i < titles.length; i += 50) {
        final List<String> slice = titles.sublist(i, i + 50 > titles.length ? titles.length : i + 50);
        final Map<String, Object?> json = await _getJson(Uri.https('www.wikidata.org', '/w/api.php', <String, String>{
          'action': 'wbgetentities',
          'sites': e.key,
          'titles': slice.join('|'),
          'props': 'claims|labels|sitelinks',
          'format': 'json',
        }));
        final Map<String, Object?> entities = (json['entities'] as Map<String, Object?>?) ?? const <String, Object?>{};
        for (final MapEntry<String, Object?> ent in entities.entries) {
          final Map<String, Object?> m = ent.value as Map<String, Object?>;
          if (m.containsKey('missing')) continue;
          final WdEntity entity = WdEntity(ent.key, m);
          final Map<String, Object?>? sitelinks = m['sitelinks'] as Map<String, Object?>?;
          final Map<String, Object?>? link = sitelinks?[e.key] as Map<String, Object?>?;
          final String? title = link?['title'] as String?;
          if (title == null) continue;
          final String key = '${e.key}|$title';
          _entities[key] = entity;
          out[key] = entity;
        }
        // Titles that were normalised (first letter, redirects) are matched by
        // a case-insensitive pass.
        for (final String t in slice) {
          final String key = '${e.key}|$t';
          if (out.containsKey(key)) continue;
          final String? found = out.keys
              .where((String k) => k.startsWith('${e.key}|') && k.toLowerCase() == key.toLowerCase())
              .firstOrNull;
          if (found != null) out[key] = out[found]!;
        }
      }
    }
    return out;
  }

  /// Wikimedia language code of a language item (cached; one lookup each).
  String? codeFor(String? qid) {
    if (qid == null) return null;
    return _langCodes[qid] ?? _knownLanguageCodes[qid];
  }

  Future<List<Map<String, String>>> sparql(String query, String cacheName) async {
    final File cache = File(p.join(cacheDir, 'sparql-$cacheName.json'));
    String body;
    if (cache.existsSync()) {
      body = cache.readAsStringSync();
    } else {
      final http.Response r = await _post(Uri.https('query.wikidata.org', '/sparql'), <String, String>{'query': query});
      body = r.body;
      cache.writeAsStringSync(body);
    }
    final Map<String, Object?> json = jsonDecode(body) as Map<String, Object?>;
    final List<Object?> bindings = ((json['results'] as Map<String, Object?>)['bindings'] as List<Object?>);
    return bindings.map((Object? b) {
      final Map<String, Object?> m = b as Map<String, Object?>;
      return <String, String>{
        for (final MapEntry<String, Object?> e in m.entries)
          e.key: ((e.value as Map<String, Object?>)['value'] ?? '').toString(),
      };
    }).toList();
  }

  Future<http.Response> _post(Uri uri, Map<String, String> form) async {
    Object? last;
    for (int attempt = 1; attempt <= 4; attempt++) {
      try {
        final http.Response r = await _client
            .post(uri, headers: <String, String>{
              'user-agent': userAgent,
              'accept': 'application/sparql-results+json',
            }, body: form)
            .timeout(const Duration(seconds: 120));
        if (r.statusCode == 200) return r;
        last = 'HTTP ${r.statusCode}: ${r.body.length > 200 ? r.body.substring(0, 200) : r.body}';
        if (r.statusCode != 429 && r.statusCode < 500) break;
      } catch (e) {
        last = e;
      }
      await Future<void>.delayed(Duration(seconds: 5 * attempt));
    }
    throw FetchException('Wikidata query failed: $last');
  }

  Future<Map<String, Object?>> _getJson(Uri uri) async {
    final String name = 'get-${uri.toString().hashCode.toRadixString(16)}.json';
    final File cache = File(p.join(cacheDir, name));
    if (cache.existsSync()) return jsonDecode(cache.readAsStringSync()) as Map<String, Object?>;
    final http.Response r = await fetchWithRetry(_client, uri, attempts: 4);
    cache.writeAsStringSync(r.body);
    return jsonDecode(r.body) as Map<String, Object?>;
  }
}

/// Wikidata language items -> codes, for the original language of a
/// translated work: the catalogue languages plus the usual source languages
/// of translations.
const Map<String, String> _knownLanguageCodes = <String, String>{
  'Q1860': 'en', 'Q150': 'fr', 'Q188': 'de', 'Q1321': 'es', 'Q652': 'it', 'Q5146': 'pt', 'Q7737': 'ru',
  'Q397': 'la', 'Q35497': 'grc', 'Q36510': 'el', 'Q1412': 'fi', 'Q9027': 'sv', 'Q9035': 'da', 'Q9043': 'no',
  'Q25167': 'nb', 'Q25164': 'nn', 'Q7411': 'nl', 'Q809': 'pl', 'Q9056': 'cs', 'Q9058': 'sk', 'Q9067': 'hu',
  'Q7913': 'ro', 'Q7918': 'bg', 'Q8798': 'uk', 'Q9091': 'be', 'Q6654': 'hr', 'Q9299': 'sr', 'Q9296': 'mk',
  'Q9063': 'sl', 'Q9292': 'bs', 'Q9072': 'et', 'Q9078': 'lv', 'Q9083': 'lt', 'Q8748': 'sq', 'Q7850': 'zh',
  'Q37041': 'lzh', 'Q5287': 'ja', 'Q9176': 'ko', 'Q13955': 'ar', 'Q9168': 'fa', 'Q9288': 'he', 'Q256': 'tr',
  'Q1568': 'hi', 'Q1617': 'ur', 'Q9610': 'bn', 'Q5885': 'ta', 'Q8097': 'te', 'Q36236': 'ml', 'Q5218': 'gu',
  'Q1571': 'mr', 'Q58635': 'pa', 'Q29921': 'as', 'Q8108': 'ka', 'Q8785': 'hy', 'Q8641': 'yi', 'Q11059': 'sa',
  'Q9199': 'mn', 'Q9252': 'kk', 'Q9255': 'ky', 'Q9264': 'uz', 'Q9260': 'vi', 'Q9217': 'th', 'Q9237': 'ms',
  'Q9240': 'id', 'Q33549': 'jv', 'Q34002': 'su', 'Q9248': 'tg', 'Q25285': 'tt', 'Q14196': 'af', 'Q7838': 'sw',
  'Q7026': 'ca', 'Q8752': 'eu', 'Q9307': 'gl', 'Q9142': 'ig', 'Q34311': 'yo', 'Q56475': 'ha', 'Q33578': 'ny',
  'Q34004': 'sn', 'Q33573': 'rw', 'Q13275': 'so', 'Q33239': 'ceb', 'Q33823': 'ne', 'Q9228': 'my',
  'Q9205': 'km', 'Q33491': 'ht', 'Q58680': 'ps', 'Q9309': 'cy',
};

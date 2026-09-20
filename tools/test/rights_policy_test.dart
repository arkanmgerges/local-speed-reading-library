import 'package:lsr_library_tools/lsr_library_tools.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  const RightsPolicy policy = RightsPolicy(currentYear: 2026);

  BookMetadata edition({int? authorDeath = 1889, int? published = 1881, String status = 'public-domain', Map<String, Object?>? translator, int? translationYear, List<String> evidence = const <String>['https://example.org/e']}) {
    final Map<String, Object?> m = sampleMetadata();
    m['work'] = <String, Object?>{
      ...m['work'] as Map<String, Object?>,
      'author': <String, Object?>{'name': 'A', 'deathYear': ?authorDeath},
      'originalPublicationYear': ?published,
    }..removeWhere((String k, Object? v) => published == null && k == 'originalPublicationYear');
    m['edition'] = <String, Object?>{
      ...m['edition'] as Map<String, Object?>,
      if (translator != null) 'kind': 'translation',
      'translator': ?translator,
      'translationPublicationYear': ?translationYear,
    };
    m['rights'] = <String, Object?>{...m['rights'] as Map<String, Object?>, 'status': status, 'evidence': evidence};
    return BookMetadata(m);
  }

  test('thresholds: life + 70 and 95 years since publication', () {
    expect(policy.latestDeathYear, 1955);
    expect(policy.latestPublicationYear, 1930);
    expect(policy.evaluate(edition(authorDeath: 1955, published: 1930)).publishable, isTrue);
    expect(policy.evaluate(edition(authorDeath: 1956)).reasons.single, contains('author died in 1956'));
    expect(policy.evaluate(edition(published: 1931)).reasons.single, contains('first published in 1931'));
  });

  test('unknown years are not publishable', () {
    expect(policy.evaluate(edition(authorDeath: null)).reasons.single, contains('deathYear is unknown'));
    expect(policy.evaluate(edition(published: null)).reasons.single, contains('originalPublicationYear'));
  });

  test('status, evidence and verification date are required', () {
    expect(policy.evaluate(edition(status: 'uncertain')).reasons.single, contains('not "public-domain"'));
    expect(policy.evaluate(edition(evidence: const <String>[])).reasons.single, contains('evidence is empty'));
  });

  test('a translation is judged on the translator and the translation year', () {
    final BookMetadata ok = edition(translator: <String, Object?>{'name': 'T', 'deathYear': 1950}, translationYear: 1920);
    expect(policy.evaluate(ok).publishable, isTrue);
    final BookMetadata recentTranslator = edition(translator: <String, Object?>{'name': 'T', 'deathYear': 1980}, translationYear: 1920);
    expect(policy.evaluate(recentTranslator).reasons.single, contains('translator died in 1980'));
    final BookMetadata recentTranslation = edition(translator: <String, Object?>{'name': 'T', 'deathYear': 1950}, translationYear: 1949);
    expect(policy.evaluate(recentTranslation).reasons.single, contains('first published in 1949'));
    final BookMetadata unknownTranslator = edition(translator: <String, Object?>{'name': 'T'}, translationYear: 1920);
    expect(policy.evaluate(unknownTranslator).reasons.single, contains('translator.deathYear is unknown'));
  });
}

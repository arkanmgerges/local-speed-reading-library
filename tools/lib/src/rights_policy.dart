import 'package:lsr_library_tools/src/metadata.dart';

/// Outcome of the publishing-policy check for one edition.
class RightsVerdict {
  const RightsVerdict({required this.publishable, required this.reasons});

  /// True when the edition may enter the production catalogue.
  final bool publishable;

  /// Why not (empty when publishable).
  final List<String> reasons;
}

/// PUBLIC DOMAIN ONLY, evaluated conservatively for worldwide distribution:
///
/// * `rights.status` must be `public-domain`, with evidence and a
///   verification date;
/// * every author **and** translator must have died before 1 January of
///   (current year - 70), i.e. `deathYear <= currentYear - 71` (life + 70);
/// * the text as distributed (the translation for a translation, otherwise
///   the original) must have been first published at least 95 full years
///   ago (`year <= currentYear - 96`), which covers the US term for works
///   published with notice.
///
/// Anything that cannot be proven with the recorded years is *not*
/// publishable, regardless of how old the original author is. The metadata
/// stays in the repository marked `uncertain` until someone adds evidence.
class RightsPolicy {
  const RightsPolicy({required this.currentYear});

  final int currentYear;

  int get latestDeathYear => currentYear - 71;
  int get latestPublicationYear => currentYear - 96;

  RightsVerdict evaluate(BookMetadata m) {
    final List<String> reasons = <String>[];
    if (m.rightsStatus != 'public-domain') {
      reasons.add('rights.status is "${m.rightsStatus}", not "public-domain"');
    }
    if (m.rightsEvidence.isEmpty) {
      reasons.add('rights.evidence is empty');
    }
    if ((m.rightsVerifiedAt ?? '').isEmpty) {
      reasons.add('rights.verifiedAt is missing');
    }
    final int? authorDeath = m.authorDeathYear;
    if (authorDeath == null) {
      reasons.add('work.author.deathYear is unknown');
    } else if (authorDeath > latestDeathYear) {
      reasons.add(
          'author died in $authorDeath; must be $latestDeathYear or earlier (life + 70)');
    }
    if (m.isTranslation) {
      final int? translatorDeath = m.translatorDeathYear;
      if (translatorDeath == null) {
        reasons.add('edition.translator.deathYear is unknown');
      } else if (translatorDeath > latestDeathYear) {
        reasons.add(
            'translator died in $translatorDeath; must be $latestDeathYear or earlier (life + 70)');
      }
    }
    final int? published = m.isTranslation
        ? (m.translationPublicationYear ?? m.editionPublicationYear)
        : (m.originalPublicationYear ?? m.editionPublicationYear);
    if (published == null) {
      reasons.add(m.isTranslation
          ? 'edition.translationPublicationYear (or editionPublicationYear) is unknown'
          : 'work.originalPublicationYear (or editionPublicationYear) is unknown');
    } else if (published > latestPublicationYear) {
      reasons.add(
          'first published in $published; must be $latestPublicationYear or earlier (95-year term)');
    }
    return RightsVerdict(publishable: reasons.isEmpty, reasons: reasons);
  }
}

# Copyright and rights

## Policy: public domain only

The catalogue distributes only texts that are in the public domain **worldwide**, judged
conservatively. An edition is publishable only when all of the following hold and are
recorded in its metadata file:

1. `rights.status` is `public-domain`, with at least one `evidence` link, a `verifiedBy`
   and a `verifiedAt` date.
2. The **author** died before 1 January of (current year − 70): `deathYear ≤ currentYear − 71`.
3. For a translation, the **translator** died before the same date. A translation is a
   separate copyrightable work; an old original does not make its translation free.
4. The text as distributed (the translation for a translation, otherwise the original) was
   first published at least 95 full years ago: `year ≤ currentYear − 96`. This covers the US
   term for works published with notice, so the same catalogue is safe in the app's markets.
5. Missing years mean *not publishable*, never "probably fine".

The check is code, not judgement: `tools/lib/src/rights_policy.dart`, run by `lsr validate`
and again by the catalogue builder. An edition that fails is kept in the repository with
`rights.status: uncertain` (or `restricted`) and is skipped by the catalogue and the publish
workflow. Marking such an edition `public-domain` is a validation error.

The model is licence-agnostic (`status`, `basis[]`, `jurisdictions[]`), so Creative Commons
or other licences could be supported later by adding a status and a policy rule. They are not
supported now.

## What each edition records

`work.author.deathYear`, `edition.translator.deathYear`, `originalPublicationYear`,
`editionPublicationYear`, `translationPublicationYear`, `source.provider`, `source.url`,
`source.identifier`, `source.revision` / `source.pages[].revision`, `source.retrievedAt`,
`rights.status`, `rights.basis[]`, `rights.jurisdictions[]`, `rights.statement`,
`rights.evidence[]`, `rights.verifiedBy`, `rights.verifiedAt`, `asset.normalizerVersion`,
`asset.assetVersion`. The same provenance and the rights statement are embedded in every
distributed asset, so a downloaded book is self-describing.

## Provider notes

### Wikisource
* Texts that are public domain stay public domain; Wikisource adds no restriction to them.
* Content **created by Wikisource contributors** (their own translations, annotations,
  introductions) is licensed CC BY-SA, not public domain. It is not imported. Only editions
  whose translator is a named, long-dead person qualify.
* Header/navigation templates, edit links, reference lists and footnote markers are removed;
  the page title and revision id are recorded for every page that makes up the text.

### Project Gutenberg
* Gutenberg's own rights statement is "public domain in the USA". This project additionally
  requires the worldwide test above, so some Gutenberg books are excluded.
* The Project Gutenberg licence permits redistribution of the text without the licence
  header/footer provided the Project Gutenberg trademark is not used. The pipeline removes the
  boilerplate, transcriber notes and every mention of the trademark from the distributed
  text; `lsr validate` fails a build that still contains one. Attribution ("source: Project
  Gutenberg ebook #N") lives in the provenance record and in the app's book details.
* The site asks robots not to crawl. The importer fetches single, explicitly listed books
  with an identifying User-Agent and retries with back-off.

### Europeana, national libraries, Internet Archive, Open Library
* Used for discovery only. Being downloadable does not make an item public domain; each
  needs its own rights review and, if imported, an importer that records the item's own
  rights statement and identifier.

Not accepted as sources: scanned-only PDFs, OCR dumps without a curated text, arbitrary
websites, and "borrow-only" copies of in-copyright books.

## Attribution

Nothing legally required is removed. Provider, URL, identifier, revision and retrieval date
travel with the asset and are shown by the app. Translator names are part of the edition
record and of the manifest.

## Takedown / review

Open an issue titled `rights: <editionId>` with the concern and any evidence. A maintainer
sets `rights.status` to `restricted` (or `uncertain`), which removes the edition from the
catalogue at the next publish; the metadata file stays in the repository with the decision
recorded in `rights.notes`. Copies already installed by users are not reachable by us and are
not deleted. Published asset objects are kept immutable but are no longer referenced; they can
be deleted from the bucket by hand if required.

## Licensing of this repository

* Tooling, workflows, schemas and documentation: MIT (`LICENSE`).
* Metadata, rights/provenance records, catalogue files, registries: CC0 1.0 (`LICENSE-METADATA`).
* Literary texts: public domain on their own terms. No file in this repository claims
  ownership of them or relicenses them.

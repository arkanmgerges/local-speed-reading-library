# Adding a book

One edition at a time. Prefer works that matter in the language's literature over bulk.

## 1. Pick the work and the exact edition

* Identify the work, the author and, for a translation, the translator.
* Find a reputable machine-readable source: Wikisource first, Project Gutenberg second.
  Check that the source is the edition you mean (same translator, complete text).
* Do not add a second edition of a work in the same language unless there is a reason
  (`lsr validate` warns).

## 2. Verify rights

Collect the author's and translator's death years and the first-publication year of the
text you are distributing, with links (Wikipedia, Wikidata, the provider's author page).
Apply the test in [copyright-and-rights.md](copyright-and-rights.md). If anything is
unknown, set `rights.status` to `uncertain`; the file is still welcome.

## 3. Write the metadata file

`metadata/<language>/<editionId>.json`, where `editionId` is
`<author-surname>-<title-slug>.<language>.<edition-slug>` (all lower case, `[a-z0-9.-]`).
Copy an existing file as a template:

```json
{
  "schemaVersion": 1,
  "work": { "workId": "slavici-moara-cu-noroc", "originalTitle": "Moara cu noroc",
            "originalLanguage": "ro",
            "author": { "name": "Ioan Slavici", "birthYear": 1848, "deathYear": 1925 },
            "originalPublicationYear": 1881 },
  "edition": { "editionId": "slavici-moara-cu-noroc.ro.wikisource", "language": "ro",
               "title": "Moara cu noroc", "kind": "original" },
  "source": { "provider": "wikisource", "site": "ro.wikisource.org",
              "url": "https://ro.wikisource.org/wiki/Moara_cu_noroc",
              "identifier": "Moara cu noroc", "format": "html" },
  "rights": { "status": "public-domain",
              "basis": ["author died 1925", "first published 1881"],
              "jurisdictions": ["worldwide-conservative"],
              "statement": "Public domain worldwide. …",
              "evidence": ["https://ro.wikipedia.org/wiki/Ioan_Slavici"],
              "verifiedBy": "your-github-handle", "verifiedAt": "2026-09-20" },
  "genres": ["Fiction"],
  "publish": { "assetVersion": 1 }
}
```

Provider specifics:

* **Wikisource**: `identifier` is the page title; `site` the host. Multi-page books
  (`Title/Chapter 1`, …) are discovered from links on the main page in document order; to
  control the list, write `source.pages` yourself (titles only, `lsr pin` fills the revisions).
* **Gutenberg**: `identifier` is the ebook number; `format` is `epub`.

## 4. Pin, build, review

```bash
cd tools
dart run bin/lsr.dart pin <editionId>      # writes source.revision / source.pages
dart run bin/lsr.dart build <editionId>    # fetch, normalise, package; writes the asset block
dart run bin/lsr.dart show <editionId>     # chapter outline
```

Look at the outline and at `build/books/<lang>/<editionId>/v1/book.json`:

* chapters and titles match the book; no table of contents, no reference list, no licence
  text, no transcriber notes, no "by Author" line, no figure captions;
* first and last paragraphs are the book's own;
* word count is plausible.

If something is off, add `import` hints and rebuild with `--offline --allow-rewrite`:

| Hint | Effect |
|---|---|
| `chapterHeadingLevels` | which `<hN>` start chapters (default `[1,2,3]`) |
| `skipHeadings` | headings whose whole section is dropped (added to the defaults) |
| `removeSelectors` | extra CSS selectors removed before extraction |
| `dropParagraphsMatching` | regular expressions; matching paragraphs are dropped |
| `firstChapterTitle` | title for text before the first heading |

`--allow-rewrite` is only for versions that were never uploaded. Once a version is on the
CDN, changes need `publish.assetVersion` bumped.

## 5. Validate and open a pull request

```bash
dart run bin/lsr.dart catalog
dart run bin/lsr.dart validate
dart test
```

Commit the metadata file and the regenerated `catalog/` files (never `build/`). CI runs
the same validation; after merge, the publish workflow builds the same bytes (it checks
`contentSha256`), uploads the asset and publishes the catalogue.

## Batch discovery

`tools/bin/discover.dart` finds candidates for every catalogue language and writes their
metadata files; `scripts/batch-build.sh` pins, builds, prunes and validates them.

```bash
# once: the offline Gutenberg catalogue (about 130 MB, extracts to cache/epub/*/pg*.rdf)
curl -A "lsr-library-tools/0.1" -o rdf-files.tar.bz2 https://www.gutenberg.org/cache/epub/feeds/rdf-files.tar.bz2
mkdir rdf && tar -xjf rdf-files.tar.bz2 -C rdf

cd tools
dart run bin/discover.dart --rdf ../rdf --per-language 20 --overshoot 12 \
    --report ../build/discover-report.json --write
cd .. && scripts/batch-build.sh --delay 2          # pin, build, prune to 20 per language, catalog, validate
```

What discovery accepts, per source:

* **Gutenberg** (ranked by downloads): every creator, translator and other named contributor
  has a death year that passes the policy; no poetry/drama/periodical subjects; not a later
  volume. An original needs a first-publication year on the Wikidata item behind the
  "Wikipedia page about this book" link, or an imprint year in the MARC 260 field
  (recorded as `editionPublicationYear`). A translation needs exactly one translator and an
  imprint year. Portuguese is split into `pt` and `pt-BR` by the author's citizenship.
* **Wikisource** (ranked by Wikidata sitelinks): works written in the language whose author(s)
  died early enough and whose first publication is recorded on Wikidata; translations only
  when the translator and the translation year are recorded. Poems, plays, songs, speeches
  and documents are excluded by class and genre.

Everything else is left out rather than guessed. `rights.notes` marks the batch origin.
After the build, `bin/prune.dart` removes editions that did not build or have fewer than
6000 words, and keeps the first 20 per language in discovery order. Review the outlines
with `lsr show` where a book looks off, and fix with `import` hints as above.

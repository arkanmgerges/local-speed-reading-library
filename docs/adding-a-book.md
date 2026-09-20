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

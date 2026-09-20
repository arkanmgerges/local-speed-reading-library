# Local Speed Reading — public-domain library

The public, auditable source of truth for the books that the
[Local Speed Reading](https://localspeedreading.com) app can download on demand.

This repository holds **metadata, rights records, provenance, schemas, tooling and
documentation**. It does not hold the generated book assets: those are built by the
tools here and published to Cloudflare R2, where the app fetches them from
`https://books.localspeedreading.com`. GitHub is never used as the download server.

## Licensing (read this first)

Three different kinds of material live here, under three different terms:

| Material | Where | Terms |
|---|---|---|
| Tooling, workflows, schemas, docs written for this project | `tools/`, `.github/`, `schemas/`, `docs/` | [MIT](LICENSE) |
| Metadata and catalogue records created by this project | `metadata/`, `catalog/`, `sources/` | [CC0 1.0](LICENSE-METADATA) |
| The literary texts themselves | built into R2 assets, never committed | **Public domain.** Nothing here relicenses them; each edition's rights record says why it is public domain and where it came from. |

Details, per-provider obligations and the takedown process: [docs/copyright-and-rights.md](docs/copyright-and-rights.md).

## How it fits together

```
Wikisource / Project Gutenberg  (pinned revisions)
        │  tools: lsr pin → lsr build   (import → normalise → package → sha256)
        ▼
this repository                  metadata/<lang>/<editionId>.json  +  catalog/
        │  GitHub Actions: validate → build → upload immutable assets → publish catalogue
        ▼
Cloudflare R2  →  https://books.localspeedreading.com/{catalog,books}/…
        ▼
the app: catalog.json → languages/<lang>.json → user taps Download → verify → read offline
```

* One edition = one metadata file = one immutable asset per version:
  `books/<lang>/<editionId>/v<N>/book.json.gz`.
* The app downloads a book only when the user asks for that book. Browsing never
  downloads text.
* Publishing policy: **public domain only**, judged conservatively for worldwide
  distribution (author *and* translator dead for 70+ years, first published 95+ years
  ago). Anything uncertain stays out of the catalogue.

Architecture, formats and decisions: [docs/architecture.md](docs/architecture.md).

## Repository layout

```
schemas/        JSON Schema (draft-07) for metadata, normalized books, manifests, catalog
metadata/       one hand-reviewable file per edition: work, edition, source, rights, asset
catalog/        GENERATED catalog.json + languages/<lang>.json (committed for auditability)
sources/        provider registry and the language registry shared with the app
tools/          Dart package with the `lsr` command (pin, build, validate, catalog, publish-check)
docs/           architecture, rights, adding a book, Cloudflare R2, publishing
build/          gitignored: source snapshots and generated assets
```

## Quick start

```bash
cd tools
dart pub get
dart run bin/lsr.dart validate                 # schemas, ids, languages, rights, catalogue
dart run bin/lsr.dart pin <editionId>          # record the provider revision(s)
dart run bin/lsr.dart build <editionId>        # fetch → normalise → build/…/book.json.gz, records the asset block
dart run bin/lsr.dart catalog                  # regenerate catalog/
dart run bin/lsr.dart show <editionId>         # chapter outline of a built book
dart run bin/lsr.dart publish-check            # compare build/ with the CDN
dart test
```

Adding a book, step by step: [docs/adding-a-book.md](docs/adding-a-book.md).
Publishing and the required secrets: [docs/publishing.md](docs/publishing.md).

## Status

Pilot: 3 Romanian editions (Wikisource) and 3 English editions (Project Gutenberg).
The long-term target is about 20 books in each of 80+ languages, added gradually and
reproducibly.

# Contributing

Thank you for helping build a public-domain library that people can read offline.

## What a contribution looks like

* **A new edition**: one metadata file under `metadata/<lang>/`, built and validated
  locally, in a pull request. See [docs/adding-a-book.md](docs/adding-a-book.md).
* **A correction**: fix the metadata (author years, title, genres, source) and bump
  `publish.assetVersion` only if the *text* must change.
* **A rights concern**: open an issue titled `rights: <editionId>` with the evidence.
  The edition is set to `restricted` and dropped from the catalogue on the next publish;
  nothing is deleted from the repository, so the record of the decision stays public.
* **Tooling**: Dart, `dart analyze` clean, `dart test` green, behaviour covered by a test.

## Rules that a pull request must satisfy

1. `dart run bin/lsr.dart validate` reports no errors.
2. Public domain only, by the conservative test in
   [docs/copyright-and-rights.md](docs/copyright-and-rights.md): author **and** translator
   dead for 70+ years, first published 95+ years ago, evidence links recorded. If you cannot
   prove it, set `rights.status` to `uncertain`; the file is welcome, the book stays unpublished.
3. Sources are reputable and machine-readable (Wikisource, Project Gutenberg first). No
   scanned-only PDFs, no OCR dumps, no arbitrary websites, no "borrow-only" library copies.
4. One edition per file, one work id per work, no duplicate translations of the same work in
   the same language unless there is a stated reason.
5. Never commit `build/`, credentials or anything from `~/.aws`.
6. Commit messages follow Conventional Commits: `feat(metadata): add ro Creangă …`,
   `fix(tools): …`, `docs: …`.

## Review checklist (maintainers)

- [ ] Metadata file at `metadata/<language>/<editionId>.json`, schema-valid.
- [ ] Author / translator death years and publication year checked against the evidence links.
- [ ] `lsr show <editionId>` outline looks like the book: right chapters, no licence text,
      no table of contents, no footnote lists, no transcriber notes.
- [ ] First and last paragraphs are the book's own text.
- [ ] `lsr validate` and `dart test` pass in CI.

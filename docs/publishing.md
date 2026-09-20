# Publishing

## Pipeline

```
metadata change (PR)
  → validate.yml: dart analyze, dart test, lsr validate, lsr catalog --check
  → merge to main
  → publish.yml:
      lsr validate
      lsr build --all --check          (rebuild from pinned sources; contentSha256 must match)
      lsr publish-check --plan         (what is missing on the CDN; refuses to overwrite)
      upload missing books/**          (immutable headers, no overwrite)
      upload catalog/**                (short cache headers)
      lsr publish-check                (everything identical)
```

Assets are uploaded before the catalogue, so a manifest never points at an object that does
not exist yet. Old versions are never deleted by the workflow.

## Secrets (GitHub → Settings → Secrets and variables → Actions)

| Name | Value | Notes |
|---|---|---|
| `R2_ACCOUNT_ID` | Cloudflare account id | from the R2 overview page |
| `R2_ACCESS_KEY_ID` | R2 API token id | token created with **Object Read & Write** on bucket `lsr-books` only |
| `R2_SECRET_ACCESS_KEY` | R2 API token secret | shown once at creation |
| `R2_BUCKET` | `lsr-books` | |

Repository variable (not secret): `BOOKS_BASE_URL` = `https://books.localspeedreading.com/`.

Least privilege: the token is scoped to one bucket, object-level only, no account
permissions. Rotate it by creating a new token, updating the secrets, then deleting the old
token. The token is never stored anywhere else: not in the app, not in this repository, not
in `build/`.

## Uploading by hand (pilot, before CI exists)

Uses the AWS CLI against the R2 S3 endpoint. Export the same four values locally:

```bash
export R2_ACCOUNT_ID=… R2_ACCESS_KEY_ID=… R2_SECRET_ACCESS_KEY=… R2_BUCKET=lsr-books
cd tools && dart run bin/lsr.dart validate && cd ..
scripts/upload.sh            # uploads missing books/** then catalog/**
cd tools && dart run bin/lsr.dart publish-check
```

`scripts/upload.sh` is the same script the workflow runs. It never overwrites a `books/**`
object (`--if-none-match` semantics are emulated with a HEAD check first) and sets the
Cache-Control/Content-Type metadata listed in [cloudflare-r2.md](cloudflare-r2.md).

## Rollback

* A bad **book**: bump `publish.assetVersion`, fix, rebuild, publish. The old object stays
  but is no longer referenced. To hide a book quickly, set `rights.status` to `restricted`
  and publish the catalogue.
* A bad **catalogue**: `git revert` the metadata/catalog commit and publish again; the
  catalogue objects are overwritten (they are the only mutable objects).

## Verifying a deployment

```bash
curl -sI https://books.localspeedreading.com/catalog/catalog.json | grep -iE "cache-control|content-type|etag"
curl -sI https://books.localspeedreading.com/books/ro/creanga-amintiri-din-copilarie.ro.wikisource/v1/book.json.gz | grep -iE "cache-control|content-type"
curl -s  https://books.localspeedreading.com/books/ro/creanga-amintiri-din-copilarie.ro.wikisource/v1/book.json.gz | sha256sum
```

The last hash must equal `asset.sha256` in the metadata file.

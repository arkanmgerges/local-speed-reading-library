# Cloudflare R2 and the `books.localspeedreading.com` host

Everything here is configured by hand in the Cloudflare dashboard (Free plan). No secret
ever leaves Cloudflare except the one API token stored in GitHub Actions.

## 1. Bucket

* R2 → Create bucket → name `lsr-books`, location hint **EU** (Western Europe).
* No object versioning needed: every asset path is already versioned and immutable.
* Leave the bucket private; public access goes only through the custom domain below.

## 2. Custom domain

* Bucket → Settings → Custom Domains → Add `books.localspeedreading.com`. Cloudflare creates
  the proxied DNS record in the `localspeedreading.com` zone and issues the certificate.
* Wait until the status is *Active*, then check:
  `curl -I https://books.localspeedreading.com/catalog/catalog.json` → `200`, `cf-ray` header.
* **Disable the `r2.dev` public URL** for the bucket (Settings → Public access → r2.dev
  subdomain → Disable). The only public entry point is the custom domain, which the rules
  below protect.

## 3. Object metadata (set at upload, see `scripts/upload.sh`)

| Prefix | Content-Type | Cache-Control |
|---|---|---|
| `catalog/catalog.json` | `application/json; charset=utf-8` | `public, max-age=300, must-revalidate` |
| `catalog/languages/*.json` | `application/json; charset=utf-8` | `public, max-age=900, must-revalidate` |
| `books/**/book.json.gz` | `application/gzip` | `public, max-age=31536000, immutable` |

R2 custom domains return these headers as stored, and Cloudflare's cache honours them.

## 4. Cache Rules (Caching → Cache Rules)

1. **Books, immutable** — expression
   `(http.host eq "books.localspeedreading.com" and starts_with(http.request.uri.path, "/books/"))`
   → Cache eligibility: *Eligible for cache*; Edge TTL: *Ignore cache-control header and use
   this TTL*, 1 year; Browser TTL: *Respect origin*; Cache key → **ignore query string**
   (custom cache key, query string: *Ignore*). Arbitrary `?x=` suffixes then cannot bypass the
   cache.
2. **Catalogue, short** — expression
   `(http.host eq "books.localspeedreading.com" and starts_with(http.request.uri.path, "/catalog/"))`
   → *Eligible for cache*; Edge TTL: *Use cache-control header if present*; Browser TTL:
   *Respect origin*; query string: *Ignore*.

## 5. WAF custom rules (Security → WAF → Custom rules; Free plan allows 5)

1. **Block non-read methods** —
   `(http.host eq "books.localspeedreading.com" and not http.request.method in {"GET" "HEAD" "OPTIONS"})`
   → Block.
2. **Block unknown paths** —
   `(http.host eq "books.localspeedreading.com" and not (starts_with(http.request.uri.path, "/catalog/") or starts_with(http.request.uri.path, "/books/") or starts_with(http.request.uri.path, "/covers/")))`
   → Block. (Adjust if new top-level prefixes are added.)

## 6. Rate limiting (Security → WAF → Rate limiting rules; Free plan allows 1)

* Expression `(http.host eq "books.localspeedreading.com")`, characteristics: IP, rate
  **60 requests per 10 seconds**, action Block for 10 seconds. A normal client makes at most
  three requests per book; this only stops scrapers and loops.

## 7. Bot and challenge settings

* Do **not** enable Bot Fight Mode, Managed Challenge or "Under Attack" mode for this host:
  the app uses a plain HTTP client and cannot solve a browser challenge. If a zone-wide
  setting exists, add a WAF *Skip* rule for `http.host eq "books.localspeedreading.com"`
  that skips those features.
* Security level: Medium or lower.
* DDoS protection is automatic on the proxied host; nothing to configure.

## 8. CORS, compression, other

* No CORS headers: the only client is the native app. Add them only if a web client appears.
* Do not enable Cloudflare's automatic Brotli/gzip re-encoding concerns for `.gz` objects:
  they are served as `application/gzip` without `Content-Encoding`, so the client verifies
  the exact bytes it downloads. Cloudflare does not re-compress `application/gzip`.
* Query-string cache busting is unnecessary for `books/**` and disabled by the cache key rule.

## 9. Budget and alerts

* R2 Free tier: 10 GB storage, 10 M Class B (read) operations per month, 1 M Class A
  (write). Egress through the custom domain is free. 1,600 books × ~150 KB ≈ 240 MB.
* Notifications → add **R2 usage** alerts at 50 % and 80 % of the free tier, and a
  **Billing** alert. Set an R2 usage cap if the account offers one.

## 10. The apex website (separate, but on the same zone)

The site repository is served by GitHub Pages at `arkanmgerges.github.io/local-speed-reading-site/`;
`localspeedreading.com` has no DNS record yet. To move it to the apex:

1. Add a `CNAME` file containing `localspeedreading.com` to the site repository.
2. DNS: `A` records for `@` → `185.199.108.153`, `185.199.109.153`, `185.199.110.153`,
   `185.199.111.153` and `CNAME www` → `arkanmgerges.github.io` (DNS-only while GitHub
   provisions the certificate; proxied afterwards is fine).
3. GitHub → repository Settings → Pages → custom domain → verify, then *Enforce HTTPS*.
4. The old `github.io` URLs redirect to the domain, so the Play Console privacy-policy link
   keeps working; update it to `https://localspeedreading.com/privacy.html` anyway.

`assetlinks.json` is not needed: the app declares no App Links. Add it under
`/.well-known/` only if `android:autoVerify` intent filters are ever introduced.

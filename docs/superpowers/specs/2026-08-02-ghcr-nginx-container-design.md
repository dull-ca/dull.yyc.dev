# Container image for dull.yyc.dev — design

Date: 2026-08-02
Status: proposed

## Problem

`dull.yyc.dev` is an Astro static site deployed by Netlify (`netlify.toml`). It
has no CI. We want a container image, published to ghcr.io, that serves the
built site from nginx, as small as we can reasonably make it — so the site can
move to Dr. Dub's own hardware (`dull01`, provisioned in `dulliac`) when that is
ready.

Netlify keeps serving production for now. The image runs alongside it until the
cutover, so nothing in this design touches `netlify.toml`.

## Constraints inherited from the other repos

This is not a greenfield decision. Three constraints come from `golem`:

1. **`nix flake check` is the one gate** (golem ADR 0035 §1). CI is not a
   distinct system; any machine with nix runs the same command.
2. **GitHub Actions is rejected as a standing preference**, softened by the
   2026-07-29 amendment to "interim only, until the self-hosted golem-managed
   box exists." Both workflows here are interim on the same terms.
3. **The release publish mechanism is an open question** (ADR 0035 §5), which
   supersedes ADR 0028 without deciding a replacement. Publishing images to
   ghcr.io is exactly the kind of choice §5 left open, so it is recorded as
   interim in an ADR rather than settled by a workflow file.

The binary cache is `dull-ca` on cachix, wired repo-scoped through each flake's
`nixConfig` — the same public key golem uses:

```
dull-ca.cachix.org-1:dRCsbIU6rWu2X/4+BOxwvtyVOHUXXmRp7ZmEXwne9bk=
```

## Measurements

All figures measured on 2026-08-02, x86_64-linux, nixpkgs-unstable. Sizes are
nix closure size, except alpine-slim which is the uncompressed image.

| Route | Size | Notes |
|---|---|---|
| **`nginx-static-no-tls` (chosen)** | **1.69 MB** | zero store references |
| override of `pkgsStatic.nginx` | 1.70 MB | works, but couples to nginx internals |
| `nginx:alpine-slim` | 5.8 MB | a distro; 5.7 MB compressed |
| `nixpkgs#nginx` (glibc) | 53.2 MB | cached upstream |
| `caddy` (golem's website image) | 89.3 MB | for comparison |

The chosen route is 3.4× smaller than alpine-slim and carries no shell, no
package manager, and no distro.

## Two repositories

The nginx derivation lives in **`dull-ca/nix`** (already created, empty), not in
this repo. `dull.yyc.dev` consumes it as a pinned flake input.

Two reasons, in order of weight:

**Ownership.** `dull-ca/nix` writes its own build rather than overriding
nixpkgs' package, so there is no dependency on another package's internal
attributes. An extracted repo that merely relocated an override would have moved
the problem; owning the build removes it. It still inherits `src` and `version`
from `pkgs.nginx`, so this is ownership of the build configuration only, not of
the source or the version.

**Pinning.** The derivation and the frequently-edited website no longer share a
`flake.lock`. The website pins a known-good `nginx-static-no-tls` and bumps it
deliberately, rather than discovering breakage during an unrelated nixpkgs bump.

Normally that insulation costs a divergent nixpkgs in the closure. Here it costs
nothing, and that follows directly from the measurement: the binary is
statically linked with **zero store references**, so a second nixpkgs pin has no
effect on the final image — no shared libc, no duplicated closure, same 1.69 MB
artifact.

`dull-ca/nix` is scoped as the shared nix repo rather than a single-purpose one,
so future derivations reuse its CI and cachix wiring instead of spawning a repo
each. `packages.nginx-static-no-tls` is its first inhabitant.

### Acknowledged cost

A second repo, its own CI, and a cross-repo `nix flake update` whenever the
website wants a newer nginx. For a coming-soon page this is real ceremony. It is
accepted because the derivation is a genuinely separate artifact with a
different change cadence, and because a second consumer is plausible (golem's
website container is Caddy at 89.3 MB and could use this instead — not proposed
here, merely noted).

## The static nginx build — our build, nixpkgs' source

We write our own `stdenv.mkDerivation`, but it **inherits `src` and `version`
from `pkgs.nginx`**:

```nix
inherit (pkgs.nginx) src version;
```

This is the important part of the design. We reuse from nixpkgs exactly what is
valuable — the pinned source, its hash, and the version, which nixpkgs bumps in
response to nginx security releases — and own only the build configuration,
which is the part we actually need to differ on. There is no hardcoded tarball
hash to maintain and no version for us to track.

Otherwise it depends only on `pkgsStatic.stdenv`, `pkgsStatic.pcre2`, and
`pkgsStatic.zlib` — stable interfaces — rather than on another package's
internal build phases.

The measured result: **1.69 MB, zero store references**. Inheriting `src` and
`version` produces a bit-identical output to a hardcoded `fetchurl`, so this
costs nothing and gains nixpkgs' version tracking.

### Why not `nginx.override`, the supported interface

`generic.nix` is curried, and its outer arguments (`withStream`, `withMail`,
`withPerl`, `withKTLS`, `withGeoIP`, `withImageFilter`, `withSlice`, `modules`)
are a genuine supported override surface. It was investigated and **cannot
produce this build.**

`generic.nix` lines 114–132 set an **unconditional** module list —
`--with-http_ssl_module`, `--with-http_v3_module`, `--with-http_xslt_module`,
`--with-http_dav_module`, `--with-http_flv_module`, `--with-http_mp4_module`
and more — gated by no argument at all. The inner `configureFlags` argument only
appends (line 174), and nginx's configure has no `--without-` counterpart for
opt-in modules, so an appended flag cannot remove one. `.override` can drop
stream, mail, perl and kTLS; it cannot drop the OpenSSL, libxml2 and libxslt
dependencies that account for the bulk of the size.

That is why the build configuration is ours. It is not a preference.

Four things it must set, each found by a failed build:

- **`dontAddStaticConfigureFlags = true`.** The static stdenv adapter otherwise
  appends `--enable-static --disable-shared`, which nginx's hand-rolled
  `./configure` rejects outright. Setting this in the derivation's own args
  works; setting it via `overrideAttrs` on nixpkgs' nginx does not, which is
  why the override route had to filter the flags out instead.
- **`dontAddPrefix = true`** and **`configurePlatforms = [ ]`.** stdenv's generic
  configure phase adds `--prefix=$out`, `--build=`, and `--host=`; nginx rejects
  the autoconf platform flags.
- **A replaced `installPhase`.** With `--prefix=/etc/nginx`, `make install` tries
  to create `/etc/nginx` inside the sandbox and dies on `Permission denied`.
  Copying `objs/nginx` directly avoids this *and* keeps the store path out of
  the binary.
- **`rm -rf $out/nix-support` in `postFixup`.** `nuke-refs` cleans the binary,
  but the propagated-build-inputs metadata file still names the `pcre2-dev` and
  `zlib-dev` paths, which alone dragged the closure to 7.75 MB. It is meaningless
  for a leaf binary package.

`nuke-refs` is safe here precisely because the binary is statically linked — the
store paths it clears are dead strings in nginx's `-V` configure banner, not
runtime dependencies.

Verified functionally before adopting: serves `200 OK` with `text/html`, resolves
clean URLs through `try_files`, returns `text/css` for stylesheets, `404` for
missing paths, and shuts down cleanly.

### The name is a safety property

The package is called **`nginx-static-no-tls`**, and the `-no-tls` is the point:
**this binary cannot serve HTTPS.** Verified —

```
nginx: [emerg] the "ssl" parameter requires ngx_http_ssl_module
```

It is built to sit behind a TLS-terminating reverse proxy and must never be
exposed directly to the internet. The name carries that constraint everywhere
the package is referenced, so nobody has to read this document to learn it. The
`README.md` in `dull-ca/nix` states it again in full.

That it *cannot* do TLS is itself the strongest protection: misuse is
immediately visible as plaintext rather than silently insecure.

### Module inventory

Not "no modules" — nginx's **default** set, minus the upstream family, minus
everything opt-in. Verified by probing the built binary with `nginx -t`.

**Absent (compiled out):**

- **TLS/SSL** — no HTTPS, at all
- `proxy`, `fastcgi`, `uwsgi`, `scgi`, `memcached` — explicitly `--without-`
- HTTP/2 and HTTP/3, `xslt`, `dav`, `flv`, `mp4`, `sub`, `auth_request`,
  `secure_link`, `stub_status`, `random_index`, `degradation`, `image_filter`,
  `geoip`, `slice`, `stream`, `mail`, `perl` — never requested

**Present:**

- `gzip_static`, `threads`, `realip` — explicitly requested
- nginx defaults we did not disable: `autoindex`, `ssi`, `auth_basic`,
  `rewrite`, `limit_req`, `limit_conn`, `access`, `charset`, `gzip`, `map`,
  `geo`, `referer`, `split_clients`, `browser`, `empty_gif`

`autoindex` and `ssi` are the two footguns in that list. Both default to *off*
in nginx and `deploy/nginx.conf` does not enable either; noted here so a future
edit is a deliberate choice rather than an accident.

`realip` is included because the image is designed to run behind a proxy — without
it, every access log line shows the proxy's address instead of the client's. It
costs 5.6 KB and pulls in no dependencies.

### What we give up, stated plainly

**CVE response is shared, not ours alone.** Because we inherit `src` and
`version`, nixpkgs still decides which nginx we build; a security bump lands in
`dull-ca/nix` through a routine `nix flake update` with nothing to hand-edit.
What remains ours is *pulling* that update promptly — nixpkgs cannot push it to
a pinned lock. The mitigation is a scheduled workflow in `dull-ca/nix` that runs
`nix flake update` and opens a PR, so a new nginx arrives as a reviewable,
CI-tested change rather than something to remember.

This is a materially smaller obligation than owning the version outright, and it
is the reason to inherit `src` rather than hardcode a tarball hash.

**We drop nixpkgs' two nginx patches.** `nix-skip-check-logs-path.patch` is
unnecessary — the build succeeds without it. `nix-etag-1.15.4.patch` is
**verified irrelevant here**: it keys on `@nixStoreDir@` and only changes ETag
computation for files served out of `/nix/store`, whereas the image serves from
`/var/www/html`.

The underlying issue it addresses still applies, though: nix normalises store
mtimes to the epoch, so the default mtime-derived `ETag` and `Last-Modified` are
not meaningful for files copied into the image, and content changing without
changing size could reuse an ETag. The design handles this directly — Astro
content-hashes `/_astro/` filenames, so asset cache correctness comes from the
filename, and HTML gets `etag off` with a short TTL rather than a misleading
validator.

**Retreat path:** if owning the build configuration ever becomes tiresome,
`nixpkgs#nginx` (53.2 MB, upstream-cached) is a drop-in replacement for the
package output.

## Repo 1 — `dull-ca/nix`

- **`flake.nix`**
  - `nixConfig` with the `dull-ca` cachix substituter and key.
  - `packages.nginx-static-no-tls` — the derivation above, emitting `bin/nginx` and
    `conf/mime.types` and nothing else.
  - `checks.nginx-static-no-tls-serves` — the smoke test below.
- **`.github/workflows/ci.yml`** — interim, mirroring golem's: `install-nix-action`,
  `cachix-action` (`dull-ca`, `secrets.DULL_CA_CACHIX_PRIVATE_KEY`),
  `nix flake check`.
- **`.github/workflows/update.yml`** — scheduled `nix flake update`, opening a PR
  when nixpkgs moves. Since the derivation inherits `src`/`version` from
  `pkgs.nginx`, this is how an nginx security release reaches us: as a
  CI-tested, reviewable PR rather than a task to remember.
- **`README.md`** — what the repo is for, why `nginx-static-no-tls` exists, and how
  nginx security updates reach it (via `update.yml`, since the version comes
  from nixpkgs).

The derivation carries explanatory comments in golem's `flake.nix` style. The
four required settings (`dontAddStaticConfigureFlags`, `dontAddPrefix`,
`configurePlatforms`, the `nix-support` removal) each look like noise and each
cost a failed build to discover. This does not loosen the no-comments rule for
application source.

Because `checks.nginx-version-current` reaches the network, it cannot run in a
pure nix check. It is implemented as a separate workflow step rather than a
flake check, so `nix flake check` stays pure and offline.

### Smoke test

A nix check that starts the built binary against a fixture root and asserts
behaviour, because a binary that builds is not necessarily a binary that serves:

- request `/` → `200`, `Content-Type: text/html`
- request a missing path → `404`
- `pid` set to a writable path, **not** `/dev/null`, which produced
  `unlink() "/dev/null" failed (13: Permission denied)` on shutdown during
  validation

## Repo 2 — `dull.yyc.dev`

The split between bun and nix mirrors golem's `mkWebsiteContainer`, for the
reason golem's `flake.nix` already documents: Astro pulls ~137 platform-split
native packages (sharp/libvips, esbuild, rollup) that `buildNpmPackage` cannot
reproduce. **bun builds the site; nix only packages it.**

- **`flake.nix`** — the repo currently has only `devenv.nix`.
  - `inputs.dull-nix.url = "github:dull-ca/nix"`, pinned in `flake.lock`.
  - `packages.container` — `dockerTools.buildLayeredImage` over a pre-built
    `dist/`, using `dull-nix.packages.${system}.nginx-static-no-tls`.
  - `siteDist` resolution copies golem's three-case ladder: `DULL_SITE_DIST`
    env var (forcing `--impure`) → in-tree `./dist` → `null`. When null, the
    container package is omitted from `packages` via `optionalAttrs` rather
    than failing evaluation, so a pure `nix flake check` stays green.
  - `checks.nginx-config` — runs `nginx -t` against `deploy/nginx.conf` at
    build time, so a broken config fails the gate instead of crash-looping in
    production.
- **`deploy/nginx.conf`** — the analogue of golem's `sites/website/Caddyfile`.
- **`.github/workflows/ci.yml`** — interim, same shape as golem's.
- **`docs/adr/0001-interim-ghcr-container-channel.md`** — records ghcr.io as an
  interim channel pending ADR 0035 §5.

Note that `dull-nix` does **not** use `inputs.nixpkgs.follows`. Letting it keep
its own nixpkgs pin is the whole point of the split; because the binary has zero
references, the divergence costs nothing.

## Image contents

`buildLayeredImage` from an empty base:

- the 1.69 MB static nginx binary and `mime.types`
- the site `dist/` at `/var/www/html`
- `deploy/nginx.conf` at `/etc/nginx/nginx.conf`
- `dockerTools.fakeNss`, which supplies `/etc/passwd` and `/etc/group` with
  `nobody` (uid 65534) — the unprivileged user the container runs as
- a world-writable `/tmp` for nginx's client-body temp path, since `nobody`
  must be able to write there

Config:

- `Entrypoint = [ "/bin/nginx", "-c", "/etc/nginx/nginx.conf" ]`
- `ExposedPorts = { "8080/tcp" = {}; }`
- `User = "nobody"`

**Port 8080, non-root.** Binding 80 unprivileged needs `CAP_NET_BIND_SERVICE`;
the image sits behind a reverse proxy on `dull01`, so the privileged port buys
nothing.

## nginx configuration

- `daemon off;` — the container's foreground process
- logs to `/dev/stdout` and `/dev/stderr`, never to files
- `pid /tmp/nginx.pid`
- `try_files $uri $uri/index.html $uri/ =404` for Astro's clean URLs
- `gzip_static on` for precompressed assets
- `set_real_ip_from` for the proxy's network and `real_ip_header X-Forwarded-For`,
  so logs record the client rather than the proxy. The trusted range is left as a
  deployment concern for `dulliac` — it must not be `0.0.0.0/0`, which would let
  any client spoof its own address
- `/_astro/` hashed assets get `Cache-Control: public, max-age=31536000, immutable`;
  HTML gets a short TTL and `etag off`, since nix's epoch mtimes make the default
  mtime-derived validator misleading (see "What we give up" above)
- custom `404.html`

## CI flow

Two triggers in `dull.yyc.dev`, per Dr. Dub's instruction that PR and main only
*check* and a tag explicitly releases.

**Pull requests and pushes to main — build, never push:**

1. `cachix/install-nix-action`, then `cachix/cachix-action` (cache `dull-ca`,
   `secrets.DULL_CA_CACHIX_PRIVATE_KEY`)
2. `bun install --frozen-lockfile`
3. `bun run check` — `astro check && biome check .`, a **hard gate**
4. `bun run build`
5. `nix flake check` — includes the `nginx -t` config check
6. `DULL_SITE_DIST=$PWD/dist nix build --impure .#container`

**Tag `v*` — build, then publish:**

7. `skopeo copy docker-archive:result docker://ghcr.io/dull-ca/dull.yyc.dev:$VERSION`
   and `:latest`, authenticated with `GITHUB_TOKEN`

`$VERSION` is the git tag with its leading `v` stripped — tag `v1.2.3` publishes
`ghcr.io/dull-ca/dull.yyc.dev:1.2.3` and moves `:latest`. The image name is
lowercased from the repo name, which ghcr.io requires. The tag is the sole
source of the version; `package.json`'s `version` field is not consulted and
stays at `0.0.1`.

skopeo needs no docker daemon and keeps the push a thin, swappable step, so
moving off ghcr.io later is a one-line change rather than a rewrite.

Because `bun run check` is a hard gate, the first PR goes red if the repo has
existing type or lint violations. Implementation runs it locally first and
fixes anything it surfaces.

## Testing

- **`dull-ca/nix`**: the derivation builds, and the smoke test above proves the
  binary serves. This is where behaviour is tested.
- **`dull.yyc.dev`**: `nginx -t` on `deploy/nginx.conf` inside `nix flake check`,
  plus a container smoke test that runs the built image, requests `/` and
  asserts `200` + `Content-Type: text/html`, and requests a missing path and
  asserts `404`. This is the check that caught the `pid /dev/null` problem
  during design, so it earns its place.
- No unit tests are proposed for the site itself; that is out of scope.

## Sequencing

`dull-ca/nix` is built and pushed first, so `dull.yyc.dev` consumes a real
pinned input from its first commit rather than a throwaway in-repo version.

## Alternatives considered

**`pkgsStatic.nginx` unmodified.** Does not build. The static stdenv adapter
appends `--enable-static --disable-shared` to nginx's hand-rolled `./configure`,
which rejects them.

**`nginx.override { … }`, the supported interface.** Investigated first, because
reusing nixpkgs' derivation through its intended surface would be the cleanest
outcome. It cannot work: `generic.nix` hardcodes the SSL/v3/xslt/dav/flv/mp4
module list unconditionally, and the inner `configureFlags` argument only
appends. See "Why not `nginx.override`" above.

**Overriding nixpkgs' nginx via `overrideAttrs`** (filtering the injected static
flags, replacing `configureFlags` and `installPhase`). Built and measured at
1.70 MB with zero references, so it works — but it depends on nginx's internal
derivation attributes, an unstable interface. It also required keeping `patches`
intact, because clearing them breaks nginx's `postPatch` `@nixStoreDir@`
substitution. Rejected in favour of our own build, which is 1.69 MB, depends
only on stdenv/pcre2/zlib, and still inherits `src` and `version` from nixpkgs.

**Hardcoding the nginx tarball URL and hash.** Works and is bit-identical to
inheriting `src`, but makes version tracking and CVE response entirely ours.
Rejected: inheriting costs nothing and keeps nixpkgs in that loop.

**`nginx:alpine-slim` in a Dockerfile.** 5.8 MB, upstream CVE patching, no nix
required. Rejected on size (3.4× larger) and because it puts a distro, a shell,
and a package manager in the image. Remains the fallback if the nix route ever
stops earning its keep.

**Caddy**, as golem's website container uses. 89.3 MB closure. Rejected on size;
its automatic-HTTPS advantage is irrelevant behind a reverse proxy.

## Out of scope

- Cutting production over from Netlify to the image
- Deploying to `dull01` (that is `dulliac`'s job)
- Switching golem's website container from Caddy to this nginx
- multi-arch images — `dull01` is x86_64; add `aarch64` if that changes
- Resolving ADR 0035 §5; this design deliberately stays interim

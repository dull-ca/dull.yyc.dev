# Build the site in nix, not on the runner

## Problem

CI claims nix is the build gate. It isn't.

`ci.yml:3-4` states: *"The actual gate is `nix flake check`, which is
machine-agnostic — moving to that box changes where this runs, not what it
checks."*

What `nix flake check` actually checks, in full:

```
$ nix flake show --json
{"checks":{"x86_64-linux":{"nginx-config":{...,"name":"nginx-config-valid",...}}}}
```

One `nginx -t` on a config file. `packages` is empty in pure evaluation
because `flake.nix:35-40` resolves `siteDist` to `null` when `dist/` isn't
visible, and `optionalAttrs` then drops `container` entirely.

The site is built by `bun install --frozen-lockfile` and `bun run build`
executing directly on the runner (`ci.yml:37-39`, `release.yml:39-41`), with
bun supplied by `oven-sh/setup-bun@v2` at `bun-version: latest` — unpinned,
so the toolchain drifts between runs. nix's only contribution is
`dockerTools.buildLayeredImage` copying the resulting directory into a layer,
reached via `--impure` and `DULL_SITE_DIST`.

The machine-agnostic gate covers a config file. The part that genuinely varies
by machine — an unpinned bun resolving 629 packages off the npm registry, 137
of them platform-split natives — is precisely the part outside nix.

## Goal

The site becomes a nix derivation. `nix build .#container` produces the image
from source alone: no bun on the runner, no `--impure`, no `DULL_SITE_DIST`.

The builder is reusable, so it lands in `dull-nix` rather than here.

## Why a hand-rolled builder

nixpkgs has no bun builder. Verified against the same `nixpkgs-unstable` this
flake pins:

| attribute | |
|---|---|
| `buildNpmPackage`, `fetchNpmDeps` | exists |
| `pnpm.fetchDeps` | exists |
| `buildBunPackage`, `bun.fetchDeps`, `bunConfigHook` | **absent** |

The blessed builders are not a different mechanism — `fetchNpmDeps` is itself
a fixed-output derivation over the package cache with a hash the caller bumps.
The only "approved" path would be switching package manager. Bun stays; the
FOD gets written by hand and lives in `dull-nix` so it's written once.

## Spike results

A throwaway implementation was built and run against this repo before this
spec was written. All four unknowns are resolved.

**The FOD is deterministic.** `nix build --rebuild` reproduced
`sha256-iPP83n41DF0EHZQdsbq1F9SnSxWp5kn+48QCUu4Z2Lk=` exactly. This was the
main maintainability risk; it is not one.

**Native modules need `autoPatchelfIgnoreMissingDeps = [
"libc.musl-x86_64.so.1" ]`.** autoPatchelf resolves every gnu-variant native
module cleanly (`@rollup/rollup-linux-x64-gnu`,
`@tailwindcss/oxide-linux-x64-gnu`, `lightningcss-linux-x64-gnu`,
`@img/sharp-linux-x64`, `@biomejs/cli-linux-x64`) against `stdenv.cc.cc.lib`.
It fails only on the musl variants, which bun installs alongside the gnu ones
and which never load on this platform. esbuild is statically linked and
skipped automatically.

**Shebangs must be patched across the whole tree**, not just `node_modules/.bin`
— those entries are symlinks, so `patchShebangs node_modules/.bin` silently
leaves `#!/usr/bin/env node` in `node_modules/astro/astro.js` and the build
dies with `bad interpreter`.

**`--ignore-scripts` is sufficient.** No postinstall step is required, which is
also what keeps the FOD hashable.

The resulting `dist/` matches a bun-built one: `classified-stamp.*.svg` and
`client.*.js` are hash-identical. The CSS differs by exactly one rule
(`.table{display:table}`) because the local gitignored `dist/` is stale
relative to `src/` — the nix output is the correct one.

## Design

### 1. `dull-nix` gains `overlays.default`

An overlay adding two attributes to `pkgs`, so callers write
`pkgs.buildBunPackage` exactly as they would `pkgs.buildNpmPackage`.

`fetchBunDeps { src, hash }` — fixed-output derivation. Takes only
`package.json` and `bun.lock`, runs `bun install --frozen-lockfile
--no-progress --ignore-scripts` with network access and bun pinned from
nixpkgs, strips `node_modules/.cache` and `.bun-tag*`, and yields the
`node_modules` tree.

`buildBunPackage { src, bunDepsHash, buildScript ? "build", installDir ?
"dist", ... }` — pure derivation. Copies the deps in writable, runs
`autoPatchelf` with the musl exclusion, runs `patchShebangs node_modules`,
executes `bun run ${buildScript}`, installs `${installDir}` to `$out`.
Sets `dontAutoPatchelf = true` so the fixup hook doesn't re-scan the built
output, which contains no ELF.

Nothing site-specific appears in either.

### 2. `dull-nix` gains a fixture check

A minimal bun project committed in the repo — `package.json`, `bun.lock`, one
source file — that `buildBunPackage` builds, asserting the expected output
exists. This matches how `nginx-static-no-tls` is covered: the properties that
matter are asserted, not assumed.

The fixture carries its own `bunDepsHash` to bump, and it makes `dull-nix` CI
depend on the npm registry. Accepted: without it, a `buildBunPackage`
regression surfaces only as a downstream repo's red CI, and the weekly
`update.yml` nixpkgs-bump PR cannot report that it broke the builder.

### 3. `dull.yyc.dev/flake.nix` consumes it

`pkgs` is imported with `dull-nix.overlays.default` applied.
`packages.site = pkgs.buildBunPackage { src = ./.; bunDepsHash = "..."; }`,
and `mkContainer` takes that store path directly.

Deleted: `siteDist`, `builtins.getEnv "DULL_SITE_DIST"`, the `optionalAttrs`
guard, and the `--impure` requirement. `packages.container` becomes
unconditional and pure-evaluable — so `nix flake check` builds the real
artifact instead of a config file, which is what the CI comment claimed all
along.

`src` needs filtering (`node_modules`, `dist`, `.astro`) to keep the
derivation from rebuilding on unrelated churn.

### 4. `bun run check` becomes `checks.site-check`

`astro check` and `biome check`, run in nix against the same deps derivation,
so they are part of the gate rather than a runner step.

### 5. Both workflows collapse

`ci.yml` and `release.yml` reduce to: checkout → `install-nix` → `cachix` →
`nix flake check` → `nix build .#container` → smoke test, plus the existing
skopeo publish steps in `release.yml`.

Removed from both: `oven-sh/setup-bun`, `bun install --frozen-lockfile`,
`bun run check`, `bun run build`, `DULL_SITE_DIST`, `--impure`.

Comments in both files are cut to the few facts not evident from the YAML —
the skopeo `registries.conf` v1/v2 workaround and the `trap cleanup EXIT`
rationale are worth keeping; the rest goes, including the `nix flake check`
claim this spec exists to falsify.

## Consequences

`bun.lock` changes now require bumping `bunDepsHash` in `flake.nix`. This is
the standing cost of the FOD approach and is identical to what `npmDepsHash`
imposes on every `buildNpmPackage` in nixpkgs.

`devenv.nix` is unaffected — bun remains the local development toolchain.

## Out of scope

Switching package managers. Replacing GitHub Actions, which remains interim
per golem ADR 0035 and is unchanged by this work.

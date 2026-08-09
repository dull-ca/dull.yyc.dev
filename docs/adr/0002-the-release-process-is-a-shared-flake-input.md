# 0002 — The release process is a shared flake input

## Status

Accepted 2026-08-09. Narrows how ADR 0001's `v*` tag trigger is reached; it
does not revisit ghcr.io as the channel or ADR 0001's interim terms.

Adopts golem ADR 0056's decision and its constraints, and the durable half of
its consequences. Not its first consequence or its amendment: those record
golem's own transient red gate and lock move, and this repository's lock moved
in `0cf37d1` ahead of the wiring. What is recorded below is the part that is
not golem's.

## Context

Under ADR 0001 a `v*` tag is the whole release interface, and a tag is
unconstrained: any string, any commit, any number of times. This repository's
only tag, `v0.1.0`, was pushed by hand, because nothing else has ever existed
to push one.

What has to be true before a tag exists — the version's shape, the tag unused,
the commit on `origin/main`, the version unpublished — is not about this
repository. golem enumerated that list (ADR 0053) and then moved it out of its
own tree into `dull-ca/nix` (ADR 0056), which is already a flake input here for
`buildBunPackage` and `nginx-static-no-tls`.

A bespoke implementation was written here anyway and thrown away.
`feat/guarded-releases` carries `ci/release.sh` (124 lines),
`ci/release-guards.sh` (86) and `ci/release-guards.test.sh` (73),
near-identical to golem's. Two copies of an ancestor check in two repositories
cannot be diffed in one checkout, and a drifted guard is worse than none
because it is trusted.

What is this repository's is small: the published image is
`ghcr.io/dull-ca/dull.yyc.dev`, a registry answer is how "already published" is
asked, and nothing on disk carries the version.

## Decision

**The driver, the guards and the guard suite come from `dull-ca/nix`, pinned by
`flake.lock`.** `flake.nix` builds `packages.release` from
`pkgs.mkReleaseCommand` and `packages.release-guards` from
`pkgs.releaseGuards`, and gates `releaseGuardsTest` as
`checks.release-guards-hold` at the pinned revision under this repository's
nixpkgs. `devenv.nix`'s `release` script is a `nix run` of the first.

Three of the shared command's constraints are worth naming where the decision
is taken, because each refuses a release rather than adapting to it: releases
run from a clean `main` that is not behind `origin/main`; the changelog is
`CHANGELOG.md` at the repository root, rewritten in full every release; a hooks
script supplying one subcommand supplies all four. How the version is read, and
everything else, is dull-nix's README under `mkReleaseCommand`.

**`ci/release-hooks.sh` is this repository's entire half** — 92 lines against
the abandoned branch's 283.

**`set-version` prints nothing, so a release commit carries `CHANGELOG.md`
alone.** `package.json` is read for its scripts and dependencies, but its
`version` field is read by nothing — a placeholder in a package marked
`private` and published to no registry.

**`assert-unpublished` refuses on ambiguity.** golem's hook reads every
non-zero `skopeo inspect` as "not published" (`|| return 0`). That is right for
a 404 and wrong for a 401, a DNS failure or a bad authfile — and this
repository's ghcr package is private, which makes an unauthenticated inspect's
401 the common case rather than the rare one. This hook admits only `manifest
unknown` and `name unknown` as evidence of absence; every other failure refuses
and prints what the registry said.
`checks.release-hooks-classify-registry-errors` drives the built hook against a
stub skopeo — the only way to exercise the classification without a network
call.

**`release.yml` keeps `on: push: tags` and re-checks what it still can**,
because a hand-pushed tag reaches it having bypassed `release` entirely.
`assert-releasable` and `assert-on-main` come from `.#release-guards` — the
same pinned flake, not a second copy of the pattern. `assert-unpublished` and
the image name the publish step writes both come from `ci/release-hooks.sh` in
the checkout, which is the point of that file: one place, so the reference the
guard inspects cannot disagree with the reference the publish writes. Nothing
re-checks that the tag is unused; by then it exists.

## Consequences

- **Releasing locally needs ghcr credentials** — `skopeo login ghcr.io`, or
  `GHCR_AUTHFILE` — where golem's `|| return 0` needs none. Nothing announces
  that; it surfaces as a refusal at release time, quoting skopeo. Whether it
  bites at all is the open question below.
- **The gate runs three times per release, twice on a runner.** `warm-cache`
  locally on the release commit, `ci.yml` on the push of that commit to `main`,
  and `release.yml` on the tag. The two runner passes should be cache hits from
  the local warm. The tag run is not redundant with them — a `v*` tag can point
  at any commit — but the `ci.yml` run is.
- **golem ADR 0056's consequences hold here unchanged**: the release path
  depends on `flake.lock`, and a lock without `mkReleaseCommand` fails the
  whole gate rather than one check; a guard fix arrives only when someone runs
  `nix flake update`; changing a guard is two repositories and two reviews; a
  cold store with no network cannot build `release`.
- **Foreclosed:** nothing about the channel. ghcr.io, the `skopeo copy`, and
  ADR 0001's interim terms are untouched.

## Open questions

- **What ghcr.io answers an anonymous `inspect` of a missing tag on a private
  package.** If it is `manifest unknown`, the classification is satisfied
  without credentials and the first consequence above shrinks to nothing. If it
  is a 401, every local release refuses until credentials exist. This has not
  been checked — it needs a network call, and this branch was built without
  one. `--no-creds` is load-bearing: without it skopeo reads the default
  authfile, and a machine that has ever logged in answers a different question.

  ```sh
  skopeo inspect --no-tags --no-creds \
    docker://ghcr.io/dull-ca/dull.yyc.dev:0.0.0-absent
  ```

## Cross-references

- golem ADR 0053 — the guards, and why a local command creates the tag.
- golem ADR 0055 — the version and changelog read from the commits, and the
  release commit that lands on `main` before the tag.
- golem ADR 0056 — the move into `dull-ca/nix`, argued for both consumers.
- `dull-ca/nix` README, `mkReleaseCommand` — the hook contract, the arguments,
  and how the version is read.
- `ci/release-hooks.sh`, `flake.nix`, `.github/workflows/release.yml`.

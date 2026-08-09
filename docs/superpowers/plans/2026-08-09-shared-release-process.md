# Shared Release Process Implementation Plan

> The plan as written, kept as the record of what was planned. Nothing below
> describes the shipped code — the sketches, the attribute names and the
> verification steps all drifted from it. What shipped is `flake.nix`,
> `ci/release-hooks.sh`, `devenv.nix` and `.github/workflows/release.yml`; why
> it shipped that way is
> `docs/adr/0002-the-release-process-is-a-shared-flake-input.md`.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace this repo's would-be bespoke release machinery with `dull-nix`'s `mkReleaseCommand`, supplying only the repo-specific hooks — and fix the fail-open registry guard inherited from golem.

**Architecture:** `flake.nix` gains `packages.release` (built by `pkgs.mkReleaseCommand`), `packages.release-guards` (`pkgs.releaseGuards`) and `checks.release-guards-hold` (`pkgs.releaseGuardsTest`). The version derivation, the changelog, the confirmation, the tag and the push all come from dull-nix. `ci/release-hooks.sh` is the entire repo-specific half: what is published (`ghcr.io/dull-ca/dull.yyc.dev`), and the fact that nothing on disk carries the version. `devenv.nix` exposes `release` as a thin `nix run` wrapper; `.github/workflows/release.yml` obtains the same guards from the same pinned flake instead of a second copy.

**Tech Stack:** nix flakes, devenv, bash, skopeo, git-cliff, GitHub Actions.

## Global Constraints

- Branch is `feat/shared-release-process`, already created off `origin/main` with three commits on it. Never push, fetch, run `gh`, `git push`, or `nix flake update`.
- Never run `release` end-to-end — it pushes.
- Do not touch `netlify.toml`, `public/`, or anything favicon/manifest related.
- Do not create `ci/release.sh`, `ci/release-guards.sh` or `ci/release-guards.test.sh`. Those are the bespoke implementation being replaced; they must never exist on this branch.
- Published image is exactly `ghcr.io/dull-ca/dull.yyc.dev`.
- Repository URL is exactly `https://github.com/dull-ca/dull.yyc.dev`.
- `package.json`'s `version` is a placeholder that nothing reads. This repo versions nothing on disk.
- Comment density: match `dull-ca/golem`. Comment the non-obvious *why* only. No multi-paragraph essays, no explaining what a line plainly does.
- `nix flake check` must pass at the end of every task that changes `flake.nix`.

## Reference material (read before starting)

- `/home/lakin/personal-repos/dull-ca/nix/README.md`, section `## mkReleaseCommand` — the contract.
- `/home/lakin/personal-repos/dull-ca/nix/fixtures/release-hooks/release-hooks.sh` — the minimal four-subcommand example.
- `/home/lakin/personal-repos/golem/ci/release-hooks.sh` — the real consumer. **Its `assert_unpublished` contains the bug this plan fixes. Do not copy it.**
- `/home/lakin/personal-repos/golem/flake.nix` ~231-250 and ~361-363 — the flake wiring to match.
- `/home/lakin/personal-repos/golem/devenv.nix` ~30-40 and ~140 — the packages and the `release` script.
- `/home/lakin/personal-repos/golem/.github/workflows/release.yml` ~30-80 — how CI gets the guards.

## File Structure

- **Create `ci/release-hooks.sh`** — the four hook subcommands. Sole owner of the published image name and of the "is this already published" question.
- **Modify `flake.nix`** — `release`, `release-guards` in `packages`; `release-guards-hold` and a hooks-classification check in `checks`.
- **Modify `devenv.nix`** — `release` script, plus the packages the release path needs.
- **Modify `.github/workflows/release.yml`** — guards from the flake, hook for the registry check.
- **Create `docs/adr/0002-the-release-process-is-a-shared-flake-input.md`**.
- **Modify `README.md`** — a `## Releasing` section.

---

### Task 1: The hooks script and its flake wiring

**Files:**
- Create: `ci/release-hooks.sh`
- Modify: `flake.nix`

**Interfaces:**
- Produces: `packages.release` (`bin/release`, `bin/release-hooks`), `packages.release-guards` (`bin/release-guards`), `checks.release-guards-hold`, `checks.release-hooks-classify-registry-errors`.
- Produces: `ci/release-hooks.sh` answering `assert-ready`, `describe VERSION`, `assert-unpublished VERSION`, `set-version VERSION`, and exiting 2 on anything else.

**The contract, restated so it is not re-derived:**

| subcommand | argument | contract |
| --- | --- | --- |
| `assert-ready` | none | non-zero refuses, before any tag is read |
| `describe` | `vX.Y.Z` (with the `v`) | prints summary lines; `printf '%-9s %s\n'` to line up with the driver's own `commit`/`version` rows |
| `assert-unpublished` | `vX.Y.Z` (with the `v`) | non-zero refuses |
| `set-version` | `X.Y.Z` (**without** the `v`) | writes the version where it belongs, prints each path to stage. Prints nothing when there is no version file. |

`release-guards` is on `PATH` when the driver calls the hooks, so `describe` may ask `release-guards is-stable "$VERSION"`.

**The bug being fixed.** golem's `assert_unpublished` ends the inspect with `|| return 0`: *every* non-zero exit is read as "not published". A 404 means that. A 401, a DNS failure, a malformed authfile, a v1 `registries.conf` — none of them do, and all of them currently make the guard pass silently at exactly the moment it exists to refuse. The ghcr package for this repo is private and a local inspect is anonymous, so the common local case is a 401 that reads as "go ahead". This repo's hook must **classify** instead: only a registry answer that genuinely means "this tag/repo does not exist" counts as unpublished; every other failure refuses and says why.

- [ ] **Step 1: Write the failing check**

Add to `flake.nix`, inside `checks`. It drives the built `bin/release-hooks` against a stub `skopeo`, which is the only way to exercise the classification without a network:

```nix
# The registry answer is classified, not merely tested for zero: only a
# genuine "this tag does not exist" means unpublished, and a 401 or a DNS
# failure must refuse rather than wave the release through.
release-hooks-classify-registry-errors =
  pkgs.runCommand "release-hooks-classify-registry-errors" { } ''
    mkdir -p bin
    cat >bin/skopeo <<'STUB'
    #!/bin/sh
    printf '%s\n' "$SKOPEO_STDERR" >&2
    exit "$SKOPEO_STATUS"
    STUB
    chmod +x bin/skopeo
    export PATH=$PWD/bin:$PATH

    hooks=${release}/bin/release-hooks

    SKOPEO_STATUS=1 SKOPEO_STDERR='manifest unknown' \
      $hooks assert-unpublished v1.2.3 \
      || { echo "a missing manifest must read as unpublished"; exit 1; }

    SKOPEO_STATUS=1 SKOPEO_STDERR='name unknown' \
      $hooks assert-unpublished v1.2.3 \
      || { echo "a missing repository must read as unpublished"; exit 1; }

    if SKOPEO_STATUS=1 SKOPEO_STDERR='unauthorized: authentication required' \
      $hooks assert-unpublished v1.2.3 2>/dev/null; then
      echo "a 401 must refuse, not pass as unpublished"; exit 1
    fi

    if SKOPEO_STATUS=0 SKOPEO_STDERR='' \
      $hooks assert-unpublished v1.2.3 2>/dev/null; then
      echo "an existing tag must refuse"; exit 1
    fi

    touch $out
  '';
```

This needs `release` bound in the `let`, so add that in the same step (see Step 3).

- [ ] **Step 2: Run the check and watch it fail**

Run: `cd /home/lakin/personal-repos/dull-ca/dull.yyc.dev && nix build --no-link .#checks.x86_64-linux.release-hooks-classify-registry-errors`

Expected: FAIL — `ci/release-hooks.sh` does not exist yet, so evaluation or the build errors out.

- [ ] **Step 3: Write `ci/release-hooks.sh` and the flake wiring**

`ci/release-hooks.sh` — the four subcommands, all four written out. `set-version` prints nothing because nothing on disk carries the version:

```bash
#!/usr/bin/env bash
set -euo pipefail

readonly published_image=ghcr.io/dull-ca/dull.yyc.dev

refuse() {
  if [[ ${GITHUB_ACTIONS-} == true ]]; then
    printf '::error::%s\n' "$*" >&2
  else
    printf 'refusing to release: %s\n' "$*" >&2
  fi
  return 1
}

assert_ready() {
  command -v skopeo >/dev/null 2>&1 || command -v nix >/dev/null 2>&1 \
    || refuse 'neither skopeo nor nix is on PATH, and one of them is what asks ghcr.io whether this version is already published'
}

assert_unpublished() {
  local version=${1-} reference="docker://$published_image:${1#v}" output status=0
  local -a skopeo=(skopeo) authfile=()
  command -v skopeo >/dev/null 2>&1 || skopeo=(nix run nixpkgs#skopeo --)
  if [[ -n ${GHCR_AUTHFILE-} ]]; then authfile=(--authfile "$GHCR_AUTHFILE"); fi

  output=$("${skopeo[@]}" inspect --no-tags "${authfile[@]}" "$reference" 2>&1 >/dev/null) || status=$?

  ((status != 0)) || refuse "$published_image:${version#v} is already published -- one version string names one artifact forever; release the next version instead"

  case $output in
    *'manifest unknown'* | *'name unknown'*) return 0 ;;
  esac
  refuse "could not establish whether $published_image:${version#v} exists; skopeo said: $output"
}

describe() {
  local version=${1-} latest
  if release-guards is-stable "$version"; then
    latest="moves to $version"
  else
    latest="unchanged -- $version is a prerelease"
  fi
  printf '%-9s %s:%s\n' image "$published_image" "${version#v}"
  printf '%-9s %s\n' ':latest' "$latest"
}

set_version() {
  :
}

case ${1-} in
  assert-ready) assert_ready ;;
  assert-unpublished) assert_unpublished "${2-}" ;;
  describe) describe "${2-}" ;;
  set-version) set_version "${2-}" ;;
  image) printf '%s\n' "$published_image" ;;
  *)
    printf 'usage: release-hooks {assert-ready|assert-unpublished|describe|set-version|image} ARGUMENT\n' >&2
    exit 2
    ;;
esac
```

Notes for the implementer, not to be transcribed as comments:
- `2>&1 >/dev/null` (that order) sends stderr to the capture and stdout to the bin. Reversed, it captures the manifest instead of the error.
- `((status != 0)) || refuse ...` — `refuse` returns 1, `set -e` propagates. Verify that; if `set -e` does not fire in your arrangement, use an explicit `if`/`return 1`.
- The `image` subcommand is not part of the contract and `release` never calls it; `release.yml` uses it so the image name lives in exactly one file.
- `case` on the captured text is deliberately narrow. If a different registry error string ever needs admitting, it is one pattern here and no change to dull-nix.

`flake.nix` — bind in the `let` (after `container`):

```nix
release = pkgs.mkReleaseCommand {
  hooks = ./ci/release-hooks.sh;
  repositoryUrl = "https://github.com/dull-ca/dull.yyc.dev";
  warmCommand = "warm-cache";
  releaseWorkflow = "release.yml";
};
```

and in the outputs:

```nix
checks = {
  # ... existing ...
  release-guards-hold = pkgs.releaseGuardsTest;
  release-hooks-classify-registry-errors = ...;  # from Step 1
};

packages = {
  inherit site container release;
  release-guards = pkgs.releaseGuards;
};
```

`repositoryUrl` and not `cliffConfig`: this repo's changelog does not exist yet and carries no history that the bundled `cliff.toml` would drop. Pass `cliffConfig` only if you find a concrete reason, and say why in the report.

- [ ] **Step 4: Run the check and watch it pass**

Run: `cd /home/lakin/personal-repos/dull-ca/dull.yyc.dev && nix build --no-link .#checks.x86_64-linux.release-hooks-classify-registry-errors`

Expected: builds successfully.

- [ ] **Step 5: Exercise the hooks by hand, offline**

Run, and record the output:

```bash
cd /home/lakin/personal-repos/dull-ca/dull.yyc.dev
hooks=$(nix build --no-link --print-out-paths .#release)/bin/release-hooks
guards=$(nix build --no-link --print-out-paths .#release-guards)/bin
PATH="$guards:$PATH" $hooks assert-ready; echo "assert-ready -> $?"
PATH="$guards:$PATH" $hooks describe v1.2.3
PATH="$guards:$PATH" $hooks describe v1.2.3-rc1
PATH="$guards:$PATH" $hooks set-version 1.2.3 | wc -c
$hooks image
$hooks bogus-subcommand; echo "usage arm -> $?"
```

Expected: `assert-ready` exits 0; `describe v1.2.3` prints an `image` line and a `:latest moves to v1.2.3` line, both nine-column aligned; `describe v1.2.3-rc1` says `:latest` is unchanged; `set-version` prints 0 bytes; `image` prints `ghcr.io/dull-ca/dull.yyc.dev`; the usage arm exits 2.

`assert-unpublished` against the real registry cannot be exercised — it needs the network and credentials. The stub-driven check in Step 1 is what covers its logic.

- [ ] **Step 6: Run the whole gate**

Run: `cd /home/lakin/personal-repos/dull-ca/dull.yyc.dev && nix flake check --print-build-logs`

Expected: `all checks passed!`, and the output names `release-guards-hold`, `release-hooks-classify-registry-errors`, `container`, `nginx-config`, `site-check`.

- [ ] **Step 7: Commit** (historian)

---

### Task 2: The two callers — devenv and the workflow

**Files:**
- Modify: `devenv.nix`
- Modify: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: `packages.release`, `packages.release-guards`, `ci/release-hooks.sh` from Task 1.

**`devenv.nix`:**

`scripts.release.exec` becomes the `nix run` form — devenv resolves its own scripts first and the flake output is itself named `release`, so a bare `exec release` would recurse:

```nix
scripts.release.exec = ''cd "$DEVENV_ROOT" && exec nix run "$DEVENV_ROOT#release" -- "$@"'';
```

Keep `scripts.warm-cache` exactly as it is — `release` invokes it by name through `warmCommand`.

Add to `packages` (which already has `biome`, `cachix`, `gh` from the cherry-picked commit): `git-cliff`, and `skopeo`. `git-cliff` writes the changelog and `release` refuses without it. `skopeo` is both what `assert-unpublished` prefers over the `nix run` fallback and — now that the guard refuses on a 401 instead of waving it through — how `skopeo login ghcr.io` is available to produce the credentials the guard needs against a private package.

**`.github/workflows/release.yml`:**

Adopt golem's shape. It must not reference `ci/release-guards.sh` (which does not exist), and it must not re-implement the version regex.

- `actions/checkout@v4` gains `with: fetch-depth: 0` — `release-guards assert-on-main` walks history.
- After the cachix step, before anything else:

```yaml
      - name: Put the release guards on PATH
        run: |
          guards=$(nix build --no-link --print-out-paths .#release-guards)
          echo "$guards/bin" >> "$GITHUB_PATH"

      - name: Resolve the version and the commit
        run: |
          release-guards assert-releasable "$GITHUB_REF_NAME"
          echo "VERSION=${GITHUB_REF_NAME#v}" >> "$GITHUB_ENV"
          echo "RELEASE_COMMIT=$(git rev-parse "$GITHUB_SHA^{commit}")" >> "$GITHUB_ENV"
          if release-guards is-stable "$GITHUB_REF_NAME"; then
            echo "IS_STABLE_RELEASE=true" >> "$GITHUB_ENV"
          else
            echo "IS_STABLE_RELEASE=false" >> "$GITHUB_ENV"
          fi

      - name: Refuse to release a commit that is not on main
        run: release-guards assert-on-main "$RELEASE_COMMIT"
```

This replaces the existing `Derive version from tag` step entirely.

- The existing `Configure container registries.conf` and `Authenticate to ghcr.io` steps move **above** the gate, because the registry guard needs them. The auth step must additionally export the authfile so the hook can read it:

```yaml
          echo "GHCR_AUTHFILE=$RUNNER_TEMP/ghcr-auth.json" >> "$GITHUB_ENV"
```

- Then, still before the gate:

```yaml
      - name: Refuse to overwrite a published version
        run: ci/release-hooks.sh assert-unpublished "$GITHUB_REF_NAME"
```

- The existing `nix flake check`, `nix build .#container`, smoke test and the two `skopeo copy` steps follow, unchanged except that the copies now read `--dest-authfile "$RUNNER_TEMP/ghcr-auth.json"` as they already do. Do not touch the smoke test or its `trap cleanup EXIT`.
- The order is deliberate and worth one comment: everything that can refuse runs before the first thing that costs money or minutes.

- [ ] **Step 1: Edit `devenv.nix`**

As above.

- [ ] **Step 2: Verify the devenv shell evaluates and the wrapper resolves**

Run: `cd /home/lakin/personal-repos/dull-ca/dull.yyc.dev && nix build --no-link --print-out-paths .#release && nix eval --raw .#devShells.x86_64-linux.default.name 2>/dev/null || true`

Then confirm the wrapper's target exists: `nix run .#release -- --help` is **not** safe (it may push). Instead assert the binary is there:

`test -x "$(nix build --no-link --print-out-paths .#release)/bin/release" && echo ok`

Expected: `ok`.

- [ ] **Step 3: Edit `.github/workflows/release.yml`**

As above.

- [ ] **Step 4: Verify the workflow is well-formed and references nothing that does not exist**

Run:

```bash
cd /home/lakin/personal-repos/dull-ca/dull.yyc.dev
nix run nixpkgs#yq -- -e '.jobs.publish.steps | length' .github/workflows/release.yml
grep -n 'release-guards.sh' .github/workflows/release.yml; echo "bespoke references -> $?"
grep -n 'release-hooks.sh\|release-guards' .github/workflows/release.yml
```

Expected: the YAML parses and reports a step count; the `release-guards.sh` grep finds nothing (exit 1); the last grep shows the guards steps and the hook step.

Also confirm every shell snippet is syntactically valid bash by extracting and running `bash -n` over the `run:` blocks, or by eye if extraction is more trouble than it is worth — say which you did.

- [ ] **Step 5: Run the whole gate again**

Run: `cd /home/lakin/personal-repos/dull-ca/dull.yyc.dev && nix flake check --print-build-logs`

Expected: `all checks passed!`

- [ ] **Step 6: Commit** (historian)

---

### Task 3: The documentation

**Files:**
- Create: `docs/adr/0002-the-release-process-is-a-shared-flake-input.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: everything from Tasks 1 and 2.

**The ADR.** Match `docs/adr/0001-interim-ghcr-container-channel.md` in shape: `# 0002 — <title>`, `## Status`, `## Context`, `## Decision`, `## Consequences`. Dated 2026-08-09. It narrows how ADR 0001's `v*` tag trigger is reached and does not revisit ghcr.io as the channel.

It must record:

- A `v*` tag is the whole release interface under ADR 0001, and a tag is unconstrained: any string, any commit, any number of times. Something has to constrain it.
- The constraints — releasable version, unused tag, commit on `origin/main`, version not already published — are not specific to this repo. `dull-ca/nix` owns them as `mkReleaseCommand`, `releaseGuards` and `releaseGuardsTest`, pinned through `flake.lock`; `dull-ca/golem` is the other consumer. This repo does not carry a second copy, and a bespoke implementation on `feat/guarded-releases` was abandoned in favour of the shared one.
- What is repo-specific and therefore lives here: `ci/release-hooks.sh` — the published image `ghcr.io/dull-ca/dull.yyc.dev`, the registry question, and the fact that **nothing on disk carries the version**, so `set-version` prints nothing and a release commit carries `CHANGELOG.md` alone. `package.json`'s `version` is a placeholder nothing reads.
- Three constraints arrive with the shared command and are not negotiable: releases run from a clean `main` level with `origin/main`; the changelog is `CHANGELOG.md` at the root, rewritten in full each release; a hooks script supplying one subcommand supplies all four.
- The version comes from conventional-commit subjects on squash-merged pull requests. A range with no conventional subject is refused rather than guessed at.
- **The registry guard refuses on ambiguity.** golem's inherited version treats every non-zero `skopeo inspect` as "not published", which reads a 401 or a DNS failure as permission to proceed — and against this repo's *private* ghcr package, an anonymous local inspect is exactly that 401. This repo's hook admits only `manifest unknown` and `name unknown` as evidence of absence; anything else refuses and prints what the registry actually said. The consequence, which belongs in `## Consequences`: releasing locally now needs ghcr credentials (`skopeo login ghcr.io`, or `GHCR_AUTHFILE`), where before it silently did not.
- `release.yml` keeps `on: push: tags` and re-runs every guard it still can, because a hand-pushed tag reaches it having bypassed `release` entirely. It cannot re-check that the tag is unused; by then it exists. It obtains the guards from the same pinned flake rather than carrying a copy.
- The gate runs locally before the tag (via `warm-cache`) so a red gate costs no tag, and again in the workflow because a tag can point at any commit.

**`README.md`.** Add a `## Releasing` section after the build section and before `## Credits`. Short. It should say: releases start with `release` in the devenv shell; the bare form derives the version from the conventional-commit subjects since the last tag and `release major|minor|patch|vX.Y.Z` overrules it; it shows what it read and waits for a literal `Y`; it warms the cache, pushes `main`, tags, and watches `release.yml`. Note that it needs a clean `main` at `origin/main`, an authenticated `gh`, and ghcr credentials for the publish guard. Point at `docs/adr/0002-…` and at `dull-ca/nix`'s `mkReleaseCommand` for the rest.

- [ ] **Step 1: Write the ADR**

- [ ] **Step 2: Write the README section**

- [ ] **Step 3: Verify every claim**

Every factual claim in both documents must be checked against the code as written — `ci/release-hooks.sh`, `flake.nix`, `.github/workflows/release.yml`, and `dull-ca/nix`'s `release/release.sh` and README. Re-read them; do not write from memory of this plan. Report any claim in this plan that turned out to be wrong.

- [ ] **Step 4: Commit** (historian)

---

## Verification summary to produce at the end

- Verbatim `nix flake check --print-build-logs` output.
- Verbatim output of the by-hand hook invocations from Task 1 Step 5.
- An explicit statement of what could **not** be exercised: `assert-unpublished` against the real ghcr.io, the `release` command end-to-end (it pushes), and `release.yml` (it needs a tag push).
- Line counts: `ci/release-hooks.sh` here versus `ci/release.sh` (124) + `ci/release-guards.sh` (86) + `ci/release-guards.test.sh` (73) = 283 lines on the abandoned `feat/guarded-releases`.

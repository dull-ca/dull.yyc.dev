# Nix-native site build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the dull.yyc.dev site a pure nix derivation built by a reusable `buildBunPackage` that lives in `dull-nix`, so `nix build .#container` produces the image from committed source alone.

**Architecture:** `dull-nix` gains `overlays.default` exporting `fetchBunDeps` (a fixed-output derivation that runs `bun install` with network access and yields a `node_modules` tree) and `buildBunPackage` (a pure derivation that copies those deps in writable, patches ELF and shebangs, and runs a `package.json` script). A committed bun fixture project in `dull-nix` proves both, as checks. `dull.yyc.dev` then imports `nixpkgs` with that overlay applied, defines `packages.site`, feeds it straight into `mkContainer`, and both GitHub workflows drop bun entirely.

**Tech Stack:** Nix flakes (`nixpkgs-unstable`, `flake-utils`), bun 1.3.13 (from the nixpkgs pin), `autoPatchelfHook`, `dockerTools.buildLayeredImage`, Astro, GitHub Actions.

**Source spec:** `docs/superpowers/specs/2026-08-08-nix-native-site-build-design.md`

## Global Constraints

- **Two repos, two branches.** `dull-nix` = `/home/lakin/personal-repos/dull-ca/nix`, branch `feat/build-bun-package`. `dull.yyc.dev` = `/home/lakin/personal-repos/dull-ca/dull.yyc.dev`, branch `feat/nix-native-site-build`. Never commit to `main` in either.
- **Never push, never run `gh`, never run any authenticated or remote-mutating command.** Local branches and local commits only.
- **`dull.yyc.dev`'s `dull-nix` input must stay `github:dull-ca/nix` in every commit.** The local dull-nix changes are unpushed, so the consumer is verified with `nix build --override-input dull-nix /home/lakin/personal-repos/dull-ca/nix ...`. Never commit a `path:` input and never hand-edit `flake.lock`.
- **Verify by building, not by reading.** Every task's completion claim is backed by pasted real command output.
- **`devenv.nix` is not touched.** bun stays the local development toolchain.
- **No package-manager switch.** bun stays.
- Only system `x86_64-linux`.
- The site's deps FOD hash is already known and verified reproducible: `sha256-iPP83n41DF0EHZQdsbq1F9SnSxWp5kn+48QCUu4Z2Lk=`. It is an **output** hash — it depends only on `package.json` + `bun.lock` content and the bun version, not on how `src` is filtered. The fixture's hash is different and must be discovered.
- Known-good spike, already verified — reuse rather than rediscover: `/tmp/claude-1000/-home-lakin-personal-repos-dull-ca-dull-yyc-dev/4f9b7153-80fe-46e9-aa1e-a082578840fb/scratchpad/spike/flake.nix`.
  - `bun install --frozen-lockfile --no-progress --ignore-scripts`, with `SSL_CERT_FILE` pointed at `pkgs.cacert`.
  - Strip `node_modules/.cache` and any `.bun-tag*` before hashing.
  - `autoPatchelfIgnoreMissingDeps = [ "libc.musl-x86_64.so.1" ]` — bun installs musl native variants alongside gnu ones and they never load here.
  - `patchShebangs node_modules` over the **whole** tree; `node_modules/.bin` entries are symlinks, so patching only `.bin` leaves `#!/usr/bin/env node` in the real files and the build dies with `bad interpreter`.
  - `buildInputs = [ pkgs.stdenv.cc.cc.lib ]`; `nativeBuildInputs` needs `pkgs.bun`, `pkgs.nodejs`, `pkgs.autoPatchelfHook`.
  - `dontAutoPatchelf = true` so the fixup hook does not rescan the ELF-free build output.
- **Repo conventions to match in `dull-nix`:** one single `flake.nix` holding the derivations inline (no `pkgs/` subdirectory), `flake-utils.lib.eachSystem [ "x86_64-linux" ]`, every non-obvious property asserted as a `checks.*` entry with a failure message that says what regressed, and a README section that explains *why* rather than *what*.
- **Role split (enforced by the orchestrator, stated here so implementers know the contract):** the implementing agent writes **zero comments and zero prose**; a separate documenting agent adds every comment, README section and doc afterwards. Do not "helpfully" add comments during implementation.

---

## File Structure

**`dull-nix` (`/home/lakin/personal-repos/dull-ca/nix`)**

- Modify `flake.nix` — add top-level `overlays.default` (system-independent, so it sits outside `eachSystem`), apply it to the flake's own `pkgs`, and add the two fixture checks.
- Create `fixtures/bun-package/package.json` — the minimal bun project the checks build.
- Create `fixtures/bun-package/bun.lock` — its committed lockfile.
- Create `fixtures/bun-package/src/index.js` — fixture source, bundled by the build script.
- Create `fixtures/bun-package/src/style.css` — fixture source, minified by the build script.
- Modify `README.md` — a `## buildBunPackage` section.

**`dull.yyc.dev` (`/home/lakin/personal-repos/dull-ca/dull.yyc.dev`)**

- Modify `flake.nix` — apply the overlay, add `siteSrc` filter, `packages.site`, unconditional `packages.container`, `checks.site-check`; delete `siteDist`, `builtins.getEnv "DULL_SITE_DIST"` and the `optionalAttrs` guard.
- Modify `.github/workflows/ci.yml` — drop bun, drop `--impure`/`DULL_SITE_DIST`.
- Modify `.github/workflows/release.yml` — same, keeping the skopeo publish steps.

---

## Task 1: `fetchBunDeps` and the bun fixture project

**Repo:** `dull-nix` — `/home/lakin/personal-repos/dull-ca/nix`, branch `feat/build-bun-package`.

**Files:**
- Create: `/home/lakin/personal-repos/dull-ca/nix/fixtures/bun-package/package.json`
- Create: `/home/lakin/personal-repos/dull-ca/nix/fixtures/bun-package/bun.lock`
- Create: `/home/lakin/personal-repos/dull-ca/nix/fixtures/bun-package/src/index.js`
- Create: `/home/lakin/personal-repos/dull-ca/nix/fixtures/bun-package/src/style.css`
- Modify: `/home/lakin/personal-repos/dull-ca/nix/flake.nix`

**Interfaces:**
- Produces: `overlays.default`, a standard nixpkgs overlay `final: prev: { ... }` adding `fetchBunDeps` to `pkgs`.
- Produces: `fetchBunDeps { src, hash, pname ? "bun-deps" }` → derivation whose `$out` **is** the `node_modules` tree (i.e. `$out/esbuild/package.json` exists, not `$out/node_modules/esbuild/...`). `src` may be a path or a `lib.cleanSourceWith` result; only `package.json` and `bun.lock` at its root are read.
- Produces: `checks.bun-fixture-deps-contain-platform-split-natives`.
- Consumed by Task 2 (`buildBunPackage` calls `fetchBunDeps`) and Task 4 (site deps).

### Why the fixture needs native modules

The single most fragile thing in this builder is `autoPatchelfIgnoreMissingDeps = [ "libc.musl-x86_64.so.1" ]`. It exists because bun installs `*-linux-x64-musl` native packages alongside the `*-linux-x64-gnu` ones it will actually load. If bun ever stops doing that, the exclusion becomes dead code that silently hides a *real* missing dependency later. So the fixture must depend on a package with platform-split natives, and a check must assert both variants are present.

`esbuild` alone will not do: it is statically linked and autoPatchelf skips it. It is still worth including, because its `bin/esbuild` is a `#!/usr/bin/env node` script reached through a `node_modules/.bin` **symlink** — which is exactly the shape that proves `patchShebangs node_modules` (Task 2).

- [ ] **Step 1: Create the branch**

```bash
cd /home/lakin/personal-repos/dull-ca/nix
git checkout -b feat/build-bun-package
```

- [ ] **Step 2: Write the fixture project source**

`fixtures/bun-package/package.json`:

```json
{
  "name": "dull-nix-bun-fixture",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "esbuild src/index.js --bundle --minify --outfile=dist/bundle.js && lightningcss --minify src/style.css -o dist/style.css"
  },
  "dependencies": {
    "esbuild": "^0.25.0",
    "lightningcss-cli": "^1.30.0"
  }
}
```

`fixtures/bun-package/src/index.js`:

```js
export const greeting = "buildBunPackage works";

console.log(greeting);
```

`fixtures/bun-package/src/style.css`:

```css
.fixture {
  color: rgb(0, 0, 0);
  padding: 1px 1px 1px 1px;
}
```

- [ ] **Step 3: Generate the lockfile with the *pinned* bun**

The lockfile must be one that `--frozen-lockfile` accepts under the bun version nixpkgs pins (1.3.13 at time of writing). `--inputs-from` makes `nixpkgs#bun` resolve through this repo's own `flake.lock` rather than the registry:

```bash
cd /home/lakin/personal-repos/dull-ca/nix/fixtures/bun-package
nix run --inputs-from /home/lakin/personal-repos/dull-ca/nix nixpkgs#bun -- install --ignore-scripts
```

Then confirm a **text** `bun.lock` was produced (not a binary `bun.lockb`) and delete the local `node_modules`:

```bash
cd /home/lakin/personal-repos/dull-ca/nix/fixtures/bun-package
ls
head -5 bun.lock
rm -rf node_modules
```

If a `bun.lockb` appeared instead, re-run with `--save-text-lockfile`.

- [ ] **Step 4: Confirm the fixture actually exercises the musl split**

Before writing any nix, check that this dependency set really does pull both variants. Reinstall into a scratch dir and look:

```bash
cd /home/lakin/personal-repos/dull-ca/nix/fixtures/bun-package
nix run --inputs-from /home/lakin/personal-repos/dull-ca/nix nixpkgs#bun -- install --frozen-lockfile --ignore-scripts
ls node_modules | grep -E 'linux-x64'
```

Expected: at least one `*-linux-x64-gnu` **and** at least one `*-linux-x64-musl` entry.

If no musl variant appears, this fixture does not exercise the property the check is meant to protect. Do not paper over it — add a dependency that does (candidates with platform-split natives: `@tailwindcss/oxide`, `@biomejs/biome`, `rollup`), regenerate the lockfile, and **report in your task report exactly which dependency set you settled on and what `ls node_modules | grep linux-x64` printed.** Then `rm -rf node_modules` again.

- [ ] **Step 5: Write the failing check**

Add to `flake.nix`. Restructure `outputs` so the overlay is a top-level (non-system) output and `pkgs` is imported with it applied. The existing `nginx-static-no-tls` derivation and its four checks stay exactly as they are:

```nix
  outputs = { self, nixpkgs, flake-utils }:
    {
      overlays.default = final: prev: { };
    } // flake-utils.lib.eachSystem [ "x86_64-linux" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
        };
        static = pkgs.pkgsStatic;

        # ... nginx-static-no-tls unchanged ...

        bunFixtureDeps = pkgs.fetchBunDeps {
          src = ./fixtures/bun-package;
          pname = "bun-fixture-deps";
          hash = pkgs.lib.fakeHash;
        };
      in
      {
        # ... packages unchanged ...

        checks = {
          # ... the four nginx checks unchanged ...

          bun-fixture-deps-contain-platform-split-natives =
            pkgs.runCommand "bun-fixture-deps-contain-platform-split-natives" { } ''
              gnu=$(ls ${bunFixtureDeps} | grep -E 'linux-x64-gnu$' || true)
              musl=$(ls ${bunFixtureDeps} | grep -E 'linux-x64-musl$' || true)

              echo "gnu variants: $gnu"
              echo "musl variants: $musl"

              if [ -z "$gnu" ]; then
                echo "FAIL: no *-linux-x64-gnu package in the deps tree."
                exit 1
              fi

              if [ -z "$musl" ]; then
                echo "FAIL: no *-linux-x64-musl package in the deps tree."
                exit 1
              fi

              echo "$gnu $musl" > $out
            '';
        };
      });
```

- [ ] **Step 6: Run the check to verify it fails**

```bash
cd /home/lakin/personal-repos/dull-ca/nix
nix flake check --print-build-logs 2>&1 | tail -30
```

Expected: FAIL, evaluation error — `attribute 'fetchBunDeps' missing`.

- [ ] **Step 7: Implement `fetchBunDeps` in the overlay**

Replace the empty overlay body:

```nix
      overlays.default = final: prev: {
        fetchBunDeps =
          { src
          , hash
          , pname ? "bun-deps"
          }:
          let
            lockSrc = final.lib.cleanSourceWith {
              inherit src;
              name = "${pname}-lock-src";
              filter = path: type:
                type == "regular"
                && builtins.elem (baseNameOf path) [ "package.json" "bun.lock" ];
            };
          in
          final.stdenvNoCC.mkDerivation {
            inherit pname;
            version = "0";
            src = lockSrc;

            nativeBuildInputs = [ final.bun final.cacert ];

            buildPhase = ''
              runHook preBuild
              export HOME=$TMPDIR
              export SSL_CERT_FILE=${final.cacert}/etc/ssl/certs/ca-bundle.crt
              bun install --frozen-lockfile --no-progress --ignore-scripts
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              rm -rf node_modules/.cache
              find node_modules -name '.bun-tag*' -delete
              cp -r node_modules $out
              runHook postInstall
            '';

            dontFixup = true;
            outputHashMode = "recursive";
            outputHashAlgo = "sha256";
            outputHash = hash;
          };
      };
```

- [ ] **Step 8: Discover the fixture's real deps hash**

`lib.fakeHash` makes the build fail with the correct hash in the message:

```bash
cd /home/lakin/personal-repos/dull-ca/nix
nix build .#checks.x86_64-linux.bun-fixture-deps-contain-platform-split-natives --print-build-logs 2>&1 | tail -20
```

Expected: `hash mismatch in fixed-output derivation` with a `got: sha256-...` line. Copy that value into `hash =` in place of `pkgs.lib.fakeHash`.

- [ ] **Step 9: Run the check to verify it passes**

```bash
cd /home/lakin/personal-repos/dull-ca/nix
nix flake check --print-build-logs 2>&1 | tail -20
```

Expected: PASS, no output on success. Also confirm the deps tree really is a bare `node_modules` (this is the shape Task 2 depends on):

```bash
cd /home/lakin/personal-repos/dull-ca/nix
nix build .#checks.x86_64-linux.bun-fixture-deps-contain-platform-split-natives --print-build-logs
cat result
```

Expected: a line naming both a `-linux-x64-gnu` and a `-linux-x64-musl` package.

- [ ] **Step 10: Verify the FOD is reproducible**

The whole approach rests on this. Do not skip it:

```bash
cd /home/lakin/personal-repos/dull-ca/nix
nix build --rebuild .#checks.x86_64-linux.bun-fixture-deps-contain-platform-split-natives --print-build-logs 2>&1 | tail -20
```

Expected: no `hash mismatch` and no `differs from previous round` output. If it is *not* reproducible, stop and report — it changes the design, and a non-deterministic FOD must not be committed as a green check.

- [ ] **Step 11: Commit**

```bash
cd /home/lakin/personal-repos/dull-ca/nix
git add fixtures flake.nix
git commit
```

---

## Task 2: `buildBunPackage`

**Repo:** `dull-nix` — `/home/lakin/personal-repos/dull-ca/nix`, branch `feat/build-bun-package`.

**Files:**
- Modify: `/home/lakin/personal-repos/dull-ca/nix/flake.nix`

**Interfaces:**
- Consumes: `fetchBunDeps { src, hash, pname }` from Task 1.
- Produces: `buildBunPackage { src, bunDepsHash, buildScript ? "build", installDir ? "dist", ... }` → derivation. Every unrecognised argument is forwarded to `stdenvNoCC.mkDerivation`, and **caller arguments win over the builder's defaults**, so a caller can override `installPhase` (Task 5 relies on exactly this). `nativeBuildInputs`, `buildInputs` and `passthru` are *merged*, not replaced.
- Produces: `passthru.bunDeps` on the result — the `fetchBunDeps` derivation, so callers can reuse the same deps tree.
- Produces: `checks.buildBunPackage-builds-fixture`.
- Consumed by Task 4 (`packages.site`) and Task 5 (`checks.site-check`).

- [ ] **Step 1: Write the failing check**

Add to `flake.nix`, in the same `let` and `checks` as Task 1:

```nix
        bunFixture = pkgs.buildBunPackage {
          pname = "bun-fixture";
          src = ./fixtures/bun-package;
          bunDepsHash = "<the hash Task 1 discovered>";
        };
```

```nix
          buildBunPackage-builds-fixture =
            pkgs.runCommand "buildBunPackage-builds-fixture" { } ''
              if [ ! -f ${bunFixture}/bundle.js ]; then
                echo "FAIL: esbuild produced no bundle.js -- the bundler never ran."
                ls -R ${bunFixture}
                exit 1
              fi

              if ! grep -q 'buildBunPackage works' ${bunFixture}/bundle.js; then
                echo "FAIL: bundle.js does not contain the fixture source string."
                cat ${bunFixture}/bundle.js
                exit 1
              fi

              if [ ! -f ${bunFixture}/style.css ]; then
                echo "FAIL: lightningcss produced no style.css -- the native"
                echo "module never loaded."
                ls -R ${bunFixture}
                exit 1
              fi

              if grep -q 'rgb(0, 0, 0)' ${bunFixture}/style.css; then
                echo "FAIL: style.css is not minified -- lightningcss ran but did"
                echo "no work."
                cat ${bunFixture}/style.css
                exit 1
              fi

              cat ${bunFixture}/style.css > $out
            '';
```

- [ ] **Step 2: Run the check to verify it fails**

```bash
cd /home/lakin/personal-repos/dull-ca/nix
nix flake check --print-build-logs 2>&1 | tail -30
```

Expected: FAIL, evaluation error — `attribute 'buildBunPackage' missing`.

- [ ] **Step 3: Implement `buildBunPackage` in the overlay**

Add alongside `fetchBunDeps` in `overlays.default`:

```nix
        buildBunPackage =
          { src
          , bunDepsHash
          , buildScript ? "build"
          , installDir ? "dist"
          , nativeBuildInputs ? [ ]
          , buildInputs ? [ ]
          , passthru ? { }
          , ...
          }@args:
          let
            bunDeps = final.fetchBunDeps {
              inherit src;
              hash = bunDepsHash;
              pname = "${args.pname or "bun-package"}-deps";
            };

            forwarded = builtins.removeAttrs args [
              "bunDepsHash"
              "buildScript"
              "installDir"
              "nativeBuildInputs"
              "buildInputs"
              "passthru"
            ];
          in
          final.stdenvNoCC.mkDerivation ({
            inherit src;

            nativeBuildInputs = [
              final.bun
              final.nodejs
              final.autoPatchelfHook
            ] ++ nativeBuildInputs;

            buildInputs = [ final.stdenv.cc.cc.lib ] ++ buildInputs;

            autoPatchelfIgnoreMissingDeps = [ "libc.musl-x86_64.so.1" ];
            dontAutoPatchelf = true;

            configurePhase = ''
              runHook preConfigure
              cp -r ${bunDeps} node_modules
              chmod -R u+w node_modules
              autoPatchelf node_modules
              patchShebangs node_modules
              runHook postConfigure
            '';

            buildPhase = ''
              runHook preBuild
              export HOME=$TMPDIR
              bun run ${buildScript}
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              cp -r ${installDir} $out
              runHook postInstall
            '';

            passthru = { inherit bunDeps; } // passthru;
          } // forwarded);
```

- [ ] **Step 4: Run the check to verify it passes**

```bash
cd /home/lakin/personal-repos/dull-ca/nix
nix flake check --print-build-logs 2>&1 | tail -20
nix build .#checks.x86_64-linux.buildBunPackage-builds-fixture --print-build-logs
cat result
```

Expected: `nix flake check` clean; `result` holds the minified CSS.

- [ ] **Step 5: Prove the two fragile settings are load-bearing**

Both `autoPatchelfIgnoreMissingDeps` and the whole-tree `patchShebangs` are unobvious, and a future reader will be tempted to delete them. Establish that they are needed *right now*, on this fixture, so the documenting agent can state it as fact rather than as folklore. These are temporary local edits — revert each before moving on.

1. Temporarily delete the `autoPatchelfIgnoreMissingDeps` line, run `nix build .#checks.x86_64-linux.buildBunPackage-builds-fixture --print-build-logs 2>&1 | tail -30`, record the failure, restore the line.
2. Temporarily change `patchShebangs node_modules` to `patchShebangs node_modules/.bin`, run the same build, record the failure, restore the line.

Record the exact error text for each in your task report. If either edit does **not** fail the build, say so plainly — that means the fixture does not cover that property and the check is weaker than it looks.

```bash
cd /home/lakin/personal-repos/dull-ca/nix
git diff --stat
```

Expected after restoring: `flake.nix` diff matches what you intended to keep.

- [ ] **Step 6: Re-run the full gate and commit**

```bash
cd /home/lakin/personal-repos/dull-ca/nix
nix flake check --print-build-logs 2>&1 | tail -20
git add flake.nix
git commit
```

---

## Task 3: `dull-nix` README section

**Repo:** `dull-nix` — `/home/lakin/personal-repos/dull-ca/nix`, branch `feat/build-bun-package`.

**Files:**
- Modify: `/home/lakin/personal-repos/dull-ca/nix/README.md`

This task is documentation only; there is no implementation step. It is a separate task because it documents the union of Tasks 1 and 2, and because a reviewer can reject the prose while accepting the code.

**What the section must cover** (match the existing `nginx-static-no-tls` section's register — short, direct, explains *why*, no restating of what the code plainly says):

- [ ] **Step 1: Write the `## buildBunPackage` section**

It must answer, at minimum:

1. How a consumer wires it up — the overlay, and the fact that `pkgs.buildBunPackage` is then used exactly like `pkgs.buildNpmPackage`.
2. Why it exists at all: `buildBunPackage`, `bun.fetchDeps` and `bunConfigHook` are **absent** from nixpkgs (verified against the same `nixpkgs-unstable` this flake pins), while `buildNpmPackage`/`fetchNpmDeps` and `pnpm.fetchDeps` exist. The blessed builders are the same mechanism — `fetchNpmDeps` is itself an FOD with a hash the caller bumps — so this is not an unusual approach, just an unwritten one.
3. The standing cost: **changing `bun.lock` means bumping `bunDepsHash`**, identical to what `npmDepsHash` imposes on every `buildNpmPackage`. Show the workflow for finding the new hash (`lib.fakeHash`, read the `got:` line).
4. Why `autoPatchelfIgnoreMissingDeps = [ "libc.musl-x86_64.so.1" ]` is there — bun installs musl native variants alongside the gnu ones and they never load on this platform. Cite the observed failure from Task 2 Step 5.
5. Why `patchShebangs` covers the whole tree and not `node_modules/.bin` — `.bin` entries are symlinks. Cite the observed `bad interpreter` failure from Task 2 Step 5.
6. That the fixture check makes `dull-nix` CI depend on the npm registry, and that this was accepted deliberately: without it a `buildBunPackage` regression only ever surfaces as a downstream repo's red CI, and the weekly `update.yml` nixpkgs bump cannot report that it broke the builder.
7. That `--ignore-scripts` is used, so packages needing a postinstall step are not supported — and that this is what keeps the FOD hashable.

- [ ] **Step 2: Verify the documented consumer snippet actually evaluates**

Do not ship a README snippet nobody ran. Write the exact snippet from the README to a scratch flake and evaluate it, or at minimum confirm the attribute path it names resolves:

```bash
cd /home/lakin/personal-repos/dull-ca/nix
nix eval --raw --expr 'builtins.typeOf (builtins.getFlake "/home/lakin/personal-repos/dull-ca/nix").overlays.default' --impure
```

Expected: `lambda`.

- [ ] **Step 3: Commit**

```bash
cd /home/lakin/personal-repos/dull-ca/nix
git add README.md
git commit
```

---

## Task 4: `dull.yyc.dev` builds the site in nix

**Repo:** `dull.yyc.dev` — `/home/lakin/personal-repos/dull-ca/dull.yyc.dev`, branch `feat/nix-native-site-build`.

**Files:**
- Modify: `/home/lakin/personal-repos/dull-ca/dull.yyc.dev/flake.nix`

**Interfaces:**
- Consumes: `dull-nix.overlays.default`, giving `pkgs.buildBunPackage` (Task 2).
- Produces: `packages.site` (the built `dist/` as a store path), `packages.container` — **unconditional**, no `optionalAttrs`.
- Produces: `siteSrc` and `bunDepsHash` in the `let` block, both consumed by Task 5.

**How to verify against unpushed `dull-nix`:** the committed input stays `github:dull-ca/nix`. Every build command below therefore carries
`--override-input dull-nix /home/lakin/personal-repos/dull-ca/nix`.
After **every** such command, confirm the lock was not rewritten:

```bash
cd /home/lakin/personal-repos/dull-ca/dull.yyc.dev
git diff --stat -- flake.lock
```

Expected: empty. If it is not empty, `git checkout -- flake.lock` and report it.

- [ ] **Step 1: Create the branch**

```bash
cd /home/lakin/personal-repos/dull-ca/dull.yyc.dev
git checkout -b feat/nix-native-site-build
```

- [ ] **Step 2: Write the failing build**

Edit `flake.nix`. Apply the overlay and add the site derivation; leave `mkContainer`, `checks.nginx-config` and the whole `nixConfig`/`inputs` block otherwise untouched:

```nix
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ dull-nix.overlays.default ];
        };
        nginx = dull-nix.packages.${system}.nginx-static-no-tls;

        siteSrc = pkgs.lib.cleanSourceWith {
          name = "dull-yyc-dev-src";
          src = pkgs.lib.cleanSource ./.;
          filter = path: type:
            let rel = pkgs.lib.removePrefix (toString ./. + "/") (toString path);
            in !(pkgs.lib.hasPrefix "node_modules" rel
              || pkgs.lib.hasPrefix "dist" rel
              || pkgs.lib.hasPrefix ".astro" rel);
        };

        bunDepsHash = "sha256-iPP83n41DF0EHZQdsbq1F9SnSxWp5kn+48QCUu4Z2Lk=";

        site = pkgs.buildBunPackage {
          pname = "dull-yyc-dev-site";
          src = siteSrc;
          inherit bunDepsHash;
        };
```

Delete the `siteDist` binding entirely. Change `mkContainer` from a function of `dist` to use `site` directly, or keep it as a function and call it with `site` — the implementer's judgement; `mkContainer site` is the smaller diff.

Replace the `packages` output:

```nix
        packages = {
          inherit site;
          container = mkContainer site;
        };
```

- [ ] **Step 3: Run the build to verify the site derivation works**

```bash
cd /home/lakin/personal-repos/dull-ca/dull.yyc.dev
nix build --override-input dull-nix /home/lakin/personal-repos/dull-ca/nix .#site --print-build-logs 2>&1 | tail -40
ls result
```

Expected: `result/index.html` plus `_astro/` assets.

If the build fails with a **hash mismatch**, do not assume the spike hash was wrong — first confirm your `package.json` and `bun.lock` are the committed ones. Only then take the `got:` value, and **report the change and why it happened.**

- [ ] **Step 4: Verify the output matches what bun produces**

The spec claims the nix `dist/` matches a bun-built one apart from the local `dist/` being stale. Confirm it independently:

```bash
cd /home/lakin/personal-repos/dull-ca/dull.yyc.dev
find result -type f | sort | head -20
grep -o 'classified-stamp[^"]*' result/index.html | head -3
```

Expected: the same asset filenames as the site currently serves. Record the file list in your report.

- [ ] **Step 5: Verify the container builds purely**

No `--impure`, no `DULL_SITE_DIST`:

```bash
cd /home/lakin/personal-repos/dull-ca/dull.yyc.dev
nix build --override-input dull-nix /home/lakin/personal-repos/dull-ca/nix .#container --print-build-logs 2>&1 | tail -20
ls -l result
```

Expected: `result` is a `.tar.gz` docker archive.

- [ ] **Step 6: Prove the pure evaluation really is pure**

The point of the whole change is that `container` no longer needs `--impure`. Assert it:

```bash
cd /home/lakin/personal-repos/dull-ca/dull.yyc.dev
nix eval --override-input dull-nix /home/lakin/personal-repos/dull-ca/nix .#packages.x86_64-linux.container.drvPath
grep -rn 'DULL_SITE_DIST\|getEnv\|optionalAttrs' flake.nix || echo "none remain"
```

Expected: a `/nix/store/....drv` path, and `none remain`.

- [ ] **Step 7: Smoke test the real image with docker**

```bash
cd /home/lakin/personal-repos/dull-ca/dull.yyc.dev
docker load < result
docker rm -f dull-smoke 2>/dev/null || true
docker run -d --name dull-smoke -p 8099:8080 dull.yyc.dev:latest
sleep 3
curl -s -o /dev/null -w 'root=%{http_code} ctype=%{content_type}\n' http://127.0.0.1:8099/
curl -s -o /dev/null -w 'missing=%{http_code}\n' http://127.0.0.1:8099/definitely-not-here
curl -s http://127.0.0.1:8099/ | head -5
docker logs dull-smoke
docker rm -f dull-smoke
```

Expected: `root=200 ctype=text/html`, `missing=404`, and the served HTML is the site's real markup — not an nginx default page and not an empty directory listing.

- [ ] **Step 8: Confirm the lock is untouched, then commit**

```bash
cd /home/lakin/personal-repos/dull-ca/dull.yyc.dev
git status --short
git diff --stat -- flake.lock
grep -n 'dull-nix.url' flake.nix
git add flake.nix
git commit
```

Expected: `flake.lock` unmodified; `dull-nix.url = "github:dull-ca/nix";` still committed.

---

## Task 5: `bun run check` becomes `checks.site-check`

**Repo:** `dull.yyc.dev` — `/home/lakin/personal-repos/dull-ca/dull.yyc.dev`, branch `feat/nix-native-site-build`.

**Files:**
- Modify: `/home/lakin/personal-repos/dull-ca/dull.yyc.dev/flake.nix`

**Interfaces:**
- Consumes: `siteSrc` and `bunDepsHash` from Task 4; `buildBunPackage`'s caller-args-win merge from Task 2.
- Produces: `checks.site-check`.

`package.json`'s `check` script is `astro check && biome check .`. It produces no output directory, so `installDir` is meaningless here — override `installPhase` instead. That override is possible only because Task 2 forwards caller arguments *over* the builder's defaults; if it does not work, that is a Task 2 bug, not something to work around here.

Because `siteSrc` and `bunDepsHash` are identical to Task 4's, `fetchBunDeps` resolves to the **same store path** and the deps are installed once, not twice.

- [ ] **Step 1: Write the failing check**

Add to the `let` block:

```nix
        siteCheck = pkgs.buildBunPackage {
          pname = "dull-yyc-dev-check";
          src = siteSrc;
          inherit bunDepsHash;
          buildScript = "check";
          installPhase = ''
            runHook preInstall
            touch $out
            runHook postInstall
          '';
        };
```

and to `checks`:

```nix
          site-check = siteCheck;
```

- [ ] **Step 2: Run it**

```bash
cd /home/lakin/personal-repos/dull-ca/dull.yyc.dev
nix build --override-input dull-nix /home/lakin/personal-repos/dull-ca/nix .#checks.x86_64-linux.site-check --print-build-logs 2>&1 | tail -40
```

Expected: PASS, with `astro check` and `biome check` output visible in the build log.

Likely first failure: `astro check` needs generated types (`.astro/`), which the source filter excludes. If it fails for that reason, add `astro sync` ahead of it via a `preBuild` hook in this derivation — do **not** unfilter `.astro`, which is a gitignored artifact and would make the derivation depend on local state.

Second likely failure: `biome check .` walking `node_modules`. If it does, confirm whether `biome.json` already excludes it before changing anything.

Report which of these (if either) you hit and what you did.

- [ ] **Step 3: Verify the deps derivation is shared, not duplicated**

```bash
cd /home/lakin/personal-repos/dull-ca/dull.yyc.dev
nix eval --raw --override-input dull-nix /home/lakin/personal-repos/dull-ca/nix .#packages.x86_64-linux.site.bunDeps.outPath
echo
nix eval --raw --override-input dull-nix /home/lakin/personal-repos/dull-ca/nix .#checks.x86_64-linux.site-check.bunDeps.outPath
echo
```

Expected: the two store paths are identical. If they differ, the deps are being fetched twice and the `siteSrc`/`bunDepsHash` sharing is not working — fix it rather than accepting it.

- [ ] **Step 4: Run the whole gate**

```bash
cd /home/lakin/personal-repos/dull-ca/dull.yyc.dev
nix flake check --override-input dull-nix /home/lakin/personal-repos/dull-ca/nix --print-build-logs 2>&1 | tail -20
git diff --stat -- flake.lock
```

Expected: clean; lock untouched.

- [ ] **Step 5: Commit**

```bash
cd /home/lakin/personal-repos/dull-ca/dull.yyc.dev
git add flake.nix
git commit
```

---

## Task 6: Collapse both workflows

**Repo:** `dull.yyc.dev` — `/home/lakin/personal-repos/dull-ca/dull.yyc.dev`, branch `feat/nix-native-site-build`.

**Files:**
- Modify: `/home/lakin/personal-repos/dull-ca/dull.yyc.dev/.github/workflows/ci.yml`
- Modify: `/home/lakin/personal-repos/dull-ca/dull.yyc.dev/.github/workflows/release.yml`

**Interfaces:**
- Consumes: `packages.container` being pure (Task 4) and `checks.site-check` (Task 5).

**Removed from both files:** `oven-sh/setup-bun@v2`, `bun install --frozen-lockfile`, `bun run check`, `bun run build`, `DULL_SITE_DIST`, `--impure`.

**Kept, unchanged, in `release.yml`:** the version-derivation step, the `registries.conf` step, the `skopeo login` step, and both `skopeo copy` steps — including their comments, which document facts the YAML does not show.

**Kept in both:** the smoke test, byte-for-byte identical between the two files.

**Comments:** cut to the few facts not evident from the YAML. The `registries.conf` v1/v2 workaround and the `trap cleanup EXIT` rationale stay. Everything else goes — **including the `ci.yml` header claim that `nix flake check` is the machine-agnostic gate**, which was false when written and is the reason this spec exists. If it is restated at all, it must be restated as something now true.

- [ ] **Step 1: Rewrite `ci.yml`**

The `check` job's steps become exactly:

```yaml
      - uses: actions/checkout@v4

      - uses: cachix/install-nix-action@v31
      - uses: cachix/cachix-action@v15
        with:
          name: dull-ca
          authToken: ${{ secrets.DULL_CA_CACHIX_PRIVATE_KEY }}

      - run: nix flake check --print-build-logs

      - run: nix build .#container --print-build-logs

      - name: Smoke test the image
        run: |
          docker load < result

          cleanup() {
            docker logs dull-smoke || true
            docker rm -f dull-smoke || true
          }
          trap cleanup EXIT

          docker run -d --name dull-smoke -p 8099:8080 dull.yyc.dev:latest

          for i in $(seq 1 30); do
            curl -sf -o /dev/null http://127.0.0.1:8099/ && break
            sleep 1
          done
          root=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8099/)
          ctype=$(curl -s -o /dev/null -w '%{content_type}' http://127.0.0.1:8099/)
          missing=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8099/definitely-not-here)
          test "$root" = 200 || { echo "FAIL root: $root"; exit 1; }
          test "$ctype" = "text/html" || { echo "FAIL ctype: $ctype"; exit 1; }
          test "$missing" = 404 || { echo "FAIL 404: $missing"; exit 1; }
          echo "smoke test passed"
```

`name`, `on`, `runs-on` and the `permissions: contents: read` block are unchanged.

- [ ] **Step 2: Rewrite `release.yml`**

Same three deletions. Its step list becomes: checkout → `install-nix` → `cachix` → `nix flake check --print-build-logs` → `nix build .#container --print-build-logs` → smoke test → derive version → registries.conf → skopeo login → publish versioned → move `:latest`.

- [ ] **Step 3: Verify both files are valid YAML and the two smoke tests are identical**

```bash
cd /home/lakin/personal-repos/dull-ca/dull.yyc.dev
nix run nixpkgs#yq-go -- '.jobs' .github/workflows/ci.yml > /dev/null && echo "ci.yml parses"
nix run nixpkgs#yq-go -- '.jobs' .github/workflows/release.yml > /dev/null && echo "release.yml parses"

nix run nixpkgs#yq-go -- '.jobs.check.steps[] | select(.name == "Smoke test the image") | .run' .github/workflows/ci.yml > /tmp/smoke-ci.txt
nix run nixpkgs#yq-go -- '.jobs.publish.steps[] | select(.name == "Smoke test the image") | .run' .github/workflows/release.yml > /tmp/smoke-release.txt
diff /tmp/smoke-ci.txt /tmp/smoke-release.txt && echo "smoke tests identical"
```

Expected: both parse, and `smoke tests identical`.

- [ ] **Step 4: Verify nothing bun-shaped survives**

```bash
cd /home/lakin/personal-repos/dull-ca/dull.yyc.dev
grep -rn 'setup-bun\|bun install\|bun run\|DULL_SITE_DIST\|--impure' .github/workflows/ || echo "clean"
```

Expected: `clean`.

- [ ] **Step 5: Re-run the local equivalent of what CI will run**

The workflows cannot be executed here, so run the commands they contain:

```bash
cd /home/lakin/personal-repos/dull-ca/dull.yyc.dev
nix flake check --override-input dull-nix /home/lakin/personal-repos/dull-ca/nix --print-build-logs 2>&1 | tail -20
nix build --override-input dull-nix /home/lakin/personal-repos/dull-ca/nix .#container --print-build-logs 2>&1 | tail -5
docker load < result
docker rm -f dull-smoke 2>/dev/null || true
docker run -d --name dull-smoke -p 8099:8080 dull.yyc.dev:latest
sleep 3
curl -s -o /dev/null -w 'root=%{http_code} ctype=%{content_type}\n' http://127.0.0.1:8099/
curl -s -o /dev/null -w 'missing=%{http_code}\n' http://127.0.0.1:8099/definitely-not-here
docker rm -f dull-smoke
git diff --stat -- flake.lock
```

Expected: check clean, container builds, `root=200 ctype=text/html`, `missing=404`, lock untouched.

- [ ] **Step 6: Commit**

```bash
cd /home/lakin/personal-repos/dull-ca/dull.yyc.dev
git add .github/workflows/ci.yml .github/workflows/release.yml
git commit
```

---

## Follow-up for Dr. Dub (not part of this plan)

The `dull-nix` changes are unpushed, so `dull.yyc.dev`'s `flake.lock` still points at a `github:dull-ca/nix` revision that has no `overlays.default`. Everything in Tasks 4-6 is verified with `--override-input`. **`dull.yyc.dev` CI will fail until `dull-nix` is pushed and `nix flake update dull-nix` is run and committed.** That bump is deliberately left out of this branch: committing a lock that points at an unpushed revision, or at a local `path:`, would be worse than leaving it obviously undone.

# dull.yyc.dev

Static site for the Department of Unnecessary Labour LLC. Astro, React and
Tailwind, packaged as a container serving plaintext HTTP behind a
TLS-terminating proxy.

The site is a nix derivation — `dull-nix`'s `buildBunPackage` runs the Astro
build inside the sandbox, so nothing is built on the CI runner:

```sh
nix flake check          # astro check, biome, nginx config, the container
                         # image, and the release guards and hooks
nix build .#site         # the built dist/
nix build .#container    # the docker archive
```

Local development still uses bun directly (`bun run dev`), via `devenv`.

## Releasing

`release`, in the devenv shell. The bare form reads the version from the
conventional-commit subjects since the latest stable tag; `release
major|minor|patch|vX.Y.Z` names it instead. It shows every merge it read and
the changelog it will write, waits for a literal `Y`, then commits
`CHANGELOG.md`, warms the cache, pushes `main`, tags that commit, and watches
the `release.yml` run that publishes to ghcr.io.

Have ready: a clean `main` that is not behind `origin/main`, an authenticated
`gh`, and a cachix write token for the `dull-ca` cache (`cachix authtoken`, or
`CACHIX_AUTH_TOKEN`) — `warm-cache` runs after the confirmation, and a missing
token stops it there and is reported as the gate failing. The publish guard
asks ghcr.io whether the version already exists and refuses on any answer it
cannot read as absence, so `skopeo login ghcr.io` may be needed as well.

`docs/adr/0002-the-release-process-is-a-shared-flake-input.md` for why the
process lives in `dull-ca/nix`; that repository's README, under
`mkReleaseCommand`, for the rest of it.

## Licence

Copyright © 2026 Department of Unnecessary Labour LLC.

The repository is licensed in two halves, because software copyleft and content
copyleft are not the same instrument.

The **code** — everything under `src/`, `ci/`, `deploy/`, plus `flake.nix`,
`devenv.nix`, and the build and tooling configuration — is
[GNU AGPL-3.0-or-later](LICENSE). The site is served by a container we build
here, so a fork that deploys a modified stack owes its users that stack's
source, not only the JavaScript their browser already receives.

The **content** — the prose, the imagery, and `src/assets/` — is
[CC BY-SA 4.0](LICENSE-CONTENT). CC BY-SA is one-way compatible with GPLv3, so
the two halves can mix in that direction if they ever need to.

Third-party assets keep their own licences; see Credits below.

Neither licence grants any right to the "Department of Unnecessary Labour"
name, the DULL abbreviation, or the marks and logos. Those are reserved.
Copyright licences do not convey trademarks, and a fork must wear its own name.

## Credits

The favicon is ["Double Face Mask"][icon] by **Lorc**, licensed under
[CC BY 3.0][cc]. It is unmodified except for a background rect and colours
inverted under `prefers-color-scheme: dark`.

[icon]: https://game-icons.net/1x1/lorc/double-face-mask.html
[cc]: https://creativecommons.org/licenses/by/3.0/

# 0001 — Interim publish channel: ghcr.io for the container image

## Status

Accepted 2026-08-02. Interim, pending golem ADR 0035 §5.

## Context

golem ADR 0035 §5 leaves the release publish mechanism an **open question**. It
supersedes ADR 0028's Forgejo/Codeberg channel without deciding a replacement,
naming two candidates: GitHub Releases pushed from the self-hosted box, or
artifacts served from Dr. Dub's own infrastructure. Neither is built yet.

`dull.yyc.dev` now produces a container image (`packages.container`, see
`docs/superpowers/specs/2026-08-02-ghcr-nginx-container-design.md`) that has to
live somewhere before `dulliac` can deploy it to `dull01`. Choosing a registry
is exactly the kind of choice ADR 0035 §5 deliberately left open.

ADR 0035 also rejects GitHub Actions as a standing preference — Dr. Dub will
not run CI on a hosted CI product tied to the forge — softened by its
2026-07-29 amendment to "interim only, until the self-hosted golem-managed box
exists." That coupling is real here too: ghcr.io is GitHub's own registry, not
a neutral third party.

Netlify serves production today (`netlify.toml`); nothing here changes that.

## Decision

Publish to `ghcr.io/dull-ca/dull.yyc.dev` from a GitHub Actions workflow
(`.github/workflows/release.yml`), on git tags matching `v*`, **as an interim
channel** — on the same terms ADR 0035 sets for the CI gate itself.

This does not answer ADR 0035 §5. It is recorded here so the choice is visible
as a decision rather than sitting undocumented in a workflow file.

The publish step is a single `skopeo copy` reading the `docker-archive` nix
produces directly — skopeo reads the gzipped archive as-is, no decompression
step needed. Nothing else in the build knows about ghcr.io, so moving to a
self-hosted registry later is one destination argument, not a rewrite.

Pull requests and pushes to main build and smoke-test the image but never
publish it; only a `v*` tag does. This keeps "check" and "release" as separate
triggers, matching ADR 0035's tag-driven release policy.

## Consequences

- The image is available for `dulliac` to deploy to `dull01` without waiting
  for ADR 0035 §5 to resolve.
- Netlify continues to serve production; this adds a channel rather than
  cutting anything over.
- The forge coupling ADR 0035 objects to is real here — ghcr.io is GitHub's
  registry. It is accepted on the same interim terms as the CI itself, and the
  two move together: when the self-hosted golem-managed box exists, both the
  gate and this publish step are due for replacement.
- **Foreclosed:** nothing. The registry is one `skopeo` destination argument;
  switching it does not touch the build.

## Cross-references

- golem ADR 0035 — the CI gate, the GitHub Actions rejection and its interim
  amendment, and §5's open release question this ADR does not resolve.
- `.github/workflows/release.yml` — the tag-driven publish this ADR records.
- `docs/superpowers/specs/2026-08-02-ghcr-nginx-container-design.md` — the
  container image design.

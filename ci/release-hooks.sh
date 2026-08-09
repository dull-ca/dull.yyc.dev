#!/usr/bin/env bash
#
# dull.yyc.dev's half of the release: the version, changelog, guards, and tag
# come from dull-nix's mkReleaseCommand (dull-ca/nix README, "mkReleaseCommand").
# What a release of this repo publishes is only knowable here.
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
  command -v release-guards >/dev/null 2>&1 \
    || refuse 'release-guards is not on PATH, and it is what tells describe whether :latest moves'
}

assert_unpublished() {
  local version=${1-} reference="docker://$published_image:${1#v}" output status=0
  local -a skopeo=(skopeo) authfile=()
  # Fallback, not requirement: devenv.nix's packages put skopeo on PATH for a
  # local `release`, but release.yml never does -- it reaches skopeo through
  # `nix run nixpkgs#skopeo` on every call, so this hook needs the same
  # fallback there.
  command -v skopeo >/dev/null 2>&1 || skopeo=(nix run nixpkgs#skopeo --)
  if [[ -n ${GHCR_AUTHFILE-} ]]; then authfile=(--authfile "$GHCR_AUTHFILE"); fi

  # `2>&1 >/dev/null`, in that order: stderr is duped into the capture, then
  # stdout is discarded. Reversed, this would capture the manifest instead of
  # the error.
  output=$("${skopeo[@]}" inspect --no-tags "${authfile[@]}" "$reference" 2>&1 >/dev/null) || status=$?

  ((status != 0)) || refuse "$published_image:${version#v} is already published -- one version string names one artifact forever; release the next version instead"

  # golem's assert-unpublished treats any failed inspect as unpublished
  # (`|| return 0`) -- true for a 404, but just as true for a DNS failure or a
  # bad authfile. This package is private, so an unauthenticated local
  # inspect gets a 401 as the common case, not a rare one. Classify instead:
  # only a registry answer that names an actual absence counts as
  # unpublished; anything else refuses.
  case $output in
    *'manifest unknown'* | *'name unknown'*) return 0 ;;
  esac
  refuse "could not establish whether $published_image:${version#v} exists; skopeo said: $output"
}

describe() {
  local version=${1-} latest
  # Deliberately duplicated, not left to assert_ready: a caller invoking this
  # script directly -- skipping the wrapper's PATH and its assert-ready step
  # -- would otherwise get describe printing a confidently wrong :latest line.
  command -v release-guards >/dev/null 2>&1 \
    || refuse 'release-guards is not on PATH, and it is what tells describe whether :latest moves'
  if release-guards is-stable "$version"; then
    latest="moves to $version"
  else
    latest="unchanged -- $version is a prerelease"
  fi
  # `release` prints this above the confirmation and again on success;
  # `%-9s` matches its own `commit`/`version` rows so these line up under them.
  printf '%-9s %s:%s\n' image "$published_image" "${version#v}"
  printf '%-9s %s\n' ':latest' "$latest"
}

set_version() {
  # package.json's version is a placeholder -- private, unpublished, unread by
  # anything here -- so nothing to rewrite; the release commit carries
  # CHANGELOG.md alone.
  :
}

case ${1-} in
  assert-ready) assert_ready ;;
  assert-unpublished) assert_unpublished "${2-}" ;;
  describe) describe "${2-}" ;;
  set-version) set_version "${2-}" ;;
  # Not one of the four hooks mkReleaseCommand calls -- keeps the image name
  # in one place a caller can read instead of repeating the string.
  image) printf '%s\n' "$published_image" ;;
  *)
    printf 'usage: release-hooks {assert-ready|assert-unpublished|describe|set-version|image} ARGUMENT\n' >&2
    exit 2
    ;;
esac

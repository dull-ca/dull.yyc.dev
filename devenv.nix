{ pkgs, ... }:

{
  # Caches the devenv environment itself; the site and container image flow
  # through the flake's nixConfig and warm-cache instead.
  cachix.enable = true;
  cachix.pull = [ "dull-ca" ];
  cachix.push = "dull-ca";

  languages.javascript = {
    enable = true;
    bun = {
      enable = true;
      install.enable = true;
    };
  };

  packages = with pkgs; [
    biome
    # `cachix.enable` above configures the cache but ships no binary, and
    # `warm-cache` needs one. `gh` is what `release` waits on; `git-cliff`
    # writes the changelog; `skopeo` is what release-hooks.sh asks ghcr.io
    # through. mkReleaseCommand's wrapper puts only release-guards on PATH,
    # not any of these.
    cachix
    gh
    git-cliff
    skopeo
  ];

  # The gate CI runs — the same `nix flake check` over the same `checks`
  # attrset — with every gate output pushed to cachix, so the CI run has
  # nothing left to build.
  #
  # NOTE: `cachix push` reports a rejected push with a red ✗ and still exits 0,
  # hence the check below that the outputs really landed. Nix caches a "not in
  # this cache" answer for an hour, hence the zeroed negative TTL.
  scripts.warm-cache.exec = ''
    set -euo pipefail
    cd "$DEVENV_ROOT"
    cachixConfig="''${XDG_CONFIG_HOME:-$HOME/.config}/cachix/cachix.dhall"
    if [ -z "''${CACHIX_AUTH_TOKEN:-}" ] && [ ! -f "$cachixConfig" ]; then
      {
        echo "warm-cache: no cachix auth token — every push would silently no-op."
        echo
        echo "Mint a write token for the dull-ca cache at"
        echo "    https://app.cachix.org/cache/dull-ca/settings/authtokens"
        echo "then store it once:"
        echo
        echo "    cachix authtoken <token>"
        echo "    (writes $cachixConfig)"
        echo
        echo "or export it for this shell only (nushell):"
        echo
        echo '    $env.CACHIX_AUTH_TOKEN = "<token>"'
      } >&2
      exit 1
    fi
    nix flake check --print-build-logs

    gateOutputs=$(nix eval --raw '.#checks.x86_64-linux' --apply \
      'checks: builtins.concatStringsSep "\n" (map (c: c.outPath) (builtins.attrValues checks))')

    # Pushed by path, not by watching the build. `cachix watch-exec` only pushes
    # what the wrapped command ADDS to the store, so anything already built --
    # a second run, or a gate someone just ran by hand -- pushes nothing and
    # says nothing. Pushing the gate's outputs explicitly is idempotent and does
    # not care how they got there.
    echo "$gateOutputs" | cachix push dull-ca

    unpushed=""
    for path in $gateOutputs; do
      if ! nix path-info --store https://dull-ca.cachix.org \
        --narinfo-cache-negative-ttl 0 "$path" >/dev/null 2>&1; then
        unpushed="$unpushed  $path"$'\n'
      fi
    done

    if [ -n "$unpushed" ]; then
      {
        echo "warm-cache: the gate passed, but these outputs never reached dull-ca:"
        printf '%s' "$unpushed"
        echo "cachix marks a rejected push with a red x and still exits 0, so scroll up."
        echo "The usual cause is a token without write access to dull-ca; check with:"
        echo "    cachix push dull-ca <one of the paths above>"
      } >&2
      exit 1
    fi

    echo "warm-cache: gate passed, every output is in dull-ca — CI has nothing left to build."
  '';

  # Goes through `nix run` rather than a bare `exec release`: devenv resolves
  # its own scripts before anything else on PATH, and the flake output this
  # calls is itself named `release` -- a bare `exec release` would call this
  # very script again.
  scripts.release.exec = ''cd "$DEVENV_ROOT" && exec nix run "$DEVENV_ROOT#release" -- "$@"'';
}

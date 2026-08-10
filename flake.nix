{
  description = "dull.yyc.dev static site container";

  nixConfig = {
    # Repo-scoped cachix cache, shared wiring with dull-nix and golem.
    extra-substituters = [ "https://dull-ca.cachix.org" ];
    extra-trusted-public-keys = [
      "dull-ca.cachix.org-1:dRCsbIU6rWu2X/4+BOxwvtyVOHUXXmRp7ZmEXwne9bk="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # NOTE: not inputs.nixpkgs.follows -- nginx is static, but overlays.default
    # runs against *this* nixpkgs, so dull-nix's CI can't vouch for our hashes.
    dull-nix.url = "github:dull-ca/nix";
  };

  outputs = { self, nixpkgs, flake-utils, dull-nix }:
    flake-utils.lib.eachSystem [ "x86_64-linux" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ dull-nix.overlays.default ];
        };
        nginx = dull-nix.packages.${system}.nginx-static-no-tls;

        # Belt-and-braces: dist/, node_modules/, .astro/ are gitignored and
        # already absent from the git-tracked ./. tree; this guards a committed copy.
        # NOTE: .gitignore itself must stay unfiltered -- biome (see
        # siteCheck) reads it in the sandbox and errors outright without one.
        siteSrc = pkgs.lib.cleanSourceWith {
          name = "dull-yyc-dev-src";
          src = pkgs.lib.cleanSource ./.;
          filter = path: type:
            let rel = pkgs.lib.removePrefix (toString ./. + "/") (toString path);
            in !(pkgs.lib.hasPrefix "node_modules" rel
              || pkgs.lib.hasPrefix "dist" rel
              || pkgs.lib.hasPrefix ".astro" rel);
        };

        # Bump when bun.lock or the pinned bun version changes (see dull-nix's fetchBunDeps).
        bunDepsHash = "sha256-iPP83n41DF0EHZQdsbq1F9SnSxWp5kn+48QCUu4Z2Lk=";

        site = pkgs.buildBunPackage {
          pname = "dull-yyc-dev-site";
          src = siteSrc;
          inherit bunDepsHash;
        };

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

        mkContainer = dist: pkgs.dockerTools.buildLayeredImage {
          name = "dull.yyc.dev";
          tag = "latest";
          contents = [
            nginx
            # Supplies /etc/passwd and /etc/group so `nobody` resolves --
            # the image is built from an empty base with no distro files.
            pkgs.dockerTools.fakeNss
            (pkgs.runCommand "dull-site-root" { } ''
              mkdir -p $out/var/www/html $out/etc/nginx
              cp -r ${dist}/. $out/var/www/html/
              cp ${./deploy/nginx.conf} $out/etc/nginx/nginx.conf
              cp ${nginx}/conf/mime.types $out/etc/nginx/mime.types
            '')
          ];
          # `chmod 1777` in runCommand above is reverted by nix's store
          # canonicalization (dirs -> 0555); extraCommands runs against the
          # image layer after that, so it's the only thing that sticks.
          # nginx needs writable /tmp for its pid and client-body files.
          extraCommands = ''
            mkdir -p tmp
            chmod 1777 tmp
          '';
          config = {
            Entrypoint = [ "/bin/nginx" "-c" "/etc/nginx/nginx.conf" ];
            # Non-root can't bind 80 without CAP_NET_BIND_SERVICE, and this
            # sits behind a reverse proxy anyway, so a privileged port buys
            # nothing.
            ExposedPorts = { "8080/tcp" = { }; };
            User = "nobody";
            # Travels in the image manifest so `docker inspect`/`skopeo
            # inspect` surface it without reading docs/adr/0001.
            # `image.source` links the private package back to this repo on
            # GitHub, which is what lets a repo-scoped pull token suffice.
            Labels = {
              "org.opencontainers.image.description" =
                "Serves plaintext HTTP only. nginx is built without "
                + "ngx_http_ssl_module and CANNOT serve HTTPS -- it must sit "
                + "behind a TLS-terminating reverse proxy and must never be "
                + "exposed directly to the internet.";
              "org.opencontainers.image.source" = "https://github.com/dull-ca/dull.yyc.dev";
            };
          };
        };

        container = mkContainer site;

        # The version, changelog and guards come from dull-nix's
        # mkReleaseCommand; ci/release-hooks.sh is this repo's half -- what a
        # release publishes and how it checks that. repositoryUrl (not
        # cliffConfig) is enough: there's no CHANGELOG.md yet for the bundled
        # cliff.toml's section mapping to misfile.
        release = pkgs.mkReleaseCommand {
          hooks = ./ci/release-hooks.sh;
          repositoryUrl = "https://github.com/dull-ca/dull.yyc.dev";
          warmCommand = "warm-cache";
          releaseWorkflow = "release.yml";
        };
      in
      {
        # container joins the gate, so one `nix flake check` covers everything
        # a release publishes and warm-cache needs no special case. It stays in
        # packages too: ci.yml/release.yml `nix build .#container` for the
        # docker smoke test hits this same derivation -- a cache hit, not a rebuild.
        checks = {
          # NOTE: fails the build gate on a broken server block instead of
          # letting it crash-loop in production.
          nginx-config = pkgs.runCommand "nginx-config-valid" { } ''
            mkdir -p etc/nginx var/www/html tmp
            cp ${./deploy/nginx.conf} etc/nginx/nginx.conf
            cp ${nginx}/conf/mime.types etc/nginx/mime.types

            # No /etc/nginx or /var/www/html in the sandbox, so paths below
            # are rewritten to sandbox-local equivalents. Validates syntax
            # and module availability only -- the real layout gets a
            # container smoke test in CI.
            substituteInPlace etc/nginx/nginx.conf \
              --replace '/etc/nginx/mime.types' "$PWD/etc/nginx/mime.types" \
              --replace '/var/www/html' "$PWD/var/www/html" \
              --replace '/tmp/nginx.pid' "$PWD/tmp/nginx.pid"

            ${nginx}/bin/nginx -t -c $PWD/etc/nginx/nginx.conf
            touch $out
          '';

          site-check = siteCheck;
          inherit container;

          # The guards decide what may be released, held to the dull-nix
          # revision this flake pins -- not whatever dull-nix's own gate last
          # saw.
          release-guards-hold = pkgs.releaseGuardsTest;

          # Drives the built release-hooks (ci/release-hooks.sh) against a stub
          # skopeo, which is the only way to exercise the 401-vs-404
          # classification without a network call. The arms around it pin the
          # rest of the hook contract: assert-ready's PATH requirements,
          # describe's two lines and their column width, set-version's silence,
          # and exit 2 for an unknown subcommand.
          release-hooks-hold =
            pkgs.runCommand "release-hooks-hold" { } ''
              mkdir -p bin
              cat >bin/skopeo <<'STUB'
              #!/bin/sh
              printf '%s\n' "$SKOPEO_STDERR" >&2
              exit "$SKOPEO_STATUS"
              STUB
              chmod +x bin/skopeo
              export PATH=$PWD/bin:${pkgs.releaseGuards}/bin:$PATH

              hooks=${release}/bin/release-hooks

              $hooks assert-ready \
                || { echo "assert-ready must pass with skopeo and release-guards on PATH"; exit 1; }

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

              if SKOPEO_STATUS=0 SKOPEO_STDERR=none \
                $hooks assert-unpublished v1.2.3 2>/dev/null; then
                echo "an existing tag must refuse"; exit 1
              fi

              described=$($hooks describe v1.2.3)
              printf '%s\n' "$described" | grep -Fqx 'image     ghcr.io/dull-ca/dull.yyc.dev:1.2.3' \
                || { echo "describe must name the image and tag a release publishes"; exit 1; }
              printf '%s\n' "$described" | grep -Fqx ':latest   moves to v1.2.3' \
                || { echo "describe must say :latest moves for a stable version"; exit 1; }

              prereleased=$($hooks describe v1.2.3-rc1)
              printf '%s\n' "$prereleased" | grep -Fqx ':latest   unchanged -- v1.2.3-rc1 is a prerelease' \
                || { echo "describe must leave :latest where it is for a prerelease"; exit 1; }

              [ "$($hooks set-version v1.2.3 2>&1 | wc -c)" -eq 0 ] \
                || { echo "set-version must write nothing -- the release commit carries CHANGELOG.md alone"; exit 1; }

              usage_status=0
              $hooks not-a-hook >/dev/null 2>&1 || usage_status=$?
              [ "$usage_status" -eq 2 ] \
                || { echo "an unknown hook must exit 2, not $usage_status"; exit 1; }

              touch $out
            '';
        };

        packages = {
          inherit site container release;
          # bin/release-guards, for a CI job re-checking a tag pushed by hand
          # without going through `release` itself.
          release-guards = pkgs.releaseGuards;
        };
      });
}

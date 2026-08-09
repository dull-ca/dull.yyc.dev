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
    # NOTE: not inputs.nixpkgs.follows -- the divergent pin is the point of
    # splitting dull-nix out, and costs nothing since its nginx is static.
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

        # Filtered so touching dist/ or node_modules/ -- both gitignored,
        # not real inputs -- doesn't invalidate this derivation.
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

        # Bump when bun.lock changes (see dull-nix's fetchBunDeps).
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
      in
      {
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
        };

        packages = {
          inherit site;
          container = mkContainer site;
        };
      });
}

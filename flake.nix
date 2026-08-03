{
  description = "dull.yyc.dev static site container";

  nixConfig = {
    # Repo-scoped `dull-ca` cachix cache, same wiring as the sibling repos
    # (dull-nix, golem).
    extra-substituters = [ "https://dull-ca.cachix.org" ];
    extra-trusted-public-keys = [
      "dull-ca.cachix.org-1:dRCsbIU6rWu2X/4+BOxwvtyVOHUXXmRp7ZmEXwne9bk="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # NOTE: deliberately not `inputs.nixpkgs.follows` -- letting dull-nix
    # keep its own nixpkgs pin is the whole point of splitting it into its
    # own repo. The nginx binary it publishes is statically linked with zero
    # store references, so the divergent pin costs nothing in this image.
    dull-nix.url = "github:dull-ca/nix";
  };

  outputs = { self, nixpkgs, flake-utils, dull-nix }:
    flake-utils.lib.eachSystem [ "x86_64-linux" ] (system:
      let
        pkgs = import nixpkgs { inherit system; };
        nginx = dull-nix.packages.${system}.nginx-static-no-tls;

        # NOTE: `dist/` is a gitignored build artifact, so a pure flake
        # evaluation -- which only sees committed source -- can't read it.
        # Reading `DULL_SITE_DIST` is what forces `nix build --impure`. When
        # neither resolves, `siteDist` is null and `packages` (below) omits
        # `container` via `optionalAttrs` instead of failing evaluation --
        # that's what keeps a pure `nix flake check` green with no dist/.
        siteDist =
          let env = builtins.getEnv "DULL_SITE_DIST";
          in
          if env != "" then /. + env
          else if builtins.pathExists ./dist then ./dist
          else null;

        # bun builds the site; nix only packages the result. Astro pulls in
        # ~137 platform-split native packages (sharp/libvips, esbuild,
        # rollup) that `buildNpmPackage` can't reproduce -- the same split
        # golem's flake.nix makes, for the same reason.
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
          # NOTE: the world-writable /tmp nginx needs (for its pid and
          # client-body temp files, running as `nobody`) can't be produced by
          # a `chmod 1777` inside the `runCommand` above: Nix canonicalizes
          # every store output's permissions after the build (dirs ->
          # 0555, special bits stripped), so the chmod is silently reverted
          # and nginx fails at startup with
          # `mkdir() "/tmp/client_body" failed (13: Permission denied)`.
          # `extraCommands` runs against the image layer instead of a store
          # path, after that canonicalization, so it's the mechanism that
          # actually sticks. Verified by hitting the failure above with the
          # chmod in `runCommand`, then confirming the reverted `dr-xr-xr-x`
          # mode with `stat` before moving it here.
          extraCommands = ''
            mkdir -p tmp
            chmod 1777 tmp
          '';
          config = {
            Entrypoint = [ "/bin/nginx" "-c" "/etc/nginx/nginx.conf" ];
            # Unprivileged port: binding 80 as non-root needs
            # CAP_NET_BIND_SERVICE, and the image sits behind a reverse
            # proxy where a privileged port buys nothing.
            ExposedPorts = { "8080/tcp" = { }; };
            User = "nobody";
            # The plaintext-only constraint is a property of the artifact,
            # not of this repo, and whoever deploys it may never read
            # docs/adr/0001. An OCI label travels inside the image manifest,
            # so `docker inspect` / `skopeo inspect` surfaces it wherever the
            # image ends up.
            Labels = {
              "org.opencontainers.image.description" =
                "Serves plaintext HTTP only. nginx is built without "
                + "ngx_http_ssl_module and CANNOT serve HTTPS -- it must sit "
                + "behind a TLS-terminating reverse proxy and must never be "
                + "exposed directly to the internet.";
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

            # NOTE: the nix sandbox has no /etc/nginx or /var/www/html, so
            # paths are rewritten to sandbox-local equivalents below. This
            # validates syntax and module availability; the real file in its
            # real container layout is covered by a container smoke test in
            # CI, not here.
            substituteInPlace etc/nginx/nginx.conf \
              --replace '/etc/nginx/mime.types' "$PWD/etc/nginx/mime.types" \
              --replace '/var/www/html' "$PWD/var/www/html" \
              --replace '/tmp/nginx.pid' "$PWD/tmp/nginx.pid"

            ${nginx}/bin/nginx -t -c $PWD/etc/nginx/nginx.conf
            touch $out
          '';
        };

        packages = pkgs.lib.optionalAttrs (siteDist != null) {
          container = mkContainer siteDist;
        };
      });
}

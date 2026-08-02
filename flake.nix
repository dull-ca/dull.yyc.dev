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
      });
}

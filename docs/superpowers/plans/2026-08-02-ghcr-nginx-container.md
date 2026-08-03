# ghcr.io nginx container for dull.yyc.dev — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish a ~1.7 MB container image to ghcr.io that serves the built Astro site from a statically linked, TLS-free nginx.

**Architecture:** Two repos. `dull-ca/nix` owns `packages.nginx-static-no-tls` — our own build of nginx, inheriting `src`/`version` from `pkgs.nginx` so nixpkgs keeps tracking security releases. `dull.yyc.dev` consumes it as a pinned flake input and assembles the image with `dockerTools.buildLayeredImage`. bun builds the site; nix only packages it.

**Tech Stack:** nix flakes, flake-utils, nixpkgs-unstable, `pkgsStatic`, `dockerTools`, bun, Astro 5, GitHub Actions (interim), cachix (`dull-ca`), skopeo.

**Spec:** `docs/superpowers/specs/2026-08-02-ghcr-nginx-container-design.md`

## Global Constraints

- Cachix cache is `dull-ca`, key `dull-ca.cachix.org-1:dRCsbIU6rWu2X/4+BOxwvtyVOHUXXmRp7ZmEXwne9bk=`, secret `DULL_CA_CACHIX_PRIVATE_KEY`. Wire it via `nixConfig` in every flake.
- Systems: `x86_64-linux` only.
- GitHub Actions is **interim** (golem ADR 0035). Every workflow file carries a header comment saying so.
- The package name is `nginx-static-no-tls`. The `-no-tls` is a safety property — never shorten it.
- The image listens on **8080** and runs as **`nobody`**. Never port 80, never root.
- Application source carries **no comments** (house rule). Nix files and workflows **do** carry explanatory comments, matching golem's `flake.nix` style.
- Do not modify `netlify.toml`. Netlify keeps serving production.
- All nix code in this plan is verified working as written — do not "improve" the four non-obvious settings in Task 1 (`dontAddStaticConfigureFlags`, `dontAddPrefix`, `configurePlatforms`, `rm -rf $out/nix-support`). Each was found by a failed build.

---

# Part A — `dull-ca/nix`

Repo already cloned at `/home/lakin/personal-repos/dull-ca/nix`, empty with an unborn HEAD.

### Task 1: The `nginx-static-no-tls` package and its smoke test

**Files:**
- Create: `/home/lakin/personal-repos/dull-ca/nix/flake.nix`
- Create: `/home/lakin/personal-repos/dull-ca/nix/.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: `packages.x86_64-linux.nginx-static-no-tls`, a derivation with `bin/nginx` and `conf/mime.types` and **zero store references**. Also `checks.x86_64-linux.nginx-static-no-tls-serves`.

- [ ] **Step 1: Ensure the branch is `main`**

```bash
cd /home/lakin/personal-repos/dull-ca/nix
git symbolic-ref HEAD refs/heads/main
```

- [ ] **Step 2: Write `.gitignore`**

```gitignore
result
result-*
```

- [ ] **Step 3: Write `flake.nix` with the package and a smoke test that must fail first**

Write the file exactly as below, then change **one line** before running it:

```
test "$missing" = 404   →   test "$missing" = 999
```

That deliberate break makes the check fail on its first run, proving it can fail
rather than passing vacuously. Step 5 restores it.

```nix
{
  description = "Shared nix packages for dull-ca";

  # Repo-scoped cachix cache, same as golem (ADR 0035).
  nixConfig = {
    extra-substituters = [ "https://dull-ca.cachix.org" ];
    extra-trusted-public-keys = [
      "dull-ca.cachix.org-1:dRCsbIU6rWu2X/4+BOxwvtyVOHUXXmRp7ZmEXwne9bk="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [ "x86_64-linux" ] (system:
      let
        pkgs = import nixpkgs { inherit system; };
        static = pkgs.pkgsStatic;

        # Our own build of nginx, NOT an override of nixpkgs' package.
        #
        # `nginx.override` cannot produce this: generic.nix hardcodes an
        # unconditional module list (ssl, v3, xslt, dav, flv, mp4), the inner
        # `configureFlags` argument only appends, and nginx's configure has no
        # `--without-` for opt-in modules. So the build configuration is ours.
        #
        # But `src` and `version` are inherited, so nixpkgs still decides which
        # nginx we build and its security bumps reach us through a routine
        # `nix flake update` with no hash to hand-edit.
        nginx-static-no-tls = static.stdenv.mkDerivation {
          pname = "nginx-static-no-tls";
          inherit (pkgs.nginx) src version;

          buildInputs = [ static.pcre2 static.zlib ];
          nativeBuildInputs = [ pkgs.nukeReferences ];

          # The static stdenv adapter appends `--enable-static --disable-shared`,
          # which nginx's hand-rolled ./configure rejects outright. This suppresses
          # them. (It only works when set in the derivation's own args — setting it
          # through `overrideAttrs` on nixpkgs' nginx silently does nothing.)
          dontAddStaticConfigureFlags = true;

          # stdenv's generic configure phase otherwise adds `--prefix=$out`,
          # `--build=` and `--host=`; nginx rejects the autoconf platform flags.
          dontAddPrefix = true;
          configurePlatforms = [ ];

          configureFlags = [
            "--prefix=/etc/nginx"
            "--sbin-path=/bin/nginx"
            "--conf-path=/etc/nginx/nginx.conf"
            "--http-log-path=/dev/stdout"
            "--error-log-path=/dev/stderr"
            "--pid-path=/tmp/nginx.pid"
            "--http-client-body-temp-path=/tmp/client_body"
            "--with-http_gzip_static_module"
            # Included because this image is designed to sit behind a proxy;
            # without it every access log line shows the proxy's address.
            "--with-http_realip_module"
            "--with-threads"
            "--without-http_proxy_module"
            "--without-http_fastcgi_module"
            "--without-http_uwsgi_module"
            "--without-http_scgi_module"
            "--without-http_memcached_module"
            "--crossbuild=Linux::x86_64"
          ];

          # `make install` would try to create /etc/nginx inside the sandbox and
          # die on Permission denied. Copying objs/nginx directly also keeps the
          # store path out of the binary.
          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin $out/conf
            cp objs/nginx $out/bin/nginx
            cp conf/mime.types $out/conf/mime.types
            runHook postInstall
          '';

          # nuke-refs is safe only because the binary is statically linked: the
          # store paths it clears are dead strings in nginx's -V banner, not
          # runtime dependencies. Removing nix-support matters just as much —
          # its propagated-build-inputs file names the pcre2-dev and zlib-dev
          # paths and alone dragged the closure from 1.7 MB to 7.75 MB.
          postFixup = ''
            nuke-refs $out/bin/nginx
            rm -rf $out/nix-support
          '';

          meta = {
            description =
              "Statically linked nginx for static files, behind a TLS-terminating proxy";
            longDescription = ''
              Cannot serve HTTPS — ngx_http_ssl_module is not compiled in.
              Never expose this directly to the internet.
            '';
            platforms = [ "x86_64-linux" ];
          };
        };
      in
      {
        packages = {
          inherit nginx-static-no-tls;
          default = nginx-static-no-tls;
        };

        checks = {
          # A binary that builds is not necessarily a binary that serves.
          nginx-static-no-tls-serves =
            pkgs.runCommand "nginx-static-no-tls-serves"
              { nativeBuildInputs = [ pkgs.curl ]; } ''
              mkdir -p root/sub conf
              echo '<h1>ok</h1>' > root/index.html
              echo '<h1>sub</h1>' > root/sub/index.html
              echo 'body{}' > root/app.css

              cat > conf/nginx.conf <<EOF
              daemon off;
              error_log stderr crit;
              pid $PWD/nginx.pid;
              events { worker_connections 64; }
              http {
                include ${nginx-static-no-tls}/conf/mime.types;
                default_type application/octet-stream;
                access_log off;
                server {
                  listen 8399;
                  root $PWD/root;
                  location / { try_files \$uri \$uri/index.html \$uri/ =404; }
                }
              }
              EOF

              ${nginx-static-no-tls}/bin/nginx -c $PWD/conf/nginx.conf &
              nginx_pid=$!
              for i in $(seq 1 50); do
                curl -sf -o /dev/null http://127.0.0.1:8399/ && break
                sleep 0.2
              done

              code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8399/)
              ctype=$(curl -s -o /dev/null -w '%{content_type}' http://127.0.0.1:8399/)
              clean=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8399/sub)
              css=$(curl -s -o /dev/null -w '%{content_type}' http://127.0.0.1:8399/app.css)
              missing=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8399/nope)

              kill $nginx_pid || true

              test "$code" = 200 || { echo "FAIL root: $code"; exit 1; }
              test "$ctype" = "text/html" || { echo "FAIL ctype: $ctype"; exit 1; }
              test "$clean" = 200 || { echo "FAIL clean url: $clean"; exit 1; }
              test "$css" = "text/css" || { echo "FAIL css: $css"; exit 1; }
              test "$missing" = 404 || { echo "FAIL 404: $missing"; exit 1; }

              echo "all assertions passed" > $out
            '';
        };
      });
}
```

- [ ] **Step 4: Run the check and verify it FAILS**

```bash
cd /home/lakin/personal-repos/dull-ca/nix
git add flake.nix .gitignore
nix flake check --print-build-logs
```

Expected: FAIL with `FAIL 404: 404`. (`git add` is required — nix flakes only see git-tracked files.)

- [ ] **Step 5: Correct the assertion**

Change `test "$missing" = 999` back to:

```nix
test "$missing" = 404 || { echo "FAIL 404: $missing"; exit 1; }
```

- [ ] **Step 6: Run the check and verify it PASSES**

```bash
nix flake check --print-build-logs
```

Expected: PASS, no output errors.

- [ ] **Step 7: Verify the size and reference guarantees**

```bash
nix build --no-link --print-out-paths .#nginx-static-no-tls
nix path-info -S --closure-size .#nginx-static-no-tls
nix-store -q --references $(nix build --no-link --print-out-paths .#nginx-static-no-tls)
```

Expected: closure ≈ 1,686,352 bytes (~1.69 MB) and **zero** reference lines. If any reference appears, `postFixup` did not run correctly — do not proceed.

- [ ] **Step 8: Verify the safety property the name claims**

```bash
P=$(nix build --no-link --print-out-paths .#nginx-static-no-tls)
printf 'daemon off;\nevents {}\nhttp { server { listen 8097 ssl; } }\n' > /tmp/ssl-probe.conf
$P/bin/nginx -t -c /tmp/ssl-probe.conf
```

Expected: `nginx: [emerg] the "ssl" parameter requires ngx_http_ssl_module`. If this succeeds instead, the name is a lie — stop and investigate.

- [ ] **Step 9: Commit**

```bash
git add flake.nix flake.lock .gitignore
git commit -m "feat: nginx-static-no-tls, a 1.7MB static nginx for static sites"
```

---

### Task 2: CI, scheduled updates, and the README

**Files:**
- Create: `/home/lakin/personal-repos/dull-ca/nix/.github/workflows/ci.yml`
- Create: `/home/lakin/personal-repos/dull-ca/nix/.github/workflows/update.yml`
- Create: `/home/lakin/personal-repos/dull-ca/nix/README.md`

**Interfaces:**
- Consumes: `checks.x86_64-linux.nginx-static-no-tls-serves` from Task 1.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Write `.github/workflows/ci.yml`**

```yaml
# Interim CI: the same gate as everywhere else (`nix flake check`, golem ADR
# 0035), run by GitHub Actions until the self-hosted golem-managed box exists.
# cachix-action configures the dull-ca cache for pull and pushes every path
# built during the check.
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v31
      - uses: cachix/cachix-action@v15
        with:
          name: dull-ca
          authToken: ${{ secrets.DULL_CA_CACHIX_PRIVATE_KEY }}
      - run: nix flake check --print-build-logs
```

- [ ] **Step 2: Write `.github/workflows/update.yml`**

```yaml
# nginx-static-no-tls inherits `src` and `version` from nixpkgs' nginx, so an
# nginx security release reaches us as a nixpkgs bump. This turns that into a
# CI-tested pull request rather than something to remember.
name: Update flake inputs

on:
  schedule:
    - cron: "0 6 * * 1"
  workflow_dispatch:

jobs:
  update:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v31
      - uses: cachix/cachix-action@v15
        with:
          name: dull-ca
          authToken: ${{ secrets.DULL_CA_CACHIX_PRIVATE_KEY }}
      - run: nix flake update
      - run: nix flake check --print-build-logs
      - uses: peter-evans/create-pull-request@v7
        with:
          commit-message: "chore: nix flake update"
          title: "chore: nix flake update"
          body: |
            Automated nixpkgs bump.

            `nginx-static-no-tls` inherits `src` and `version` from
            `pkgs.nginx`, so this is how nginx security releases arrive.
            Check the nginx version change in `flake.lock` before merging.
          branch: automation/flake-update
          delete-branch: true
```

- [ ] **Step 3: Write `README.md`**

````markdown
# dull-ca/nix

Shared nix packages for dull-ca. Consume them as a flake input:

```nix
inputs.dull-nix.url = "github:dull-ca/nix";
```

## `nginx-static-no-tls`

A statically linked nginx (~1.69 MB closure, **zero store references**) for
serving static files from a container.

**It cannot serve HTTPS.** `ngx_http_ssl_module` is not compiled in:

```
nginx: [emerg] the "ssl" parameter requires ngx_http_ssl_module
```

It is built to sit behind a TLS-terminating reverse proxy and **must never be
exposed directly to the internet**. That it cannot do TLS is the point — misuse
shows up immediately as plaintext rather than as something silently insecure.

### What's in it

Not "no modules" — nginx's *default* set, minus the upstream family, minus
everything opt-in.

**Absent:** TLS/SSL, HTTP/2, HTTP/3, proxy, fastcgi, uwsgi, scgi, memcached,
xslt, dav, flv, mp4, sub, auth_request, secure_link, stub_status, stream, mail,
perl, geoip.

**Present:** `gzip_static`, `threads`, `realip`, plus nginx defaults —
`autoindex`, `ssi`, `auth_basic`, `rewrite`, `limit_req`, `limit_conn`,
`access`, `charset`, `gzip`, `map`, `geo`, `referer`.

`autoindex` and `ssi` both default to *off*. Enabling either should be a
deliberate decision.

### Why it's our own build

`nginx.override` cannot produce it: `generic.nix` hardcodes an unconditional
module list (ssl, v3, xslt, dav, flv, mp4), and its inner `configureFlags`
argument only appends — nginx has no `--without-` for opt-in modules.

We still inherit `src` and `version` from `pkgs.nginx`, so nixpkgs decides which
nginx we build. **nginx security updates reach this repo through
`.github/workflows/update.yml`**, which bumps `flake.lock` weekly and opens a
CI-tested PR.

### Deployment note

`realip` is compiled in but the trusted-proxy range is the consumer's
responsibility. Never set `set_real_ip_from 0.0.0.0/0` — that lets any client
spoof its own address in your logs.
````

- [ ] **Step 4: Verify the workflows are valid YAML**

```bash
cd /home/lakin/personal-repos/dull-ca/nix
nix run nixpkgs#yq -- . .github/workflows/ci.yml > /dev/null && echo "ci.yml ok"
nix run nixpkgs#yq -- . .github/workflows/update.yml > /dev/null && echo "update.yml ok"
```

Expected: both print `ok`.

- [ ] **Step 5: Commit and push**

```bash
git add .github README.md
git commit -m "ci: interim flake check and scheduled nixpkgs bumps"
git push -u origin main
```

- [ ] **Step 6: Confirm CI is green before Part B**

Part B pins this repo by revision, so it must be pushed and passing first.

```bash
gh run list --repo dull-ca/nix --limit 3
```

Expected: the `CI` run for `main` is `completed / success`. If `DULL_CA_CACHIX_PRIVATE_KEY` is not yet set on the repo, add it in GitHub settings before re-running.

---

# Part B — `dull.yyc.dev`

Working directory: `/home/lakin/personal-repos/dull-ca/dull.yyc.dev`. All paths
in Part B are relative to it.

Part A must be pushed and green first — Task 3 pins `github:dull-ca/nix`.

### Task 3: `deploy/nginx.conf` and the flake that validates it

**Files:**
- Create: `deploy/nginx.conf`
- Create: `flake.nix`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `dull-nix.packages.x86_64-linux.nginx-static-no-tls` from Task 1.
- Produces: `checks.x86_64-linux.nginx-config`, and the `siteDist` / `mkContainer` bindings Task 4 extends.

- [ ] **Step 1: Write `deploy/nginx.conf`**

```nginx
daemon off;
worker_processes auto;
error_log /dev/stderr warn;
pid /tmp/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    access_log    /dev/stdout;

    sendfile      on;
    tcp_nopush    on;
    server_tokens off;

    gzip_static   on;

    # Nix normalises store mtimes to the epoch, so the default mtime-derived
    # ETag is not a meaningful validator for files copied into the image.
    # Asset cache correctness comes from Astro's content-hashed filenames.
    etag off;

    # Trust only RFC1918 proxies. Never widen this to 0.0.0.0/0 — that lets any
    # client spoof its own address in the logs.
    set_real_ip_from 10.0.0.0/8;
    set_real_ip_from 172.16.0.0/12;
    set_real_ip_from 192.168.0.0/16;
    real_ip_header   X-Forwarded-For;

    server {
        listen      8080;
        root        /var/www/html;
        index       index.html;
        error_page  404 /404.html;

        location /_astro/ {
            add_header Cache-Control "public, max-age=31536000, immutable";
        }

        location / {
            try_files $uri $uri/index.html $uri/ =404;
            add_header Cache-Control "public, max-age=300";
        }
    }
}
```

- [ ] **Step 2: Add `result` to `.gitignore`**

Append to the `# === Build ===` section:

```gitignore
result
result-*
```

- [ ] **Step 3: Write `flake.nix`**

```nix
{
  description = "dull.yyc.dev static site container";

  nixConfig = {
    extra-substituters = [ "https://dull-ca.cachix.org" ];
    extra-trusted-public-keys = [
      "dull-ca.cachix.org-1:dRCsbIU6rWu2X/4+BOxwvtyVOHUXXmRp7ZmEXwne9bk="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # Deliberately NOT `inputs.nixpkgs.follows` — letting dull-nix keep its own
    # nixpkgs pin is the point of the split. The nginx binary is statically
    # linked with zero store references, so the divergence costs nothing.
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
          # A broken server block should fail the gate, not crash-loop in
          # production. The paths are rewritten because the sandbox has no
          # /etc/nginx or /var/www/html; this validates syntax and module
          # availability, and the container smoke test in CI covers the real
          # file in its real layout.
          nginx-config = pkgs.runCommand "nginx-config-valid" { } ''
            mkdir -p etc/nginx var/www/html tmp
            cp ${./deploy/nginx.conf} etc/nginx/nginx.conf
            cp ${nginx}/conf/mime.types etc/nginx/mime.types

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
```

- [ ] **Step 4: Verify the config check fails on a broken config**

Temporarily introduce an error — change `worker_connections 1024;` to `worker_connections;` — then:

```bash
cd /home/lakin/personal-repos/dull-ca/dull.yyc.dev
git add flake.nix deploy/nginx.conf .gitignore
nix flake check --print-build-logs
```

Expected: FAIL with `invalid number of arguments in "worker_connections" directive`.

- [ ] **Step 5: Restore the config and verify the check passes**

Restore `worker_connections 1024;`, then:

```bash
nix flake check --print-build-logs
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add flake.nix flake.lock deploy/nginx.conf .gitignore
git commit -m "feat: nginx config and flake gate for the site container"
```

---

### Task 4: The container image

**Files:**
- Modify: `flake.nix`

**Interfaces:**
- Consumes: `nginx` and `checks.nginx-config` from Task 3.
- Produces: `packages.x86_64-linux.container`, a `docker-archive` tarball, present **only** when a site `dist/` is resolvable.

- [ ] **Step 1: Add `siteDist` and `mkContainer` to the `let` block in `flake.nix`**

Insert after the `nginx = ...` binding:

```nix
        # `dist/` is a gitignored build artifact, so a pure flake evaluation
        # (which only sees committed source) can't read it. Three cases, in
        # order: `DULL_SITE_DIST` carries the built path (reading the env var
        # forces `nix build --impure`); else an in-tree `dist/` if present; else
        # null. Null means no dist is available, and `container` is then omitted
        # from `packages` entirely (below) rather than failing eval — so a pure
        # `nix flake check` stays green.
        siteDist =
          let env = builtins.getEnv "DULL_SITE_DIST";
          in
          if env != "" then /. + env
          else if builtins.pathExists ./dist then ./dist
          else null;

        mkContainer = dist: pkgs.dockerTools.buildLayeredImage {
          name = "dull.yyc.dev";
          tag = "latest";
          contents = [
            nginx
            # Supplies /etc/passwd and /etc/group so `nobody` resolves.
            pkgs.dockerTools.fakeNss
            (pkgs.runCommand "dull-site-root" { } ''
              mkdir -p $out/var/www/html $out/etc/nginx
              cp -r ${dist}/. $out/var/www/html/
              cp ${./deploy/nginx.conf} $out/etc/nginx/nginx.conf
              cp ${nginx}/conf/mime.types $out/etc/nginx/mime.types
            '')
          ];
          # nginx runs as `nobody` and must write its pid and client-body temp
          # files under /tmp. This has to happen here, against the image layer
          # — not in the runCommand above. See the correction note below.
          extraCommands = ''
            mkdir -p tmp
            chmod 1777 tmp
          '';
          config = {
            Entrypoint = [ "/bin/nginx" "-c" "/etc/nginx/nginx.conf" ];
            ExposedPorts = { "8080/tcp" = { }; };
            User = "nobody";
          };
        };
```

> **Correction (2026-08-03).** This snippet originally created `$out/tmp` and
> `chmod 1777`'d it **inside the `runCommand`**. That does not work, and the
> failure is silent at build time. Nix canonicalizes every store output's
> permissions after the build — directories become `0555` and special bits
> including the sticky bit are stripped — so the `chmod` is reverted with no
> error, `/tmp` lands in the image read-only, and nginx dies at startup with:
>
> ```
> mkdir() "/tmp/client_body" failed (13: Permission denied)
> ```
>
> `buildLayeredImage`'s `extraCommands` runs against the image layer rather
> than a store path, after that canonicalization, so the mode sticks. The
> shipped `flake.nix` is authoritative; where this plan and the code disagree,
> the code is right.

- [ ] **Step 2: Add the conditional `packages` output**

Add alongside the existing `checks` attribute in the returned set:

```nix
        packages = pkgs.lib.optionalAttrs (siteDist != null) {
          container = mkContainer siteDist;
        };
```

- [ ] **Step 3: Verify a pure `nix flake check` still passes with no dist**

```bash
cd /home/lakin/personal-repos/dull-ca/dull.yyc.dev
rm -rf dist
git add flake.nix
nix flake check --print-build-logs
```

Expected: PASS. The `container` package must be absent, not broken.

- [ ] **Step 4: Build the site and then the image**

```bash
bun install --frozen-lockfile
bun run build
DULL_SITE_DIST=$PWD/dist nix build --impure .#container --print-build-logs
ls -l result
```

Expected: `result` is a tarball of a few MB.

- [ ] **Step 5: Load the image and verify its size and metadata**

```bash
docker load < result
docker image inspect dull.yyc.dev:latest \
  --format 'size={{.Size}} user={{.Config.User}} ports={{.Config.ExposedPorts}} entrypoint={{.Config.Entrypoint}}'
```

Expected: `user=nobody`, `ports=map[8080/tcp:{}]`, entrypoint `[/bin/nginx -c /etc/nginx/nginx.conf]`, and a size in the low single-digit MB.

- [ ] **Step 6: Run the container and verify it actually serves**

```bash
docker rm -f dull-smoke 2>/dev/null || true
docker run -d --name dull-smoke -p 8099:8080 dull.yyc.dev:latest
sleep 2
curl -s -o /dev/null -w 'root=%{http_code} type=%{content_type}\n' http://127.0.0.1:8099/
curl -s -o /dev/null -w 'missing=%{http_code}\n' http://127.0.0.1:8099/definitely-not-here
docker logs dull-smoke
docker rm -f dull-smoke
```

Expected: `root=200 type=text/html` and `missing=404`. Logs must show no permission errors. If nginx cannot write `/tmp/nginx.pid`, the `extraCommands` block in Step 1 did not take effect — and if you moved that `chmod` back into the `runCommand`, see the correction note there for why it silently does nothing.

- [ ] **Step 7: Commit**

```bash
git add flake.nix
git commit -m "feat: build the site container image with dockerTools"
```

---

### Task 5: CI — check and build, never push

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `packages.container` from Task 4, `bun run check` and `bun run build` from `package.json`.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Run the lint gate locally first**

`bun run check` becomes a hard gate, so any pre-existing violation must be fixed now rather than discovered as a red first PR.

```bash
cd /home/lakin/personal-repos/dull-ca/dull.yyc.dev
bun install --frozen-lockfile
bun run check
```

Expected: clean. If it reports errors, fix them and commit before continuing — `bun run lint:fix` and `bun run format` handle the mechanical ones.

- [ ] **Step 2: Write `.github/workflows/ci.yml`**

```yaml
# Interim CI (golem ADR 0035): GitHub Actions runs the same `nix flake check`
# gate any machine with nix runs, until the self-hosted golem-managed box
# exists. Pull requests and main build the image but never publish it —
# publishing happens only on a tag, in release.yml.
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: oven-sh/setup-bun@v2
        with:
          bun-version: latest

      - uses: cachix/install-nix-action@v31
      - uses: cachix/cachix-action@v15
        with:
          name: dull-ca
          authToken: ${{ secrets.DULL_CA_CACHIX_PRIVATE_KEY }}

      - run: bun install --frozen-lockfile
      - run: bun run check
      - run: bun run build

      - run: nix flake check --print-build-logs

      # Astro's dist can't be produced purely (~137 platform-split native
      # packages), so the image build is impure and sits outside the gate.
      - name: Build container image
        run: DULL_SITE_DIST=$PWD/dist nix build --impure .#container --print-build-logs

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

> **Correction (2026-08-03).** This snippet originally had no `trap`, calling
> `docker logs` and `docker rm -f` inline after the `curl` probes. GitHub
> Actions runs `run:` blocks under `bash -eo pipefail`, so the moment the
> container is unreachable the script aborts at the failing command — and both
> of those lines sit *after* it. The result is the worst case for debugging: no
> container logs (the only evidence of why nginx died) and a leaked container
> on a self-hosted runner. `trap cleanup EXIT` fires on every exit path,
> including the connection-refused one, which is exactly the case the smoke
> test exists to catch. This trap is load-bearing, not tidiness — keep it, and
> keep it identical in `release.yml`. The shipped workflows are authoritative.

- [ ] **Step 3: Verify the workflow is valid YAML**

```bash
nix run nixpkgs#yq -- . .github/workflows/ci.yml > /dev/null && echo "ci.yml ok"
```

Expected: `ci.yml ok`.

- [ ] **Step 4: Commit and push, then confirm CI is green**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: interim gate building and smoke-testing the container"
git push
gh run list --limit 3
```

Expected: the `CI` run completes `success`.

---

### Task 6: Tag-driven publish to ghcr.io, and the ADR

**Files:**
- Create: `.github/workflows/release.yml`
- Create: `docs/adr/0001-interim-ghcr-container-channel.md`

**Interfaces:**
- Consumes: `packages.container` from Task 4.
- Produces: images at `ghcr.io/dull-ca/dull.yyc.dev:<version>` and `:latest`.

- [ ] **Step 1: Write `docs/adr/0001-interim-ghcr-container-channel.md`**

```markdown
# 0001-interim-ghcr-container-channel

## Status

Accepted 2026-08-02. Interim, pending golem ADR 0035 §5.

## Context

golem ADR 0035 §5 declares the release publish mechanism an **open question**.
It supersedes ADR 0028's Forgejo channel without deciding a replacement, and
names two candidates: GitHub Releases pushed from the self-hosted box, or
artifacts served from Dr. Dub's own infrastructure.

`dull.yyc.dev` now produces a container image that has to live somewhere before
it can run on `dull01`. Choosing a registry therefore touches a question ADR
0035 deliberately left open.

ADR 0035 also records that GitHub Actions is rejected as a standing preference,
softened by its 2026-07-29 amendment to "interim only, until the self-hosted
golem-managed box exists."

## Decision

Publish to `ghcr.io/dull-ca/dull.yyc.dev` from a GitHub Actions workflow, on
git tags matching `v*`, **as an interim channel**.

This does **not** answer ADR 0035 §5. It is recorded here so the choice is
visible as a decision rather than sitting undocumented in a workflow file.

The push is a single `skopeo copy` step reading the `docker-archive` nix
produces. Nothing else in the build knows about ghcr.io, so moving to a
self-hosted registry is a one-line change.

Pull requests and pushes to main build the image and never publish it. Only a
tag publishes.

## Consequences

- The image is available for `dulliac` to deploy to `dull01` without waiting for
  ADR 0035 §5 to resolve.
- Netlify continues to serve production; this adds a channel rather than cutting
  anything over.
- The forge coupling ADR 0035 objects to is real here — ghcr.io is GitHub's
  registry. It is accepted on the same interim terms as the CI itself, and both
  move together when the self-hosted box exists.
- **Foreclosed:** nothing. The registry is one `skopeo` destination argument.

## Cross-references

- golem ADR 0035 — the CI gate, the Actions rejection, and §5's open release
  question.
- `.github/workflows/release.yml` — the tag-driven publish.
- `docs/superpowers/specs/2026-08-02-ghcr-nginx-container-design.md` — the design.
```

- [ ] **Step 2: Write `.github/workflows/release.yml`**

```yaml
# Interim publish channel (ADR 0001, pending golem ADR 0035 §5). Only a `v*`
# tag publishes; CI on PRs and main builds the image but never pushes it.
name: Release

on:
  push:
    tags: ["v*"]

jobs:
  publish:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4

      - uses: oven-sh/setup-bun@v2
        with:
          bun-version: latest

      - uses: cachix/install-nix-action@v31
      - uses: cachix/cachix-action@v15
        with:
          name: dull-ca
          authToken: ${{ secrets.DULL_CA_CACHIX_PRIVATE_KEY }}

      - run: bun install --frozen-lockfile
      - run: bun run check
      - run: bun run build

      - name: Build container image
        run: DULL_SITE_DIST=$PWD/dist nix build --impure .#container --print-build-logs

      # The git tag is the sole source of the version; package.json's version
      # field is not consulted. ghcr.io requires a lowercase image name.
      - name: Derive version from tag
        run: echo "VERSION=${GITHUB_REF_NAME#v}" >> "$GITHUB_ENV"

      - name: Publish to ghcr.io
        run: |
          nix run nixpkgs#skopeo -- copy \
            --dest-creds "${{ github.actor }}:${{ secrets.GITHUB_TOKEN }}" \
            docker-archive:result \
            docker://ghcr.io/dull-ca/dull.yyc.dev:${VERSION}
          nix run nixpkgs#skopeo -- copy \
            --dest-creds "${{ github.actor }}:${{ secrets.GITHUB_TOKEN }}" \
            docker-archive:result \
            docker://ghcr.io/dull-ca/dull.yyc.dev:latest
```

- [ ] **Step 3: Verify the workflow is valid YAML**

```bash
nix run nixpkgs#yq -- . .github/workflows/release.yml > /dev/null && echo "release.yml ok"
```

Expected: `release.yml ok`.

- [ ] **Step 4: Verify skopeo can read the archive nix produced**

This catches a format mismatch locally, before a tag depends on it.

```bash
nix run nixpkgs#skopeo -- inspect docker-archive:result | head -20
```

Expected: JSON metadata. If skopeo rejects the gzipped archive, decompress first
(`gunzip -c result > image.tar`) and copy from `docker-archive:image.tar`, adding
that step to the workflow.

- [ ] **Step 5: Commit and push**

```bash
git add .github/workflows/release.yml docs/adr/0001-interim-ghcr-container-channel.md
git commit -m "ci: publish container to ghcr.io on tags, with ADR"
git push
```

- [ ] **Step 6: Cut a release and verify the published image**

```bash
git tag v0.1.0
git push origin v0.1.0
gh run list --workflow Release --limit 1
```

Then, once green:

```bash
docker pull ghcr.io/dull-ca/dull.yyc.dev:0.1.0
docker run -d --name dull-published -p 8099:8080 ghcr.io/dull-ca/dull.yyc.dev:0.1.0
sleep 2
curl -s -o /dev/null -w 'published=%{http_code}\n' http://127.0.0.1:8099/
docker rm -f dull-published
```

Expected: `published=200`. Note the package defaults to private on ghcr.io — make
it public in the repo's package settings if `dull01` will pull it unauthenticated.

---

## Notes for the implementer

**Where the container smoke test lives, and why.** It is a CI step, not a flake
check. `nix flake check` runs in a sandbox with no docker daemon, so a check that
runs the image cannot work there. The flake check validates the nginx *config*;
CI validates the *image*.

**`git add` before `nix flake check`.** Nix flakes only see git-tracked files. A
new file that hasn't been staged is invisible, and the error message
(`path does not exist`) does not say so.

**Don't add `inputs.nixpkgs.follows` to `dull-nix`.** Letting it keep its own
nixpkgs pin is the entire point of the two-repo split. Because the nginx binary
is statically linked with zero store references, the divergence costs nothing in
the final image.

**If the closure grows.** Re-run the reference check from Task 1 Step 7. A
non-empty `nix-store -q --references` means something reintroduced a store path
into the binary or `$out` — almost certainly a new module pulling a library, or
`postFixup` not running.

**`404.html` does not exist yet.** The spec lists a custom 404 page and
`deploy/nginx.conf` carries `error_page 404 /404.html;`, but `src/pages/` holds
only `index.astro`, so Astro emits no `404.html`. This is harmless — nginx
internally redirects to the missing page and still returns a plain `404`, which
is exactly what the smoke tests assert. Adding `src/pages/404.astro` is a
follow-up for whoever owns the site's content; it is deliberately **not** part of
this plan, which is scoped to CI and packaging. Leave the `error_page` directive
in place so the page works the moment it is added.

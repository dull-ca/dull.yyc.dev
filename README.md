# dull.yyc.dev

Static site for the Department of Unnecessary Labour LLC. Astro, React and
Tailwind, packaged as a container serving plaintext HTTP behind a
TLS-terminating proxy.

The site is a nix derivation — `dull-nix`'s `buildBunPackage` runs the Astro
build inside the sandbox, so nothing is built on the CI runner:

```sh
nix flake check          # astro check, biome, nginx config
nix build .#site         # the built dist/
nix build .#container    # the docker archive
```

Local development still uses bun directly (`bun run dev`), via `devenv`.

## Credits

The favicon is ["Double Face Mask"][icon] by **Lorc**, licensed under
[CC BY 3.0][cc]. It is unmodified except for a background rect and colours
inverted under `prefers-color-scheme: dark`.

[icon]: https://game-icons.net/1x1/lorc/double-face-mask.html
[cc]: https://creativecommons.org/licenses/by/3.0/

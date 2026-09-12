Put custom xbps-src templates here for packages that don't exist in
upstream void-packages (your own software, a patched fork, etc).
Layout matches void-packages: `srcpkgs/<name>/template`.

These get overlaid onto the void-packages checkout before every build,
so they always take priority over any same-named stock package.
Subpackages declared via `<name>_package()` hooks in the template get
their `srcpkgs/<subpkg>` symlink generated automatically - you don't
need to create those by hand.

Note: if one package here depends on another package here (via
`hostmakedepends`/`makedepends`/`depends`), `build_only.sh` will fetch
just that specific dependency from the `repo-glibc` release before
building - it doesn't seed the whole release, and it doesn't seed
anything at all when this directory has no templates in it.

Note: check_updates.py currently detects upstream Void version bumps
automatically. For a package whose template lives only here, add/bump
it yourself and dispatch build-normal.yml (or build-large.yml) by hand
with that package name - there's no "upstream" to diff against.

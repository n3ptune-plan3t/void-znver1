#!/bin/sh
# Compile phase - the checkpointable part for build-large.yml, and the
# first half of build-normal.yml. Bootstraps/updates void-packages,
# overlays any custom templates from this repo's srcpkgs/, builds $PKG,
# and stages the result at $GITHUB_WORKSPACE/hostdir-binpkgs for the
# separate publish job to pick up. Does NOT touch GitHub Releases.
set -e

if [ -z "${PKG:-}" ]; then
  echo "PKG is not set - pass the package name to build" >&2
  exit 1
fi
CPU_MARCH="${CPU_MARCH:-znver1}"
WORKDIR=/home/builder/void-packages

xbps-install -Suy xbps
xbps-install -Suy
xbps-install -Sy bash git sudo xtools github-cli

id builder >/dev/null 2>&1 || useradd -M -G xbuilder builder
echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder

if [ -d "$WORKDIR/.git" ]; then
  echo "==> Reusing cached void-packages checkout"
else
  echo "==> No cached checkout found, cloning fresh"
  mkdir -p /home/builder
  git clone --depth 1 https://github.com/void-linux/void-packages "$WORKDIR"
fi
chown -R builder /home/builder/void-packages

# Update even a cached checkout to latest - a shallow fetch is cheap,
# and this is what lets upstream template bumps actually take effect
# instead of building against a stale week-old tree forever.
su builder -c "cd $WORKDIR && git fetch --depth 1 origin master && git reset --hard origin/master"

if ! grep -q "march=$CPU_MARCH" "$WORKDIR/etc/conf" 2>/dev/null; then
  cat >> "$WORKDIR/etc/conf" <<EOF
XBPS_CFLAGS+=" -march=$CPU_MARCH -mtune=$CPU_MARCH"
XBPS_CXXFLAGS+=" -march=$CPU_MARCH -mtune=$CPU_MARCH"
EOF
fi
export RUSTFLAGS="-C target-cpu=$CPU_MARCH"

# Overlay custom templates for packages we maintain ourselves (not in
# upstream void-packages) so they always take priority over stock Void.
# Done before the hostdir seeding step below, since seeding now needs
# to know what these templates depend on.
if [ -d "$GITHUB_WORKSPACE/srcpkgs" ]; then
  for pkgdir in "$GITHUB_WORKSPACE"/srcpkgs/*/; do
    [ -d "$pkgdir" ] || continue
    name=$(basename "$pkgdir")
    rm -rf "$WORKDIR/srcpkgs/$name"
    cp -r "$pkgdir" "$WORKDIR/srcpkgs/$name"
    chown -R builder "$WORKDIR/srcpkgs/$name"
  done

  for template in "$GITHUB_WORKSPACE"/srcpkgs/*/template; do
    [ -f "$template" ] || continue
    pkgname=$(basename "$(dirname "$template")")
    grep -oE '^[A-Za-z0-9._+-]+_package\(\)' "$template" 2>/dev/null \
      | sed -E 's/_package\(\)$//' \
      | while read -r subpkg; do
          [ "$subpkg" = "$pkgname" ] && continue
          target="$WORKDIR/srcpkgs/$subpkg"
          mkdir -p "$target"
          rm -f "$target/template"
          ln -s "../$pkgname/template" "$target/template"
          chown -R builder "$target"
          echo "==> Linked subpackage $subpkg -> $pkgname"
        done
  done
fi

# Seed hostdir/binpkgs from the rolling repo-glibc release - but only
# when it's actually needed. xbps-src resolves ordinary deps from
# Void's stock binary repo on its own; the only reason to seed anything
# here is so a custom package (one of ours, not upstream Void) can
# depend on another custom package that only exists in our own release.
# A plain upstream rebuild with no custom templates needs none of this,
# so downloading (part of) the release for it is pure waste - and that
# waste grows every time packages.txt grows, on runners with ~14GB free
# disk. So: no custom templates -> skip entirely. Custom templates
# present -> download only the specific packages they actually depend
# on, not the whole release.
CUSTOM_PKGS=""
if [ -d "$GITHUB_WORKSPACE/srcpkgs" ]; then
  for pkgdir in "$GITHUB_WORKSPACE"/srcpkgs/*/; do
    [ -d "$pkgdir" ] || continue
    CUSTOM_PKGS="$CUSTOM_PKGS $(basename "$pkgdir")"
  done
fi

if [ -z "$CUSTOM_PKGS" ]; then
  echo "==> No custom templates in srcpkgs/ - skipping repo-glibc hostdir seed."
else
  # Pull hostmakedepends/makedepends/depends out of every custom
  # template (best-effort text parsing, not a full shell eval, so it
  # won't catch dependencies computed dynamically at build time), then
  # keep only the tokens that name one of our OWN custom packages -
  # anything else is a stock Void package xbps-src already gets from
  # the official binary repo without our help.
  NEEDED=""
  for template in "$GITHUB_WORKSPACE"/srcpkgs/*/template; do
    [ -f "$template" ] || continue
    deps=$(awk '
      /^(hostmakedepends|makedepends|depends)=/ {
        line=$0; sub(/^[^=]+=/, "", line); sub(/^"/, "", line)
        if (line ~ /"/) { sub(/".*/, "", line); print line; next }
        print line; capturing=1; next
      }
      capturing {
        line=$0
        if (line ~ /"/) { sub(/".*/, "", line); print line; capturing=0 }
        else { print line }
      }
    ' "$template" 2>/dev/null)
    for tok in $deps; do
      name=$(printf '%s' "$tok" | sed -E 's/[<>=!].*$//')
      [ -n "$name" ] || continue
      case " $CUSTOM_PKGS " in
        *" $name "*)
          case " $NEEDED " in
            *" $name "*) ;;
            *) NEEDED="$NEEDED $name" ;;
          esac
          ;;
      esac
    done
  done

  if [ -z "$NEEDED" ]; then
    echo "==> Custom templates present but none depend on each other - skipping repo-glibc hostdir seed."
  else
    echo "==> Seeding hostdir/binpkgs with just: $NEEDED"
    mkdir -p "$WORKDIR/hostdir/binpkgs"
    set --
    for name in $NEEDED; do
      set -- "$@" --pattern "${name}-*.xbps"
    done
    gh release download repo-glibc --repo "$REPO" \
      --dir "$WORKDIR/hostdir/binpkgs" "$@" --clobber 2>/dev/null \
      || echo "No matching packages in repo-glibc release yet - building from a clean local repo."
    chown -R builder "$WORKDIR/hostdir"
    if [ -n "$(find "$WORKDIR/hostdir/binpkgs" -maxdepth 1 -name '*.xbps' 2>/dev/null)" ]; then
      su builder -c "cd $WORKDIR && xbps-rindex -a hostdir/binpkgs/*.xbps"
    fi
  fi
fi

cd "$WORKDIR"

if [ -d masterdir-x86_64 ]; then
  echo "==> Reusing cached masterdir, updating bootstrap packages"
  su builder -c './xbps-src bootstrap-update' || {
    echo "==> bootstrap-update failed, rebootstrapping from scratch"
    rm -rf masterdir-x86_64
    su builder -c './xbps-src binary-bootstrap'
  }
else
  echo "==> No cached masterdir, bootstrapping fresh"
  su builder -c './xbps-src binary-bootstrap'
fi

# Optional per-package extra repo - see extra-repos/README.md
if [ -f "$GITHUB_WORKSPACE/extra-repos/$PKG.conf" ]; then
  echo "==> Enabling extra repo for $PKG"
  mkdir -p masterdir-x86_64/etc/xbps.d
  cp "$GITHUB_WORKSPACE/extra-repos/$PKG.conf" "masterdir-x86_64/etc/xbps.d/17-$PKG.conf"
  su builder -c 'yes | xbps-install -r masterdir-x86_64 -Sy'
fi

su builder -c "xgensum -i srcpkgs/$PKG/template" || true
su builder -c "./xbps-src pkg $PKG"

mkdir -p "$GITHUB_WORKSPACE/hostdir-binpkgs"
cp -r "$WORKDIR"/hostdir/binpkgs/. "$GITHUB_WORKSPACE/hostdir-binpkgs/"
echo "==> build_only.sh finished, staged output at hostdir-binpkgs/"

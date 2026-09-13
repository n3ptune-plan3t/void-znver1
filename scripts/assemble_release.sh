#!/bin/sh
# Publish phase - runs in the concurrency-locked "publish" job, after
# build_only.sh's output has been downloaded (as a workflow artifact)
# into BINPKGS_DIR. De-dupes stale versions, stages out/ (this run's
# package, for the per-package release) and merged/ (everything, for
# the rolling repo-glibc release), signs+indexes.
set -e

if [ -z "${PKG:-}" ]; then
  echo "PKG is not set" >&2
  exit 1
fi
BINPKGS_DIR="${BINPKGS_DIR:-$GITHUB_WORKSPACE/hostdir-binpkgs}"
cd "$BINPKGS_DIR"

# xbps-rindex -c doesn't reliably prune superseded files, so do it
# explicitly and log what gets removed.
echo "==> De-duplicating $BINPKGS_DIR"
ls ./*.x86_64.xbps 2>/dev/null \
  | sed -E 's/-[^-]+_[0-9]+\.x86_64\.xbps$//' \
  | sort -u \
  | while read -r base; do
      matches=$(ls -- "$base"-*.x86_64.xbps 2>/dev/null | grep -E "^${base}-[0-9]")
      newest=$(printf '%s\n' "$matches" | sort -V | tail -n1)
      printf '%s\n' "$matches" | while read -r f; do
        [ "$f" = "$newest" ] && continue
        echo "==> Removing stale $f (superseded by $newest)"
        rm -f -- "$f"
      done
    done

mkdir -p "$GITHUB_WORKSPACE/out"
find "$BINPKGS_DIR" -maxdepth 1 -name "${PKG}-*.xbps" -exec cp {} "$GITHUB_WORKSPACE/out/" \;
if [ -z "$(ls -A "$GITHUB_WORKSPACE/out" 2>/dev/null)" ]; then
  echo "::error::no .xbps found for $PKG in $BINPKGS_DIR" >&2
  exit 1
fi

# Sanity check (log-only, doesn't block publish): confirm the binaries we
# just built actually got compiled for v3+, not silently falling back to
# baseline x86-64. Recent binutils/glibc embed a GNU_PROPERTY ISA-level
# note when -march produces code above baseline; not every toolchain or
# binary type does this (interpreted-language packages, static data-only
# packages, older toolchains), so absence isn't proof of failure - it's
# just worth a look if you see it on something you expect to be hot code.
echo "==> Checking compiled ISA level (informational only)"
mkdir -p /tmp/isa-check
cd /tmp/isa-check
for f in "$GITHUB_WORKSPACE"/out/*.xbps; do
  tar -xf "$f" -C /tmp/isa-check --wildcards 'usr/bin/*' 2>/dev/null || true
done
FOUND_NOTE=0
for bin in /tmp/isa-check/usr/bin/*; do
  [ -f "$bin" ] || continue
  NOTE=$(readelf -n "$bin" 2>/dev/null | grep -i "x86 ISA needed" || true)
  if [ -n "$NOTE" ]; then
    echo "==> $(basename "$bin"): $NOTE"
    FOUND_NOTE=1
  fi
done
if [ "$FOUND_NOTE" -eq 0 ]; then
  echo "==> No x86 ISA-level GNU_PROPERTY note found on any installed binary."
  echo "    Not necessarily a problem (many toolchains/binaries don't embed"
  echo "    this), but if $PKG is compute-heavy, worth spot-checking that"
  echo "    XBPS_CFLAGS actually reached its build."
fi
rm -rf /tmp/isa-check

mkdir -p "$GITHUB_WORKSPACE/merged"
cp "$BINPKGS_DIR"/*.xbps "$GITHUB_WORKSPACE/merged/"

cd "$GITHUB_WORKSPACE/merged"
if [ -n "${REPO_SIGNING_KEY_B64:-}" ]; then
  # Accept either the intended base64-encoded key OR a raw PEM pasted
  # directly into the secret by mistake - the latter is the far more
  # common failure mode (base64 -d aborting with "invalid input"
  # because '-----BEGIN...' contains '-', which isn't valid base64).
  if printf '%s' "$REPO_SIGNING_KEY_B64" | grep -q -- '-----BEGIN'; then
    echo "==> REPO_SIGNING_KEY_B64 looks like a raw PEM, not base64 - using it as-is"
    printf '%s\n' "$REPO_SIGNING_KEY_B64" > /tmp/repokey.rsa
  else
    # tr strips any stray whitespace a copy/paste into the GitHub secret
    # box may have introduced (a plain space or \r isn't tolerated by
    # base64 -d the way \n is) - cheap insurance against "invalid input"
    # from an otherwise-correct secret value.
    if ! printf '%s' "$REPO_SIGNING_KEY_B64" | tr -d '[:space:]' | base64 -d > /tmp/repokey.rsa 2>/tmp/b64err.log; then
      echo "::error::REPO_SIGNING_KEY_B64 failed to base64-decode: $(cat /tmp/b64err.log) - re-check the secret value (should be \`base64 -w0 repokey.pem\`, pasted whole, with no surrounding quotes)" >&2
      rm -f /tmp/repokey.rsa /tmp/b64err.log
      exit 1
    fi
    rm -f /tmp/b64err.log
  fi
  if ! head -c 11 /tmp/repokey.rsa 2>/dev/null | grep -q '\-\-\-\-\-BEGIN'; then
    echo "::error::REPO_SIGNING_KEY_B64 didn't decode to a PEM private key - re-check the secret value" >&2
    rm -f /tmp/repokey.rsa
    exit 1
  fi
  xbps-rindex -a ./*.xbps
  xbps-rindex --sign --signedby "${REPO_SIGNEDBY:-void-cpu-opt}" --privkey /tmp/repokey.rsa .
  rm -f /tmp/repokey.rsa
else
  xbps-rindex -a ./*.xbps
fi
echo "==> assemble_release.sh finished: out/ has this run's package, merged/ has the full repo"

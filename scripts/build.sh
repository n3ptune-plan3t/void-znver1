#!/bin/sh
# Convenience wrapper for manual/local testing inside a void-glibc-full
# container: runs the build phase then the assembly phase back to back.
# The actual CI workflows call build_only.sh and assemble_release.sh
# separately (as build/publish jobs) so publishes can be serialized
# with the concurrency group while builds run in parallel.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
sh "$DIR/build_only.sh"
BINPKGS_DIR="${GITHUB_WORKSPACE:-.}/hostdir-binpkgs" sh "$DIR/assemble_release.sh"

#!/bin/sh
# Runs build_only.sh under a wall-clock watchdog for one package. If it
# isn't done by SOFT_LIMIT_SECS, sends a graceful stop signal so make/ninja
# finish their current unit, and exits 75 so build-large.yml knows to
# re-dispatch itself for another attempt rather than treating this as a
# real failure.
set -eu

PKG_ARG="$1"
SOFT_LIMIT="${2:-20700}"   # 5h45m default, leaves margin before the 6h kill
DIR="$(cd "$(dirname "$0")" && pwd)"

PKG="$PKG_ARG" sh "$DIR/build_only.sh" > "$GITHUB_WORKSPACE/build-$PKG_ARG.log" 2>&1 &
BUILD_PID=$!

START=$(date +%s)
while kill -0 "$BUILD_PID" 2>/dev/null; do
    sleep 30
    NOW=$(date +%s)
    ELAPSED=$((NOW - START))
    if [ "$ELAPSED" -ge "$SOFT_LIMIT" ]; then
        echo "==> soft time limit hit at ${ELAPSED}s, stopping build gracefully"
        kill -TERM "$BUILD_PID" 2>/dev/null || true
        wait "$BUILD_PID" 2>/dev/null || true
        echo "needs_continuation=true"
        exit 75
    fi
done

wait "$BUILD_PID"
STATUS=$?

if [ "$STATUS" -ne 0 ]; then
    echo "==> build failed (exit $STATUS), see build-$PKG_ARG.log"
    tail -n 200 "$GITHUB_WORKSPACE/build-$PKG_ARG.log"
    exit "$STATUS"
fi

echo "==> build finished within this attempt"
echo "needs_continuation=false"

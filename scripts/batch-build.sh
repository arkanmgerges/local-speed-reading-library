#!/usr/bin/env bash
# Pins, builds and prunes every edition that has no asset block yet (the
# output of `dart run bin/discover.dart --write`), then regenerates the
# catalogue and validates. Provider requests are spaced by --delay seconds.
#
#   scripts/batch-build.sh [--delay 2] [--min-words 6000] [--per-language 20] [--report build/discover-report.json]
#
# Prune only runs when the build produced at least one asset, so a broken
# build never deletes the candidate files.
set -uo pipefail

DELAY=2 MIN_WORDS=6000 PER_LANGUAGE=20 REPORT=build/discover-report.json
while [ $# -gt 0 ]; do
  case "$1" in
    --delay) DELAY="$2"; shift 2 ;;
    --min-words) MIN_WORDS="$2"; shift 2 ;;
    --per-language) PER_LANGUAGE="$2"; shift 2 ;;
    --report) REPORT="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 64 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/tools"

dart run bin/lsr.dart pin --unbuilt --delay "$DELAY" > "$ROOT/build/pin.log" 2>&1
echo "pinned: $(grep -c '^pinned' "$ROOT/build/pin.log"), failed: $(grep -c '^FAILED' "$ROOT/build/pin.log")"
dart run bin/lsr.dart build --unbuilt --delay "$DELAY" > "$ROOT/build/build.log" 2>&1
BUILT=$(grep -c '^built' "$ROOT/build/build.log")
echo "built: $BUILT, failed: $(grep -c '^FAILED' "$ROOT/build/build.log")"
if [ "$BUILT" -eq 0 ]; then
  echo "nothing was built; not pruning (see build/build.log)" >&2
  exit 1
fi
dart run bin/prune.dart --report "$ROOT/$REPORT" --min-words "$MIN_WORDS" --per-language "$PER_LANGUAGE" > "$ROOT/build/prune.log" 2>&1
tail -1 "$ROOT/build/prune.log"
dart run bin/lsr.dart catalog
dart run bin/lsr.dart validate

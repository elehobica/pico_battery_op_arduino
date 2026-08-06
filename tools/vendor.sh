#!/bin/bash
#------------------------------------------------------
# Copyright (c) 2026, Elehobica
# Released under the BSD-2-Clause
# refer to https://opensource.org/licenses/BSD-2-Clause
#------------------------------------------------------
#
# Regenerate src/ of this Arduino library from its upstream sources.
#
# This library is a repackaging of two upstream projects, and every file under src/ is a
# generated artifact that is nevertheless committed (the Arduino Library Manager distributes
# the repository as an archive, so submodules and build-time generation are not an option):
#
#   src/pico_battery_op.h            <- elehobica/pico_battery_op  (verbatim)
#   src/pico_battery_op.cpp          <- elehobica/pico_battery_op  (verbatim)
#   src/pbo_vendor/pbo_rosc.h        <- raspberrypi/pico-sdk       (verbatim)
#   src/pbo_vendor/pbo_sleep.h       <- raspberrypi/pico-extras    (patched, see transform_sleep_h)
#   src/pbo_vendor/pbo_sleep.c       <- raspberrypi/pico-extras    (patched, see transform_sleep_c)
#
# The source repositories and the pico-extras / pico-sdk tags are HARDCODED below on purpose:
# the GitHub Actions workflow that runs this script is manually triggered, and hardcoding the
# origins means a trigger cannot be abused to vendor code from somewhere else.
#
# Usage:
#   ./tools/vendor.sh [--ref REF] [--out DIR]
#   ./tools/vendor.sh --local [--out DIR]
#
#   --ref REF    upstream (pico_battery_op) branch / tag / commit to fetch. default: main
#   --out DIR    repository root to write src/ into. default: the parent of tools/
#   --local      copy from local checkouts instead of downloading. Requires the environment
#                variables UPSTREAM_ROOT, PICO_EXTRAS_PATH and PICO_SDK_PATH. Used to verify
#                this script against a known-good tree without network access.
#
# The output is deterministic: running the script twice with the same inputs produces
# byte-identical files, so a CI run with nothing to update leaves no diff behind.

set -euo pipefail

#------------------------------------------------------
# Hardcoded origins
#------------------------------------------------------
UPSTREAM_REPO="elehobica/pico_battery_op"
UPSTREAM_REF_DEFAULT="main"

PICO_EXTRAS_REPO="raspberrypi/pico-extras"
PICO_EXTRAS_TAG="sdk-2.3.0"

PICO_SDK_REPO="raspberrypi/pico-sdk"
PICO_SDK_TAG="2.3.0"

# paths within each origin
UPSTREAM_PATH_H="pico_battery_op.h"
UPSTREAM_PATH_CPP="pico_battery_op.cpp"
EXTRAS_PATH_SLEEP_C="src/rp2_common/pico_sleep/sleep.c"
EXTRAS_PATH_SLEEP_H="src/rp2_common/pico_sleep/include/pico/sleep.h"
SDK_PATH_ROSC_H="src/rp2_common/hardware_rosc/include/hardware/rosc.h"

# Global functions defined by pico-extras' sleep.c / sleep.h. Arduino links every library of a
# sketch together, so these are renamed with a pbov_ prefix to avoid colliding with any other
# library that bundles the same pico-extras sources.
# NOTE: rosc_disable / rosc_set_dormant / rosc_restart are deliberately NOT renamed - they are
# only declared here, and must resolve to the single implementation inside the core's libpico.a.
PBOV_NAMES=(
    sleep_run_from_dormant_source
    sleep_run_from_xosc
    sleep_run_from_lposc
    sleep_run_from_rosc
    sleep_goto_sleep_until
    sleep_goto_sleep_for
    sleep_goto_dormant_until
    sleep_goto_dormant_until_pin
    sleep_goto_dormant_until_edge_high
    sleep_goto_dormant_until_level_high
    sleep_power_up
    dormant_source_valid
)

#------------------------------------------------------
# Arguments
#------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPSTREAM_REF="$UPSTREAM_REF_DEFAULT"
MODE="remote"

usage() {
    cat <<'EOF'
Regenerate src/ of this Arduino library from its upstream sources.

Usage:
  ./tools/vendor.sh [--ref REF] [--out DIR]
  ./tools/vendor.sh --local [--out DIR]

  --ref REF    upstream (pico_battery_op) branch / tag / commit to fetch. default: main
  --out DIR    repository root to write src/ into. default: the parent of tools/
  --local      copy from local checkouts instead of downloading. Requires the environment
               variables UPSTREAM_ROOT, PICO_EXTRAS_PATH and PICO_SDK_PATH.
  --help       show this message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ref|-r)
            [[ $# -ge 2 ]] || { echo "error: $1 requires an argument" >&2; exit 1; }
            UPSTREAM_REF="$2"; shift 2 ;;
        --out|-o)
            [[ $# -ge 2 ]] || { echo "error: $1 requires an argument" >&2; exit 1; }
            OUT="$2"; shift 2 ;;
        --local)
            MODE="local"; shift ;;
        --help|-h)
            usage; exit 0 ;;
        *)
            echo "error: unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# an empty --ref (from a workflow input left blank) falls back to the default
[[ -n "$UPSTREAM_REF" ]] || UPSTREAM_REF="$UPSTREAM_REF_DEFAULT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

#------------------------------------------------------
# Fetch
#------------------------------------------------------
fetch_remote() {  # <repo> <ref> <path> <dest>
    local repo="$1" ref="$2" path="$3" dest="$4"
    local url="https://raw.githubusercontent.com/${repo}/${ref}/${path}"
    if ! curl -fsSL "$url" -o "$dest"; then
        echo "error: failed to download $url" >&2
        exit 1
    fi
    echo "fetched $repo@$ref $path"
}

fetch_local() {  # <root-var-name> <root> <path> <dest>
    local var="$1" root="$2" path="$3" dest="$4"
    if [[ -z "$root" ]]; then
        echo "error: --local requires the environment variable $var" >&2
        exit 1
    fi
    if [[ ! -f "$root/$path" ]]; then
        echo "error: source not found: $root/$path (\$$var)" >&2
        exit 1
    fi
    cp "$root/$path" "$dest"
    echo "copied \$$var/$path"
}

# Resolve the upstream ref to a commit so VENDOR_INFO.txt records exactly what was taken.
resolve_upstream_commit() {
    local sha=""
    if [[ "$MODE" == "local" ]]; then
        sha="$(git -C "${UPSTREAM_ROOT:-.}" rev-parse HEAD 2>/dev/null || true)"
    else
        local api="https://api.github.com/repos/${UPSTREAM_REPO}/commits/${UPSTREAM_REF}"
        local hdr=()
        [[ -n "${GITHUB_TOKEN:-}" ]] && hdr=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
        sha="$(curl -fsSL "${hdr[@]}" -H "Accept: application/vnd.github.sha" "$api" 2>/dev/null || true)"
    fi
    # only accept something that looks like a full sha
    if [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
        echo "$sha"
    else
        echo "unresolved"
    fi
}

if [[ "$MODE" == "local" ]]; then
    fetch_local UPSTREAM_ROOT     "${UPSTREAM_ROOT:-}"     "$UPSTREAM_PATH_H"     "$WORK/pico_battery_op.h"
    fetch_local UPSTREAM_ROOT     "${UPSTREAM_ROOT:-}"     "$UPSTREAM_PATH_CPP"   "$WORK/pico_battery_op.cpp"
    fetch_local PICO_EXTRAS_PATH  "${PICO_EXTRAS_PATH:-}"  "$EXTRAS_PATH_SLEEP_C" "$WORK/sleep.c"
    fetch_local PICO_EXTRAS_PATH  "${PICO_EXTRAS_PATH:-}"  "$EXTRAS_PATH_SLEEP_H" "$WORK/sleep.h"
    fetch_local PICO_SDK_PATH     "${PICO_SDK_PATH:-}"     "$SDK_PATH_ROSC_H"     "$WORK/rosc.h"
else
    fetch_remote "$UPSTREAM_REPO"    "$UPSTREAM_REF"     "$UPSTREAM_PATH_H"     "$WORK/pico_battery_op.h"
    fetch_remote "$UPSTREAM_REPO"    "$UPSTREAM_REF"     "$UPSTREAM_PATH_CPP"   "$WORK/pico_battery_op.cpp"
    fetch_remote "$PICO_EXTRAS_REPO" "$PICO_EXTRAS_TAG"  "$EXTRAS_PATH_SLEEP_C" "$WORK/sleep.c"
    fetch_remote "$PICO_EXTRAS_REPO" "$PICO_EXTRAS_TAG"  "$EXTRAS_PATH_SLEEP_H" "$WORK/sleep.h"
    fetch_remote "$PICO_SDK_REPO"    "$PICO_SDK_TAG"     "$SDK_PATH_ROSC_H"     "$WORK/rosc.h"
fi

#------------------------------------------------------
# Transform
#------------------------------------------------------
# alternation of the global names to prefix; \b...\b makes the order irrelevant and keeps
# already-prefixed names (pbov_sleep_power_up) and unrelated text (sleep_run_*) untouched
PBOV_ALT="$(IFS='|'; echo "${PBOV_NAMES[*]}")"

UART_GUARD_COMMENT="the Arduino core owns Serial/UART; setup_default_uart is not linked under ARDUINO"

transform_sleep_h() {  # <src> <dest>
    sed -E \
        -e 's/^#(ifndef|define) _PICO_SLEEP_H_$/#\1 _PBO_VENDOR_SLEEP_H_/' \
        -e 's|^#include "hardware/rosc_extra.h"$|#include "pbo_rosc.h"    // vendored hardware/rosc.h (not on the arduino-pico include path)|' \
        -e "s/\\b(${PBOV_ALT})\\b/pbov_\\1/g" \
        "$1" > "$2"
}

transform_sleep_c() {  # <src> <dest>
    sed -E \
        -e 's|^#include "pico/sleep.h"$|#include "pbo_sleep.h"|' \
        -e "s/\\b(${PBOV_ALT})\\b/pbov_\\1/g" \
        -e "s|^    setup_default_uart\(\);\$|#if !defined(ARDUINO)\n    setup_default_uart();  // ${UART_GUARD_COMMENT}\n#endif|" \
        "$1" > "$2"
}

SRC="$OUT/src"
VENDOR="$SRC/pbo_vendor"
mkdir -p "$VENDOR"

cp "$WORK/pico_battery_op.h"   "$SRC/pico_battery_op.h"
cp "$WORK/pico_battery_op.cpp" "$SRC/pico_battery_op.cpp"
cp "$WORK/rosc.h"              "$VENDOR/pbo_rosc.h"
transform_sleep_h "$WORK/sleep.h" "$VENDOR/pbo_sleep.h"
transform_sleep_c "$WORK/sleep.c" "$VENDOR/pbo_sleep.c"

#------------------------------------------------------
# Self check
#
# The transform is a set of textual substitutions against upstream files that may change without
# notice, so every assumption it makes is asserted here rather than silently producing sources
# that fail to compile (or, worse, compile and collide at link time).
#------------------------------------------------------
fail() { echo "error: vendoring self check failed: $1" >&2; exit 1; }

# 1. no un-prefixed global left in either vendored sleep file. \b prevents matching the
#    pbov_-prefixed forms, and 'sleep_run_*' in prose does not match 'sleep_run_from'.
for f in "$VENDOR/pbo_sleep.c" "$VENDOR/pbo_sleep.h"; do
    if grep -nE '\b(sleep_run_from|sleep_goto_|sleep_power_up|dormant_source_valid)' "$f"; then
        fail "un-prefixed global name left in $(basename "$f") (see matches above)"
    fi
done

# 2. the prefix was actually applied (guards against an upstream rename silently no-op'ing it)
for name in "${PBOV_NAMES[@]}"; do
    grep -q "pbov_${name}" "$VENDOR/pbo_sleep.c" "$VENDOR/pbo_sleep.h" \
        || fail "pbov_${name} not found in the vendored sleep sources"
done

# 3. rosc_* must keep their real names (they resolve to the core's libpico.a)
grep -q 'pbov_rosc_' "$VENDOR/pbo_sleep.c" && fail "rosc_* must not be prefixed"
for name in rosc_disable rosc_set_dormant rosc_restart; do
    grep -qE "\b${name}\b" "$VENDOR/pbo_sleep.c" \
        || fail "${name} not found in pbo_sleep.c (upstream may have changed)"
done

# 4. exactly the two setup_default_uart() call sites are guarded
n_guard="$(grep -c '^#if !defined(ARDUINO)$' "$VENDOR/pbo_sleep.c" || true)"
[[ "$n_guard" == "2" ]] || fail "expected 2 ARDUINO guards in pbo_sleep.c, found $n_guard"
n_uart="$(grep -c 'setup_default_uart();' "$VENDOR/pbo_sleep.c" || true)"
[[ "$n_uart" == "2" ]] || fail "expected 2 setup_default_uart() calls in pbo_sleep.c, found $n_uart"

# 5. include / guard rewrites left nothing behind
grep -q '_PICO_SLEEP_H_'    "$VENDOR/pbo_sleep.h" && fail "include guard not renamed in pbo_sleep.h"
grep -q 'rosc_extra.h'      "$VENDOR/pbo_sleep.h" && fail "rosc_extra.h include not rewritten in pbo_sleep.h"
grep -q '_PBO_VENDOR_SLEEP_H_' "$VENDOR/pbo_sleep.h" || fail "renamed include guard missing in pbo_sleep.h"
grep -q '"pico/sleep.h"'    "$VENDOR/pbo_sleep.c" && fail "pico/sleep.h include not rewritten in pbo_sleep.c"
grep -q '"pbo_sleep.h"'     "$VENDOR/pbo_sleep.c" || fail "pbo_sleep.h include missing in pbo_sleep.c"

# 6. the verbatim copies are what we think they are
grep -q '_HARDWARE_ROSC_H_' "$VENDOR/pbo_rosc.h"     || fail "pbo_rosc.h does not look like hardware/rosc.h"
grep -q 'pbo_init'          "$SRC/pico_battery_op.h" || fail "pico_battery_op.h does not look like the library header"

#------------------------------------------------------
# Provenance
#
# Intentionally free of timestamps so that re-running with unchanged origins yields no diff.
#------------------------------------------------------
UPSTREAM_COMMIT="$(resolve_upstream_commit)"
if [[ "$MODE" == "local" ]]; then
    UPSTREAM_REF_LABEL="(--local checkout; --ref not used)"
else
    UPSTREAM_REF_LABEL="$UPSTREAM_REF"
fi
cat > "$VENDOR/VENDOR_INFO.txt" <<EOF
Generated by tools/vendor.sh - do not edit by hand.

pico_battery_op.h, pico_battery_op.cpp
  origin : https://github.com/${UPSTREAM_REPO}
  ref    : ${UPSTREAM_REF_LABEL}
  commit : ${UPSTREAM_COMMIT}
  patch  : none (verbatim copy)

pbo_sleep.c, pbo_sleep.h
  origin : https://github.com/${PICO_EXTRAS_REPO}
  tag    : ${PICO_EXTRAS_TAG}
  paths  : ${EXTRAS_PATH_SLEEP_C}
           ${EXTRAS_PATH_SLEEP_H}
  patch  : include rewrite, include guard rename, pbov_ prefix on the global functions,
           setup_default_uart() guarded with #if !defined(ARDUINO)

pbo_rosc.h
  origin : https://github.com/${PICO_SDK_REPO}
  tag    : ${PICO_SDK_TAG}
  path   : ${SDK_PATH_ROSC_H}
  patch  : none (verbatim copy)
EOF

echo "vendored into $SRC"

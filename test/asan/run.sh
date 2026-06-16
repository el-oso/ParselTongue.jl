#!/usr/bin/env bash
# ASan/LSan gate for the generated C glue. Generates the shim for
# test/fixtures/asan_carriers.jl, compiles it + driver.c with AddressSanitizer
# (Julia is NOT linked — pt_* are stubbed in driver.c), and runs the harness.
# A leak in the marshalling glue (e.g. a reverted A1/A2 fix) fails this.
#
#   test/asan/run.sh            # uses `cc` and `python3`
#   CC=gcc test/asan/run.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
cc="${CC:-cc}"
py="${PYTHON3:-python3}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "==> generating shim"
julia --project="$root" "$here/gen_shim.jl" > "$work/shim_generated.c"

echo "==> compiling with -fsanitize=address"
# python3-config --embed gives the libpython link flags for an embedded interpreter.
pycflags="$($py-config --includes)"
pyldflags="$($py-config --ldflags --embed)"
"$cc" -fsanitize=address -fno-omit-frame-pointer -g -O1 \
      -Wno-unused-function -I"$work" \
      "$here/driver.c" $pycflags $pyldflags -o "$work/asan_glue"

echo "==> running"
# PYTHONMALLOC=malloc routes CPython allocations through libc so ASan sees them and
# DECREF'd objects are actually freed (keeps the reachable set clean).
out="$(PYTHONMALLOC=malloc PYTHONDONTWRITEBYTECODE=1 \
       ASAN_OPTIONS=detect_leaks=1:exitcode=1 "$work/asan_glue" 2>&1)" || {
    echo "$out"; echo "ASAN GATE: FAIL"; exit 1; }
echo "$out"
echo "$out" | grep -q ASAN_GLUE_OK && { echo "ASAN GATE: PASS"; exit 0; }
echo "ASAN GATE: FAIL (no OK marker)"; exit 1

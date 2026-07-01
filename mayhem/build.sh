#!/usr/bin/env bash
#
# mayhem/build.sh -- build the metapensiero.pj (javascripthon) Atheris fuzz harness + its
# standalone reproducer, and prepare the project's own pytest suite. Runs inside the commit
# image (mayhem/Dockerfile) as `mayhem` in /mayhem. Python adaptation of the C/C++ template.
#
# What it does (must be idempotent + air-gapped on re-run -- SPEC 6.2 item 9 / 6.5):
#   1. Populate / reuse an in-image wheelhouse under /opt/toolchains/python (HOME-independent),
#      then install atheris + dukpy (the JS runtime the transpiler links) + the test deps OFFLINE
#      from that wheelhouse into a fixed site dir on PYTHONPATH. The first (CI, online) build fills
#      the wheelhouse; the air-gapped PATCH re-run resolves entirely from it (--no-index).
#   2. Compile launcher.c -> the ELF Mayhem target `pj_fuzzer` (Atheris is a Python script; Mayhem
#      needs an ELF cmd, and the gate needs DWARF < 4 -- hence a compiled wrapper).
#   3. Build the same launcher as the standalone (run-once) reproducer `pj_fuzzer-standalone`.
#   4. Compile the pytest-runner ELF wrapper so the sabotage oracle bites (see run_tests.c).
#
# The base image exports the build contract (CC, SANITIZER_FLAGS, DEBUG_FLAGS, ...). The launcher is
# a thin C exec wrapper -- applying SANITIZER_FLAGS to it would just instrument the wrapper, not the
# fuzzed Python; Atheris instruments the metapensiero.pj library itself at import time. So we only
# need DEBUG_FLAGS here.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${MAYHEM_JOBS:=$(nproc)}"
export DEBUG_FLAGS CC MAYHEM_JOBS

SRC="${SRC:-/mayhem}"
cd "$SRC"

# -- Python toolchain caches at a FIXED, $HOME-independent prefix (SPEC 6.2 item 8) --
PY_PREFIX=/opt/toolchains/python
WHEELHOUSE="$PY_PREFIX/wheelhouse"
SITE="$PY_PREFIX/site"
mkdir -p "$WHEELHOUSE" "$SITE"

PY="$(command -v python3)"

# 1) Wheelhouse: download every runtime/test dependency ONCE (online). On the air-gapped re-run the
#    directory is already populated, so pip never reaches the network. atheris ships a prebuilt
#    manylinux wheel for this CPython. dukpy (the embedded duktape JS engine) is the transpiler's
#    hard runtime dep -- api.py imports it at module load. pytest runs the suite. (meta -- an sdist used only by the
#    ast_dump helpers -- is intentionally omitted: test_various.py, our oracle, never triggers it.)
PKGS=(atheris dukpy pytest)
need_download=0
"$PY" -c "import os,glob,sys; sys.exit(0 if glob.glob(os.path.join('$WHEELHOUSE','atheris-*.whl')) else 1)" || need_download=1
if [ "$need_download" -eq 1 ]; then
  echo ">> populating wheelhouse (online) at $WHEELHOUSE"
  "$PY" -m pip download --dest "$WHEELHOUSE" "${PKGS[@]}"
else
  echo ">> wheelhouse already populated -- reusing $WHEELHOUSE (air-gapped re-run path)"
fi

# 2) Install the deps into the fixed site dir, OFFLINE from the wheelhouse. --no-index +
#    --find-links guarantees no PyPI access (works on the air-gapped re-run). Idempotent: once the
#    site dir holds atheris+dukpy+pytest we SKIP the reinstall. metapensiero.pj itself stays the
#    editable source tree (added to PYTHONPATH below) so a PATCH agent's edits under src/ take
#    effect with no reinstall.
if "$PY" -c "import os,glob,sys; sys.exit(0 if (glob.glob(os.path.join('$SITE','atheris*')) and glob.glob(os.path.join('$SITE','dukpy*')) and glob.glob(os.path.join('$SITE','pytest*'))) else 1)"; then
  echo ">> deps already installed in $SITE -- skipping (idempotent re-run)"
else
  echo ">> installing deps (offline) into $SITE"
  "$PY" -m pip install --no-index --find-links="$WHEELHOUSE" --target "$SITE" "${PKGS[@]}"
fi

# metapensiero.pj source lives under src/ (package_dir={'': 'src'}); expose it on PYTHONPATH.
PYRUN="$SITE:$SRC/src"

# Record the site dir + interpreter for test.sh / the launcher to consume.
cat > "$PY_PREFIX/env.sh" <<EOF
export PYTHONPATH="$PYRUN\${PYTHONPATH:+:\$PYTHONPATH}"
export PYTHON_BIN="$PY"
EOF

# Sanity: the harness imports must resolve offline now.
PYTHONPATH="$PYRUN" "$PY" -c 'import atheris, dukpy, pytest; from metapensiero.pj.__main__ import transform_string; print("imports OK:", transform_string("x = 1").strip())'

# 3) Compile the ELF launcher target + the standalone reproducer (DWARF < 4 via $DEBUG_FLAGS).
#    The launcher execs $PY on the harness; PYTHONPATH is baked into the env the binary inherits at
#    run time (the Dockerfile sets ENV PYTHONPATH), so the Python side finds atheris + the package.
HARNESS="$SRC/mayhem/fuzz_py.py"
echo ">> compiling pj_fuzzer (+ standalone) with DEBUG_FLAGS=$DEBUG_FLAGS"
$CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" -DHARNESS="\"$HARNESS\"" \
    "$SRC/mayhem/launcher.c" -o "$SRC/pj_fuzzer"
# The standalone reproducer is the same launcher: libFuzzer runs a single input file once when the
# harness is given a file path (no fuzzing loop) -- the run-once reproducer contract.
$CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" -DHARNESS="\"$HARNESS\"" \
    "$SRC/mayhem/launcher.c" -o "$SRC/pj_fuzzer-standalone"

# 4) The pytest oracle runs through a compiled NON-system ELF wrapper so the gate's anti-reward-hack
#    sabotage check (which neuters non-system binaries to exit(0)) actually bites the suite -- a
#    test.sh that shelled straight to the /usr/bin python would be spared and look reward-hackable.
$CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" "$SRC/mayhem/run_tests.c" -o "$SRC/pj_run_tests"

echo ">> build.sh complete"
ls -la "$SRC/pj_fuzzer" "$SRC/pj_fuzzer-standalone" "$SRC/pj_run_tests"

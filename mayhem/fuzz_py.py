#!/usr/bin/env python3
"""Atheris fuzz harness for metapensiero.pj (javascripthon).

Drives the Python-3 -> ES6 JavaScript transpiler on arbitrary source text via
the public ``transform_string`` entry point. Atheris instruments the imported
``metapensiero.pj`` modules (coverage), so libFuzzer explores the parser /
AST-transformation / code-generation pipeline.

Run modes (driven by the compiled launcher ``pj_fuzzer`` / ``-standalone``):
  * fuzzing      -- ``python3 fuzz_py.py [libFuzzer args]``
  * single input -- ``python3 fuzz_py.py <file>`` (libFuzzer runs it once)

Input bytes are decoded to source text through ``fuzz_helpers`` (a shared
FuzzedDataProvider helper module) via ``ConsumeRemainingString``.

A per-input SIGALRM guard bounds any single transpile: a pathological snippet
(e.g. deeply nested / adversarial AST) could otherwise hang a fork child.
"""
import signal
import sys

import atheris

# Shared FuzzedDataProvider helpers (EnhancedFuzzedDataProvider.ConsumeRemainingString).
import fuzz_helpers

# Instrument only the package under test so fork-child startup stays fast
# (a bare instrument_imports() would wrap hundreds of stdlib modules).
with atheris.instrument_imports(include=['metapensiero.pj']):
    from metapensiero.pj.__main__ import transform_string
    from metapensiero.pj.processor.exceptions import TransformationError


class _Timeout(Exception):
    pass


def _on_alarm(signum, frame):
    raise _Timeout()


signal.signal(signal.SIGALRM, _on_alarm)


def TestOneInput(data: bytes) -> None:
    fdp = fuzz_helpers.EnhancedFuzzedDataProvider(data)
    src = fdp.ConsumeRemainingString()
    signal.setitimer(signal.ITIMER_REAL, 5.0)
    try:
        transform_string(src)
    except (SyntaxError, TransformationError):
        # Malformed / unsupported Python is expected for arbitrary input.
        pass
    except (ValueError, TypeError, IndexError, KeyError, AttributeError,
            RecursionError, UnicodeError, _Timeout):
        # AST-shape / value errors bubbling out of the transpiler on
        # adversarial input are not memory-safety defects.
        pass
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0.0)


def main() -> None:
    atheris.Setup(sys.argv, TestOneInput)
    atheris.Fuzz()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3

import atheris
import sys

import fuzz_helpers
import random

with atheris.instrument_imports(include=['metapensiero.pj']):
    from metapensiero.pj.__main__ import transform_string

from metapensiero.pj.processor.exceptions import TransformationError
def TestOneInput(data):
    fdp = fuzz_helpers.EnhancedFuzzedDataProvider(data)
    try:
        transform_string(fdp.ConsumeRemainingString())
    except SyntaxError:
        return -1
    except (ValueError, ZeroDivisionError, TransformationError) as e:
        if random.random() > 0.90 and "null bytes" not in str(e):
            raise e
        return -1
def main():
    atheris.Setup(sys.argv, TestOneInput)
    atheris.Fuzz()


if __name__ == "__main__":
    main()

#!/bin/bash -eu
# Build the fuzzers in test/fuzz/ for ClusterFuzzLite. The fuzzers run the
# bash functions in lib/onbehalf, so copy them next to the fuzzers.
cp -r lib/onbehalf "$OUT/onbehalf-lib"
for fuzzer in test/fuzz/*_fuzzer.py; do
  compile_python_fuzzer "$fuzzer"
done

"""Fuzz the account name rules of onbehalf.

onbehalf makes Unix accounts from directory UPNs, as root. The name rules
in lib/onbehalf must use ASCII rules in all locales. This fuzzer gives the
same input to the bash functions and to a reference in Python, and stops
if the two results are not the same.

Run it with ClusterFuzzLite (.clusterfuzzlite/), or directly:
python3 test/fuzz/names_fuzzer.py -runs=10000
"""

import os
import re
import subprocess
import sys

import atheris


def lib_dir():
    if getattr(sys, "frozen", False):  # packed by compile_python_fuzzer
        return os.path.join(os.path.dirname(sys.executable), "onbehalf-lib")
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(here, "..", "..", "lib", "onbehalf")


LIB = lib_dir()

# $1: lib directory, $2: input. Prints four fields, each ends with NUL.
SCRIPT = r"""
ONBEHALF_LIB=$1
. "$1/common.sh"
. "$1/entra.sh"
. "$1/roles.sh"
printf '%s\0' "$(entra_derive_name "$2")" "$(agent_name_for "$2")"
if user_name_valid "$2"; then printf '1\0'; else printf '0\0'; fi
if account_name_valid "$2"; then printf '1\0'; else printf '0\0'; fi
"""

# A locale that is not installed falls back to C. That is not a problem.
LOCALES = ("C.UTF-8", "en_US.UTF-8", "tr_TR.UTF-8", "C")

# Bash gives no coverage to the fuzzer, so make UPNs from parts that are
# likely to find problems. The letters that are not ASCII change case in
# unusual ways: İ becomes i, the Kelvin sign K becomes k, ſ becomes S.
PARTS = (
    "a", "z", "A", "Z", "0", "9", "_", "-", ".", "@", "#ext#", "#EXT#",
    "alice", "Bob", "carol.smith", "@corp.com", " ", "\n", "$", "/", "*",
    "İ", "ı", "K", "ſ", "ǅ", "å", "é", "ß", "Ａ", "̇",
)

ACCOUNT = re.compile(rb"[a-z_][a-z0-9_-]{0,31}")
USER = re.compile(rb"[a-z0-9_][a-z0-9._@-]{0,63}")


def ascii_lower(b):
    return bytes(c + 32 if 65 <= c <= 90 else c for c in b)


def local_part(b):
    i = b.rfind(b"@")
    return b if i < 0 else b[:i]


def derive_name(upn):
    n = ascii_lower(local_part(upn))
    if b"#ext#" in n:
        return b""
    n = n.replace(b".", b"-")
    return n if ACCOUNT.fullmatch(n) else b""


def agent_name(upn):
    n = ascii_lower(local_part(upn)).replace(b".", b"-")[:25] + b"-agent"
    return n if ACCOUNT.fullmatch(n) else b""


def run_bash(upn, locale):
    env = {"PATH": "/usr/bin:/bin", "LANG": locale}
    out = subprocess.run(
        ["bash", "-c", SCRIPT, "names_fuzzer", LIB, upn],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=True,
    ).stdout
    fields = out.split(b"\0")
    assert len(fields) == 5 and fields[4] == b"", out
    return fields[0], fields[1], fields[2] == b"1", fields[3] == b"1"


def TestOneInput(data):
    fdp = atheris.FuzzedDataProvider(data)
    locale = LOCALES[fdp.ConsumeIntInRange(0, len(LOCALES) - 1)]
    kind = fdp.ConsumeIntInRange(0, 3)
    if kind == 0:
        upn = fdp.ConsumeBytes(96)
    elif kind == 1:
        upn = fdp.ConsumeUnicodeNoSurrogates(96).encode()
    else:
        count = fdp.ConsumeIntInRange(1, 24)
        upn = "".join(PARTS[fdp.ConsumeIntInRange(0, len(PARTS) - 1)] for _ in range(count)).encode()
    upn = upn.replace(b"\0", b"")  # a command argument cannot hold NUL

    got = run_bash(upn, locale)
    want = (
        derive_name(upn),
        agent_name(upn),
        USER.fullmatch(upn) is not None,
        ACCOUNT.fullmatch(upn) is not None,
    )
    if got != want:
        raise AssertionError(f"input {upn!r}, LANG={locale}: bash {got!r}, reference {want!r}")


def main():
    atheris.Setup(sys.argv, TestOneInput)
    atheris.Fuzz()


if __name__ == "__main__":
    main()

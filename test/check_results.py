"""Require at least one cocotb case and a successful result for every case."""

import sys
from xml.etree import ElementTree


def check(path):
    cases = ElementTree.parse(path).findall(".//testcase")
    if not cases:
        raise SystemExit(f"{path}: no test cases")
    for case in cases:
        for status in ("error", "failure", "skipped"):
            if case.find(status) is not None:
                raise SystemExit(f"{path}: {case.get('classname')}.{case.get('name')}: {status}")


if __name__ == "__main__":
    check(sys.argv[1])

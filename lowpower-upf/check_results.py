#!/usr/bin/env python3
"""Gate on cocotb's results.xml — exit non-zero if any test failed/errored.

cocotb's Make flow returns 0 even when a testcase fails (the verdict lives in
results.xml), so CI and the bug demo use this to turn a JUnit failure into a
shell failure.

    python3 check_results.py [results.xml]
"""
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

p = Path(sys.argv[1] if len(sys.argv) > 1 else "results.xml")
if not p.exists():
    print(f"check_results: {p} not found", file=sys.stderr)
    sys.exit(2)

cases = ET.parse(p).getroot().findall(".//testcase")
bad = [c for c in cases if c.find("failure") is not None or c.find("error") is not None]
print(f"{len(cases) - len(bad)}/{len(cases)} tests passed")
for c in bad:
    print(f"  FAIL {c.get('classname')}.{c.get('name')}")
sys.exit(1 if (bad or not cases) else 0)

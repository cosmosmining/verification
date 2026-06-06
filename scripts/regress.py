#!/usr/bin/env python3
"""Parallel-seed regression runner for sdram_lite_ctrl.

Backends
  cocotb (default) : runs the license-free Verilator mirror across seeds here.
  uvm              : runs `make uvm SIM=<sim> ...` per seed (campus simulators).

Outputs (under --out, default regression_out/)
  results_<seed>.xml   per-seed JUnit (cocotb) or synthesized JUnit (uvm)
  run_<seed>.log       full per-seed log
  junit.xml            merged JUnit across all seeds
  triage.md            failure-triage table (seed x test -> status / first error)
  summary.html         human-readable dashboard

Examples
  scripts/regress.py --num-seeds 8 --jobs 4
  scripts/regress.py --seeds "1 2 3 4" --backend uvm --sim dsim --uvm-test sdram_random_test
"""
import argparse
import concurrent.futures as cf
import html
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


# --------------------------------------------------------------------------- run
def run_cocotb(seed: int, outdir: Path, module: str):
    res = outdir / f"results_{seed}.xml"
    log = outdir / f"run_{seed}.log"
    build = outdir / f"sim_build_{seed}"
    env = os.environ.copy()
    env["COCOTB_RESULTS_FILE"] = str(res)
    cmd = ["make", "-C", str(REPO / "sim" / "cocotb"),
           f"SEED={seed}", f"SIM_BUILD={build}", f"MODULE={module}"]
    t0 = time.time()
    with open(log, "w") as fh:
        rc = subprocess.call(cmd, stdout=fh, stderr=subprocess.STDOUT, env=env)
    return dict(seed=seed, rc=rc, results=res, log=log, secs=time.time() - t0)


def run_uvm(seed: int, outdir: Path, sim: str, test: str):
    log = outdir / f"run_{seed}.log"
    cmd = ["make", "-C", str(REPO), "uvm",
           f"SIM={sim}", f"SEED={seed}", f"UVM_TEST={test}"]
    t0 = time.time()
    with open(log, "w") as fh:
        rc = subprocess.call(cmd, stdout=fh, stderr=subprocess.STDOUT)
    res = outdir / f"results_{seed}.xml"
    cases = parse_uvm_log(log, test)
    write_junit(res, f"seed{seed}", cases)
    return dict(seed=seed, rc=rc, results=res, log=log, secs=time.time() - t0)


# ------------------------------------------------------------------------- parse
def parse_uvm_log(log: Path, test: str):
    """Derive pass/fail from a UVM log (UVM_ERROR/UVM_FATAL counts)."""
    text = log.read_text(errors="ignore") if log.exists() else ""
    n_err = len(re.findall(r"UVM_ERROR(?!\s*:?\s*0\b)", text))
    fatal = "UVM_FATAL" in text
    # the UVM report summary line, if present, is authoritative
    m = re.search(r"UVM_ERROR\s*:?\s*(\d+)", text)
    if m:
        n_err = int(m.group(1))
    failed = fatal or n_err > 0 or "TEST FAILED" in text or not text
    msg = ""
    if failed:
        for line in text.splitlines():
            if "UVM_ERROR" in line or "UVM_FATAL" in line:
                msg = line.strip()
                break
        if not msg:
            msg = "no UVM report / simulator not found"
    return [(test, "fail" if failed else "pass", msg)]


def parse_cocotb_junit(path: Path):
    """Return list of (testname, status, message) from a cocotb results.xml."""
    out = []
    if not path.exists():
        return [("<no results>", "fail", "results.xml missing (compile/run error)")]
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as e:
        return [("<parse error>", "fail", str(e))]
    for tc in root.iter("testcase"):
        name = tc.get("name", "?")
        fail = tc.find("failure")
        err = tc.find("error")
        if fail is not None or err is not None:
            node = fail if fail is not None else err
            out.append((name, "fail", (node.get("message") or node.text or "").strip()[:200]))
        else:
            out.append((name, "pass", ""))
    return out or [("<empty>", "fail", "no testcases")]


# ------------------------------------------------------------------------- write
def write_junit(path: Path, suite: str, cases):
    ts = ET.Element("testsuite", name=suite,
                    tests=str(len(cases)),
                    failures=str(sum(1 for _, s, _ in cases if s == "fail")))
    for name, status, msg in cases:
        tc = ET.SubElement(ts, "testcase", name=name, classname=suite)
        if status == "fail":
            f = ET.SubElement(tc, "failure", message=msg[:200])
            f.text = msg
    ET.ElementTree(ts).write(path, encoding="utf-8", xml_declaration=True)


def merge_junit(per_seed, out: Path):
    root = ET.Element("testsuites")
    tot = fails = 0
    for seed, cases in per_seed:
        ts = ET.SubElement(root, "testsuite", name=f"seed{seed}",
                           tests=str(len(cases)),
                           failures=str(sum(1 for _, s, _ in cases if s == "fail")))
        for name, status, msg in cases:
            tot += 1
            tc = ET.SubElement(ts, "testcase", name=name, classname=f"seed{seed}")
            if status == "fail":
                fails += 1
                fe = ET.SubElement(tc, "failure", message=msg[:200])
                fe.text = msg
    ET.ElementTree(root).write(out, encoding="utf-8", xml_declaration=True)
    return tot, fails


def write_triage(per_seed, out: Path):
    lines = ["# Regression triage", "",
             "| Seed | Test | Status | First error |",
             "|------|------|--------|-------------|"]
    for seed, cases in per_seed:
        for name, status, msg in cases:
            badge = "PASS" if status == "pass" else "**FAIL**"
            lines.append(f"| {seed} | {name} | {badge} | {msg.replace('|', ' ')[:80]} |")
    out.write_text("\n".join(lines) + "\n")


def write_html(per_seed, out: Path, tot, fails, secs):
    rows = []
    for seed, cases in per_seed:
        for name, status, msg in cases:
            color = "#1a7f37" if status == "pass" else "#cf222e"
            rows.append(f"<tr><td>{seed}</td><td>{html.escape(name)}</td>"
                        f"<td style='color:{color};font-weight:bold'>{status.upper()}</td>"
                        f"<td>{html.escape(msg[:120])}</td></tr>")
    status = "PASS" if fails == 0 else f"{fails} FAIL"
    out.write_text(f"""<!doctype html><meta charset=utf-8>
<title>sdram_lite_ctrl regression</title>
<body style="font-family:system-ui;margin:2rem">
<h2>sdram_lite_ctrl regression — {status}</h2>
<p>{tot} testcases, {fails} failures, {secs:.1f}s wall.</p>
<table border=1 cellpadding=6 style="border-collapse:collapse">
<tr style="background:#eee"><th>Seed</th><th>Test</th><th>Status</th><th>Message</th></tr>
{''.join(rows)}
</table></body>""")


# -------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--backend", choices=["cocotb", "uvm"], default="cocotb")
    ap.add_argument("--seeds", help='space-separated, e.g. "1 2 3"')
    ap.add_argument("--num-seeds", type=int, default=8)
    ap.add_argument("--jobs", type=int, default=min(8, (os.cpu_count() or 2)))
    ap.add_argument("--out", default="regression_out")
    ap.add_argument("--module", default="tb_smoke", help="cocotb test module")
    ap.add_argument("--sim", default="dsim", help="UVM simulator")
    ap.add_argument("--uvm-test", default="sdram_random_test")
    args = ap.parse_args()

    seeds = ([int(s) for s in args.seeds.split()] if args.seeds
             else list(range(1, args.num_seeds + 1)))
    outdir = (REPO / args.out)
    outdir.mkdir(parents=True, exist_ok=True)

    print(f"[regress] backend={args.backend} seeds={seeds} jobs={args.jobs}")
    t0 = time.time()
    results = {}
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        futs = {}
        for s in seeds:
            if args.backend == "cocotb":
                futs[ex.submit(run_cocotb, s, outdir, args.module)] = s
            else:
                futs[ex.submit(run_uvm, s, outdir, args.sim, args.uvm_test)] = s
        for fut in cf.as_completed(futs):
            r = fut.result()
            results[r["seed"]] = r
            print(f"[regress] seed {r['seed']:>4} rc={r['rc']} ({r['secs']:.1f}s)")

    per_seed = []
    for s in seeds:
        r = results[s]
        cases = (parse_cocotb_junit(r["results"]) if args.backend == "cocotb"
                 else parse_uvm_log(r["log"], args.uvm_test))
        per_seed.append((s, cases))

    tot, fails = merge_junit(per_seed, outdir / "junit.xml")
    write_triage(per_seed, outdir / "triage.md")
    write_html(per_seed, outdir / "summary.html", tot, fails, time.time() - t0)

    print(f"[regress] {tot} testcases, {fails} failures -> {outdir}/junit.xml, triage.md, summary.html")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()

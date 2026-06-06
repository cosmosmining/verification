#!/usr/bin/env python3
"""Coverage merge + HTML summary for sdram_lite_ctrl.

cocotb backend (runnable here): runs the Verilator mirror with --coverage across
seeds, merges the per-seed coverage.dat with verilator_coverage, and emits a
coverage percentage + HTML report (line/toggle/branch breakdown). This is
structural coverage of the DUT -- the functional covergroup closure lives in the
UVM environment and is merged on the campus simulators (see --sim).

uvm backend: prints the documented vendor merge commands (urg / vcover / imc /
dsim) for merging the functional-coverage databases; not runnable license-free.

Usage:
  scripts/merge_coverage.py --num-seeds 4
  scripts/merge_coverage.py --backend uvm --sim vcs
"""
import argparse
import os
import shutil
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
COCOTB = REPO / "sim" / "cocotb"

UVM_MERGE_DOC = {
    "vcs":     "urg -dir simv.vdb -format both -report cov_report   # merges *.vdb",
    "questa":  "vcover merge merged.ucdb cov_*.ucdb && vcover report -html -htmldir cov_html merged.ucdb",
    "xcelium": "imc -execcmd 'merge cov_work/scope/* -out merged; report -html -out cov_html merged'",
    "dsim":    "dsim -code-cov-merge merged.db cov_*.db && dcreport -out_dir cov_html merged.db",
}


def run_seed_coverage(seed: int, outdir: Path) -> Path:
    """Run one cocotb seed with --coverage; return the per-seed coverage.dat."""
    build = outdir / f"covbuild_{seed}"
    env = os.environ.copy()
    env["COCOTB_RESULTS_FILE"] = str(outdir / f"covresults_{seed}.xml")
    subprocess.call(
        ["make", "-C", str(COCOTB), f"SEED={seed}", f"SIM_BUILD={build}", "COVERAGE=1"],
        stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT, env=env,
    )
    src = COCOTB / "coverage.dat"
    dst = outdir / f"cov_{seed}.dat"
    if src.exists():
        shutil.move(str(src), str(dst))
        return dst
    return None


def parse_dat(path: Path):
    """Return {category: [total, hit]} and overall (total, hit)."""
    cats = {"toggle": [0, 0], "line": [0, 0], "branch": [0, 0], "other": [0, 0]}
    total = hit = 0
    for line in path.read_text(errors="ignore").splitlines():
        if not line.startswith("C "):
            continue
        try:
            count = int(line.rsplit(" ", 1)[1])
        except (ValueError, IndexError):
            continue
        cat = ("toggle" if "toggle" in line else
               "line" if "line" in line else
               "branch" if "branch" in line else "other")
        cats[cat][0] += 1
        total += 1
        if count > 0:
            cats[cat][1] += 1
            hit += 1
    return cats, total, hit


def pct(hit, tot):
    return 100.0 * hit / tot if tot else 0.0


def write_html(cats, total, hit, seeds, out: Path):
    rows = "".join(
        f"<tr><td>{c}</td><td>{h}/{t}</td><td>{pct(h, t):.1f}%</td></tr>"
        for c, (t, h) in cats.items() if t
    )
    out.write_text(f"""<!doctype html><meta charset=utf-8>
<title>sdram_lite_ctrl structural coverage</title>
<body style="font-family:system-ui;margin:2rem">
<h2>sdram_lite_ctrl — Verilator structural coverage</h2>
<p>Merged over seeds {seeds}. <b>Overall: {pct(hit, total):.1f}%</b> ({hit}/{total} points).</p>
<table border=1 cellpadding=6 style="border-collapse:collapse">
<tr style="background:#eee"><th>Category</th><th>Hit/Total</th><th>Coverage</th></tr>
{rows}
<tr style="font-weight:bold"><td>ALL</td><td>{hit}/{total}</td><td>{pct(hit, total):.1f}%</td></tr>
</table>
<p style="color:#555">Functional covergroup closure (page/bank/cmd/timing/refresh)
is collected in the UVM environment and merged on the campus simulators.</p>
</body>""")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--backend", choices=["cocotb", "uvm"], default="cocotb")
    ap.add_argument("--num-seeds", type=int, default=4)
    ap.add_argument("--out", default="regression_out")
    ap.add_argument("--sim", default="vcs")
    args = ap.parse_args()

    if args.backend == "uvm":
        print(f"# UVM functional-coverage merge for SIM={args.sim} (run on campus simulator):")
        print(UVM_MERGE_DOC.get(args.sim, "  (unknown simulator)"))
        return

    outdir = REPO / args.out
    outdir.mkdir(parents=True, exist_ok=True)
    seeds = list(range(1, args.num_seeds + 1))
    print(f"[cov] running {len(seeds)} coverage seeds...")
    dats = [d for s in seeds if (d := run_seed_coverage(s, outdir))]
    if not dats:
        print("[cov] no coverage.dat produced (is verilator --coverage working?)")
        return

    merged = outdir / "merged.dat"
    subprocess.call(["verilator_coverage", "--write", str(merged)] + [str(d) for d in dats],
                    stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    cats, total, hit = parse_dat(merged)
    covdir = outdir / "coverage_html"
    covdir.mkdir(exist_ok=True)
    write_html(cats, total, hit, seeds, covdir / "index.html")

    print(f"[cov] overall structural coverage: {pct(hit, total):.1f}% ({hit}/{total})")
    for c, (t, h) in cats.items():
        if t:
            print(f"[cov]   {c:7s}: {pct(h, t):5.1f}%  ({h}/{t})")
    print(f"[cov] HTML -> {covdir/'index.html'}")


if __name__ == "__main__":
    main()

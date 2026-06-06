#!/usr/bin/env python3
"""Bug-hunt driver for sdram_lite_ctrl.

Injects 8 realistic RTL bugs one at a time (revertible string mutations on
rtl/sdram_lite_ctrl.sv), runs the matching cocotb configuration, and confirms
each bug is caught -- by the scoreboard mirror (functional bugs) or by the
bound SVA executed under Verilator (timing bugs). For every bug it saves a
patch under bugs/patches/, captures the failing test/assertion + first error
line as evidence, then restores the clean RTL with `git checkout`.

Run from the repo root:  python3 bugs/run_bug_hunt.py
Single-branch workflow note: the bugs live as patches here (not a divergent
branch), which is more reproducible -- each can be re-applied independently.
"""
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
RTL = REPO / "rtl" / "sdram_lite_ctrl.sv"
PATCHES = REPO / "bugs" / "patches"

# id, name, F-id, category, catch, mode, (find, replace)
BUGS = [
    dict(id=1, name="Wrong bank decode (overlaps row bits)", fid="F-010",
         catch="scoreboard", mode="smoke",
         find="    return a[COL_W+ROW_W +: BANK_W];",
         repl="    return a[COL_W +: BANK_W]; // BUG1: bank decode overlaps row"),
    dict(id=2, name="Dropped response back-pressure (ignores rsp_ready)", fid="F-007",
         catch="scoreboard", mode="smoke",
         find="          if (rsp_valid && rsp_ready) begin",
         repl="          if (rsp_valid) begin // BUG2: ignores rsp_ready"),
    dict(id=3, name="tRCD off-by-one (CAS one cycle early)", fid="F-017",
         catch="assertion", mode="assert",
         find="            trcd_cnt    <= {1'b0, t_rcd_q};",
         repl="            trcd_cnt    <= {1'b0, t_rcd_q} - 5'd1; // BUG3: tRCD off-by-one",
         all=True),
    dict(id=4, name="Error flag not sticky (cleared by refresh logic)", fid="F-023",
         catch="scoreboard", mode="smoke",
         find="        else              refresh_pending <= 1'b1;",
         repl="        else              refresh_pending <= 1'b1;\n        err_range <= 1'b0; // BUG4: error flag not sticky"),
    dict(id=5, name="Out-of-range returns OKAY (error path broken)", fid="F-022",
         catch="scoreboard", mode="smoke",
         find="            rsp_resp  <= NRESP_ERROR;",
         repl="            rsp_resp  <= NRESP_OKAY; // BUG5: OOR error suppressed"),
    dict(id=6, name="Byte strobes ignored on write", fid="F-011",
         catch="scoreboard", mode="smoke",
         find="                if (cur_strb[b]) mem[cur_index][b*8 +: 8] <= cur_wdata[b*8 +: 8];",
         repl="                mem[cur_index][b*8 +: 8] <= cur_wdata[b*8 +: 8]; // BUG6: ignores wstrb"),
    dict(id=7, name="Reset leak: err_range not cleared on reset", fid="F-025",
         catch="scoreboard", mode="smoke",
         find="      err_range <= 1'b0; err_addr_q <= '0; err_addr_valid <= 1'b0;",
         repl="      err_addr_q <= '0; err_addr_valid <= 1'b0; // BUG7: err_range leaks through reset"),
    dict(id=8, name="tREF starved (refresh never pending)", fid="F-019",
         catch="assertion", mode="assert",
         find="        else              refresh_pending <= 1'b1;",
         repl="        else              refresh_pending <= 1'b0; // BUG8: refresh never requested"),
]


def restore():
    subprocess.run(["git", "checkout", "--", str(RTL)], cwd=REPO,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def run_cocotb(mode):
    args = "ASSERT=1" if mode == "assert" else ""
    subprocess.run(["make", "-C", str(REPO / "sim" / "cocotb"), "clean"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    cmd = ["make", "-C", str(REPO / "sim" / "cocotb"), "SEED=7"]
    if args:
        cmd.append(args)
    p = subprocess.run(cmd, capture_output=True, text=True)
    return p.stdout + p.stderr


def evidence(out, mode):
    """Return (caught, where, first_line)."""
    m = re.search(r"Assertion failed in \S+\.(\w+):", out)
    if m:
        return True, f"SVA {m.group(1)}", m.group(0).strip()
    fails = re.search(r"FAIL=(\d+)", out)
    nfail = int(fails.group(1)) if fails else 0
    # first scoreboard/test error line
    first = ""
    for line in out.splitlines():
        if ("mismatch" in line or "not set" in line or "reset leak" in line
                or "response count" in line or "ERROR" in line):
            first = line.strip()[-120:]
            break
    if nfail > 0 or first:
        # which test failed
        ft = re.search(r"(\w+)\s+failed", out)
        where = f"test {ft.group(1)}" if ft else "scoreboard"
        return True, where, first or f"FAIL={nfail}"
    return False, "-", "(no failure observed)"


def main():
    PATCHES.mkdir(parents=True, exist_ok=True)
    restore()
    results = []
    try:
        for b in BUGS:
            src = RTL.read_text()
            n = src.count(b["find"])
            assert n >= 1, f"bug {b['id']}: anchor not found"
            if not b.get("all") and n != 1:
                print(f"  bug {b['id']}: WARN anchor not unique ({n})")
            new = src.replace(b["find"], b["repl"]) if b.get("all") \
                else src.replace(b["find"], b["repl"], 1)
            RTL.write_text(new)
            # save patch
            diff = subprocess.run(["git", "diff", "--", str(RTL)], cwd=REPO,
                                  capture_output=True, text=True).stdout
            (PATCHES / f"bug_{b['id']:02d}.patch").write_text(diff)
            # run + evaluate
            out = run_cocotb(b["mode"])
            caught, where, line = evidence(out, b["mode"])
            results.append((b, caught, where, line))
            tag = "CAUGHT" if caught else "MISSED"
            print(f"[bug {b['id']}] {tag:6s} via {b['catch']:10s} ({where}) :: {b['name']}")
            restore()
    finally:
        restore()

    # write results table
    lines = ["# Bug-hunt results (auto-generated by bugs/run_bug_hunt.py)", "",
             "| # | Bug | F-id | Expected catch | Caught? | Where | Evidence |",
             "|---|-----|------|----------------|---------|-------|----------|"]
    n_caught = sum(1 for _, c, _, _ in results if c)
    for b, caught, where, line in results:
        lines.append(f"| {b['id']} | {b['name']} | {b['fid']} | {b['catch']} | "
                     f"{'YES' if caught else 'NO'} | {where} | "
                     f"`{line.replace('|', ' ')[:70]}` |")
    lines += ["", f"**{n_caught}/{len(results)} bugs caught** "
              f"({sum(1 for b,_,_,_ in [(r[0],)+r[1:] for r in results] if b['catch']=='scoreboard')} "
              "scoreboard-domain, "
              f"{sum(1 for r in results if r[0]['catch']=='assertion')} assertion-domain)."]
    (REPO / "bugs" / "RESULTS.md").write_text("\n".join(lines) + "\n")
    print(f"\n{n_caught}/{len(results)} caught -> bugs/RESULTS.md, patches in bugs/patches/")
    sys.exit(0 if n_caught == len(results) else 1)


if __name__ == "__main__":
    main()

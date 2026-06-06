#!/usr/bin/env bash
# ===========================================================================
# Full UVM regression for sdram_lite_ctrl on a campus / licensed simulator.
#
#   SIM=questa ./scripts/campus_regress.sh        # or vcs | xcelium | dsim | xsim
#
# Runs every UVM test across a seed sweep (parallel via scripts/regress.py),
# then merges functional coverage. Produces regression_out/junit.xml + per-test
# logs and a coverage report. Run from the repo root.
#
# Locally license-free options for SIM: dsim (Metrics DSim Desktop) or xsim
# (AMD Vivado) -- both ship UVM. VCS/Questa/Xcelium on the lab machines.
# ===========================================================================
set -uo pipefail

SIM="${SIM:-dsim}"
SEEDS="${SEEDS:-1 2 3 4 5}"
JOBS="${JOBS:-5}"

TESTS=(
  sdram_smoke_test
  sdram_reg_test
  sdram_random_test
  sdram_locality_test
  sdram_backpressure_test
  sdram_illegal_addr_test
  sdram_refresh_collision_test
  sdram_allbanks_thrash_test
  sdram_csr_reprogram_test
  sdram_reset_during_traffic_test
)

echo ">> Campus regression: SIM=$SIM seeds='$SEEDS'"
rc=0
for t in "${TESTS[@]}"; do
  echo "==== $t ===="
  python3 scripts/regress.py --backend uvm --sim "$SIM" \
      --uvm-test "$t" --seeds "$SEEDS" --jobs "$JOBS" \
      --out "regression_out/$t" || rc=1
done

echo ">> Merging functional coverage"
python3 scripts/merge_coverage.py --backend uvm --sim "$SIM"

echo ">> Done (rc=$rc). See regression_out/<test>/{junit.xml,triage.md,summary.html}"
exit $rc

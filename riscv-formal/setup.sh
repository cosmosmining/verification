#!/usr/bin/env bash
# ===========================================================================
# riscv-formal on PicoRV32 — reproducible bring-up
#
# Fetches the third-party formal suite (YosysHQ/riscv-formal) and the
# third-party core under test (YosysHQ/picorv32), both pinned to exact
# commits, selects the SMT engine to match whatever solver is installed,
# and generates the per-check SymbiYosys harnesses.
#
# Nothing here is vendored into the repo: this is the "verify something I
# did NOT design" project, so the design and the harness are pulled from
# upstream at exactly the revisions recorded below. `work/` is gitignored.
#
#   ./setup.sh                 # default engine: yices  (z3 fallback)
#   SOLVER=z3 ./setup.sh       # if only z3 is installed
# ===========================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$HERE/work"

# ---- pinned upstream revisions (integrity-checked) ------------------------
RVF_COMMIT=325a0f688bb588ea9ddb64c93f75eb6daac07db8                       # riscv-formal
PICORV32_COMMIT=87c89acc18994c8cf9a2311e871818e87d304568                  # picorv32 (branch: main)
PICORV32_SHA256=0836050971b3c6cdd28ac3b1e5719a67fb645161912bef1e472e63995ceb0622
SOLVER="${SOLVER:-yices}"

echo ">> tools: $(yosys --version 2>/dev/null | head -1)  |  sby $(command -v sby)  |  solver=$SOLVER"
command -v sby   >/dev/null || { echo "ERROR: SymbiYosys (sby) not on PATH — see README install notes"; exit 1; }
command -v yosys >/dev/null || { echo "ERROR: yosys not on PATH"; exit 1; }

mkdir -p "$WORK"; cd "$WORK"

# ---- riscv-formal (the harness) -------------------------------------------
if [ ! -d riscv-formal/.git ]; then
  echo ">> cloning riscv-formal ..."
  git clone --quiet https://github.com/YosysHQ/riscv-formal.git riscv-formal
fi
git -C riscv-formal fetch --quiet --depth 1 origin "$RVF_COMMIT" 2>/dev/null || git -C riscv-formal fetch --quiet origin
git -C riscv-formal checkout --quiet "$RVF_COMMIT"
echo ">> riscv-formal @ $(git -C riscv-formal rev-parse --short HEAD)"

CORE="$WORK/riscv-formal/cores/picorv32"

# ---- picorv32.v (the DUT), pinned by commit and verified by content hash ---
# NB: upstream's cores/picorv32/Makefile fetches .../picorv32/master/picorv32.v,
# but the picorv32 default branch was renamed master -> main, so that URL 404s.
# We fetch the pinned commit instead and verify the hash, which is strictly
# more reproducible.
echo ">> fetching pinned picorv32.v ..."
curl -fsSL -o "$CORE/picorv32.v" \
  "https://raw.githubusercontent.com/YosysHQ/picorv32/${PICORV32_COMMIT}/picorv32.v"
echo "${PICORV32_SHA256}  ${CORE}/picorv32.v" | sha256sum -c - \
  || { echo "ERROR: picorv32.v integrity check failed"; exit 1; }

# ---- engine selection ------------------------------------------------------
# We run upstream's rv32imc check plan VERBATIM; the only edit is selecting the
# SMT engine to match the installed solver (genchecks.py defaults to boolector).
cd "$CORE"
if grep -q '^solver ' checks.cfg; then
  sed -i "s/^solver .*/solver ${SOLVER}/" checks.cfg
else
  sed -i "/^isa /a solver ${SOLVER}" checks.cfg
fi
echo ">> engine: $(grep '^solver' checks.cfg)"

# ---- generate the per-check SymbiYosys harnesses --------------------------
rm -rf checks
python3 ../../checks/genchecks.py
N=$(ls checks/*.sby | wc -l)
echo ">> generated ${N} checks in ${CORE}/checks"
echo ">> next: python3 run_checks.py --jobs \$(nproc)"

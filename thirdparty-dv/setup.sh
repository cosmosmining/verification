#!/usr/bin/env bash
# ===========================================================================
# Third-party AXI4-Lite crossbar DV — reproducible bring-up
#
# Fetches alexforencich/verilog-axi (pinned) and generates a 2x2 axil_crossbar
# wrapper with per-port named interfaces so the cocotbext-axi VIP can bind to
# each master/slave. Nothing third-party is vendored; work/ is gitignored.
#
#   ./setup.sh
# ===========================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$HERE/work"
VAXI_COMMIT=516bd5dadc3365b7f9e225d2af8fe0b8d804fe53   # verilog-axi (pinned)

command -v verilator >/dev/null || { echo "ERROR: verilator not on PATH"; exit 1; }
python3 -c "import cocotbext.axi" 2>/dev/null || {
  echo "ERROR: cocotbext-axi not installed — run: pip install -r requirements.txt"; exit 1; }

mkdir -p "$WORK"; cd "$WORK"
if [ ! -d verilog-axi/.git ]; then
  echo ">> cloning verilog-axi ..."
  git clone --quiet https://github.com/alexforencich/verilog-axi.git verilog-axi
fi
git -C verilog-axi fetch --quiet --depth 1 origin "$VAXI_COMMIT" 2>/dev/null || git -C verilog-axi fetch --quiet origin
git -C verilog-axi checkout --quiet "$VAXI_COMMIT"
echo ">> verilog-axi @ $(git -C verilog-axi rev-parse --short HEAD)"

echo ">> generating 2x2 axil_crossbar wrapper ..."
python3 verilog-axi/rtl/axil_crossbar_wrap.py -p 2 2 -o "$WORK/axil_crossbar_wrap_2x2.v"

echo ">> setup complete — run: make"

#!/bin/bash
# test_nodeorder.sh — exercise nodeorder.sh's check and apply without PBS, MPI or a built
# Abacus.  A stub `python` on $PATH answers `python -m abacus.param` with a one-line par
# file (NumZRanks = $STUB_NZ) and passes everything else to the real python, which runs
# nodelist_block.py (needs numpy).
#
# Usage: job/test/nodeorder/test_nodeorder.sh
# Exits 0 if all cases pass, 1 otherwise.

set -uo pipefail

job=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
real_python=$(command -v python3 || command -v python) || { echo "no python" >&2; exit 1; }
# Explicit template: macOS's mktemp ignores $TMPDIR unless one is given.
work=$(mktemp -d "${TMPDIR:-/tmp}/nodeorder-test.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat > "$work/bin/python" <<STUB
#!/bin/bash
if [[ \${1:-} == -m && \${2:-} == abacus.param ]]; then
    echo "NumZRanks = \$STUB_NZ"
    exit 0
fi
exec "$real_python" "\$@"
STUB
chmod +x "$work/bin/python"
export PATH="$work/bin:$PATH"

# 90 nodes in 2 racks, listed out of order: 180 ranks = 9 x 20, or 18 x 10.
for r in 4001 4000; do
    for c in 7 6 5 4 3 2 1 0; do
        for s in 0 1 2 3 4 5 6 7; do echo "x${r}c${c}s${s}b0n0.hsn.cm.aurora.alcf.anl.gov"; done
    done
done | head -n 90 > "$work/nodes"
: > "$work/sim.par2"

abacus_prod=$(dirname "$job")
overrides=()
source "$job/nodeorder.sh"

fails=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails + 1)); }

# apply_case <name> <want_rc> <nz> [VAR=VAL ...]: copy the nodes, apply, compare.
apply_case() {
    local name=$1 want_rc=$2 nz=$3; shift 3
    cp "$work/nodes" "$work/hf"
    ( export STUB_NZ=$nz "$@"; nodeorder_check; nodeorder_apply "$work/sim.par2" "$work/hf" ) \
        > "$work/log" 2>&1
    local rc=$?
    if (( (rc == 0) != (want_rc == 0) )); then
        fail "$name (rc=$rc, want $want_rc)"; sed 's/^/      /' "$work/log"; return 1
    fi
    pass "$name (rc=$rc)"
}

# Default (sorted): the slice is left exactly as written.
apply_case "unset order leaves the hostfile alone" 0 20
cmp -s "$work/hf" "$work/nodes" && pass "  ...byte-identical" || fail "  ...file changed"
apply_case "sorted leaves the hostfile alone" 0 20 ABACUS_NODE_ORDER=sorted
cmp -s "$work/hf" "$work/nodes" && pass "  ...byte-identical" || fail "  ...file changed"

# block 5x4 on 9 x 20: a permutation of the same nodes, matching nodelist_block.py directly.
apply_case "block 5x4" 0 20 ABACUS_NODE_ORDER=block ABACUS_NODE_BLOCK=5x4
cmp -s <(sort "$work/hf") <(sort "$work/nodes") && pass "  ...same node set" || fail "  ...node set differs"
"$real_python" "$job/nodelist_block.py" --nx 9 --nz 20 --block-rows 5 --block-z 4 --seed 1 \
    "$work/nodes" "$work/ref" 2> /dev/null
cmp -s "$work/hf" "$work/ref" && pass "  ...matches nodelist_block.py" || fail "  ...differs from nodelist_block.py"
# Each 5x4 block is 10 consecutive sorted nodes, so the first block's 10 nodes (rows 0-4,
# z 0-3: slots 0-1, 10-11, 20-21, 30-31, 40-41) are a consecutive run of the sorted list.
"$real_python" -c '
import re, sys
key = lambda h: tuple(map(int, re.match(r"x(\d+)c(\d+)s(\d+)b(\d+)n(\d+)", h).groups()))
srt = sorted((l.strip() for l in open(sys.argv[2])), key=key)
hf = [l.strip() for l in open(sys.argv[1])]
pos = sorted(srt.index(hf[k]) for k in (0, 1, 10, 11, 20, 21, 30, 31, 40, 41))
sys.exit(0 if pos == list(range(pos[0], pos[0] + 10)) else 1)' "$work/hf" "$work/nodes" \
    && pass "  ...first block is 10 consecutive sorted nodes" || fail "  ...first block not contiguous"

# A different seed gives a different order.
cp "$work/hf" "$work/hf.seed1"
apply_case "block 5x4 seed 2" 0 20 ABACUS_NODE_ORDER=block ABACUS_NODE_BLOCK=5x4 ABACUS_NODE_ORDER_SEED=2
cmp -s "$work/hf" "$work/hf.seed1" && fail "  ...same order as seed 1" || pass "  ...differs from seed 1"

# Default 4x4 geometry also works (and leaves a short leftover group: 18 rows of 10).
apply_case "block default 4x4" 0 10 ABACUS_NODE_ORDER=block

# Bad settings and inconsistent NumZRanks fail.
apply_case "unknown order" 1 20 ABACUS_NODE_ORDER=shuffle
apply_case "malformed block" 1 20 ABACUS_NODE_ORDER=block ABACUS_NODE_BLOCK=5by4
apply_case "odd block width" 1 20 ABACUS_NODE_ORDER=block ABACUS_NODE_BLOCK=5x3
apply_case "non-integer seed" 1 20 ABACUS_NODE_ORDER=block ABACUS_NODE_ORDER_SEED=x
apply_case "NumZRanks doesn't divide the ranks" 1 7 ABACUS_NODE_ORDER=block
apply_case "NumZRanks missing from the par2" 1 "" ABACUS_NODE_ORDER=block

echo
if (( fails )); then echo "$fails case(s) FAILED"; exit 1; fi
echo "All cases passed"

#!/bin/bash
# test_ckpt_cleanup.sh — cleanup_sims.sh must destroy every per-checkpoint DAOS container a
# sim's checkpoint directory links to before deleting that directory, and must keep the
# directory (its links are the only record) if any destroy fails.  No DAOS: a stub helper
# records the destroys it is asked for.
#
# Usage: job/test/cleanup/test_ckpt_cleanup.sh
# Exits 0 if all cases pass, 1 otherwise.

set -uo pipefail

cleanup_sims=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/cleanup_sims.sh
work=$(mktemp -d "${TMPDIR:-/tmp}/cleanup-test.XXXXXX") || exit 1
# cleanup_sims.sh seals what it cleans read-only, so open it up again before removing.
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT

cat > "$work/helper.sh" <<STUB
echo "\$*" >> "$work/helper.log"
[[ \$3 == ckpt-Sim-20261103T150000 && -n \${FAIL_ONE:-} ]] && { echo "busy" >&2; exit 1; }
exit 0
STUB

make_sim() {
    sim=$work/Sim
    chmod -R u+w "$sim" 2>/dev/null; rm -rf "$sim"
    mkdir -p "$sim/checkpoint/.scr" "$sim/checkpoint/state_0001" "$sim/log" "$sim/work"
    touch "$sim/postprocess.done"
    ln -s /tmp/AbacusAurora_run/ckpt-Sim-20261103T141502/state_0002 "$sim/checkpoint/state_0002"
    ln -s /tmp/AbacusAurora_run/ckpt-Sim-20261103T150000 "$sim/checkpoint/spare"
    ln -s /tmp/AbacusAurora_run/Checkpoints/state_0000 "$sim/checkpoint/state_0000"
    rm -f "$work/helper.log"
}

# Skip the module load cleanup_sims.sh would otherwise do for du.
export DAOS_PRELOAD=unused DAOS_AGENT_DRPC_DIR=unused ABACUS_CKPT_HELPER=$work/helper.sh

fails=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails+1)); }

make_sim
out=$("$cleanup_sims" -n "$sim" 2>&1)
grep -q 'would destroy checkpoint container AbacusAurora_run:ckpt-Sim-20261103T141502' <<<"$out" &&
grep -q 'would destroy checkpoint container AbacusAurora_run:ckpt-Sim-20261103T150000' <<<"$out" &&
[[ ! -e $work/helper.log && -d $sim/checkpoint ]] \
    && pass "dry run names both containers and destroys nothing" || { fail "dry run"; echo "$out"; }

make_sim
out=$(FAIL_ONE=1 "$cleanup_sims" "$sim" 2>&1)
[[ -L $sim/checkpoint/spare && -L $sim/checkpoint/state_0002 ]] && grep -q 'could not destroy' <<<"$out" \
    && pass "a failed destroy keeps the checkpoint directory and its links" || { fail "failed destroy"; echo "$out"; }

make_sim
out=$("$cleanup_sims" "$sim" 2>&1)
[[ $(sort "$work/helper.log") == $'destroy AbacusAurora_run ckpt-Sim-20261103T141502\ndestroy AbacusAurora_run ckpt-Sim-20261103T150000' ]] \
    && pass "destroys exactly the two ckpt containers, never Checkpoints" \
    || { fail "helper calls: $(cat "$work/helper.log" 2>/dev/null)"; echo "$out"; }
[[ ! -e $sim/checkpoint ]] && pass "then deletes the checkpoint directory" || { fail "checkpoint left"; echo "$out"; }

make_sim
out=$(ABACUS_CKPT_HELPER=$work/missing.sh "$cleanup_sims" "$sim" 2>&1)
[[ -L $sim/checkpoint/spare ]] && grep -q 'no ckpt-container.sh' <<<"$out" \
    && pass "no helper: keeps the directory" || { fail "missing helper"; echo "$out"; }

if (( fails )); then
    echo "$fails case(s) failed"
    exit 1
fi
echo "all cases passed"

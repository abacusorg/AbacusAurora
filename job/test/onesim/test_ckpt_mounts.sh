#!/bin/bash
# test_ckpt_mounts.sh — exercise onesim.sh's pre-launch mount of a sim's checkpoint
# containers (ABACUS_CHECKPOINT_CONTAINERS=1) without MPI, DAOS or a built Abacus.
#
# Stubs on $PATH: `python` answers `-m abacus.param` with a CheckpointDirectory and fails
# `-m abacus.run`; `clush` records what it was asked to run on which hosts.  The checkpoint
# directory holds the links Abacus would have made, so the map onesim writes can be
# checked line by line.
#
# Usage: job/test/onesim/test_ckpt_mounts.sh
# Exits 0 if all cases pass, 1 otherwise.

set -uo pipefail

onesim=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/onesim.sh
work=$(mktemp -d "${TMPDIR:-/tmp}/onesim-ckpt-test.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

ckptdir=$work/flare/Sim/checkpoint
mkdir -p "$ckptdir/.scr" "$ckptdir/state_0001" "$work/bin" "$work/out"
ln -s /tmp/AbacusAurora_run/ckpt-Sim-20261103T141502/state_0002 "$ckptdir/state_0002"
ln -s /tmp/AbacusAurora_run/ckpt-Sim-20261103T150000 "$ckptdir/spare"
ln -s /tmp/AbacusAurora_run/ckpt-Sim-20261103T120000 "$ckptdir/ckpt-Sim-20261103T120000.destroying"
ln -s /tmp/AbacusAurora_run/Checkpoints/state_0000 "$ckptdir/state_0000"

cat > "$work/bin/python" <<STUB
#!/bin/bash
if [[ \$* == *abacus.param* ]]; then
    echo 'OutputDirectory = "$work/out/Sim"'
    echo 'CheckpointDirectory = "$ckptdir"'
    exit 0
fi
exit 1
STUB
# Copies the map, since onesim removes it once the mount has run.
cat > "$work/bin/clush" <<STUB
#!/bin/bash
while [[ \$1 == -* ]]; do
    case \$1 in -w) echo "hosts: \$2" >> "$work/clush.log"; shift 2 ;; -f|-o) shift 2 ;; *) shift ;; esac
done
echo "cmd: \$*" >> "$work/clush.log"
set -- \$*                     # the remote command arrives as one string
map=\${!#}
cat "\$map" >> "$work/clush.maps"
exit \${CLUSH_RC:-0}
STUB
chmod +x "$work/bin/python" "$work/bin/clush"
export PATH="$work/bin:$PATH"

: > "$work/sim.par2"
printf 'x1000c0s0b0n0.hsn\nx1000c0s0b0n1.hsn\n' > "$work/hostfile"

fails=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails+1)); }

run() {
    rm -f "$work/clush.log" "$work/clush.maps"
    env HASHRUN_OUT="$work/out" ABACUS_DAOS_POOL=AbacusAurora_run ABACUS_BUILD=/b/build/ "$@" \
        "$onesim" "$work/sim.par2" "$work/hostfile" > "$work/onesim.out" 2>&1
}

# On: one clush per launch, to exactly this sim's hosts, running the helper's ensure.
run ABACUS_CHECKPOINT_CONTAINERS=1
n=$(grep -c '^cmd:' "$work/clush.log" 2>/dev/null || true)
[[ $n == 2 ]] && pass "one mount per launch (2 launches)" || fail "want 2 clush calls, got ${n:-0}"
grep -q '^hosts: x1000c0s0b0n0.hsn,x1000c0s0b0n1.hsn$' "$work/clush.log" \
    && pass "clush targets the sim's hosts" || fail "clush hosts: $(grep hosts: "$work/clush.log")"
grep -q "^cmd: bash /b/build/src/Util/ckpt-container.sh ensure AbacusAurora_run $work/out/ckpt_mounts\." "$work/clush.log" \
    && pass "runs the helper's ensure on the job's pool" || fail "clush cmd: $(grep cmd: "$work/clush.log")"
want='x1000c0s0b0n0.hsn ckpt-Sim-20261103T141502 ckpt-Sim-20261103T150000 '
[[ $(head -1 "$work/clush.maps") == "$want" ]] \
    && pass "map: checkpoint + spare containers, not .destroying or legacy" \
    || fail "map line: '$(head -1 "$work/clush.maps")'"
[[ -z $(ls "$work/out"/ckpt_mounts.* 2>/dev/null) ]] && pass "map removed afterwards" || fail "map left behind"

# A failed mount warns but still launches: Abacus names the node.
run ABACUS_CHECKPOINT_CONTAINERS=1 CLUSH_RC=1
grep -q 'not every checkpoint container mounted' "$work/onesim.out" && \
    [[ $(grep -c '^=== abacus invocation ' "$work/onesim.out") == 2 ]] \
    && pass "a failed mount warns and launches anyway" || fail "failed-mount handling"

# Off (the default): no clush at all.
run ABACUS_CHECKPOINT_CONTAINERS=0
[[ ! -e $work/clush.log ]] && pass "off: no mounts" || fail "off: clush was called"
run
[[ ! -e $work/clush.log ]] && pass "unset: no mounts" || fail "unset: clush was called"

if (( fails )); then
    echo "$fails case(s) failed"
    exit 1
fi
echo "all cases passed"

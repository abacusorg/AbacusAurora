#!/bin/bash
# test_ckpt_mounts.sh — exercise onesim.sh's pre-launch remount of a sim's restart point
# (ABACUS_CHECKPOINT_CONTAINERS=1) without MPI, DAOS or a built Abacus.
#
# Stubs on $PATH: `python` answers `-m abacus.param` with a CheckpointDirectory and fails
# `-m abacus.run`; `clush` records its hosts and runs the remote command here, as one host;
# `mountpoint` answers from a list of fake mounts, which the stub helper edits.  The
# checkpoint directory holds the links Abacus would have made.  /tmp/<pool> is a real
# directory, a test-only pool name, since the remote command globs it.
#
# Usage: job/test/onesim/test_ckpt_mounts.sh
# Exits 0 if all cases pass, 1 otherwise.

set -uo pipefail

onesim=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/onesim.sh
work=$(mktemp -d "${TMPDIR:-/tmp}/onesim-ckpt-test.XXXXXX") || exit 1
pool=onesim-ckpt-test-$$
trap 'rm -rf "$work" "/tmp/$pool"' EXIT

ckptdir=$work/daos/Sim/checkpoint
mkdir -p "$ckptdir/.scr" "$ckptdir/state_0001" "$work/bin" "$work/build/src/Util"
c=/tmp/$pool/ckpt-Sim
ln -s "${c}-20261103T141502/state_9990" "$ckptdir/state_9990"
ln -s "${c}-20261104T090000/state_10020" "$ckptdir/state_10020"         # numerically newest
ln -s "${c}-20261104T100000" "$ckptdir/state_10050.new"                 # an interrupted claim
ln -s "${c}-20261104T110000" "$ckptdir/spare"
ln -s "${c}-20261103T120000" "$ckptdir/ckpt-Sim-20261103T120000.destroying"
ln -s "/tmp/$pool/Checkpoints/state_10100" "$ckptdir/state_10100"       # not a container
want_label=ckpt-Sim-20261104T090000

cat > "$work/bin/python" <<STUB
#!/bin/bash
if [[ \$* == *abacus.param* ]]; then
    echo 'OutputDirectory = "$work/out/Sim"'
    echo 'CheckpointDirectory = "$ckptdir"'
    exit 0
fi
exit 1
STUB
cat > "$work/bin/clush" <<STUB
#!/bin/bash
while [[ \$1 == -* ]]; do
    case \$1 in -w) echo "hosts: \$2" >> "$work/clush.log"; shift 2 ;; -f|-o) shift 2 ;; *) shift ;; esac
done
echo "cmd: \$*" >> "$work/clush.log"
bash -c "\$*"                 # the remote shell's parse of the one-string command
STUB
cat > "$work/bin/mountpoint" <<STUB
#!/bin/bash
grep -qxF -- "\${!#}" "$work/mounted"
STUB
cat > "$work/build/src/Util/ckpt-container.sh" <<STUB
echo "\$*" >> "$work/helper.log"
[[ -n \${HELPER_FAIL:-} ]] && exit 1
case \$1 in
    mount)   echo "/tmp/\$2/\$3" >> "$work/mounted" ;;
    unmount) grep -vxF -- "/tmp/\$2/\$3" "$work/mounted" > "$work/mounted.new"; mv "$work/mounted.new" "$work/mounted" ;;
esac
STUB
chmod +x "$work/bin/python" "$work/bin/clush" "$work/bin/mountpoint"
export PATH="$work/bin:$PATH"

: > "$work/sim.par2"
printf 'x1000c0s0b0n1.hsn\nx1000c0s0b0n0.hsn\nx1000c0s0b0n0.hsn\n' > "$work/hostfile"

fails=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails+1)); }

# The previous attempt's restart point is mounted; an unmounted container sits beside it.
reset_mounts() {
    rm -rf "/tmp/$pool"
    mkdir -p "/tmp/$pool/ckpt-Sim-20261103T120000" "/tmp/$pool/ckpt-Sim-20261102T000000"
    echo "/tmp/$pool/ckpt-Sim-20261103T120000" > "$work/mounted"
    rm -f "$work/clush.log" "$work/helper.log"
}

run() {
    env ABACUS_DAOS_POOL=$pool ABACUS_BUILD=$work/build/ "$@" \
        "$onesim" "$work/sim.par2" "$work/hostfile" > "$work/onesim.out" 2>&1
}

# On: one sweep per launch, to exactly this sim's hosts.  The first unmounts the old restart
# point and mounts the newest checkpoint's container; the second finds nothing to do.
reset_mounts
run ABACUS_CHECKPOINT_CONTAINERS=1
n=$(grep -c '^cmd:' "$work/clush.log" 2>/dev/null)
[[ ${n:-0} == 2 ]] && pass "one sweep per launch (2 launches)" || fail "want 2 clush calls, got ${n:-0}"
grep -q '^hosts: x1000c0s0b0n0.hsn,x1000c0s0b0n1.hsn$' "$work/clush.log" \
    && pass "clush targets the sim's hosts, once each" || fail "clush hosts: $(grep hosts: "$work/clush.log")"
[[ $(cat "$work/helper.log" 2>/dev/null) == "unmount $pool ckpt-Sim-20261103T120000"$'\n'"mount $pool $want_label" ]] \
    && pass "unmounts the old restart point, mounts the newest checkpoint's, once" \
    || fail "helper calls: $(tr '\n' ';' < "$work/helper.log" 2>/dev/null)"
[[ $(cat "$work/mounted") == "/tmp/$pool/$want_label" ]] \
    && pass "only the restart point is left mounted" || fail "mounted: $(tr '\n' ' ' < "$work/mounted")"
grep -q 'warning: restart point' "$work/onesim.out" \
    && fail "warned on success: $(grep warning "$work/onesim.out")" || pass "no warning on success"

# A failed mount warns but still launches: Abacus names the node.
reset_mounts
run ABACUS_CHECKPOINT_CONTAINERS=1 HELPER_FAIL=1
grep -q "warning: restart point $want_label did not mount" "$work/onesim.out" && \
    [[ $(grep -c '^=== abacus invocation ' "$work/onesim.out") == 2 ]] \
    && pass "a failed mount warns and launches anyway" || fail "failed-mount handling: $(grep warning "$work/onesim.out")"

# No checkpoint container to restart from: no sweep.
reset_mounts
mv "$ckptdir" "$ckptdir.full"; mkdir -p "$ckptdir/state_0001"
run ABACUS_CHECKPOINT_CONTAINERS=1
rm -rf "$ckptdir"; mv "$ckptdir.full" "$ckptdir"
[[ ! -e $work/clush.log ]] && pass "no restart point: no sweep" || fail "no restart point: clush was called"

# Off (the default): no clush at all.
reset_mounts
run ABACUS_CHECKPOINT_CONTAINERS=0
[[ ! -e $work/clush.log ]] && pass "off: no mounts" || fail "off: clush was called"
run
[[ ! -e $work/clush.log ]] && pass "unset: no mounts" || fail "unset: clush was called"

if (( fails )); then
    echo "$fails case(s) failed"
    exit 1
fi
echo "all cases passed"

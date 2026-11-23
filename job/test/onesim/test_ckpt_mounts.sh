#!/bin/bash
# test_ckpt_mounts.sh — exercise onesim.sh's pre-launch mount of a sim's restart point
# (ABACUS_CHECKPOINT_CONTAINERS=1) without MPI, DAOS or a built Abacus.
#
# Stubs on $PATH: `python` answers `-m abacus.param` with a CheckpointDirectory and fails
# `-m abacus.run` (optionally writing a checkpoint, flushed or not, or losing a mount first);
# `clush` runs
# the remote command here as the first host it names, and onesim itself is host `head`;
# `findmnt`, `mountpoint`, `start-dfuse.sh` and the helper keep each host's fake mounts in its
# own file.  As with dfuse, when a label's owner (the host that dumped its handles) unmounts
# it, the other hosts' imports of it die: still in the mount table, but no stat answers.
#
# Usage: job/test/onesim/test_ckpt_mounts.sh
# Exits 0 if all cases pass, 1 otherwise.

set -uo pipefail

onesim=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/onesim.sh
work=$(mktemp -d "${TMPDIR:-/tmp}/onesim-ckpt-test.XXXXXX") || exit 1
pool=onesim-ckpt-test-$$
trap 'rm -rf "$work" "/tmp/$pool"' EXIT

simdir=$work/daos/Sim
ckptdir=$simdir/checkpoint
c=/tmp/$pool/ckpt-Sim
X=ckpt-Sim-20261103T120000        # the previous attempt's restart point, mounted
A=ckpt-Sim-20261103T141502        # an older checkpoint's container
B=ckpt-Sim-20261104T090000        # the newest checkpoint's container
C=ckpt-Sim-20261104T120000        # the checkpoint the first attempt writes, when asked
n0=x1000c0s0b0n0.hsn n1=x1000c0s0b0n1.hsn
mkdir -p "$work/bin" "$work/build/src/Util"

cat > "$work/bin/python" <<STUB
#!/bin/bash
if [[ \$* == *abacus.param* ]]; then
    echo 'OutputDirectory = "$work/out/Sim"'
    echo 'CheckpointDirectory = "$ckptdir"'
    exit 0
fi
if [[ ! -e $work/ran ]]; then
    touch "$work/ran"
    if [[ -n \${NEW_CKPT:-}\${NEW_UNFLUSHED:-} ]]; then
        ln -s "$c-20261104T120000/state_10080" "$ckptdir/state_10080"
        [[ -n \${NEW_CKPT:-} ]] && ln -sfn state_10080 "$ckptdir/flushed"
    fi
    [[ -n \${DROP_MOUNT:-} ]] && : > "$work/mounted.$n0"
fi
exit 1
STUB
cat > "$work/bin/clush" <<STUB
#!/bin/bash
w= x= hf=
while [[ \$1 == -* ]]; do
    case \$1 in
        -w) w=\$2; shift 2 ;;
        -x) x=\$2; shift 2 ;;
        --hostfile=*) hf=\${1#--hostfile=}; shift ;;
        -f|-o) shift 2 ;;
        *) shift ;;
    esac
done
[[ -n \$hf ]] && w=\$(sort -u "\$hf" | grep -vxF -e "\$x" | paste -sd, -)
echo "hosts: \$w" >> "$work/clush.log"
FAKEHOST=\${w%%,*} bash -c "\$*"     # the remote shell's parse of the one-string command
STUB
cat > "$work/bin/mountpoint" <<STUB
#!/bin/bash
grep -qxF -- "\${!#}" "$work/mounted.\$FAKEHOST" 2>/dev/null && ! grep -qxF -- "\${!#}" "$work/dead" 2>/dev/null
STUB
cat > "$work/bin/findmnt" <<STUB
#!/bin/bash
cat "$work/mounted.\$FAKEHOST" 2>/dev/null
STUB
cat > "$work/bin/sleep" <<'STUB'
#!/bin/bash
STUB
cat > "$work/bin/start-dfuse.sh" <<STUB
#!/bin/bash
while (( \$# )); do
    case \$1 in -m) mnt=\$2; shift ;; --dump-handles|--read-handles) mode=\$1 hfile=\$2; shift ;; esac
    shift
done
echo "\$FAKEHOST start-dfuse \$mode \${hfile#$simdir/}" >> "$work/events"
[[ -n \${FAIL_MOUNT:-} ]] && exit 0
if [[ \$mode == --dump-handles ]]; then
    echo "\$FAKEHOST handles mode \$(stat -c %a "\$hfile")" >> "$work/events"
    echo handles > "\$hfile"
    echo "\$FAKEHOST" > "$work/owner.\${mnt##*/}"
elif [[ ! -s \$hfile ]]; then
    exit 0
fi
echo "\$mnt" >> "$work/mounted.\$FAKEHOST"
grep -vxF -- "\$mnt" "$work/dead" > "$work/dead.new" 2>/dev/null; mv "$work/dead.new" "$work/dead"
STUB
cat > "$work/build/src/Util/ckpt-container.sh" <<STUB
echo "\$FAKEHOST \$1 \$3" >> "$work/events"
[[ -n \${HELPER_FAIL:-} ]] && exit 1
grep -vxF -- "/tmp/\$2/\$3" "$work/mounted.\$FAKEHOST" > "$work/mounted.new"
mv "$work/mounted.new" "$work/mounted.\$FAKEHOST"
[[ \$(cat "$work/owner.\$3" 2>/dev/null) == "\$FAKEHOST" ]] && echo "/tmp/\$2/\$3" >> "$work/dead"
true
STUB
chmod +x "$work/bin"/*
export PATH="$work/bin:$PATH"
: > "$work/sim.par2"

fails=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails+1)); }

# The prefix as Abacus leaves it, and the previous attempt's restart point mounted everywhere.
reset() {
    rm -rf "$ckptdir" "/tmp/$pool" "$work"/mounted.* "$work"/owner.* "$work"/{ran,events,clush.log,dead}
    mkdir -p "$ckptdir/.scr" "$ckptdir/state_0001" "/tmp/$pool/$X" "/tmp/$pool/ckpt-Sim-20261102T000000"
    ln -s "$c-20261103T141502/state_9990" "$ckptdir/state_9990"
    ln -s "$c-20261104T090000/state_10020" "$ckptdir/state_10020"      # numerically newest
    ln -s "$c-20261104T100000" "$ckptdir/state_10050.new"              # an interrupted claim
    ln -s "$c-20261104T110000" "$ckptdir/spare"
    ln -s "$c-20261103T120000" "$ckptdir/$X.destroying"
    ln -s "/tmp/$pool/Checkpoints/state_10100" "$ckptdir/state_10100"  # not a container
    ln -s state_10020 "$ckptdir/flushed"                               # the newest flushed
    echo "/tmp/$pool/$X" > "$work/mounted.$n0"
    echo "/tmp/$pool/$X" > "$work/mounted.$n1"
    echo "$n0" > "$work/owner.$X"
    printf '%s\n' "$n1" "$n0" "$n0" > "$work/hostfile"
}

# As multisim.pbs's daos_mount leaves a lone sim: B on every host, its owner the head node.
reset_premounted() {
    reset
    mkdir -p "/tmp/$pool/$B"
    for h in "$n0" "$n1" head; do echo "/tmp/$pool/$B" > "$work/mounted.$h"; done
    echo head > "$work/owner.$B"
}

run() {
    env FAKEHOST=head ABACUS_DAOS_POOL=$pool ABACUS_BUILD=$work/build/ "$@" \
        "$onesim" "$work/sim.par2" "$work/hostfile" > "$work/onesim.out" 2>&1
}

events() { cat "$work/events" 2>/dev/null; }
mounted() { tr '\n' ' ' < "$work/mounted.$1"; }

# The first host connects and dumps its handles; the other starts from them.  Each first
# drops the old restart point.  The relaunch finds the same one mounted: one check, no mount.
want_first="$n0 unmount $X
$n0 start-dfuse --dump-handles .handles.$B
$n0 handles mode 600
$n1 unmount $X
$n1 start-dfuse --read-handles .handles.$B"
reset
run ABACUS_CHECKPOINT_CONTAINERS=1
[[ $(events) == "$want_first" ]] && pass "one connect: the first host dumps, the other imports" \
    || fail "events:"$'\n'"$(events)"
[[ $(cat "$work/clush.log") == "hosts: $n0"$'\n'"hosts: $n1"$'\n'"hosts: $n0,$n1" ]] \
    && pass "the relaunch only checks the mount" || fail "clush calls: $(tr '\n' ';' < "$work/clush.log")"
[[ $(mounted "$n0") == "/tmp/$pool/$B " && $(mounted "$n1") == "/tmp/$pool/$B " ]] \
    && pass "only the restart point is left mounted" || fail "mounted: $n0: $(mounted "$n0") $n1: $(mounted "$n1")"
[[ ! -e $simdir/.handles.$B ]] && pass "handle file removed" || fail "handle file left behind"
grep -q warning "$work/onesim.out" && fail "warned: $(grep warning "$work/onesim.out")" || pass "no warning"

# A checkpoint written by the first attempt becomes the second's restart point.
reset
run ABACUS_CHECKPOINT_CONTAINERS=1 NEW_CKPT=1
[[ $(events) == "$want_first
$n0 unmount $B
$n0 start-dfuse --dump-handles .handles.$C
$n0 handles mode 600
$n1 unmount $B
$n1 start-dfuse --read-handles .handles.$C" ]] \
    && pass "a new restart point replaces the old on relaunch" || fail "events:"$'\n'"$(events)"

# A checkpoint whose flush has not landed: both it and the newest flushed are candidates.
reset
ln -sfn state_9990 "$ckptdir/flushed"
run ABACUS_CHECKPOINT_CONTAINERS=1
[[ $(events) == "$n0 unmount $X
$n0 start-dfuse --dump-handles .handles.$B
$n0 handles mode 600
$n0 start-dfuse --dump-handles .handles.$A
$n0 handles mode 600
$n1 unmount $X
$n1 start-dfuse --read-handles .handles.$B
$n1 start-dfuse --read-handles .handles.$A" &&
   $(mounted "$n1") == "/tmp/$pool/$B /tmp/$pool/$A " &&
   $(tail -1 "$work/clush.log") == "hosts: $n0,$n1" ]] \
    && pass "an unflushed newest: both candidates mount, and the relaunch only checks them" \
    || fail "unflushed newest:"$'\n'"$(events)"$'\n'"$(cat "$work/clush.log")"

# The first attempt wrote a checkpoint that never flushed: the relaunch adds it, keeping B.
reset
run ABACUS_CHECKPOINT_CONTAINERS=1 NEW_UNFLUSHED=1
[[ $(events) == "$want_first
$n0 unmount $B
$n0 start-dfuse --dump-handles .handles.$C
$n0 handles mode 600
$n0 start-dfuse --dump-handles .handles.$B
$n0 handles mode 600
$n1 unmount $B
$n1 start-dfuse --read-handles .handles.$C
$n1 start-dfuse --read-handles .handles.$B" ]] \
    && pass "a relaunch after an unflushed checkpoint mounts it and the newest flushed" \
    || fail "relaunch after an unflushed checkpoint:"$'\n'"$(events)"

# A mount lost between attempts fails the check and is remounted.
reset
run ABACUS_CHECKPOINT_CONTAINERS=1 DROP_MOUNT=1
[[ $(events) == "$want_first
$n0 start-dfuse --dump-handles .handles.$B
$n0 handles mode 600
$n1 unmount $B
$n1 start-dfuse --read-handles .handles.$B" ]] \
    && pass "a lost mount is remounted" || fail "events:"$'\n'"$(events)"

# Mounted with the global containers: the first launch takes it on trust, the relaunch checks.
reset_premounted
run ABACUS_CHECKPOINT_CONTAINERS=1 DAOS_CKPT_MOUNTED=$B
[[ $(cat "$work/clush.log" 2>/dev/null) == "hosts: $n0,$n1" && -z $(events) ]] \
    && pass "premounted: no sweep before the first launch, one check before the second" \
    || fail "premounted: clush: $(tr '\n' ';' < "$work/clush.log" 2>/dev/null) events: $(events)"

# A new restart point replaces the premounted one, including on the head node that owns it.
reset_premounted
run ABACUS_CHECKPOINT_CONTAINERS=1 DAOS_CKPT_MOUNTED=$B NEW_CKPT=1
[[ $(events) == "head unmount $B
$n0 unmount $B
$n0 start-dfuse --dump-handles .handles.$C
$n0 handles mode 600
$n1 unmount $B
$n1 start-dfuse --read-handles .handles.$C" && ! -s $work/mounted.head ]] \
    && pass "premounted: a new restart point unmounts the old one on its owner too" \
    || fail "premounted relaunch:"$'\n'"$(events)"

# A mount that never appears, or an unmount that fails, warns, launches anyway, and is
# retried in full before the next launch.
for f in FAIL_MOUNT:start-dfuse HELPER_FAIL:unmount; do
    step=${f#*:} f=${f%:*}
    reset
    run ABACUS_CHECKPOINT_CONTAINERS=1 $f=1
    n=$(grep -c "^$n0 $step" "$work/events")
    [[ $(grep -c "warning: restart candidate(s) $B did not mount" "$work/onesim.out") == 2 && $n == 2 ]] && \
        [[ $(grep -c '^=== abacus invocation ' "$work/onesim.out") == 2 ]] && ! grep -q "^$n1" "$work/events" \
        && pass "$f: warns, launches, retries, never reaches the other host" \
        || fail "$f:"$'\n'"$(events)"$'\n'"$(grep warning "$work/onesim.out")"
done

# One host: it only dumps.
reset
echo "$n0" > "$work/hostfile"
run ABACUS_CHECKPOINT_CONTAINERS=1
[[ $(head -3 "$work/events") == "$n0 unmount $X
$n0 start-dfuse --dump-handles .handles.$B
$n0 handles mode 600" && $(wc -l < "$work/events") == 3 ]] \
    && pass "a one-host sim mounts on that host alone" || fail "events:"$'\n'"$(events)"

# 9,000 hosts reach clush as a host file: as one -w list they exceed the 128 KiB argument limit.
reset
for i in $(seq 1 9000); do echo "x$((1000 + i))c0s0b0n0.hsn.cm.aurora.alcf.anl.gov"; done > "$work/hostfile"
run ABACUS_CHECKPOINT_CONTAINERS=1
counts=$(awk -F, '{print NF}' "$work/clush.log" | paste -sd' ' -)
[[ $counts == "1 8999 9000" ]] && ! grep -q -e "too long" -e warning "$work/onesim.out" \
    && pass "9,000 hosts: mount, then check before the relaunch" \
    || fail "9,000 hosts: clush host counts '$counts'; $(grep -e 'too long' -e warning "$work/onesim.out" | head -2)"

# No checkpoint container to restart from: no sweep.
reset
rm -f "$ckptdir"/state_*0
run ABACUS_CHECKPOINT_CONTAINERS=1
[[ ! -e $work/clush.log ]] && pass "no restart point: no sweep" || fail "no restart point: clush was called"

# Off (the default): no clush at all.
reset
run ABACUS_CHECKPOINT_CONTAINERS=0
[[ ! -e $work/clush.log ]] && pass "off: no mounts" || fail "off: clush was called"
run
[[ ! -e $work/clush.log ]] && pass "unset: no mounts" || fail "unset: clush was called"

if (( fails )); then
    echo "$fails case(s) failed"
    exit 1
fi
echo "all cases passed"

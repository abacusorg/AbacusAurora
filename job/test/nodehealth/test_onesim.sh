#!/bin/bash
# Drive onesim.sh's retry loop end to end with a stub `python`, so the shell
# wiring of the blame-and-replace path can be checked without Aurora, PBS, MPI
# or a built Abacus.
#
#   bash job/test/nodehealth/test_onesim.sh
#
# The stub answers `python -m abacus.param` with a fake OutputDirectory and
# `python -m abacus.run` with a canned per-attempt script, and forwards anything
# else (i.e. nodehealth.py) to the real interpreter.

set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
job=$(cd "$here/../.." && pwd)
onesim="$job/onesim.sh"

fails=0
check() {  # check <name> <command...>  -- passes when the command succeeds
    local name=$1; shift
    if "$@"; then echo "  ok   $name"; else echo "  FAIL $name"; fails=$((fails+1)); fi
}

check_not() {  # the negation, spelled out so a missing file cannot pass vacuously
    local name=$1; shift
    if "$@"; then echo "  FAIL $name"; fails=$((fails+1)); else echo "  ok   $name"; fi
}

has_line() { test -f "$2" && grep -qx "$1" "$2"; }

# --- the harness -------------------------------------------------------------

setup() {  # setup <spare-count>; sets $work and the environment onesim expects
    # Explicit template: macOS mktemp ignores $TMPDIR without one.
    work=$(mktemp -d "${TMPDIR:-/tmp}/onesim-test.XXXXXX") || {
        echo "cannot create a scratch dir under ${TMPDIR:-/tmp}" >&2; exit 2; }
    export HASHRUN_OUT="$work/out"
    export ABACUS_SIM_INDEX=0
    export ABACUS_SIM_LOG="$HASHRUN_OUT/sim_0.out"
    export HOSTFILE_EXTRA="$HASHRUN_OUT/hostfile_extra"
    export ABACUS_NODEHEALTH="$work/nodehealth.tsv"
    export stub_outdir="$work/simdata"
    export stub_state="$work/attempt"
    mkdir -p "$HASHRUN_OUT" "$stub_outdir"
    : > "$ABACUS_SIM_LOG"
    echo 0 > "$stub_state"

    echo "# a par2 the stub never actually reads" > "$work/fake.par2"

    hostfile="$HASHRUN_OUT/nodefile_part_000"
    { echo x4117c0s6b0n0; echo x4115c5s4b0n0
      for i in 0 1 2 3 4 5; do echo "x9999c0s0b0n$i"; done; } > "$hostfile"

    : > "$HOSTFILE_EXTRA"
    local n=$1 i=0
    while (( i < n )); do echo "x8888c0s0b0n$i" >> "$HOSTFILE_EXTRA"; i=$((i+1)); done

    # A `python` that impersonates abacus and defers everything else to python3.
    mkdir -p "$work/bin"
    cat > "$work/bin/python" <<'STUB'
#!/bin/bash
if [[ ${1:-} == -m && ${2:-} == abacus.param ]]; then
    echo "OutputDirectory = \"$stub_outdir\""
    exit 0
fi
if [[ ${1:-} == -m && ${2:-} == abacus.run ]]; then
    n=$(cat "$stub_state"); n=$((n+1)); echo "$n" > "$stub_state"
    exec "$stub_run" "$n"
fi
exec python3 "$@"
STUB
    chmod +x "$work/bin/python"
    export PATH="$work/bin:$PATH"
}

teardown() { rm -rf "$work"; }

canned() {  # canned <script-body>; becomes the fake abacus.run, $1 = attempt no.
    stub_run="$work/bin/run.sh"
    printf '#!/bin/bash\n%s\n' "$1" > "$stub_run"
    chmod +x "$stub_run"
    export stub_run
}

pool_size() { grep -c . "$HOSTFILE_EXTRA" 2>/dev/null || echo 0; }

# --- 1. a blamed node is swapped out and the sim goes on ---------------------

echo "1. shepherd SIGKILL: swap the node, relaunch, succeed"
setup 4
canned '
if (( $1 == 1 )); then
    echo "     0  99.0  12.5 239.3  3.0 9106 0.0000    0    0  0.0     0    0  0.0 264.1    -"
    echo "x4117c0s6b0n0.hsn.cm.aurora.alcf.anl.gov: shepherd died from signal 9" >&2
    echo "x4115c5s4b0n0.hsn.cm.aurora.alcf.anl.gov: rank 12 died from signal 15" >&2
    exit 1
fi
echo "Simulation completed successfully"'
before=$(pool_size)
bash "$onesim" "$work/fake.par2" "$hostfile" > "$ABACUS_SIM_LOG" 2>&1
rc=$?
new="$hostfile.a2"
check "onesim exited clean" test "$rc" -eq 0
check "a rewritten hostfile was produced" test -f "$new"
check_not "the blamed node is gone" has_line x4117c0s6b0n0 "$new"
check "the collateral node is kept" has_line x4115c5s4b0n0 "$new"
check "a spare took its place" grep -q '^x8888' "$new"
check "node count unchanged" test "$(grep -c . "$new")" -eq "$(grep -c . "$hostfile")"
check "the pool shrank by exactly one" test "$(pool_size)" -eq "$((before - 1))"
check "the sim relaunched on the new hostfile" \
    grep -q "abacus invocation 2 on $(grep -c . "$new") nodes" "$ABACUS_SIM_LOG"
check "the replacement is recorded as confirmed-bad" \
    grep -q '^x4117c0s6b0n0	.*	1	' "$ABACUS_NODEHEALTH"
teardown

# --- 2. no spares left ⇒ abort rather than relaunch onto a dead node ---------

echo "2. blamed node but an empty pool: give up instead of retrying"
setup 0
canned '
echo "     0  99.0  12.5 239.3  3.0 9106 0.0000    0    0  0.0     0    0  0.0 264.1    -"
echo "x4117c0s6b0n0.hsn.cm.aurora.alcf.anl.gov: shepherd died from signal 9" >&2
exit 1'
bash "$onesim" "$work/fake.par2" "$hostfile" > "$ABACUS_SIM_LOG" 2>&1
rc=$?
check "onesim failed" test "$rc" -eq 1
check "it said why" grep -q "spare pool is empty" "$ABACUS_SIM_LOG"
check "it did not relaunch" test "$(grep -c 'abacus invocation' "$ABACUS_SIM_LOG")" -eq 1
teardown

# --- 3. an app segfault relaunches unchanged --------------------------------

echo "3. sig 11: strike only, relaunch on the same nodes"
setup 4
canned '
if (( $1 == 1 )); then
    echo "     0  99.0  12.6 238.1  3.4 8643 0.0000    0    0  0.0     0    0  0.0 264.3    -"
    echo "NODEFAIL t_epoch=1787414456 elapsed=238.389 host=x4115c5s4b0n0 rank=2 phase=\"timestep\" op=\"signal\" sig=11" >&2
    exit 1
fi
echo "Simulation completed successfully"'
before=$(pool_size)
bash "$onesim" "$work/fake.par2" "$hostfile" > "$ABACUS_SIM_LOG" 2>&1
rc=$?
check "onesim exited clean" test "$rc" -eq 0
check "no hostfile was rewritten" test ! -f "$hostfile.a2"
check "the pool is untouched" test "$(pool_size)" -eq "$before"
check "it relaunched anyway" grep -q "abacus invocation 2" "$ABACUS_SIM_LOG"
check "a strike was recorded at the time" \
    grep -q x4115c5s4b0n0 "$HASHRUN_OUT/nodehealth/ledger.jsonl"
check_not "...and cleared once the run went clean" \
    grep -q '^x4115c5s4b0n0' "$ABACUS_NODEHEALTH"
teardown

# --- 4. the log window is per attempt ---------------------------------------

echo "4. attempt 2 is not diagnosed from attempt 1's output"
setup 4
canned '
if (( $1 == 1 )); then
    echo "x4117c0s6b0n0.hsn.cm.aurora.alcf.anl.gov: shepherd died from signal 9" >&2
    exit 1
fi
if (( $1 == 2 )); then
    echo "plain failure, nobody named" >&2
    exit 1
fi
echo "Simulation completed successfully"'
bash "$onesim" "$work/fake.par2" "$hostfile" > "$ABACUS_SIM_LOG" 2>&1
check "attempt 1 replaced a node" test -f "$hostfile.a2"
check "attempt 2 replaced nothing (its window is clean)" test ! -f "$hostfile.a3"
slice2="$HASHRUN_OUT/nodehealth/sim0.attempt2.log"
check "attempt 2's slice exists and holds its own output" grep -q "plain failure" "$slice2"
check_not "...and not attempt 1's accusation" grep -q shepherd "$slice2"
teardown

# --- 5. without the environment, behave exactly as before -------------------

echo "5. standalone (no multisim environment): unchanged behaviour"
setup 4
unset ABACUS_SIM_LOG HOSTFILE_EXTRA HASHRUN_OUT
canned 'echo "boom" >&2; exit 1'
out=$(bash "$onesim" "$work/fake.par2" "$hostfile" 2>&1)
rc=$?
check "onesim still fails cleanly" test "$rc" -eq 1
check "it says replacement is off" grep -q "node replacement disabled" <<<"$out"
teardown

echo
if (( fails )); then echo "$fails check(s) FAILED"; exit 1; fi
echo "all checks passed"

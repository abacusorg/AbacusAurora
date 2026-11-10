#!/bin/bash
# test_nodeprep.sh — exercise job/nodeprep.sh without MPI or a PBS job: nodeprep_build compiles
# nodeprep.cpp, the binary reports, and nodeprep_run summarizes a pass and never fails the
# `set -euo pipefail` script that calls it.  A stub `mpiexec` on $PATH stands in for the launch: it
# prints canned nodeprep output, or fails.  Nothing here runs --reclaim.
#
# Usage: job/test/nodeprep/test_nodeprep.sh
# Exits 0 if all cases pass, 1 otherwise.

set -uo pipefail

job=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/nodeprep-test.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

fails=0
result() {  # result <name> <ok?> [detail]
    if (( $2 )); then
        echo "PASS  $1"
    else
        echo "FAIL  $1${3:+: $3}"
        fails=$((fails + 1))
    fi
}

source "$job/nodeprep.sh"
nodeprep_build "$work/nodeprep"
result "nodeprep_build" "$(( $? == 0 ))"
# Report mode (no --reclaim) only reads /proc and /sys.
out=$("$work/nodeprep" 2>&1)
rc=$?
result "the binary reports" "$(( rc == 0 ))" "rc=$rc"

mkdir -p "$work/bin"
cat > "$work/bin/mpiexec" <<'STUB'
#!/bin/bash
[[ -n ${STUB_OUTPUT:-} ]] && cat "$STUB_OUTPUT"
exit "${STUB_RC:-0}"
STUB
chmod +x "$work/bin/mpiexec"
printf 'h1\nh2\n' > "$work/hosts"
blocks() {  # blocks <host> <node|memnode> <number> <phase> <GiB>: a line in nodeprep's format
    printf "%s %s %s %-8s free 500.0, in >= 2 MiB blocks %s, smaller 9.0; file LRU 1.0, SReclaimable 1.0, KReclaimable 25.0, SUnreclaim 2.0, Shmem 0.5, others' anon 1.0\n" "$@"
}
{
    blocks h1 node 0 before: 150.0; blocks h1 node 0 after: 460.5
    blocks h1 node 1 before: 100.0; blocks h1 node 1 after: 300.0
    blocks h2 node 0 before: 400.0; blocks h2 node 0 after: 470.0
    blocks h2 node 1 before: 120.0; blocks h2 node 1 after: 455.0
    echo 'h2 node 1 filled:  140.0 huge in 3.0 s (region filled), 320.0 small in 20.0 s (file LRU drained)'
    blocks h1 memnode 2 before: 12.0; blocks h1 memnode 2 after: 63.5
    blocks h1 memnode 3 before: 63.0; blocks h1 memnode 3 after: 63.9
    blocks h2 memnode 2 before: 40.0; echo 'h2 memnode 2 failed:  pass killed by signal 9'; blocks h2 memnode 2 after: 40.5
} > "$work/canned.txt"

# check <name> <binary> <wanted text> [VAR=VAL ...]: nodeprep_run, called the way multisim.pbs
# calls it, must print the wanted text and let the caller carry on.
check() {
    local name=$1 bin=$2 want=$3
    shift 3
    local out rc=0 ok=0
    out=$(env "$@" PATH="$work/bin:$PATH" bash -c '
              set -euo pipefail
              source "$1/nodeprep.sh"
              nodeprep_run "$2" "$3" "$4"
              echo "caller carries on"' check "$job" "$bin" "$work/hosts" "$work/log.txt" 2>&1) || rc=$?
    [[ $rc == 0 && $out == *"caller carries on"* && $out == *"$want"* ]] && ok=1
    result "$name" "$ok" "rc=$rc, output:"$'\n'"$out"
}

check "a pass reports its node count" "$work/nodeprep" \
      'nodeprep: 2 node(s) in' STUB_OUTPUT="$work/canned.txt"
check "the socket with the fewest whole blocks after leads the list" "$work/nodeprep" \
      $'fewest after first:\n  h1 node 1   100.0 ->  300.0\n' STUB_OUTPUT="$work/canned.txt"
check "median over every socket" "$work/nodeprep" \
      'median after: 455.0 over 4 socket(s)' STUB_OUTPUT="$work/canned.txt"
check "memory-only nodes are listed apart, fewest first" "$work/nodeprep" \
      $'memory-only (HBM) nodes:\n  h2 memnode 2    40.0 ->   40.5\n  h1 memnode 2    12.0 ->   63.5\n' STUB_OUTPUT="$work/canned.txt"
check "median over the memory-only nodes" "$work/nodeprep" \
      'median after: 63.5 over 3 node(s)' STUB_OUTPUT="$work/canned.txt"
check "a killed pass is named" "$work/nodeprep" \
      $'nodeprep failed 1 time(s)' STUB_OUTPUT="$work/canned.txt"
check "a failed launch warns and carries on" "$work/nodeprep" \
      "WARNING: nodeprep's launch failed (rc=3)" STUB_RC=3
check "a missing binary warns and carries on" "$work/missing" \
      'is missing'

if (( fails )); then
    echo "$fails case(s) failed"
    exit 1
fi
echo "all cases passed"

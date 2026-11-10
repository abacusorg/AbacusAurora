#!/bin/bash
# test_nodeprep.sh — exercise job/nodeprep.sh without MPI or a PBS job: nodeprep_build compiles
# nodeprep.cpp, the binary reports, and nodeprep_run summarizes a pass or a check and never fails the
# `set -euo pipefail` script that calls it.  A stub `mpiexec` on $PATH stands in for the launch: it
# prints canned nodeprep output, or fails, and records its arguments.  Nothing here runs --reclaim.
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
printf '%s\n' "$out" > "$work/real_check.txt"
out=$(nodeprep_report "$work/real_check.txt" 2>&1)
[[ $out == *"fewest first:"* && $out == *"median: "* ]]
result "a check's report reads this machine's own numbers" "$(( $? == 0 ))" "$out"

for pair in "unset reclaim" "on reclaim" "1 reclaim" "check check" "CHECK check" "off off" "no off"; do
    set -- $pair
    got=$(if [[ $1 == unset ]]; then unset ABACUS_NODEPREP; else ABACUS_NODEPREP=$1; fi; nodeprep_mode 2>&1)
    result "ABACUS_NODEPREP=$1 is $2" "$([[ $got == "$2" ]] && echo 1 || echo 0)" "got '$got'"
done
got=$(ABACUS_NODEPREP=chek nodeprep_mode 2>&1)
result "a misspelt ABACUS_NODEPREP is an error" "$(( $? != 0 ))" "got '$got'"

mkdir -p "$work/bin"
cat > "$work/bin/mpiexec" <<'STUB'
#!/bin/bash
[[ -n ${STUB_ARGS:-} ]] && printf '%s\n' "$*" > "$STUB_ARGS"
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
found() {  # found <host> <node|memnode> <number> <GiB>: a check's line (nodeprep without --reclaim)
    printf "%s %s %s: free 500.0, in >= 2 MiB blocks %s, smaller 9.0; file LRU 1.0, SReclaimable 1.0, KReclaimable 25.0, SUnreclaim 2.0, Shmem 0.5, others' anon 1.0; low watermark 0.56\n" "$@"
}
{
    found h1 node 0 460.5; found h1 node 1 300.0; found h2 node 0 470.0; found h2 node 1 455.0
    found h1 memnode 2 63.5; found h2 memnode 2 40.5
} > "$work/canned3.txt"

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

check "a pass asks for --reclaim and the DDR need" "$work/nodeprep" \
      'nodeprep: 2 node(s) in' STUB_OUTPUT="$work/canned.txt" STUB_ARGS="$work/args.txt"
[[ $(cat "$work/args.txt") == *"$work/nodeprep --reclaim --need-gib 330" ]]
result "  ...with these arguments" "$(( $? == 0 ))" "$(cat "$work/args.txt")"
check "a check says so" "$work/nodeprep" \
      'nodeprep: 2 node(s) measured (ABACUS_NODEPREP=check: nothing reclaimed) in' \
      ABACUS_NODEPREP=check STUB_OUTPUT="$work/canned3.txt" STUB_ARGS="$work/args.txt"
[[ $(cat "$work/args.txt") == *"$work/nodeprep" ]]
result "  ...and runs the binary without arguments" "$(( $? == 0 ))" "$(cat "$work/args.txt")"
check "a check lists the fewest first, one value each" "$work/nodeprep" \
      $'fewest first:\n  h1 node 1   300.0\n  h2 node 1   455.0\n' ABACUS_NODEPREP=check STUB_OUTPUT="$work/canned3.txt"
check "a check's median" "$work/nodeprep" \
      'median: 455.0 over 4 socket(s)' ABACUS_NODEPREP=check STUB_OUTPUT="$work/canned3.txt"
check "a check lists the memory-only nodes apart" "$work/nodeprep" \
      $'memory-only (HBM) nodes:\n  h2 memnode 2    40.5\n  h1 memnode 2    63.5\n  median: 40.5 over 2 node(s)' \
      ABACUS_NODEPREP=check STUB_OUTPUT="$work/canned3.txt"
rm -f "$work/args.txt"
out=$(env ABACUS_NODEPREP=off STUB_ARGS="$work/args.txt" PATH="$work/bin:$PATH" bash -c '
          set -euo pipefail; source "$1/nodeprep.sh"; nodeprep_run "$2" "$3" "$4"; echo "caller carries on"' \
          off "$job" "$work/nodeprep" "$work/hosts" "$work/log.txt" 2>&1)
[[ $out == "caller carries on" && ! -e $work/args.txt ]]
result "off launches nothing" "$(( $? == 0 ))" "$out"

# nodeprep_demote: h1's socket 1 recovers on its second pass, h2 has a short HBM node, h3 a short
# socket, h4 no result, h5 nothing wrong.
{
    blocks h1 node 0 before: 150.0; blocks h1 node 0 after: 460.5
    blocks h1 node 1 before: 100.0; blocks h1 node 1 after: 300.0
    echo 'h1 node 1 short:   300.0 in >= 2 MiB blocks, 330.0 needed; a second pass presses on kernel caches'
    blocks h1 node 1 before: 300.0; blocks h1 node 1 after: 345.0
    blocks h1 memnode 2 before: 12.0; blocks h1 memnode 2 after: 63.5
    blocks h2 node 0 before: 400.0; blocks h2 node 0 after: 470.0
    blocks h2 memnode 2 before: 40.0; echo 'h2 memnode 2 failed:  pass killed by signal 9'; blocks h2 memnode 2 after: 40.5
    blocks h3 node 0 before: 200.0; blocks h3 node 0 after: 310.0
    blocks h3 memnode 3 before: 63.0; blocks h3 memnode 3 after: 63.9
    blocks h5 node 0 before: 400.0; blocks h5 node 0 after: 470.0
} > "$work/canned2.txt"
# demote <name> <wanted order> <wanted text> <required> [VAR=VAL ...]
demote() {
    local name=$1 order=$2 want=$3 required=$4
    shift 4
    printf 'h1.net\nh2.net\nh3.net\nh4.net\nh5.net\n' > "$work/hosts5"
    local out rc=0 got ok=0
    out=$(env "$@" bash -c 'set -euo pipefail; source "$1/nodeprep.sh"; nodeprep_demote "$2" "$3" "$4"' \
              demote "$job" "$work/hosts5" "${demote_log:-$work/canned2.txt}" "$required" 2>&1) || rc=$?
    got=$(tr '\n' ' ' < "$work/hosts5")
    [[ $rc == 0 && $got == "$order " && $out == *"$want"* ]] && ok=1
    result "$name" "$ok" "rc=$rc, order: $got, output:"$'\n'"$out"
}
demote "short nodes go last, the least short first" "h1.net h5.net h4.net h3.net h2.net" \
       $'  h3: node 0 has 310.0 GiB and needs 330\n  h2: memnode 2 has 40.5 GiB and needs 58' 2
demote "with too few spares the least short run, and it warns" "h1.net h5.net h4.net h3.net h2.net" \
       $'with 1 spare(s), 2 of them run:\n  h4: no nodeprep result (runs)\n  h3: node 0 has 310.0 GiB and needs 330 (runs)\n' 4
demote "a second pass that recovers the socket counts" "h1.net h5.net h4.net h3.net h2.net" \
       'WARNING: nodeprep: 2 node(s) short' 4
demote "the checks can be turned off" "h1.net h2.net h3.net h5.net h4.net" \
       'h4: no nodeprep result' 2 ABACUS_NODEPREP_NEED_DDR_GIB=0 ABACUS_NODEPREP_NEED_HBM_GIB=0
[[ $(cat "$work/hosts5.short") == h4.net ]]
result "the short list names the demoted hosts" "$(( $? == 0 ))"

# The same nodes as a check finds them, where h1's socket 1 was already whole.
{
    found h1 node 0 460.5; found h1 node 1 345.0; found h1 memnode 2 63.5
    found h2 node 0 470.0; found h2 memnode 2 40.5
    found h3 node 0 310.0; found h3 memnode 3 63.9
    found h5 node 0 470.0
} > "$work/canned4.txt"
demote_log=$work/canned4.txt
demote "a check's short nodes go last, the least short first" "h1.net h5.net h4.net h3.net h2.net" \
       $'  h3: node 0 has 310.0 GiB and needs 330\n  h2: memnode 2 has 40.5 GiB and needs 58' 2
demote "a check names the short HBM node" "h1.net h5.net h4.net h3.net h2.net" \
       $'with 1 spare(s), 2 of them run:\n  h4: no nodeprep result (runs)\n  h3: node 0 has 310.0 GiB and needs 330 (runs)\n  h2: memnode 2 has 40.5 GiB and needs 58\n' 4
unset demote_log

if (( fails )); then
    echo "$fails case(s) failed"
    exit 1
fi
echo "all cases passed"

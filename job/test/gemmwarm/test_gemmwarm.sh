#!/bin/bash
# test_gemmwarm.sh — exercise job/gemmwarm.sh without MPI or a PBS job: the switches, each node's place in
# its rack, the file list, one node's warm-up (reading /bin/ls and its libraries in place of gemm.exe), and
# gemmwarm_run's summary, which must never fail the `set -euo pipefail` script that calls it.  A stub
# `mpiexec` on $PATH stands in for the launch: it prints canned node lines, fails, or runs the node command here.
#
# Usage: job/test/gemmwarm/test_gemmwarm.sh
# Exits 0 if all cases pass, 1 otherwise.

set -uo pipefail

job=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/gemmwarm-test.XXXXXX") || exit 1
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

source "$job/gemmwarm.sh"

for pair in "unset on" "on on" "1 on" "off off" "OFF off" "no off"; do
    set -- $pair
    got=$(if [[ $1 == unset ]]; then unset ABACUS_GEMM_WARMUP; else ABACUS_GEMM_WARMUP=$1; fi; gemmwarm_mode 2>&1)
    result "ABACUS_GEMM_WARMUP=$1 is $2" "$([[ $got == "$2" ]] && echo 1 || echo 0)" "got '$got'"
done
for pair in "on 2 0" "off 0 0" "of 2 1" "on 1.5 1" "on x 1"; do
    set -- $pair
    got=$(ABACUS_GEMM_WARMUP=$1 ABACUS_GEMM_WARMUP_STAGGER=$2 gemmwarm_check_settings 2>&1)
    rc=$?
    result "ABACUS_GEMM_WARMUP=$1 with ABACUS_GEMM_WARMUP_STAGGER=$2 $( (( $3 )) && echo 'is refused' || echo 'is accepted')" \
           "$(( (rc != 0) == $3 ))" "rc=$rc, '$got'"
done

dom=.hsn.cm.aurora.alcf.anl.gov
printf '%s\n' "x4010c0s0b0n0$dom" "x4010c1s3b0n0$dom" "x4011c0s0b0n0$dom" "x4010c7s7b0n0$dom" "x4010c1s3b0n0$dom" \
    > "$work/hosts"
for pair in "x4010c0s0b0n0 0" "x4010c1s3b0n0$dom 1" "x4010c7s7b0n0 2" "x4011c0s0b0n0 0" "x4099c0s0b0n0 0"; do
    set -- $pair
    got=$(gemmwarm_rack_rank "$work/hosts" "$1")
    result "$1 is place $2 in its rack" "$([[ $got == "$2" ]] && echo 1 || echo 0)" "got '$got'"
done

mapfile -t files < <(gemmwarm_files /bin/ls)
ok=1
for f in "${files[@]}"; do [[ -f $f && $f == /* ]] || ok=0; done
result "the file list holds only existing absolute paths" "$ok" "${files[*]}"
result "the file list has the program and its libc" \
       "$([[ " ${files[*]} " == *" $(readlink -f /bin/ls) "* && " ${files[*]} " == *libc.so* ]] && echo 1 || echo 0)" "${files[*]}"
result "the file list has no duplicates" "$(( $(printf '%s\n' "${files[@]}" | sort | uniq -d | wc -l) == 0 ))"

out=$(GEMMWARM_BIN=/bin/ls bash "$job/gemmwarm.sh" node "$work/hosts" 0 2>&1)
rc=$?
result "a node reads the files and reports" \
       "$([[ $rc == 0 && $out == *"gemmwarm: rack place 0, waited 0 s; read ${#files[@]} files"*"(rc=0)"* ]] && echo 1 || echo 0)" \
       "rc=$rc, '$out'"
out=$(GEMMWARM_BIN=$work/no-such-gemm bash "$job/gemmwarm.sh" node "$work/hosts" 0 2>&1)
rc=$?
result "a node without gemm.exe skips it and succeeds" \
       "$([[ $rc == 0 && $out == *"gemmwarm: skipped, no"* ]] && echo 1 || echo 0)" "rc=$rc, '$out'"

mkdir -p "$work/bin"
cat > "$work/bin/mpiexec" <<'STUB'
#!/bin/bash
[[ -n ${STUB_ARGS:-} ]] && printf '%s\n' "$*" > "$STUB_ARGS"
[[ -n ${STUB_OUTPUT:-} ]] && cat "$STUB_OUTPUT"
if [[ -n ${STUB_EXEC:-} ]]; then
    while (( $# )) && [[ $1 != bash ]]; do shift; done
    "$@"
fi
exit "${STUB_RC:-0}"
STUB
chmod +x "$work/bin/mpiexec"
export PATH=$work/bin:$PATH

cat > "$work/canned" <<'EOF'
x4010c0s0b0n0 gemmwarm: rack place 0, waited 0 s; read 44 files, 758 MiB, in 2.9 s (rc=0); /pe server 10.114.32.219 sent 135.2 MiB
x4010c7s7b0n0 gemmwarm: rack place 2, waited 4 s; read 44 files, 758 MiB, in 60.0 s (rc=124); /pe server 10.114.32.219 sent 10.0 MiB
EOF
got=$(set -euo pipefail; STUB_ARGS=$work/args STUB_OUTPUT=$work/canned gemmwarm_run "$work/hosts" "$work/log" 2>&1; echo "returned $?")
result "the summary counts the nodes, the bytes, the slowest read and the failures" \
       "$([[ $got == *"2 of 5 node(s) reported"*"(rc=0): 145 MiB from /pe, slowest read 60.0 s, 1 read(s) failed, 0 skipped"*"returned 0"* ]] && echo 1 || echo 0)" \
       "$got"
args=$(cat "$work/args" 2>/dev/null)
result "the launch is one bash per node, without a VNI" \
       "$([[ $args == "-n 5 --ppn 1 --cpu-bind none --no-vni --no-abort-on-failure --hostfile $work/hosts bash "*"/gemmwarm.sh node $work/hosts 2" ]] && echo 1 || echo 0)" \
       "$args"
got=$(set -euo pipefail; STUB_RC=1 gemmwarm_run "$work/hosts" "$work/log" 2>&1; echo "returned $?")
result "a failed launch is reported and not fatal" \
       "$([[ $got == *"0 of 5 node(s) reported"*"(rc=1)"*"returned 0"* ]] && echo 1 || echo 0)" "$got"
rm -f "$work/args"
got=$(set -euo pipefail; ABACUS_GEMM_WARMUP=off STUB_ARGS=$work/args gemmwarm_run "$work/hosts" "$work/log" 2>&1; echo "returned $?")
result "ABACUS_GEMM_WARMUP=off launches nothing" \
       "$([[ $got == *"gemm warm-up: off"*"returned 0"* && ! -e $work/args ]] && echo 1 || echo 0)" "$got"
got=$(set -euo pipefail; GEMMWARM_BIN=/bin/ls ABACUS_GEMM_WARMUP_STAGGER=0 STUB_EXEC=1 gemmwarm_run "$work/hosts" "$work/log" 2>&1; echo "returned $?")
result "end to end, the node's line reaches the summary" \
       "$([[ $got == *"1 of 5 node(s) reported"*"0 read(s) failed, 0 skipped"*"returned 0"* ]] && echo 1 || echo 0)" "$got"

echo
(( fails == 0 )) && echo "All cases pass" || echo "$fails case(s) failed"
(( fails == 0 ))

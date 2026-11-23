#!/bin/bash
# test_exclusions.sh — exercise job/exclusions.sh without PBS: the switches, the tracked lists' format, and
# each step multisim.pbs takes: leaving the known bad and the short nodes out whatever the spares, ending the
# job when too few remain, and choosing the spares, the listed slow nodes first, then the least memory.
#
# Usage: job/test/exclusions/test_exclusions.sh
# Exits 0 if all cases pass, 1 otherwise.

set -uo pipefail

job=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/exclusions-test.XXXXXX") || exit 1
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

source "$job/exclusions.sh"

for var in ABACUS_BAD_NODES ABACUS_SLOW_NODES; do
    for pair in "unset on" "on on" "1 on" "off off" "OFF off" "no off"; do
        set -- $pair
        got=$(if [[ $1 == unset ]]; then unset "$var"; else export "$var=$1"; fi; excl_switch "$var" 2>&1)
        result "$var=$1 is $2" "$([[ $got == "$2" ]] && echo 1 || echo 0)" "got '$got'"
    done
    (export "$var=of"; excl_check_settings 2>/dev/null)
    result "a misspelt $var is refused" "$(( $? != 0 ))"
done

# The tracked lists: every entry a well-formed short host name with a reason, none twice, none in both.
for f in "$BADNODES_FILE" "$SLOWNODES_FILE"; do
    mapfile -t listed < <(excl_list "$f")
    ok=1
    for l in "${listed[@]}"; do [[ $l =~ ^x[0-9]{4}c[0-9]s[0-9]b[0-9]n[0-9]\ .+ && $l != *" listed" ]] || ok=0; done
    result "job/${f##*/}: ${#listed[@]} entries, each a short host name with a reason" "$(( ok && ${#listed[@]} > 0 ))" \
           "$(printf '%s\n' "${listed[@]}")"
    result "job/${f##*/} names no host twice" \
           "$(( $(printf '%s\n' "${listed[@]}" | cut -d ' ' -f 1 | sort | uniq -d | wc -l) == 0 ))"
done
both=$(cat <(excl_list "$BADNODES_FILE" | cut -d ' ' -f 1) <(excl_list "$SLOWNODES_FILE" | cut -d ' ' -f 1) | sort | uniq -d)
result "no host is in both lists" "$([[ -z $both ]] && echo 1 || echo 0)" "$both"

dom=.hsn.cm.aurora.alcf.anl.gov
hosts() { printf "%s$dom\n" "$@"; }
cat > "$work/bad" <<'EOF'
# a test list
xbad2   # second reason
        #   a continuation line, no host
xbad1   # first reason
xabsent # not in the allocation
EOF
cat > "$work/slow" <<'EOF'
xslow2  # slower
xslow1  # slow
EOF

# run <name> <command...>: a step as multisim.pbs calls it, under set -euo pipefail, with the test lists;
# sets out and rc.  The caller must carry on unless the step fails.
run() {
    out=$(bash -c 'set -euo pipefail; source "$1/exclusions.sh"; BADNODES_FILE=$2; SLOWNODES_FILE=$3; shift 3
                   "$@"; echo "caller carries on"' run "$job" "${BAD:-$work/bad}" "${SLOW:-$work/slow}" "$@" 2>&1)
    rc=$?
}
lines() { tr '\n' ' ' < "$1" | sed 's/ $//'; }
short() { sed "s/$dom//g" <<< "$1"; }

# --- 1. Known bad: all of them, whatever the spares.
hosts xok1 xbad1 xok2 xbad2 xok3 > "$work/h"
run excl_bad "$work/h"
result "every listed host is left out, the rest keep their order" \
       "$([[ $(lines "$work/h") == "$(hosts xok1 xok2 xok3 | tr '\n' ' ' | sed 's/ $//')" ]] && echo 1 || echo 0)" "$(lines "$work/h")"
result "  ...listed in <hostfile>.bad in the list's order" \
       "$([[ $(cat "$work/h.bad") == "$(hosts xbad2 xbad1)" ]] && echo 1 || echo 0)" "$(cat "$work/h.bad")"
result "  ...each named with its reason, the caller carrying on" \
       "$([[ $rc == 0 && $out == *"leaving out the 2"*"  xbad2: second reason"*"  xbad1: first reason"*"caller carries on" ]] && echo 1 || echo 0)" "$out"
hosts xbad1 xbad2 > "$work/h"
run excl_bad "$work/h"
result "an allocation of only bad hosts is emptied" "$([[ $rc == 0 && ! -s $work/h ]] && echo 1 || echo 0)" "$out"

hosts xok1 xbad1 > "$work/h"
ABACUS_BAD_NODES=off run excl_bad "$work/h"
result "ABACUS_BAD_NODES=off leaves the allocation alone" \
       "$([[ $(lines "$work/h") == "$(hosts xok1 xbad1 | tr '\n' ' ' | sed 's/ $//')" && $out == *"not applied"* ]] && echo 1 || echo 0)" "$out"
BAD=$work/no-such-list run excl_bad "$work/h"
result "a missing list warns and leaves the allocation alone" \
       "$([[ $rc == 0 && $(wc -l < "$work/h") == 2 && $out == *"WARNING: bad nodes"*"missing"* ]] && echo 1 || echo 0)" "$out"
hosts xok1 xok2 > "$work/h"
run excl_bad "$work/h"
result "no listed host in the allocation leaves it alone" "$([[ $rc == 0 && $out == *"none of the 3"* ]] && echo 1 || echo 0)" "$out"

# --- excl_need: the job ends when too few remain.
hosts xok1 xok2 > "$work/h"
run excl_need "$work/h" 2 "after leaving out the bad nodes"
result "enough hosts left lets the caller carry on" "$([[ $rc == 0 && $out == *"caller carries on" ]] && echo 1 || echo 0)" "$out"
run excl_need "$work/h" 3 "after leaving out the bad nodes"
result "too few hosts left fails, saying why" \
       "$([[ $rc != 0 && $out == *"ERROR: 2 node(s) remain after leaving out the bad nodes, and the sims need 3"* && $out != *"carries on"* ]] && echo 1 || echo 0)" "$out"

# --- 2. Short after node prep: margins as nodeprep_margins writes them.
margins() {  # margins <host state margin why>...: one tab-separated line per four arguments
    while (( $# )); do printf '%s\t%s\t%s\t%s\n' "$1$dom" "$2" "$3" "$4"; shift 4; done
}
hosts xa xb xc xd > "$work/h"
margins xa ok 0.4000 "tightest: node 0" xb short -0.2500 "node 0 has 247.5 GiB and needs 330" \
        xc ok 0.0100 "tightest: memnode 2" xd unknown - "no nodeprep result" > "$work/m"
run excl_short "$work/h" "$work/m"
result "a short host is left out, into <hostfile>.short, and named" \
       "$([[ $rc == 0 && $(short "$(lines "$work/h")") == "xa xc xd" && $(cat "$work/h.short") == "$(hosts xb)" \
                    && $out == *"leaving out the 1 node(s) still short"*"  xb: node 0 has 247.5 GiB and needs 330"* ]] && echo 1 || echo 0)" "$out"

# --- 3 and 4. The spares.
# xs1..: listed slow; xm*: margins.  Sims keep their order; spares follow, best first.
hosts xm1 xslow1 xm2 xm3 xslow2 xm4 xm5 > "$work/h"
margins xm1 ok 0.5000 "t1" xslow1 ok 0.9000 "t2" xm2 ok 0.0200 "t3" xm3 unknown 0.3000 "no result for memnode 2" \
        xslow2 ok 0.8000 "t5" xm4 ok 0.0100 "t6" xm5 ok 0.6000 "t7" xgone short -0.5 "left out already" > "$work/m"
cp "$work/h" "$work/h0"
run excl_spares "$work/h" 3 "$work/m"
result "spares: the listed slow nodes first, in the list's order, then the least over the need" \
       "$([[ $out == *$'  xslow2: slow: slower\n  xslow1: slow: slow\n  xm3: no result for memnode 2\n  xm4: t6\n'* ]] && echo 1 || echo 0)" "$out"
result "  ...the sims keep their order, the spares follow best first" \
       "$([[ $(short "$(lines "$work/h")") == "xm1 xm2 xm5 xm4 xm3 xslow1 xslow2" ]] && echo 1 || echo 0)" "$(short "$(lines "$work/h")")"
result "  ...with why in <hostfile>.spares, best first, and a host already left out is not brought back" \
       "$([[ $(short "$(cut -f 1 "$work/h.spares" | tr '\n' ' ')") == "xm4 xm3 xslow1 xslow2 " && $(cut -f 2 "$work/h.spares" | head -1) == t6 ]] && echo 1 || echo 0)" \
       "$(cat "$work/h.spares")"

cp "$work/h0" "$work/h"
run excl_spares "$work/h" 6 "$work/m"
result "with one spare, the strongest-listed slow node takes it, and the other runs with a warning" \
       "$([[ $(short "$(lines "$work/h")") == "xm1 xslow1 xm2 xm3 xm4 xm5 xslow2" \
                    && $out == *"WARNING: slow nodes: no spares left for 1 listed node(s)"* && $out == *"caller carries on" ]] && echo 1 || echo 0)" "$out"

cp "$work/h0" "$work/h"
ABACUS_SLOW_NODES=off run excl_spares "$work/h" 5 "$work/m"
result "ABACUS_SLOW_NODES=off: the spares are the least over the need, a host lacking a result counting as none" \
       "$([[ $(short "$(lines "$work/h")") == "xm1 xslow1 xm2 xslow2 xm5 xm4 xm3" ]] && echo 1 || echo 0)" "$(short "$(lines "$work/h")")"
cp "$work/h0" "$work/h"
ABACUS_SLOW_NODES=off run excl_spares "$work/h" 4 "$work/m"
result "  ...then the next least" \
       "$([[ $(short "$(lines "$work/h")") == "xm1 xslow1 xslow2 xm5 xm2 xm4 xm3" ]] && echo 1 || echo 0)" "$(short "$(lines "$work/h")")"

cp "$work/h0" "$work/h"
margins xm1 ok 0.5 a xslow1 ok 0.9 b xm2 short -0.0100 "short as found" xm3 ok 0.3 d xslow2 ok 0.8 e xm4 ok 0.01 f xm5 ok 0.6 g > "$work/mc"
ABACUS_SLOW_NODES=off run excl_spares "$work/h" 6 "$work/mc"
result "a check's short host is the first spare" "$([[ $(short "$(tail -n 1 "$work/h")") == xm2 ]] && echo 1 || echo 0)" "$(short "$(lines "$work/h")")"

cp "$work/h0" "$work/h"
SLOW=$work/no-such-list run excl_spares "$work/h" 5
result "without margins or a slow list, the spares are the last hosts, best first" \
       "$([[ $(short "$(lines "$work/h")") == "xm1 xslow1 xm2 xm3 xslow2 xm4 xm5" && $out == *"xm5: last in the allocation"* ]] && echo 1 || echo 0)" "$out"

cp "$work/h0" "$work/h"
run excl_spares "$work/h" 7 "$work/m"
result "with no spares, the allocation is left alone" \
       "$([[ $rc == 0 && $(lines "$work/h") == "$(lines "$work/h0")" && ! -s $work/h.spares ]] && echo 1 || echo 0)" "$out"

# Many candidates and one spare: choosing must not end a set -euo pipefail caller.
for i in $(seq 1 2000); do printf 'xn%04d%s\n' "$i" "$dom"; done > "$work/h"
awk -v d="$dom" '{ printf "%s\tok\t%.4f\tt\n", $0, (NR % 97) / 100 }' "$work/h" > "$work/m"
run excl_spares "$work/h" 1999 "$work/m"
result "one spare from 2000 candidates, the caller carrying on" \
       "$([[ $rc == 0 && $out == *"caller carries on" && $(wc -l < "$work/h") == 2000 && $(wc -l < "$work/h.spares") == 1 ]] && echo 1 || echo 0)" \
       "rc=$rc, $(tail -n 3 <<< "$out")"

echo
(( fails == 0 )) && echo "All cases pass" || echo "$fails case(s) failed"
(( fails == 0 ))

#!/bin/bash
# test_badnodes.sh — exercise job/badnodes.sh without PBS: the switch, the tracked list's format, and
# leaving listed hosts out of an allocation as far as its spares allow, naming any that must run.
#
# Usage: job/test/badnodes/test_badnodes.sh
# Exits 0 if all cases pass, 1 otherwise.

set -uo pipefail

job=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/badnodes-test.XXXXXX") || exit 1
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

source "$job/badnodes.sh"

for pair in "unset on" "on on" "1 on" "off off" "OFF off" "no off"; do
    set -- $pair
    got=$(if [[ $1 == unset ]]; then unset ABACUS_BAD_NODES; else ABACUS_BAD_NODES=$1; fi; badnodes_mode 2>&1)
    result "ABACUS_BAD_NODES=$1 is $2" "$([[ $got == "$2" ]] && echo 1 || echo 0)" "got '$got'"
done
ABACUS_BAD_NODES=of badnodes_check_settings 2>/dev/null
result "a misspelt ABACUS_BAD_NODES is refused" "$(( $? != 0 ))"

# The tracked list: every entry a well-formed short host name with a reason, none twice.
mapfile -t listed < <(badnodes_list "$BADNODES_FILE")
ok=1
for l in "${listed[@]}"; do [[ $l =~ ^x[0-9]{4}c[0-9]s[0-9]b[0-9]n[0-9]\ .+ && $l != *" listed" ]] || ok=0; done
result "job/bad_nodes.txt: ${#listed[@]} entries, each a short host name with a reason" "$(( ok && ${#listed[@]} > 0 ))" \
       "$(printf '%s\n' "${listed[@]}")"
result "job/bad_nodes.txt names no host twice" \
       "$(( $(printf '%s\n' "${listed[@]}" | cut -d ' ' -f 1 | sort | uniq -d | wc -l) == 0 ))"

dom=.hsn.cm.aurora.alcf.anl.gov
cat > "$work/list" <<'EOF'
# a test list
xbad2   # second reason
        #   a continuation line, no host
xbad1   # first reason
xabsent # not in the allocation
EOF
hosts() { printf "%s$dom\n" "$@"; }
hosts xok1 xbad1 xok2 xbad2 xok3 > "$work/alloc"

# leave <ABACUS_BAD_NODES> <list> <required>: badnodes_leave_out, as multisim.pbs calls it, on a fresh
# copy of the allocation; sets out and rc.
leave() {
    cp "$work/alloc" "$work/h"
    out=$(ABACUS_BAD_NODES=$1 bash -c 'set -euo pipefail; source "$1/badnodes.sh"; BADNODES_FILE=$2
                                      badnodes_leave_out "$3" "$4"; echo "caller carries on"' \
              leave "$job" "$2" "$work/h" "$3" 2>&1)
    rc=$?
}
same() { [[ $(cat "$work/h") == "$(cat "$work/alloc")" && ! -s $work/h.bad ]]; }

leave on "$work/list" 3
result "with spares for all, every listed host is left out, the rest keep their order" \
       "$([[ $(cat "$work/h") == "$(hosts xok1 xok2 xok3)" ]] && echo 1 || echo 0)" "$(cat "$work/h")"
result "  ...listed in <hostfile>.bad in the list's order" \
       "$([[ $(cat "$work/h.bad") == "$(hosts xbad2 xbad1)" ]] && echo 1 || echo 0)" "$(cat "$work/h.bad")"
result "  ...each named with its reason, the caller carrying on" \
       "$([[ $rc == 0 && $out == *"leaving out 2 of the 2"*"  xbad2: second reason"*"  xbad1: first reason"*"caller carries on" && $out != *WARNING* ]] && echo 1 || echo 0)" \
       "$out"

leave on "$work/list" 4
result "with one spare, the earlier listed host is left out" \
       "$([[ $(cat "$work/h") == "$(hosts xok1 xbad1 xok2 xok3)" && $(cat "$work/h.bad") == "$(hosts xbad2)" ]] && echo 1 || echo 0)" \
       "$(cat "$work/h")"
result "  ...and the one that runs is named in a warning" \
       "$([[ $rc == 0 && $out == *"leaving out 1 of the 2"*"WARNING: bad nodes: no spares left for 1 listed node(s); they run:"*"  xbad1: first reason"*"caller carries on" ]] && echo 1 || echo 0)" \
       "$out"

leave on "$work/list" 5
result "with no spares, nothing is left out and both run with a warning" \
       "$(same && [[ $rc == 0 && $out != *"leaving out"* && $out == *"no spares left for 2"*"caller carries on" ]] && echo 1 || echo 0)" "$out"

printf 'xabsent  # not here\n' > "$work/list2"
leave on "$work/list2" 3
result "no listed host in the allocation leaves it alone" \
       "$(same && [[ $rc == 0 && $out == *"none of the 1"* ]] && echo 1 || echo 0)" "$out"
printf '# only comments\n\n' > "$work/list3"
leave on "$work/list3" 3
result "a list with no hosts leaves the allocation alone" "$(same && [[ $rc == 0 ]] && echo 1 || echo 0)" "$out"
leave off "$work/list" 3
result "ABACUS_BAD_NODES=off leaves the allocation alone" \
       "$(same && [[ $rc == 0 && $out == *"not applied"* ]] && echo 1 || echo 0)" "$out"
leave on "$work/no-such-list" 3
result "a missing list warns and leaves the allocation alone" \
       "$(same && [[ $rc == 0 && $out == *"WARNING: bad nodes"*"missing"* ]] && echo 1 || echo 0)" "$out"

echo
(( fails == 0 )) && echo "All cases pass" || echo "$fails case(s) failed"
(( fails == 0 ))

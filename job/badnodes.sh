#!/bin/bash
# Leaves the nodes listed in job/bad_nodes.txt out of the job, as many as the spares cover (README: Bad
# nodes).  Sourced by hashrun.sh, for the settings check, and by multisim.pbs.

BADNODES_FILE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bad_nodes.txt

# ABACUS_BAD_NODES as on (the default) or off.
badnodes_mode() {
    case ${ABACUS_BAD_NODES:-on} in
        [Oo][Nn]|1|[Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]) echo on ;;
        [Oo][Ff][Ff]|0|[Nn][Oo]|[Ff][Aa][Ll][Ss][Ee]) echo off ;;
        *) echo "ERROR: ABACUS_BAD_NODES='$ABACUS_BAD_NODES' (want on or off)" >&2; return 1 ;;
    esac
}

badnodes_check_settings() { badnodes_mode > /dev/null; }

# "<host> <why>" for each host in <file>: the first word of a line, with the comment after it.
badnodes_list() {  # <file>
    awk '{ line = $0; sub(/#.*/, "", line); n = split(line, w, " ") }
         n { why = $0; if (!sub(/^[^#]*#[ \t]*/, "", why)) why = "listed"; print w[1], why }' "$1"
}

# Leaves the hosts of <hostfile> listed in BADNODES_FILE out of it, in the list's order, while at least
# <required> remain, and lists them in <hostfile>.bad.  Any the spares cannot cover stay, named: they run.
badnodes_leave_out() {  # <hostfile> <required>
    local hostfile=$1 required=$2 list present n nout
    : > "$hostfile.bad"
    if [[ $(badnodes_mode 2>/dev/null) != on ]]; then
        echo "bad nodes: not applied (ABACUS_BAD_NODES=$ABACUS_BAD_NODES)"
        return 0
    fi
    if [[ ! -r $BADNODES_FILE ]]; then
        echo "WARNING: bad nodes: $BADNODES_FILE is missing; none are left out" >&2
        return 0
    fi
    list=$(badnodes_list "$BADNODES_FILE")
    [[ -n $list ]] || return 0
    # "<full host name> <short name> <why>" for each listed host in the allocation, in the list's order.
    present=$(awk 'NR == FNR { h = $0; sub(/\..*/, "", h); full[h] = $0; next } $1 in full { print full[$1], $0 }' \
                  "$hostfile" <(echo "$list"))
    if [[ -z $present ]]; then
        echo "bad nodes: none of the $(wc -l <<< "$list") in $BADNODES_FILE are in this allocation"
        return 0
    fi
    n=$(wc -l <<< "$present")
    nout=$(( $(wc -l < "$hostfile") - required ))
    (( nout < n )) || nout=$n
    (( nout > 0 )) || nout=0
    if (( nout > 0 )); then
        head -n "$nout" <<< "$present" | cut -d ' ' -f 1 > "$hostfile.bad"
        grep -v -x -F -f "$hostfile.bad" "$hostfile" > "$hostfile.tmp" && mv "$hostfile.tmp" "$hostfile"
        echo "bad nodes: leaving out $nout of the $n in this allocation (listed in $BADNODES_FILE):"
        head -n "$nout" <<< "$present" | cut -d ' ' -f 2- | awk '{ h = $1; $1 = ""; printf "  %s:%s\n", h, $0 }'
    fi
    if (( nout < n )); then
        echo "WARNING: bad nodes: no spares left for $(( n - nout )) listed node(s); they run:" >&2
        tail -n +"$(( nout + 1 ))" <<< "$present" | cut -d ' ' -f 2- | awk '{ h = $1; $1 = ""; printf "  %s:%s\n", h, $0 }' >&2
    fi
}

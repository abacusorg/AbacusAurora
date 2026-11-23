#!/bin/bash
# Which nodes of the allocation the sims run on, in the order README's Node exclusions gives.  Sourced by
# hashrun.sh, for the settings check, and by multisim.pbs.

EXCL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BADNODES_FILE=$EXCL_DIR/bad_nodes.txt
SLOWNODES_FILE=$EXCL_DIR/slow_nodes.txt

# on or off for the switch named <var>, on when unset.
excl_switch() {  # <var>
    local v=${!1:-on}
    case $v in
        [Oo][Nn]|1|[Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]) echo on ;;
        [Oo][Ff][Ff]|0|[Nn][Oo]|[Ff][Aa][Ll][Ss][Ee]) echo off ;;
        *) echo "ERROR: $1='$v' (want on or off)" >&2; return 1 ;;
    esac
}

excl_check_settings() {
    excl_switch ABACUS_BAD_NODES > /dev/null && excl_switch ABACUS_SLOW_NODES > /dev/null
}

# "<host> <why>" for each host in <file>: the first word of a line, with the comment after it.
excl_list() {  # <file>
    awk '{ line = $0; sub(/#.*/, "", line); n = split(line, w, " ") }
         n { why = $0; if (!sub(/^[^#]*#[ \t]*/, "", why)) why = "listed"; print w[1], why }' "$1"
}

# "<full host name> <short name> <why>" for each host of <list> in <hostfile>, in the list's order.
excl_present() {  # <hostfile> <list>
    awk 'NR == FNR { h = $0; sub(/\..*/, "", h); full[h] = $0; next } $1 in full { print full[$1], $0 }' \
        "$1" <(excl_list "$2")
}

# Removes the full host names in <drop> from <hostfile>, keeping the order of the rest.
excl_remove() {  # <hostfile> <drop>
    { grep -v -x -F -f "$2" "$1" || true; } > "$1.tmp" && mv "$1.tmp" "$1"
}

# 1. Leaves every host of <hostfile> listed in BADNODES_FILE out of it, into <hostfile>.bad, naming each.
excl_bad() {  # <hostfile>
    local hostfile=$1 present n
    : > "$hostfile.bad"
    if [[ $(excl_switch ABACUS_BAD_NODES 2>/dev/null) != on ]]; then
        echo "bad nodes: not applied (ABACUS_BAD_NODES=$ABACUS_BAD_NODES)"
        return 0
    fi
    if [[ ! -r $BADNODES_FILE ]]; then
        echo "WARNING: bad nodes: $BADNODES_FILE is missing; none are left out" >&2
        return 0
    fi
    present=$(excl_present "$hostfile" "$BADNODES_FILE")
    if [[ -z $present ]]; then
        echo "bad nodes: none of the $(excl_list "$BADNODES_FILE" | wc -l) in $BADNODES_FILE are in this allocation"
        return 0
    fi
    n=$(wc -l <<< "$present")
    cut -d ' ' -f 1 <<< "$present" > "$hostfile.bad"
    excl_remove "$hostfile" "$hostfile.bad"
    echo "bad nodes: leaving out the $n in this allocation (listed in $BADNODES_FILE):"
    cut -d ' ' -f 2- <<< "$present" | awk '{ h = $1; $1 = ""; printf "  %s:%s\n", h, $0 }'
}

# 2. Leaves every host <margins> (nodeprep_margins) calls short out of <hostfile>, into <hostfile>.short.
excl_short() {  # <hostfile> <margins>
    local hostfile=$1 margins=$2 n
    awk -F '\t' '$2 == "short" { print $1 }' "$margins" > "$hostfile.short"
    n=$(( $(wc -l < "$hostfile.short") ))
    (( n > 0 )) || return 0
    excl_remove "$hostfile" "$hostfile.short"
    echo "nodeprep: leaving out the $n node(s) still short of whole 2 MiB blocks:"
    awk -F '\t' '$2 == "short" { h = $1; sub(/\..*/, "", h); printf "  %s: %s\n", h, $4 }' "$margins"
}

# Returns 1, saying so, when fewer than <required> hosts remain in <hostfile> <after> what was left out.
excl_need() {  # <hostfile> <required> <after>
    local n
    n=$(( $(wc -l < "$1") ))
    (( n >= $2 )) && return 0
    echo "ERROR: $n node(s) remain $3, and the sims need $2; ask for more spares with -n" >&2
    return 1
}

# 3 and 4. Orders <hostfile> as the sims' <required> hosts, then the spares best first (with why, in
# <hostfile>.spares): the listed slow hosts, then the least over the need in <margins>, else the last.
excl_spares() {  # <hostfile> <required> [<margins>]
    local hostfile=$1 required=$2 margins=${3:-} nspare slow="" nslow=0 nrun order
    : > "$hostfile.spares"
    nspare=$(( $(wc -l < "$hostfile") - required ))
    (( nspare > 0 )) || return 0
    if [[ $(excl_switch ABACUS_SLOW_NODES 2>/dev/null) == on && -r $SLOWNODES_FILE ]]; then
        slow=$(excl_present "$hostfile" "$SLOWNODES_FILE")
        [[ -z $slow ]] || nslow=$(wc -l <<< "$slow")
    fi
    order=$(mktemp) || return 1
    # Candidates in the order they become spares; awk takes the first <nspare> still in <hostfile> and reads
    # to the end, since a reader that stops early would fail the caller's pipefail with SIGPIPE.
    {
        [[ -z $slow ]] || awk '{ h = $1; $1 = $2 = ""; sub(/^ +/, ""); printf "%s\tslow: %s\n", h, $0 }' <<< "$slow"
        if [[ -n $margins && -s $margins ]]; then
            awk -F '\t' '{ m = $3 == "-" ? 0 : $3 + 0; if ($2 == "unknown" && m > 0) m = 0
                           printf "%.6f\t%d\t%s\t%s\n", m, NR, $1, $4 }' "$margins" \
                | sort -t $'\t' -k1,1g -k2,2n | cut -f 3-
        else
            tac "$hostfile" | awk '{ printf "%s\tlast in the allocation\n", $0 }'
        fi
    } | awk -F '\t' -v n="$nspare" 'NR == FNR { here[$0] = 1; next }
                                    ($1 in here) && !seen[$1]++ && c < n { print; c++ }' "$hostfile" - > "$order"
    tac "$order" > "$hostfile.spares"
    cut -f 1 "$order" > "$order.hosts"
    excl_remove "$hostfile" "$order.hosts"
    cut -f 1 "$hostfile.spares" >> "$hostfile"
    echo "spares: $nspare, the listed slow nodes first, then the least memory in whole blocks over the need:"
    awk -F '\t' '{ h = $1; sub(/\..*/, "", h); printf "  %s: %s\n", h, $2 }' "$order"
    nrun=$(( nslow - $(awk -F '\t' '$2 ~ /^slow: / { c++ } END { print c + 0 }' "$order") ))
    if (( nrun > 0 )); then
        echo "WARNING: slow nodes: no spares left for $nrun listed node(s) in this allocation; they run" >&2
    fi
    rm -f "$order" "$order.hosts"
}

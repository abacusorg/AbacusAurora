#!/bin/bash
# Builds and runs nodeprep (nodeprep.cpp) for the job scripts: hashrun.sh builds it into the job's
# staged inputs at submit, and multisim.pbs runs it on every node before the sims.

NODEPREP_SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/nodeprep.cpp

# What a DDR socket and an HBM node must have in whole 2 MiB blocks after the pass (or as found, under
# ABACUS_NODEPREP=check), in GiB: in job 9048965 a rank took about 300 and 55.  0 turns a check off.
nodeprep_need_ddr() { echo "${ABACUS_NODEPREP_NEED_DDR_GIB:-330}"; }
nodeprep_need_hbm() { echo "${ABACUS_NODEPREP_NEED_HBM_GIB:-58}"; }

# ABACUS_NODEPREP as reclaim (on, the default), check (measure each node, change nothing) or off.
nodeprep_mode() {
    case ${ABACUS_NODEPREP:-on} in
        [Cc][Hh][Ee][Cc][Kk]) echo check ;;
        [Oo][Nn]|1|[Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]) echo reclaim ;;
        [Oo][Ff][Ff]|0|[Nn][Oo]|[Ff][Aa][Ll][Ss][Ee]) echo off ;;
        *) echo "ERROR: ABACUS_NODEPREP='$ABACUS_NODEPREP' (want on, check or off)" >&2; return 1 ;;
    esac
}

# The system compiler: the binary then needs only the node image's libstdc++, whatever modules
# are loaded when it is built or run.
nodeprep_build() {  # <binary>
    /usr/bin/g++ -O2 -pthread -Wall -o "$1" "$NODEPREP_SRC"
}

# One pass on every node of <hostfile> at once, --reclaim unless nodeprep_mode says check, with every
# NUMA node's numbers in <log>.  Never fatal: if it fails, the sims start on the nodes as they were.
nodeprep_run() {  # <binary> <hostfile> <log>
    local bin=$1 hostfile=$2 log=$3 n rc=0 t0=$SECONDS nfail mode args=() what=""
    mode=$(nodeprep_mode) || mode=reclaim
    [[ $mode != off ]] || return 0
    if [[ $mode == reclaim ]]; then
        args=(--reclaim --need-gib "$(nodeprep_need_ddr)")
    else
        what="measured (ABACUS_NODEPREP=check: nothing reclaimed) "
    fi
    if [[ ! -x $bin ]]; then
        echo "WARNING: nodeprep: $bin is missing; the sims start on the nodes as they were" >&2
        return 0
    fi
    n=$(( $(wc -l < "$hostfile") ))
    # nodeprep pins its own threads to each socket's CPUs and uses no network.  Its two fill
    # phases stop themselves after 120 s each; the timeout bounds a launch that hangs.
    # A fill that overshoots is meant to die (oom_score_adj 1000): nodeprep reports that pass as
    # "failed:" and carries on, and should a whole rank die, that must not end the rest.
    timeout -k 30 600 mpiexec -n "$n" --ppn 1 --cpu-bind none --no-vni --no-abort-on-failure \
        --hostfile "$hostfile" "$bin" ${args[@]+"${args[@]}"} > "$log" 2>&1 || rc=$?
    echo "nodeprep: $n node(s) ${what}in $(( SECONDS - t0 )) s (rc=$rc); every NUMA node's numbers are in $log"
    local failed='(: rank [0-9]+ (died from signal|exited with code))|( (mem)?node [0-9]+ failed: )'
    nfail=$(grep -c -E "$failed" "$log" 2>/dev/null) || true
    if (( nfail > 0 )); then
        echo "WARNING: nodeprep failed $nfail time(s); those start as they were (signal 9: likely the OOM killer):" >&2
        grep -E "$failed" "$log" | head -n 5 | sed 's/^/  /' >&2
    elif (( rc != 0 )); then
        echo "WARNING: nodeprep's launch failed (rc=$rc); nodes it had not reached start as they were" >&2
    fi
    nodeprep_report "$log"
}

# Free memory in whole 2 MiB blocks, in GiB, before and after the pass (each node's first "before:" and
# last "after:" line), or as a check found it ("<host> node <n>: ..."): the five with the fewest and the
# median, for the DDR sockets ("node" lines) and then for the memory-only HBM nodes ("memnode" lines).
nodeprep_report() {  # <log>
    local kind rows found=0 checked
    for kind in node memnode; do
        rows=$(awk -v kind="$kind" '$2 == kind {
                    if ($3 ~ /^[0-9]+:$/) { k = $1 " " $2 " " substr($3, 1, length($3) - 1); ph = "found" }
                    else if ($4 == "before:" || $4 == "after:") { k = $1 " " $2 " " $3; ph = $4 }
                    else next
                    for (i = 4; i < NF; i++) if ($i == "blocks") v = $(i + 1) + 0
                    if (ph != "before:") after[k] = v
                    else if (!(k in before)) before[k] = v
                }
                END { for (k in after) print after[k], (k in before ? before[k] : "-"), k }' "$1" 2>/dev/null | sort -n) || true
        [[ -n $rows ]] || continue
        found=1
        checked=0
        [[ $(head -n 1 <<< "$rows" | cut -d ' ' -f 2) == - ]] && checked=1
        if [[ $kind == memnode ]]; then
            echo "nodeprep: the same for the memory-only (HBM) nodes:"
        elif (( checked )); then
            echo "nodeprep: free memory in whole 2 MiB blocks (GiB), fewest first:"
        else
            echo "nodeprep: free memory in whole 2 MiB blocks (GiB), before -> after, fewest after first:"
        fi
        head -n 5 <<< "$rows" | awk '$2 == "-" { printf "  %s %s %s  %6.1f\n", $3, $4, $5, $1; next }
                                     { printf "  %s %s %s  %6.1f -> %6.1f\n", $3, $4, $5, $2, $1 }'
        awk -v unit="$([[ $kind == node ]] && echo socket || echo node)" -v what="$( (( checked )) && echo median || echo 'median after')" \
            '{ a[NR] = $1 } END { printf "  %s: %.1f over %d %s(s)\n", what, a[int((NR + 1) / 2)], NR, unit }' <<< "$rows"
    done
    (( found )) || echo "WARNING: nodeprep: no per-node results in $1" >&2
}

# Moves the hosts of <hostfile> that ended the pass, or a check, short of whole 2 MiB blocks
# (nodeprep_need_*), or with no result in <log>, behind the rest, the least short first: the sims then
# take them only when the spares past <required> run out.  Names each; lists them in <hostfile>.short.
nodeprep_demote() {  # <hostfile> <log> <required>
    local hostfile=$1 log=$2 required=$3 good short nshort nspare nrun
    : > "$hostfile.short"
    grep -q -E ' (mem)?node [0-9]+(:| after:) ' "$log" 2>/dev/null || return 0
    good=$(mktemp) && short=$(mktemp) || return 0
    awk -v need_ddr="$(nodeprep_need_ddr)" -v need_hbm="$(nodeprep_need_hbm)" -v good="$good" '
        FNR == NR {
            if ($2 != "node" && $2 != "memnode") next
            if ($3 ~ /^[0-9]+:$/) k = $1 " " $2 " " substr($3, 1, length($3) - 1)
            else if ($4 == "after:") k = $1 " " $2 " " $3
            else next
            for (i = 4; i < NF; i++) if ($i == "blocks") v = $(i + 1) + 0
            after[k] = v
            seen[$1] = 1
            next
        }
        FNR == 1 {
            for (k in after) {
                split(k, f, " ")
                need = f[2] == "memnode" ? need_hbm : need_ddr
                if (after[k] >= need) continue
                if (!(f[1] in ratio) || after[k] / need < ratio[f[1]]) ratio[f[1]] = after[k] / need
                why[f[1]] = why[f[1]] sprintf(", %s %s has %.1f GiB and needs %g", f[2], f[3], after[k], need)
            }
        }
        {
            h = $0
            sub(/\..*/, "", h)
            if (h in ratio) printf "%.6f\t%d\t%s\t%s\n", ratio[h], FNR, $0, substr(why[h], 3)
            else if (!(h in seen)) printf "1\t%d\t%s\tno nodeprep result\n", FNR, $0
            else print > good
        }' "$log" "$hostfile" | sort -t $'\t' -k1,1gr -k2,2n > "$short" || : > "$short"
    nshort=$(( $(wc -l < "$short") ))
    if (( nshort > 0 )); then
        cut -f3 "$short" > "$hostfile.short"
        cat "$good" "$hostfile.short" > "$hostfile"
        nspare=$(( $(wc -l < "$hostfile") - required ))
        nrun=$(( nshort > nspare ? nshort - nspare : 0 ))
        echo "nodeprep: $nshort node(s) are short of whole 2 MiB blocks; with $nspare spare(s), $nrun of them run:"
        awk -F '\t' -v nrun="$nrun" '{ h = $3; sub(/\..*/, "", h); printf "  %s: %s%s\n", h, $4, NR <= nrun ? " (runs)" : "" }' "$short"
        (( nrun == 0 )) || echo "WARNING: nodeprep: $nrun node(s) short of whole 2 MiB blocks run for want of spares" >&2
    fi
    rm -f "$good" "$short"
}

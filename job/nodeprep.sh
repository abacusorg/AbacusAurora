#!/bin/bash
# Builds and runs nodeprep (nodeprep.cpp) for the job scripts: hashrun.sh builds it into the job's
# staged inputs at submit, and multisim.pbs runs it on every node before the sims.

NODEPREP_SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/nodeprep.cpp

# What a DDR socket and an HBM node must have in whole 2 MiB blocks after the pass, in GiB, to hold a
# rank of Flagship load: in job 9048965 a rank took about 300 and 55.  0 turns a check off.
nodeprep_need_ddr() { echo "${ABACUS_NODEPREP_NEED_DDR_GIB:-330}"; }
nodeprep_need_hbm() { echo "${ABACUS_NODEPREP_NEED_HBM_GIB:-58}"; }

# The system compiler: the binary then needs only the node image's libstdc++, whatever modules
# are loaded when it is built or run.
nodeprep_build() {  # <binary>
    /usr/bin/g++ -O2 -pthread -Wall -o "$1" "$NODEPREP_SRC"
}

# One --reclaim pass on every node of <hostfile> at once, with every NUMA node's numbers in <log>.
# Never fatal: if it fails, the sims start on the nodes as they were.
nodeprep_run() {  # <binary> <hostfile> <log>
    local bin=$1 hostfile=$2 log=$3 n rc=0 t0=$SECONDS nfail
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
        --hostfile "$hostfile" "$bin" --reclaim --need-gib "$(nodeprep_need_ddr)" > "$log" 2>&1 || rc=$?
    echo "nodeprep: $n node(s) in $(( SECONDS - t0 )) s (rc=$rc); every NUMA node's numbers are in $log"
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

# Free memory in whole 2 MiB blocks before and after the pass, in GiB, from nodeprep's first "before:"
# and last "after:" line for each: the five with the fewest after it and the median, for the DDR
# sockets ("node" lines) and then for the memory-only HBM nodes ("memnode" lines).
nodeprep_report() {  # <log>
    local kind rows found=0
    for kind in node memnode; do
        rows=$(awk -v kind="$kind" '$2 == kind && ($4 == "before:" || $4 == "after:") {
                    for (i = 5; i < NF; i++) if ($i == "blocks") v = $(i + 1) + 0
                    k = $1 " " $2 " " $3
                    if ($4 == "after:") after[k] = v; else if (!(k in before)) before[k] = v
                }
                END { for (k in after) print after[k], before[k], k }' "$1" 2>/dev/null | sort -n) || true
        [[ -n $rows ]] || continue
        found=1
        if [[ $kind == node ]]; then
            echo "nodeprep: free memory in whole 2 MiB blocks (GiB), before -> after, fewest after first:"
        else
            echo "nodeprep: the same for the memory-only (HBM) nodes:"
        fi
        head -n 5 <<< "$rows" | awk '{ printf "  %s %s %s  %6.1f -> %6.1f\n", $3, $4, $5, $2, $1 }'
        awk -v unit="$([[ $kind == node ]] && echo socket || echo node)" '{ a[NR] = $1 }
            END { printf "  median after: %.1f over %d %s(s)\n", a[int((NR + 1) / 2)], NR, unit }' <<< "$rows"
    done
    (( found )) || echo "WARNING: nodeprep: no per-node results in $1" >&2
}

# Moves the hosts of <hostfile> that ended the pass short of whole 2 MiB blocks (nodeprep_need_*), or
# with no result in <log>, behind the rest, the least short first: the sims then take them only when
# the spares past <required> run out.  Names each with its reason; lists them in <hostfile>.short.
nodeprep_demote() {  # <hostfile> <log> <required>
    local hostfile=$1 log=$2 required=$3 good short nshort nspare nrun
    : > "$hostfile.short"
    grep -q -E ' (mem)?node [0-9]+ after: ' "$log" 2>/dev/null || return 0
    good=$(mktemp) && short=$(mktemp) || return 0
    awk -v need_ddr="$(nodeprep_need_ddr)" -v need_hbm="$(nodeprep_need_hbm)" -v good="$good" '
        FNR == NR {
            if ($4 != "after:") next
            for (i = 5; i < NF; i++) if ($i == "blocks") v = $(i + 1) + 0
            after[$1 " " $2 " " $3] = v
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

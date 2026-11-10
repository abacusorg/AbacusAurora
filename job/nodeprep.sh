#!/bin/bash
# Builds and runs nodeprep (nodeprep.cpp) for the job scripts: hashrun.sh builds it into the job's
# staged inputs at submit, and multisim.pbs runs it on every node before the sims.

NODEPREP_SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/nodeprep.cpp

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
        --hostfile "$hostfile" "$bin" --reclaim > "$log" 2>&1 || rc=$?
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

# Free memory in whole 2 MiB blocks before and after the pass, in GiB, from nodeprep's "before:" and
# "after:" lines: the five with the fewest after it and the median, for the DDR sockets ("node"
# lines) and then for the memory-only HBM nodes ("memnode" lines).
nodeprep_report() {  # <log>
    local kind rows found=0
    for kind in node memnode; do
        rows=$(awk -v kind="$kind" '$2 == kind && ($4 == "before:" || $4 == "after:") {
                    for (i = 5; i < NF; i++) if ($i == "blocks") v = $(i + 1) + 0
                    k = $1 " " $2 " " $3
                    if ($4 == "before:") before[k] = v; else after[k] = v
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

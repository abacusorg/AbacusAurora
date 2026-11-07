#!/bin/bash
# Builds and runs nodeprep (nodeprep.cpp) for the job scripts: hashrun.sh builds it into the job's
# staged inputs at submit, and multisim.pbs runs it on every node before the sims.

NODEPREP_SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/nodeprep.cpp

# The system compiler: the binary then needs only the node image's libstdc++, whatever modules
# are loaded when it is built or run.
nodeprep_build() {  # <binary>
    /usr/bin/g++ -O2 -pthread -Wall -o "$1" "$NODEPREP_SRC"
}

# One --reclaim pass on every node of <hostfile> at once, with every socket's numbers in <log>.
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
    # A fill that overshoots is meant to die (oom_score_adj 1000), so one node's death must not end the rest.
    timeout -k 30 600 mpiexec -n "$n" --ppn 1 --cpu-bind none --no-vni --no-abort-on-failure \
        --hostfile "$hostfile" "$bin" --reclaim > "$log" 2>&1 || rc=$?
    echo "nodeprep: $n node(s) in $(( SECONDS - t0 )) s (rc=$rc); every socket's numbers are in $log"
    nfail=$(grep -c -E ': rank [0-9]+ (died from signal|exited with code)' "$log" 2>/dev/null) || true
    if (( nfail > 0 )); then
        echo "WARNING: nodeprep failed on $nfail node(s), which start as they were (signal 9: likely the OOM killer):" >&2
        grep -E ': rank [0-9]+ (died from signal|exited with code)' "$log" | head -n 5 | sed 's/^/  /' >&2
    elif (( rc != 0 )); then
        echo "WARNING: nodeprep's launch failed (rc=$rc); nodes it had not reached start as they were" >&2
    fi
    nodeprep_report "$log"
}

# Each DDR socket's free memory in whole 2 MiB blocks before and after the pass, in GiB, from
# nodeprep's "before:" and "after:" lines: the five sockets with the fewest after it, and the median.
nodeprep_report() {  # <log>
    local rows
    rows=$(awk '$4 == "before:" || $4 == "after:" {
                    for (i = 5; i < NF; i++) if ($i == "blocks") v = $(i + 1) + 0
                    k = $1 " " $3
                    if ($4 == "before:") before[k] = v; else after[k] = v
                }
                END { for (k in after) print after[k], before[k], k }' "$1" 2>/dev/null | sort -n) || true
    if [[ -z $rows ]]; then
        echo "WARNING: nodeprep: no per-socket results in $1" >&2
        return 0
    fi
    echo "nodeprep: free memory in whole 2 MiB blocks (GiB), before -> after, fewest after first:"
    head -n 5 <<< "$rows" | awk '{ printf "  %s node %s  %6.1f -> %6.1f\n", $3, $4, $2, $1 }'
    awk '{ a[NR] = $1 } END { printf "  median after: %.1f over %d socket(s)\n", a[int((NR + 1) / 2)], NR }' <<< "$rows"
}

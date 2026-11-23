#!/bin/bash
# Builds and runs nodeprep (nodeprep.cpp) for the job scripts: hashrun.sh builds it into the job's
# staged inputs at submit, and multisim.pbs runs it on every node before the sims.

NODEPREP_SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/nodeprep.cpp

# What a DDR socket and an HBM node must have in whole 2 MiB blocks after the pass (or as found, under
# ABACUS_NODEPREP=check), in GiB: a rank took ~300 of DDR (job 9048965), and HBM fills to 64 less HBMReserveGB.  0 turns a check off.
nodeprep_need_ddr() { echo "${ABACUS_NODEPREP_NEED_DDR_GIB:-330}"; }
nodeprep_need_hbm() { echo "${ABACUS_NODEPREP_NEED_HBM_GIB:-60}"; }

# ABACUS_NODEPREP as reclaim (on, the default), check (measure each node, change nothing) or off.
nodeprep_mode() {
    case ${ABACUS_NODEPREP:-on} in
        [Cc][Hh][Ee][Cc][Kk]) echo check ;;
        [Oo][Nn]|1|[Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]) echo reclaim ;;
        [Oo][Ff][Ff]|0|[Nn][Oo]|[Ff][Aa][Ll][Ss][Ee]) echo off ;;
        *) echo "ERROR: ABACUS_NODEPREP='$ABACUS_NODEPREP' (want on, check or off)" >&2; return 1 ;;
    esac
}

# The ABACUS_NODEPREP* settings, checked together: prints what is wrong and returns 1.
nodeprep_check_settings() {
    nodeprep_mode > /dev/null || return 1
    if [[ -n ${ABACUS_NODEPREP_FAIL_SHORT+set} ]]; then
        echo "ERROR: ABACUS_NODEPREP_FAIL_SHORT is gone: a node short after node prep is always left out, and the job" \
             "ends if too few remain (README: Node exclusions)" >&2
        return 1
    fi
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

# Per host of <hostfile>, tab-separated: host, state (short; unknown: no result for a NUMA node most hosts
# report; ok), the least (GiB - need)/need over its NUMA nodes, why.  Returns 1 if <log> has no results.
nodeprep_margins() {  # <log> <hostfile>
    grep -q -E ' (mem)?node [0-9]+(:| after:) ' "$1" 2>/dev/null || return 1
    awk -v need_ddr="$(nodeprep_need_ddr)" -v need_hbm="$(nodeprep_need_hbm)" '
        function kless(a, b,   x, y) {
            split(a, x, " "); split(b, y, " ")
            if (x[1] != y[1]) return x[1] == "node"
            return x[2] + 0 < y[2] + 0
        }
        FNR == NR {
            if ($2 != "node" && $2 != "memnode") next
            if ($3 ~ /^[0-9]+:$/) n = substr($3, 1, length($3) - 1)
            else if ($4 == "after:") n = $3
            else next
            k = $2 " " n
            for (i = 4; i < NF; i++) if ($i == "blocks") v = $(i + 1) + 0
            if (!(($1, k) in after)) nkey[k]++
            after[$1, k] = v
            hosts[$1] = 1
            next
        }
        FNR == 1 {
            # The NUMA nodes in a fixed order (DDR sockets, then HBM, each by number), and those most hosts report.
            for (k in nkey) keys[++nk] = k
            for (i = 2; i <= nk; i++)
                for (j = i; j > 1 && kless(keys[j], keys[j - 1]); j--) { t = keys[j]; keys[j] = keys[j - 1]; keys[j - 1] = t }
            for (h in hosts) nh++
            for (k in nkey) if (2 * nkey[k] >= nh) expect[k] = 1
        }
        {
            h = $0
            sub(/\..*/, "", h)
            if (!(h in hosts)) { printf "%s\tunknown\t-\tno nodeprep result\n", $0; next }
            short = missing = tight = ""
            m = "-"
            for (i = 1; i <= nk; i++) {
                k = keys[i]
                if (!((h, k) in after)) { if (k in expect) missing = missing ", " k; continue }
                need = k ~ /^memnode/ ? need_hbm : need_ddr
                if (need <= 0) continue
                v = after[h, k]
                if (v < need) short = short sprintf(", %s has %.1f GiB and needs %g", k, v, need)
                r = (v - need) / need
                if (m == "-" || r < m) { m = r; tight = sprintf("tightest: %s has %.1f GiB of the %g needed", k, v, need) }
            }
            ms = m == "-" ? "-" : sprintf("%.4f", m)
            if (short != "") printf "%s\tshort\t%s\t%s\n", $0, ms, substr(short, 3)
            else if (missing != "") printf "%s\tunknown\t%s\tno result for %s%s\n", $0, ms, substr(missing, 3), tight == "" ? "" : "; " tight
            else printf "%s\tok\t%s\t%s\n", $0, ms, tight == "" ? "no need set" : tight
        }' "$1" "$2"
}

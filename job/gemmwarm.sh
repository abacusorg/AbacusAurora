#!/bin/bash
# At the end of a job, reads the files the PBS prologue's gemm.exe test loads, on every node, so the next
# job's prologue finds them cached (README: Prologue warm-up).  Sourced by multisim.pbs; run per node.

GEMMWARM_SCRIPT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")

# ABACUS_GEMM_WARMUP as on (the default) or off.
gemmwarm_mode() {
    case ${ABACUS_GEMM_WARMUP:-on} in
        [Oo][Nn]|1|[Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]) echo on ;;
        [Oo][Ff][Ff]|0|[Nn][Oo]|[Ff][Aa][Ll][Ss][Ee]) echo off ;;
        *) echo "ERROR: ABACUS_GEMM_WARMUP='$ABACUS_GEMM_WARMUP' (want on or off)" >&2; return 1 ;;
    esac
}

# Whole seconds between the warm-ups of two of our nodes in one rack.
gemmwarm_stagger() { echo "${ABACUS_GEMM_WARMUP_STAGGER:-2}"; }

# The ABACUS_GEMM_WARMUP* switches, checked at the start of the job: prints what is wrong and returns 1.
gemmwarm_check_settings() {
    gemmwarm_mode > /dev/null || return 1
    if [[ ! $(gemmwarm_stagger) =~ ^[0-9]+$ ]]; then
        echo "ERROR: ABACUS_GEMM_WARMUP_STAGGER='$ABACUS_GEMM_WARMUP_STAGGER' (want whole seconds)" >&2
        return 1
    fi
}

# <host>'s place, from 0, among the hosts of <hostfile> in its rack: x<rack>c<chassis>s<slot>b<blade>n<node>.
gemmwarm_rack_rank() {  # <hostfile> <host>
    local host=${2%%.*} i
    i=$(sed 's/\..*//' "$1" | grep "^${host%%c*}c" | sort -u | grep -n -x -F "$host" | cut -d: -f1)
    echo $(( ${i:-1} - 1 ))
}

# <gemm.exe> and what it loads: its libraries as ldd resolves them in the prologue's bare environment,
# and the Level Zero adapters that the SYCL runtime dlopens from libsycl's directory.
gemmwarm_files() {  # <gemm.exe>
    local libs sycl
    libs=$(env -i PATH=/usr/bin:/bin ldd "$1" 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i ~ /^\//) print $i}')
    sycl=$(grep -m1 '/libsycl\.so' <<<"$libs")
    {
        echo "$1"
        echo "$libs"
        if [[ -n $sycl ]]; then compgen -G "$(dirname "$sycl")/libur_adapter_level_zero*.so*" || true; fi
    } | grep . | xargs -r readlink -f | sort -u
}

# Bytes this node has read from /pe's NFS server: the server-read counter in mountstats' "bytes:" line.
gemmwarm_pe_bytes() {
    awk '$1 == "device" {m = ($5 == "/pe")} m && $1 == "bytes:" {print $6; exit}' /proc/self/mountstats 2>/dev/null
}

# One node's warm-up: wait for its turn in the rack, then read every file once, and print one line.
# GEMMWARM_BIN replaces the prologue's gemm.exe (for the tests).
gemmwarm_node() {  # <hostfile> <stagger_s>
    local gemm=${GEMMWARM_BIN:-/opt/aurora/default/support/tools/node-test/gemm.exe}
    local host rank files b0 b1 t0 rc server mib sent
    host=$(hostname -s)
    if [[ ! -x $gemm ]]; then
        echo "$host gemmwarm: skipped, no $gemm"
        return 0
    fi
    rank=$(gemmwarm_rack_rank "$1" "$host")
    sleep $(( rank * $2 ))
    mapfile -t files < <(gemmwarm_files "$gemm")
    b0=$(gemmwarm_pe_bytes)
    t0=$(date +%s.%N)
    timeout 60 cat "${files[@]}" > /dev/null
    rc=$?
    t0=$(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN {printf "%.1f", b - a}')
    b1=$(gemmwarm_pe_bytes)
    mib=$(stat -L -c %s "${files[@]}" 2>/dev/null | awk '{s += $1} END {printf "%.0f", s / 1048576}')
    sent=n/a
    [[ $b0 =~ ^[0-9]+$ && $b1 =~ ^[0-9]+$ ]] && sent=$(awk -v a="$b0" -v b="$b1" 'BEGIN {printf "%.1f", (b - a) / 1048576}')
    server=$(findmnt -n -o SOURCE /pe 2>/dev/null)
    echo "$host gemmwarm: rack place $rank, waited $(( rank * $2 )) s; read ${#files[@]} files, $mib MiB, in $t0 s (rc=$rc);" \
         "/pe server ${server%%:*} sent $sent MiB"
}

# The warm-up on every node of <hostfile>, each rack's nodes ABACUS_GEMM_WARMUP_STAGGER s apart, with
# one line per node in <log>.  Never fatal: it only spares the next job's prologue.
gemmwarm_run() {  # <hostfile> <log>
    local hostfile log=$2 n stagger per_rack rc=0 t0=$SECONDS
    if [[ $(gemmwarm_mode 2>/dev/null) != on ]]; then
        echo "gemm warm-up: off (ABACUS_GEMM_WARMUP=$ABACUS_GEMM_WARMUP)"
        return 0
    fi
    hostfile=$(readlink -f "$1")
    stagger=$(gemmwarm_stagger)
    n=$(( $(wc -l < "$hostfile") ))
    per_rack=$(sed 's/\..*//; s/c[0-9].*//' "$hostfile" | sort | uniq -c | awk '$1 > m {m = $1} END {print m + 0}')
    # The ranks are bash, which uses no network; the timeout bounds a launch that hangs.
    timeout -k 30 $(( per_rack * stagger + 180 )) mpiexec -n "$n" --ppn 1 --cpu-bind none --no-vni --no-abort-on-failure \
        --hostfile "$hostfile" bash "$GEMMWARM_SCRIPT" node "$hostfile" "$stagger" > "$log" 2>&1 || rc=$?
    awk -v n="$n" -v rc="$rc" -v s=$(( SECONDS - t0 )) -v lf="$log" '
        / gemmwarm: / { k++ }
        / gemmwarm: skipped/ { skip++ }
        /\(rc=[1-9][0-9]*\)/ { bad++ }
        match($0, /sent [0-9.]+ MiB/) { split(substr($0, RSTART, RLENGTH), a, " "); mib += a[2] }
        match($0, /, in [0-9.]+ s/) { split(substr($0, RSTART, RLENGTH), a, " "); if (a[3] + 0 > slow) slow = a[3] + 0 }
        END { printf "gemm warm-up: %d of %d node(s) reported in %d s (rc=%d): %.0f MiB from /pe, slowest read %.1f s, " \
                     "%d read(s) failed, %d skipped; every node is in %s\n", k, n, s, rc, mib, slow, bad, skip, lf }' "$log"
    return 0
}

if [[ ${BASH_SOURCE[0]} == "$0" && ${1:-} == node ]]; then
    shift
    gemmwarm_node "$@"
    exit 0
fi

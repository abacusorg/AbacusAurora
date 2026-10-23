#!/bin/bash
# Per-rank profiler launcher, chained after stderr-filter.sh in exec_prefix:
#   prof-wrap.sh [--tau] [--vtune RANK=ANALYSIS,...] [--perf RANK=MODE,...] [--paused]
#                --out DIR -- multistep ARGS...
# --tau profiles MPI calls on every rank.  --vtune runs one VTune analysis on each listed
# rank (hotspots means hardware sampling without stacks).  --perf runs perf record on each
# listed rank, MODE lbr (hardware call stacks) or flat.  Keep VTune and perf on different
# nodes: VTune's sampling driver takes the whole node's PMU.  Ranks with no tool exec the
# command untouched.
# --paused starts VTune and perf paused, for runs whose ProfileStartStep/ProfileStartSeconds
# window resumes them; TAU needs no flag, since multistep switches it off at startup itself.
set -u

tau=0 vtune_spec="" perf_spec="" paused=() out=""
while (( $# )); do
    case $1 in
        --tau) tau=1; shift ;;
        --vtune) vtune_spec=$2; shift 2 ;;
        --perf) perf_spec=$2; shift 2 ;;
        --paused) paused=(-start-paused); shift ;;
        --out) out=$2; shift 2 ;;
        --) shift; break ;;
        *) echo "prof-wrap: unknown option $1" >&2; exit 2 ;;
    esac
done
rank=${PALS_RANKID:?prof-wrap: PALS_RANKID not set}
cmd=("$@")

# This rank's entry in a RANK=VALUE,... list, or empty.
entry_for_rank() {
    local p pairs
    IFS=, read -r -a pairs <<< "$1"
    for p in ${pairs[@]+"${pairs[@]}"}; do
        [[ ${p%%=*} == "$rank" ]] && { echo "${p#*=}"; return; }
    done
}
perf_mode=$(entry_for_rank "$perf_spec")
analysis=$(entry_for_rank "$vtune_spec")
(( tau )) || [[ -n $perf_mode || -n $analysis ]] || exec "${cmd[@]}"

mkdir -p "$out"
# multistep writes its thread names here when the profiling window opens.
export ABACUS_PROFILE_DIR=$out
{
    echo "host $(hostname)"
    echo "perf_event_paranoid $(cat /proc/sys/kernel/perf_event_paranoid)"
    echo "kptr_restrict $(cat /proc/sys/kernel/kptr_restrict)"
    echo "vtune_drivers $(lsmod 2>/dev/null | awk '/^(sep|socperf|vtsspp|pax)/ {print $1}' | tr '\n' ' ')"
    echo "LD_PRELOAD ${LD_PRELOAD:-}"
    chronyc tracking 2>&1   # how well this node's clock agrees, for MPITimeline
} > "$out/node.r$rank.txt"

if (( tau )); then
    export TAU_DIR=/soft/perftools/tau/tau-2.35.2/x86_64
    export PATH=$TAU_DIR/bin:$PATH   # tau_exec calls tau-config
    # The TAU module would also prepend an older MPICH; take only the PAPI it needs.
    export LD_LIBRARY_PATH=/opt/aurora/26.181.0/spack/unified/1.1.1/install/linux-x86_64/papi-7.2.0-otce6vj/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
    export TAU_TRACE=1 TAU_TRACE_FORMAT=otf2 TAU_TRACK_MESSAGE=1 TAU_SYNCHRONIZE_CLOCKS=1
    export TAU_PROFILE=1 TAU_COMM_MATRIX=1
    export TRACEDIR=$out/tau PROFILEDIR=$out/tau
    # libTAU exports ompt_start_tool, which would turn on OpenMP tracking unasked.
    export OMP_TOOL=disabled
    mkdir -p "$out/tau"
    cmd=("$TAU_DIR/bin/tau_exec" -T mpi -- "${cmd[@]}")
fi

# vtune's own processes load its bundled libssl, which is too old for the DAOS client that
# libpil4dfs starts; keep the preload off the profiler and give it back to the application.
preload_app_only() {
    local app_preload=${LD_PRELOAD:-}
    unset LD_PRELOAD
    cmd=(bash -c '[[ -n $1 ]] && export LD_PRELOAD=${LD_PRELOAD:+$LD_PRELOAD:}$1; shift; exec "$@"'
         bash "$app_preload" "${cmd[@]}")
}

if [[ -n $perf_mode ]]; then
    perf=/home/lgarrison/opt/perf/bin/perf
    mkdir -p "$out/perf"
    case $perf_mode in
        lbr) rec=(--call-graph lbr -F 500) ;;
        flat) rec=(-F 1000) ;;
        *) echo "prof-wrap: unknown perf mode $perf_mode" >&2; exit 2 ;;
    esac
    if (( ${#paused[@]} )); then
        # -D -1 starts with events off; multistep's profiling window writes enable/disable
        # into this FIFO (ABACUS_PERF_CTL_FIFO).
        fifo=/tmp/abacus-perfctl.$USER.$rank
        rm -f "$fifo"
        mkfifo "$fifo"
        export ABACUS_PERF_CTL_FIFO=$fifo
        rec+=(-D -1 --control "fifo:$fifo")
    fi
    preload_app_only
    cmd=("$perf" record "${rec[@]}" -o "$out/perf/r$rank.$perf_mode.data" -- "${cmd[@]}")
fi

if [[ -n $analysis ]]; then
    vtune=$(command -v vtune || echo /opt/aurora/26.181.0/oneapi/vtune/latest/bin64/vtune)
    mkdir -p "$out/vtune"
    # VTune's hardware call stacks drop most samples here; take stacks from --perf lbr.
    # Collections that run VTune's bundled perf hang at startup without --perf-threads=none.
    knobs=()
    case $analysis in
        hotspots) knobs=(-knob sampling-mode=hw) ;;
        xpu-offload) knobs=(-run-pass-thru=--perf-threads=none) ;;
    esac
    preload_app_only
    cmd=("$vtune" -collect "$analysis" ${knobs[@]+"${knobs[@]}"} ${paused[@]+"${paused[@]}"}
         -r "$out/vtune/r$rank.$analysis"
         -finalization-mode=deferred -data-limit=0 -- "${cmd[@]}")
fi

exec "${cmd[@]}"

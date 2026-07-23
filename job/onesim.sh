#!/bin/bash
# onesim.sh — run ONE Abacus simulation on a given hostfile, monitoring it and
# restarting up to a few times if it dies.
#
# Kept deliberately separate from the multi-sim outer loop (multisim.sh) so that:
#   - its retry/backoff state stays private to this one sim, and
#   - the outer loop can collect a single, clean final exit code per sim.
#
# Usage: onesim.sh <par2_file> <hostfile>
#
# -np is derived from the hostfile length each attempt, so a future step can
# blacklist bad nodes / splice in spares from hostfile_extra by rewriting this
# sim's hostfile between restarts, with no change here.

set -uo pipefail   # NB: not -e; the retry loop handles abacus.run's failures itself

PAR2="$1"
HOSTFILE="$2"

PPN=2                          # processes per node; tied to the --*-bind lists below
MAX_CONSEC_FAIL=3
MIN_HEALTHY_SECONDS=600        # failures faster than this count as "rapid"

if [[ ! -r "$PAR2" ]]; then
    echo "onesim: parameter file '$PAR2' not readable" >&2
    exit 2
fi
if [[ ! -r "$HOSTFILE" ]]; then
    echo "onesim: hostfile '$HOSTFILE' not readable" >&2
    exit 2
fi

attempt=0
consec_fail=0

while true; do
    attempt=$((attempt+1))

    # Recompute per attempt: the hostfile may shrink/change between restarts.
    nnodes=$(( $(wc -l < "$HOSTFILE") ))   # arithmetic strips any wc padding
    np=$((nnodes * PPN))
    mpirun_cmd="mpirun --hostfile $HOSTFILE -ppn $PPN --cpu-bind list:1-51,105-155:53-103,157-207 --gpu-bind list:0-2:3-5 --mem-bind list:0:1 -np $np -- "

    # First attempt starts fresh; restarts continue in place.
    if (( attempt == 1 )); then
        flags="--clean"
    else
        flags=""
    fi

    echo "=== abacus invocation $attempt ($flags) on $nnodes nodes, np=$np: $(date) ==="
    t0=$SECONDS

    # Capture rc explicitly. (Do NOT put this in `if python ...; then`: a
    # not-taken if with no else returns 0, masking the real failure code.)
    python -m abacus.run $flags "$PAR2" -P "mpirun_cmd=$mpirun_cmd"
    rc=$?
    dt=$((SECONDS - t0))

    if (( rc == 0 )); then
        echo "=== clean exit after $attempt invocation(s): $(date) ==="
        exit 0
    fi

    echo "=== invocation $attempt FAILED (rc=$rc after ${dt}s); relaunching ===" >&2

    if (( dt < MIN_HEALTHY_SECONDS )); then
        consec_fail=$((consec_fail+1))
        if (( consec_fail >= MAX_CONSEC_FAIL )); then
            echo "=== $consec_fail rapid consecutive failures; giving up ===" >&2
            exit 1
        fi
    else
        consec_fail=0
    fi
done

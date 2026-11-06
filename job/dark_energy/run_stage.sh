#!/bin/bash
# STAGE=h|calib|final|all: one cosm per node, root picked from ROOTS by the PALS rank id.
# STAGE=pool: keep claiming the next unclaimed root from pool.txt (atomic mkdir in claims/)
#   and run all three stages on it, until the pool is empty or fewer than NEED_SEC seconds
#   remain before DEADLINE (epoch seconds; unset = no deadline, e.g. on the login node).
set -euo pipefail
JOB=/home/helenshao/InitialConditions/AbacusAurora/job/dark_energy
UTIL=/home/helenshao/InitialConditions/AbacusAurora/util

run_one() {
    local stage=$1 root=$2
    cd "$UTIL"
    local args=(--glass dark_energy_grid.dat)
    [[ $stage == h ]] && args+=(--table ../Cosmologies/dark_energy_grid --workdir "$JOB/hsearch")
    python -u run_class_one.py "$stage" "$root" "${args[@]}" > "$JOB/${stage}_${root}.log" 2>&1
    if [[ $stage == final ]]; then
        cd ../Cosmologies && python make_cosm_def.py "$root" >> "$JOB/${stage}_${root}.log" 2>&1
    fi
}

if [[ $STAGE == pool ]]; then
    NEED_SEC=${NEED_SEC:-2700}
    worker="$(hostname -s):${PBS_JOBID:-login}:${PALS_RANKID:-$$}"
    for n in $(cat "$JOB/pool.txt"); do
        root=abacus_cosm$n
        if [[ -n ${DEADLINE:-} ]] && (( DEADLINE - $(date +%s) < NEED_SEC )); then
            echo "$(date +%T) $worker: not enough walltime left, stopping"; break
        fi
        mkdir "$JOB/claims/$root" 2>/dev/null || continue
        echo "$worker $(date)" > "$JOB/claims/$root/worker"
        echo "$(date +%T) $worker: claimed $root"
        if ( for s in h calib final; do run_one "$s" "$root"; done ); then
            touch "$JOB/claims/$root/done"
            echo "$(date +%T) $worker: done $root"
        else
            touch "$JOB/claims/$root/failed"
            echo "$(date +%T) $worker: FAILED $root"
        fi
    done
    exit 0
fi

roots=($ROOTS)
root=abacus_cosm${roots[$PALS_RANKID]}
if [[ $STAGE == all ]]; then
    for s in h calib final; do run_one "$s" "$root"; done
else
    run_one "$STAGE" "$root"
fi

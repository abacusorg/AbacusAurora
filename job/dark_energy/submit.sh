#!/bin/bash
# Run h -> calib -> final for the dark energy grid.  debug-scaling allows only one queued
# job per user, so each stage is submitted once the previous one finishes with exit 0.
# Run inside screen.  Usage: [ROOTS="270 271"] [FIRST_JOB=<id of an already-submitted h job>] ./submit.sh
# Before the first stage, README.txt must hold the staging rows:
#   cd ../../util && python dark_energy_grid_to_grid.py && cp ../Cosmologies/dark_energy_grid ../Cosmologies/README.txt
# Afterwards (login node is fine, no CLASS):
#   cd ../../util && python merge_readme_txt_to_md.py --check && python merge_readme_txt_to_md.py --csv ../Cosmologies/cosmologies.csv
set -euo pipefail
cd /home/helenshao/InitialConditions/AbacusAurora/job/dark_energy
ROOTS=${ROOTS:-$(awk '!/^#/ && NF {print $1}' ../../util/dark_energy_grid.dat | xargs)}
echo "$ROOTS" > roots.txt
n=$(wc -w <<< "$ROOTS")
echo "$(date) roots ($n): $ROOTS"

for stage in h calib final; do
    if [[ $stage == h && -n ${FIRST_JOB:-} ]]; then
        id=$FIRST_JOB
    else
        until id=$(qsub -N de_$stage -l select=$n -o "$PWD/$stage.pbs.out" -v STAGE=$stage de.pbs); do
            sleep 120
        done
    fi
    echo "$(date) $stage $id" | tee -a jobids.txt
    while true; do
        st=$(qstat -xf "$id" | awk '/job_state/{s=$3} /Exit_status/{e=$3} END{print s, e}')
        [[ ${st%% *} == F ]] && break
        sleep 120
    done
    echo "$(date) $stage finished: '$st'"
    [[ $st == "F 0" ]] || { echo "$stage failed; see ${stage}_abacus_cosm*.log"; exit 1; }
done
echo "$(date) all stages done"

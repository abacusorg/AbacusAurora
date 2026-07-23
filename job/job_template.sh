#!/bin/bash -l
#PBS -l select=16
#PBS -q debug-scaling
#PBS -l walltime=01:00:00
#PBS -l filesystems=flare
#PBS -A Abacus
#PBS -l place=scatter

export PBS_MINUTES=60          # keep in sync with the walltime directive above
export NODES_PER_JOB=4         # nodes per simulation (consumed by multisim.sh)

# NOTE: #PBS directives are comments — PBS reads them only if they precede
# the first command, and they are NOT shell-expanded (so the walltime must be a
# literal, not ${PBS_MINUTES}). Keep PBS_MINUTES in sync with the walltime.
#
# TODO: PBS doesn't tell us how much wall time remains. We export PBS_MINUTES so
# the run can eventually compute the wall-clock end time and have Abacus halt
# just before it.

set -euo pipefail

export ABACUS=/home/eisenste/abacus
export ABACUS_BUILD=$HOME/abacus/build
. $ABACUS/env.sh

cd "$PBS_O_WORKDIR"

PAR_FILES=parfile              # one .par2 path per line
MULTISIM=$ABACUS/prod/multisim.sh   # adjust to wherever these scripts are deployed

echo "Git branch:"
git log -1 --format='%D %H'
echo

echo "Preparing to run these sims:"
cat "$PAR_FILES"
echo

echo "Node list:"
cat "$PBS_NODEFILE"
echo

# One sim failing shouldn't abort the job under `set -e`. multisim already waits
# for every sim, so all of them complete regardless of this code; capturing it
# just lets us finish cleanly (and run any teardown you add below).
multisim_rc=0
"$MULTISIM" "$PAR_FILES" || multisim_rc=$?

if (( multisim_rc != 0 )); then
    echo "WARNING: at least one sim exited nonzero (multisim rc=$multisim_rc)"
fi

echo "Done with outer script"

# Policy: propagate a nonzero exit so PBS marks the job failed if ANY sim failed.
# Change to `exit 0` if you'd rather a partial failure not flag the whole job.
exit "$multisim_rc"

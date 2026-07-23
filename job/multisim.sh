#!/bin/bash
# multisim.sh — launch several Abacus simulations, each on an equal slice of the
# PBS node allocation. Each sim runs under onesim.sh (monitor + restart).
#
# Usage: multisim.sh <par_files_list>
#   <par_files_list>: a file with one .par2 path per line (blank lines and
#                     lines beginning with '#' are ignored). Each sim should use
#                     a distinct SimName.
#
# Requires NODES_PER_JOB in the environment (exported by the PBS job script).
#
# Segments the (unique, sorted) node list into NODES_PER_JOB-node slices, one
# per sim. Any nodes beyond what the sims need go into $HOSTFILE_EXTRA (a spare
# pool for a future blacklist-and-replace step). Crashes if there aren't enough
# nodes for all sims.

set -uo pipefail

PAR_FILES="$1"

: "${NODES_PER_JOB:?NODES_PER_JOB must be set (export it from the job script)}"
: "${PBS_O_WORKDIR:?PBS_O_WORKDIR must be set}"
: "${PBS_NODEFILE:?PBS_NODEFILE must be set}"

ONESIM="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/onesim.sh"

cd "$PBS_O_WORKDIR"

JOBNUM=${PBS_JOBID%%.*}

# Unique, sorted node list (PBS_NODEFILE may list a node once per chunk/rank).
rm -f nodes.sorted nodefile_part_* hostfile_extra
sort -u "$PBS_NODEFILE" > nodes.sorted

num_nodes=$(( $(wc -l < nodes.sorted) ))   # arithmetic strips any wc padding
# Real sims = non-blank, non-comment lines.
num_sims=$(grep -cvE '^[[:space:]]*(#.*)?$' "$PAR_FILES")

required=$(( NODES_PER_JOB * num_sims ))

if (( required > num_nodes )); then
    echo "ERROR: need NODES_PER_JOB($NODES_PER_JOB) x sims($num_sims) = $required nodes," \
         "but the hostfile has only $num_nodes." >&2
    exit 1
fi

# Everything past the nodes the sims need becomes the spare pool.
num_extra=$(( num_nodes - required ))
export HOSTFILE_EXTRA="$PBS_O_WORKDIR/hostfile_extra"
tail -n +"$(( required + 1 ))" nodes.sorted > "$HOSTFILE_EXTRA"
echo "Allocation: $num_sims sim(s) x $NODES_PER_JOB nodes = $required used; ${num_extra} extra node(s) -> $HOSTFILE_EXTRA"
echo

# Launch each sim on its own slice, via the per-sim monitor script.
pids=()
i=0
while IFS= read -r par2 <&3; do
    [[ "$par2" =~ ^[[:space:]]*(#|$) ]] && continue   # skip blanks / comments

    hf="nodefile_part_$(printf '%03d' "$i")"
    start=$(( i * NODES_PER_JOB + 1 ))
    end=$(( (i + 1) * NODES_PER_JOB ))
    sed -n "${start},${end}p" nodes.sorted > "$hf"

    echo "Sim $i: $par2 on nodes:"
    cat "$hf"
    echo

    # < /dev/null is essential: mpirun/PALS reads stdin, and a backgrounded child
    # that shares the loop's stdin would drain the par-file fd and end the loop
    # early. (We also read the list on fd 3 above, for the same reason.)
    "$ONESIM" "$par2" "$PBS_O_WORKDIR/$hf" < /dev/null > "job_${JOBNUM}_${i}.out" 2>&1 &
    pid=$!
    pids+=($pid)
    echo "  launched sim $i as pid $pid -> job_${JOBNUM}_${i}.out"
    i=$((i+1))
    sleep 10          # stagger PALS launches — critical!
done 3< "$PAR_FILES"

# Block until all sims finish; surface any failure to the job's exit code.
rc=0
for idx in "${!pids[@]}"; do
    if ! wait "${pids[$idx]}"; then
        echo "Sim $idx (pid ${pids[$idx]}) exited nonzero" >&2
        rc=1
    fi
done

echo "All $num_sims sim(s) finished (rc=$rc)"
exit $rc

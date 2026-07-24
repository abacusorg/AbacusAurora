#!/bin/bash
# onesim.sh — run ONE Abacus simulation on a given hostfile, monitoring it and
# restarting up to a few times if it dies.
#
# Kept deliberately separate from the multi-sim outer loop (multisim.pbs) so that:
#   - its retry/backoff state stays private to this one sim, and
#   - the outer loop can collect a single, clean final exit code per sim.
#
# Usage: onesim.sh <par2_file> <hostfile> [KEY=VAL ...]
#
# Also records this sim's provenance (env, modules, jobspec) into its
# OutputDirectory/provenance/ before running.
#
# This sim's node slice is handed to the par2 via $MPIRUN_ARGS (--hostfile <slice>)
# and $NNODES; the site def's mpirun_cmd splices in $MPIRUN_ARGS and uses $NNODES
# for -np. Recomputed each attempt, so a future step can blacklist bad nodes /
# splice in spares from hostfile_extra by rewriting this sim's hostfile between restarts.

set -uo pipefail   # NB: not -e; the retry loop handles abacus.run's failures itself

par2="$1"
hostfile="$2"
shift 2
overrides=("$@")               # extra -P KEY=VAL params, forwarded to abacus.run

max_consec_fail=3
min_healthy_seconds=600        # failures faster than this count as "rapid"

if [[ ! -r "$par2" ]]; then
    echo "onesim: parameter file '$par2' not readable" >&2
    exit 2
fi
if [[ ! -r "$hostfile" ]]; then
    echo "onesim: hostfile '$hostfile' not readable" >&2
    exit 2
fi

# Record this sim's provenance into its OutputDirectory/provenance/ (travels with
# the data). $MPIRUN_ARGS/$NNODES default in env.sh, so the par2 parses here; and
# abacus.run won't wipe it (no --clean). The jobspec is copied if we're under hashjob.
outdir=$(python -m abacus.param "$par2" -o /dev/stdout 2>/dev/null | awk -F\" '/^OutputDirectory[[:space:]]*=/{print $2; exit}')
if [[ -n $outdir ]]; then
    prov="$outdir/provenance"
    mkdir -p "$prov"
    env | sort > "$prov/env.txt"
    module list > "$prov/modules.txt" 2>&1 || true
    [[ -n ${HASHRUN_SPEC:-} ]] && cp "$HASHRUN_SPEC/jobspec.sh" "$prov/jobspec.sh"
else
    echo "onesim: warning: could not resolve OutputDirectory; skipping provenance" >&2
fi

attempt=0
consec_fail=0

while true; do
    attempt=$((attempt+1))

    # Hand this sim's node slice to the par2 via the environment; the site def's
    # mpirun_cmd splices in $MPIRUN_ARGS$ and uses $NNODES$ for -np. Recomputed per
    # attempt (the hostfile may shrink/change between restarts).
    nnodes=$(( $(wc -l < "$hostfile") ))   # arithmetic strips any wc padding
    export MPIRUN_ARGS="--hostfile $hostfile" NNODES="$nnodes"

    echo "=== abacus invocation $attempt on $nnodes nodes: $(date) ==="
    t0=$SECONDS

    # Capture rc explicitly. (Do NOT put this in `if python ...; then`: a
    # not-taken if with no else returns 0, masking the real failure code.)
    pargs=()
    for o in ${overrides[@]+"${overrides[@]}"}; do pargs+=(-P "$o"); done
    python -m abacus.run "$par2" ${pargs[@]+"${pargs[@]}"}
    rc=$?
    dt=$((SECONDS - t0))

    if (( rc == 0 )); then
        echo "=== clean exit after $attempt invocation(s): $(date) ==="
        exit 0
    fi

    echo "=== invocation $attempt FAILED (rc=$rc after ${dt}s); relaunching ===" >&2

    if (( dt < min_healthy_seconds )); then
        consec_fail=$((consec_fail+1))
        if (( consec_fail >= max_consec_fail )); then
            echo "=== $consec_fail rapid consecutive failures; giving up ===" >&2
            exit 1
        fi
    else
        consec_fail=0
    fi
done

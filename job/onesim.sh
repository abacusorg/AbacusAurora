#!/bin/bash
# onesim.sh — run ONE Abacus simulation on a given hostfile, monitoring it and
# restarting up to a few times if it dies.  Two caps bound the retrying:
# max_consec_fail rapid failures in a row, and max_restarts relaunches in total
# however healthy each attempt looked.  See the loop at the bottom.
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
# This sim's node slice is handed to the par2 via $ABACUS_MPIRUN_ARGS (--hostfile <slice>)
# and $NNODES; the site def's mpirun_cmd splices in $ABACUS_MPIRUN_ARGS and uses $NNODES
# for -np. We APPEND --hostfile to any inherited $ABACUS_MPIRUN_ARGS (e.g. from
# `-E ABACUS_MPIRUN_ARGS=--no-vni`) rather than overwriting it. Recomputed each attempt,
# so a future step can blacklist bad nodes / splice in spares from hostfile_extra by
# rewriting this sim's hostfile between restarts.

set -uo pipefail   # NB: not -e; the retry loop handles abacus.run's failures itself

par2="$1"
hostfile="$2"
shift 2
overrides=("$@")               # extra -P KEY=VAL params, forwarded to abacus.run

max_consec_fail=2
min_healthy_seconds=14400        # failures faster than this count as "rapid".  We set this longer than a typical checkpoint.
max_restarts=3                   # hard cap on relaunches of any kind, however healthy they looked

if [[ ! -r "$par2" ]]; then
    echo "onesim: parameter file '$par2' not readable" >&2
    exit 2
fi
if [[ ! -r "$hostfile" ]]; then
    echo "onesim: hostfile '$hostfile' not readable" >&2
    exit 2
fi

pargs=()
for o in ${overrides[@]+"${overrides[@]}"}; do pargs+=(-P "$o"); done

# Record this sim's provenance into its OutputDirectory/provenance/ (travels with the
# data; abacus.run cleans only on --clean, which we never pass). $ABACUS_MPIRUN_ARGS/$NNODES default
# in env.sh, so the par2 parses here. The parse is throwaway -- abacus.run re-parses with
# each attempt's --hostfile -- but needs $pargs: OutputDirectory derives from SimName.
outdir=$(python -m abacus.param "$par2" ${pargs[@]+"${pargs[@]}"} -o /dev/stdout 2>/dev/null | awk -F\" '/^OutputDirectory[[:space:]]*=/{print $2; exit}')
if [[ -n $outdir ]]; then
    prov="$outdir/provenance"
    mkdir -p "$prov"
    env | sort > "$prov/env.txt"
    module list > "$prov/modules.txt" 2>&1 || true
    [[ -n ${HASHRUN_OUT:-} ]] && cp "$HASHRUN_OUT/jobspec.sh" "$prov/jobspec.sh"
else
    echo "onesim: warning: could not resolve OutputDirectory; skipping provenance" >&2
fi

attempt=0
consec_fail=0
total_fail=0

# Capture so that the loop doesn't keep appending
abacus_mpirun_args_base=${ABACUS_MPIRUN_ARGS:-}

while true; do
    attempt=$((attempt+1))

    # Hand this sim's node slice to the par2 via the environment: append --hostfile to
    # the inherited base ($abacus_mpirun_args_base); the site def's mpirun_cmd splices in
    # $ABACUS_MPIRUN_ARGS$ and uses $NNODES$ for -np. Recomputed per attempt (the
    # hostfile may shrink/change between restarts).
    nnodes=$(( $(wc -l < "$hostfile") ))   # arithmetic strips any wc padding
    export ABACUS_MPIRUN_ARGS="${abacus_mpirun_args_base:+$abacus_mpirun_args_base }--hostfile $hostfile" NNODES="$nnodes"

    echo "=== abacus invocation $attempt on $nnodes nodes: $(date) ==="
    t0=$SECONDS

    # Capture rc explicitly. (Do NOT put this in `if python ...; then`: a
    # not-taken if with no else returns 0, masking the real failure code.)
    python -m abacus.run "$par2" ${pargs[@]+"${pargs[@]}"}
    rc=$?
    dt=$((SECONDS - t0))

    if (( rc == 0 )); then
        echo "=== clean exit after $attempt invocation(s): $(date) ==="
        exit 0
    fi

    # Just the failure here.  Whether we relaunch is not known until the caps below have
    # been evaluated, so claiming it on this line would be a lie every time we give up.
    echo "=== invocation $attempt FAILED (rc=$rc after ${dt}s) ===" >&2

    # Two independent caps, both needed:
    #
    #   consec_fail catches a sim that dies QUICKLY over and over -- the cheap, obvious
    #   loop, cut off after max_consec_fail rapid failures in a row.
    #
    #   total_fail is the backstop for a sim that fails SLOWLY but repeatedly.  If each
    #   attempt survives longer than min_healthy_seconds, every one of them looks healthy
    #   on its own and consec_fail resets each time, so nothing above would ever stop it:
    #   the sim would keep relaunching for as long as the job's walltime allowed, which is
    #   how a single sick sim can burn an allocation.  Counting every failure regardless of
    #   how long it lasted bounds the damage at max_restarts relaunches.
    total_fail=$((total_fail+1))

    if (( dt < min_healthy_seconds )); then
        consec_fail=$((consec_fail+1))
        if (( consec_fail >= max_consec_fail )); then
            echo "=== $consec_fail rapid consecutive failures; giving up ===" >&2
            exit 1
        fi
    else
        consec_fail=0
    fi

    # Checked after the rapid-failure logic so it applies on both paths: each failure so far
    # has consumed one relaunch, so the (max_restarts + 1)'th is the one to refuse.
    if (( total_fail > max_restarts )); then
        echo "=== $total_fail failures in this sim, only $max_restarts restart(s) allowed; giving up ===" >&2
        exit 1
    fi

    # Past both caps, so a relaunch is now certain: say so, and say what is left of the
    # budget.  Reached only when neither exit above fired, so this can never contradict a
    # give-up message.
    echo "=== relaunching after $total_fail failure(s); $((max_restarts - total_fail)) restart(s) still allowed ===" >&2
done

#!/bin/bash
# onesim.sh — run ONE Abacus simulation on a given hostfile, monitoring it and
# restarting up to a few times if it dies.  Three gates bound the retrying: the
# allocation's agreed halt time, which overrides both of the caps; max_consec_fail
# rapid failures in a row; and max_restarts relaunches in total however healthy each
# attempt looked.  See halt_reason() and the loop at the bottom.
#
# Kept deliberately separate from the multi-sim outer loop (multisim.pbs) so that:
#   - its retry/backoff state stays private to this one sim, and
#   - the outer loop can collect a single, clean final exit code per sim.
#
# Usage: onesim.sh <par2_file> <hostfile> [KEY=VAL ...]
#
# Exit codes: 0 the sim exited cleanly; 1 gave up on a sim that keeps failing;
#             2 bad arguments; 3 gave up because the allocation's halt time is at hand.
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

# A relaunch is pointless once the allocation's agreed halt time has passed, and nearly
# pointless shortly before it: Abacus tests for the halt only after a COMPLETED timestep
# (CheckHaltFile's call site in multistep.cpp), so a late relaunch pays full startup, runs
# at least one whole step past the deadline, and only then writes the final state -- the
# very phase that has been hanging on DAOS -- with multisim's halt buffer already spent.
# So refuse a relaunch that cannot reach the deadline with this much room to spare.
min_relaunch_seconds=${ONESIM_MIN_RELAUNCH_SECONDS:-900}

# Why a relaunch must be refused right now, or nothing at all if it is allowed.  Both
# signals are read fresh on each call, and both come from multisim.pbs's environment;
# they are simply absent when onesim.sh is run standalone, in which case this is a no-op
# and the two caps above remain the only bound on retrying.
halt_reason() {
    # Someone asked for every sim in the allocation to stop.  Abacus deliberately does not
    # consume this file (multisim.pbs owns its lifecycle), so it is still here to be seen.
    if [[ -n ${ABACUS_JOB_HALT_FILE:-} && -e $ABACUS_JOB_HALT_FILE ]]; then
        echo "an allocation-wide halt was requested (ABACUS_JOB_HALT_FILE=$ABACUS_JOB_HALT_FILE)"
        return
    fi
    [[ -n ${ABACUS_JOB_HALT_TIME:-} ]] || return
    # Not an integer epoch time: multistep warns and ignores it, so ignore it here too
    # rather than guess at a deadline and refuse relaunches the sim would have been given.
    [[ $ABACUS_JOB_HALT_TIME =~ ^[0-9]+$ ]] || return
    local left=$(( ABACUS_JOB_HALT_TIME - $(date +%s) ))
    if (( left <= 0 )); then
        echo "the agreed halt time passed $(( -left ))s ago (ABACUS_JOB_HALT_TIME=$ABACUS_JOB_HALT_TIME)"
    elif (( left < min_relaunch_seconds )); then
        echo "only ${left}s remain before the agreed halt time (ABACUS_JOB_HALT_TIME=$ABACUS_JOB_HALT_TIME), less than the ${min_relaunch_seconds}s a relaunch needs to reach it and close out"
    fi
}

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
    python -u -m abacus.run "$par2" ${pargs[@]+"${pargs[@]}"}
    rc=$?
    dt=$((SECONDS - t0))

    if (( rc == 0 )); then
        echo "=== clean exit after $attempt invocation(s): $(date) ==="
        exit 0
    fi

    # Just the failure here.  Whether we relaunch is not known until the gates below have
    # been evaluated, so claiming it on this line would be a lie every time we give up.
    echo "=== invocation $attempt FAILED (rc=$rc after ${dt}s) ===" >&2

    # The deadline gate outranks both caps, and is checked before total_fail is charged:
    # this invocation did not fail because the sim is sick, it failed because the
    # allocation is ending (typically the final state write to DAOS hanging until
    # StepTimeout kills it), so it should not count against the retry budget either.
    # A distinct exit code keeps "the clock ran out" separable from "this sim keeps dying"
    # in the postmortem; multisim.pbs only tests for nonzero, so the job still reports the
    # failure -- the invocation WAS killed, possibly mid-write.
    reason=$(halt_reason)
    if [[ -n $reason ]]; then
        echo "=== not relaunching: $reason ===" >&2
        exit 3
    fi

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

    # Past all three gates, so a relaunch is now certain: say so, and say what is left of the
    # budget.  Reached only when neither exit above fired, so this can never contradict a
    # give-up message.
    echo "=== relaunching after $total_fail failure(s); $((max_restarts - total_fail)) restart(s) still allowed ===" >&2
done

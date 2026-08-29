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
# because a failed attempt may hand us a rewritten hostfile: see below.
#
# Node blame-and-replace. After a failure we hand this attempt's slice of our own
# output to job/nodehealth.py, which decides whether a node is to blame, and if so
# swaps it for a spare from the shared $HOSTFILE_EXTRA pool and writes us a new
# hostfile. This needs three things from multisim.pbs -- $ABACUS_SIM_LOG (the file our
# stdout+stderr were redirected into), $HOSTFILE_EXTRA and $HASHRUN_OUT -- and is
# silently skipped when run standalone without them.

set -uo pipefail   # NB: not -e; the retry loop handles abacus.run's failures itself

par2="$1"
hostfile="$2"
shift 2
overrides=("$@")               # extra -P KEY=VAL params, forwarded to abacus.run

max_consec_fail=2
min_healthy_seconds=14400        # failures faster than this count as "rapid".  We set this longer than a typical checkpoint.
max_restarts=3                   # hard cap on relaunches of any kind, however healthy they looked
max_replacements=4               # cap on node swaps; the spare pool bounds this too

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

# multisim.pbs invokes us by absolute path (not a spooled copy), so our own
# directory is the prod repo's job/.
nodehealth="${BASH_SOURCE[0]%/*}/nodehealth.py"
statedir=${HASHRUN_OUT:+$HASHRUN_OUT/nodehealth}
simidx=${ABACUS_SIM_INDEX:-0}
hostfile_base=$hostfile          # rewritten hostfiles are named from this, not from
                                 # the current one, so they don't accumulate suffixes
replacements=0

can_replace=1
for need in nodehealth:"$nodehealth" ABACUS_SIM_LOG:"${ABACUS_SIM_LOG:-}" \
            HOSTFILE_EXTRA:"${HOSTFILE_EXTRA:-}" HASHRUN_OUT:"${HASHRUN_OUT:-}"; do
    if [[ -z ${need#*:} ]]; then
        echo "onesim: node replacement disabled (${need%%:*} not set)" >&2
        can_replace=0
    fi
done
if (( can_replace )) && [[ ! -r $nodehealth || ! -r ${ABACUS_SIM_LOG:-/nonexistent} ]]; then
    echo "onesim: node replacement disabled (nodehealth.py or the sim log is unreadable)" >&2
    can_replace=0
fi
(( can_replace )) && mkdir -p "$statedir"

# Clear the strikes this job recorded against nodes that have since proved healthy.
# Without this a node that merely happened to be present at a late, recoverable
# failure would accumulate blame it never earned.
absolve_nodes() {
    (( can_replace )) || return 0
    python "$nodehealth" absolve --hostfile "$hostfile" --statedir "$statedir" || true
}

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

    # Where this attempt's output starts in the file multisim.pbs redirected us
    # into. Taken AFTER the banner above so the window holds only what the run
    # itself emitted -- no launcher messages from a previous attempt, and none of
    # our own commentary, which must never be mistaken for a NODEFAIL marker.
    logmark=0
    (( can_replace )) && logmark=$(( $(wc -c < "$ABACUS_SIM_LOG" 2>/dev/null || echo 0) ))

    # Capture rc explicitly. (Do NOT put this in `if python ...; then`: a
    # not-taken if with no else returns 0, masking the real failure code.)
    python -m abacus.run "$par2" ${pargs[@]+"${pargs[@]}"}
    rc=$?
    dt=$((SECONDS - t0))

    if (( rc == 0 )); then
        absolve_nodes
        echo "=== clean exit after $attempt invocation(s): $(date) ==="
        exit 0
    fi

    # Diagnose before announcing the failure, so the window we hand to
    # nodehealth.py ends at the run's last word.
    replaced=0
    if (( can_replace )) && (( replacements < max_replacements )); then
        slice=$statedir/sim${simidx}.attempt${attempt}.log
        tail -c "+$((logmark + 1))" "$ABACUS_SIM_LOG" > "$slice" 2>/dev/null || : > "$slice"

        newhostfile=$hostfile_base.a$((attempt + 1))
        python "$nodehealth" replace \
            --log-slice "$slice" --hostfile "$hostfile" --pool "$HOSTFILE_EXTRA" \
            --statedir "$statedir" --sim "$simidx" --attempt "$attempt" \
            --out "$newhostfile"
        case $? in
            0)  hostfile=$newhostfile
                replaced=1
                replacements=$((replacements + 1)) ;;
            2)  # A node is to blame and there is no spare to put in its place.
                # Relaunching would just re-run onto a node we believe is dead.
                echo "=== node blamed but the spare pool is empty; giving up ===" >&2
                exit 1 ;;
            *)  ;;   # 1 = nobody blamed, 3 = internal error; carry on unchanged
        esac
    elif (( can_replace )); then
        echo "=== $replacements node replacement(s) already made (max $max_replacements);" \
             "not diagnosing further ===" >&2
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
    #   how long it lasted bounds the damage at max_restarts relaunches -- plus one
    #   more for each node replacement, see `allowed` below.
    total_fail=$((total_fail+1))

    if (( replaced )); then
        # This failure is explained and its cause has been swapped out, so it is
        # not evidence of a sim that dies rapidly over and over.
        consec_fail=0
    elif (( dt < min_healthy_seconds )); then
        consec_fail=$((consec_fail+1))
        if (( consec_fail >= max_consec_fail )); then
            echo "=== $consec_fail rapid consecutive failures; giving up ===" >&2
            exit 1
        fi
    else
        # A long, healthy attempt clears any blame this job put on these nodes.
        absolve_nodes
        consec_fail=0
    fi

    # Checked after the rapid-failure logic so it applies on both paths: each failure so far
    # has consumed one relaunch, so the (max_restarts + 1)'th is the one to refuse.
    # Each node replacement buys back the restart its failure consumed: the cause
    # was external and has been removed, so it should not eat the budget meant for
    # genuinely repeated failures. max_replacements bounds how far that can go.
    allowed=$((max_restarts + replacements))
    if (( total_fail > allowed )); then
        echo "=== $total_fail failures in this sim, only $allowed restart(s) allowed; giving up ===" >&2
        exit 1
    fi

    # Past both caps, so a relaunch is now certain: say so, and say what is left of the
    # budget.  Reached only when neither exit above fired, so this can never contradict a
    # give-up message.
    echo "=== relaunching after $total_fail failure(s)" \
         "on $(wc -l < "$hostfile") nodes; $((allowed - total_fail)) restart(s) still allowed ===" >&2
done

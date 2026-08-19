#!/bin/bash
# DAOS support for the hashrun pipeline: pool/container names and the mount
# lifecycle.  Sourced by hashrun.sh (login node) and multisim.pbs (job); also
# runnable directly as `./job/daos.sh` for a health check.
#
# Sets four storage roots, either to DAOS or Flare based on user request:
#   ABACUS_WORKING_ROOT      status.log, HALT file, logs, etc
#   ABACUS_OUTPUT_ROOT       slices, groups, lightcones, tracers
#   ABACUS_CHECKPOINT_ROOT   the state and the SCR prefix
#   ABACUS_RESOURCE_ROOT     precomputed inputs, read-only during a sim: it holds
#                            Derivatives/ and Wisdom/
# These are referenced in aurora.def.
#
# Switches, all honouring on/off (and 0/no/false):
#   ABACUS_DAOS=on              use DAOS at all (also hashrun.sh --daos / --no-daos)
#   ABACUS_DAOS_OUTPUTS=on      put the outputs on DAOS too, not just the checkpoints
#   ABACUS_DAOS_RESOURCES=on    read the derivatives and wisdom from DAOS.  Stage them in
#                               first with scripts/daos-stage-resources.sh: a derivative
#                               set that is missing at run time is regenerated from
#                               scratch on one node, not fetched from flare.
#   ABACUS_DAOS_PRELOAD=off     don't LD_PRELOAD the interception library

DAOS_POOL=${ABACUS_DAOS_POOL:-AbacusAurora}
DAOS_CONT_OUTPUTS=${ABACUS_DAOS_CONT_OUTPUTS:-Outputs}
DAOS_CONT_CHECKPOINTS=${ABACUS_DAOS_CONT_CHECKPOINTS:-Checkpoints}
DAOS_CONT_RESOURCES=${ABACUS_DAOS_CONT_RESOURCES:-Resources}

FLARE_ROOT=/flare/Abacus/$USER
FLARE_RESOURCES=/flare/Abacus

_is_on() {
    case ${1:-} in
        [Oo][Ff][Ff]|0|[Nn][Oo]|[Ff][Aa][Ll][Ss][Ee]) return 1 ;;
        *) return 0 ;;
    esac
}

daos_mountpoint() { printf '/tmp/%s/%s\n' "$DAOS_POOL" "$1"; }
# Login nodes are shared, so their mounts are per-user; compute nodes are not.
daos_login_mountpoint() { printf '/tmp/%s/%s/%s\n' "$USER" "$DAOS_POOL" "$1"; }

# Apply the switches: fill daos_conts[] with the containers this job needs and point
# the storage roots at them, or at flare.  The roots are assigned unconditionally,
# never defaulted: the pipeline owns these variables, so a value inherited from the
# caller's shell must not decide where a sim's state lands.
daos_resolve() {
    daos_conts=()
    export ABACUS_WORKING_ROOT=$FLARE_ROOT
    export ABACUS_OUTPUT_ROOT=$FLARE_ROOT
    export ABACUS_CHECKPOINT_ROOT=$FLARE_ROOT
    export ABACUS_RESOURCE_ROOT=$FLARE_RESOURCES
    _is_on "${ABACUS_DAOS:-off}" || return 0   # the DAOS on/off default

    # Outputs comes along even when the outputs stay on flare: it hosts the working
    # directory.
    daos_conts+=("$DAOS_CONT_CHECKPOINTS" "$DAOS_CONT_OUTPUTS")
    ABACUS_CHECKPOINT_ROOT=$(daos_mountpoint "$DAOS_CONT_CHECKPOINTS")/$USER
    ABACUS_WORKING_ROOT=$(daos_mountpoint "$DAOS_CONT_OUTPUTS")/$USER
    if _is_on "${ABACUS_DAOS_OUTPUTS:-off}"; then   # the outputs-on-DAOS default
        ABACUS_OUTPUT_ROOT=$(daos_mountpoint "$DAOS_CONT_OUTPUTS")/$USER
    fi
    if _is_on "${ABACUS_DAOS_RESOURCES:-on}"; then   # the resources-on-DAOS default
        daos_conts+=("$DAOS_CONT_RESOURCES")
        ABACUS_RESOURCE_ROOT=$(daos_mountpoint "$DAOS_CONT_RESOURCES")
    fi
}

# The daos CLI is /usr/bin/daos but needs the module's environment (libfabric, the
# agent socket).  hashrun.sh runs from the user's shell, which may not have it.
daos_cli() {
    bash -lc 'module use /soft/modulefiles >/dev/null 2>&1
              module load daos >/dev/null 2>&1
              exec "$@"' daos_cli "$@"
}

daos_preflight() {
    if ! daos_cli daos pool query "$DAOS_POOL" >/dev/null 2>&1; then
        echo "error: DAOS pool '$DAOS_POOL' is unreachable." >&2
        echo "       If DAOS is down, resubmit with --no-daos (or export ABACUS_DAOS=off)." >&2
        return 1
    fi
}

daos_have_container() { daos_cli daos container get-prop "$DAOS_POOL" "$1" >/dev/null 2>&1; }

daos_require_containers() {
    local cont rc=0
    for cont; do
        daos_have_container "$cont" && continue
        echo "error: DAOS container $DAOS_POOL:$cont does not exist. Create it with:" >&2
        echo "         daos container create --type=POSIX $DAOS_POOL $cont" >&2
        rc=1
    done
    return $rc
}

# Mount the given containers across the allocation.  launch-dfuse.sh reads
# $PBS_NODEFILE itself and needs line 1 to be the node we are running on: it mounts
# that one by invoking dfuse locally and clushes only `tail -n +2`.  PBS puts the
# mother superior first, so never substitute a rewritten nodefile here -- reordering
# it (a sort, say) leaves line 1 unmounted, mounts the true head node twice ("Pool
# specified multiple ways"), and points dbcast at a host with no handles file, so
# every remaining node fails with DER_NONEXIST.
daos_mount() {
    local specs=() cont
    for cont; do specs+=("$DAOS_POOL:$cont"); done
    launch-dfuse.sh "${specs[@]}" || return 1
    daos_check_mounts "$@"
}

# Confirm the mounts really landed everywhere: a partial mount would have some ranks
# writing to the underlying /tmp instead, which looks like success until the restart.
daos_check_mounts() {
    local cont mnt bad
    for cont; do
        mnt=$(daos_mountpoint "$cont")
        bad=$(clush --hostfile="$PBS_NODEFILE" -f 208 -N \
                    -o '-o LogLevel=QUIET -o StrictHostKeyChecking=no' \
                    "mountpoint -q $mnt || hostname" 2>&1 | sort -u)
        if [[ -n $bad ]]; then
            echo "error: $mnt is not mounted on:" >&2
            echo "$bad" >&2
            return 1
        fi
    done
}

# clean-dfuse.sh is global (it SIGKILLs every dfuse on every node), so one call
# covers all containers.  Best-effort: this runs from an EXIT trap.
daos_unmount() {
    local specs=() cont
    for cont; do specs+=("$DAOS_POOL:$cont"); done
    clean-dfuse.sh "${specs[@]}" >/dev/null 2>&1 || true
}

# Extend $ABACUS_MPIRUN_ARGS, which onesim.sh appends --hostfile to.  Nothing is added
# unless DAOS is actually in play; both go on the mpirun line so they reach the ranks
# only, never python/uv/meson, and each is skipped if the operator already supplied it
# via -E ABACUS_MPIRUN_ARGS.
#   --no-vni    mpiexec requires it alongside DAOS.
#   LD_PRELOAD  the interception library, unless $ABACUS_DAOS_PRELOAD says otherwise.
daos_mpirun_args() {
    local daos_on=$1
    local args=${ABACUS_MPIRUN_ARGS:-}
    if (( daos_on )); then
        if [[ $args != *--no-vni* ]]; then
            args="${args:+$args }--no-vni"
        fi
        if _is_on "${ABACUS_DAOS_PRELOAD:-}" && [[ -n ${DAOS_PRELOAD:-} && $args != *libpil4dfs* ]]; then
            args="${args:+$args }--env LD_PRELOAD=$DAOS_PRELOAD"
        fi
    fi
    export ABACUS_MPIRUN_ARGS="$args"
}

daos_status() {
    local cont mnt
    daos_resolve

    echo "pool:  $DAOS_POOL"
    if (( ${#daos_conts[@]} == 0 )); then
        echo "DAOS is OFF (ABACUS_DAOS=${ABACUS_DAOS:-unset}); everything stays on flare."
    fi

    echo
    daos_cli daos pool query "$DAOS_POOL" 2>/dev/null | grep -E '^Pool |^- Rebuild|Free:' \
        || echo "pool query FAILED -- pool unreachable or agent down"

    echo
    echo "containers:"
    for cont in ${daos_conts[@]+"${daos_conts[@]}"}; do
        mnt=$(daos_mountpoint "$cont")
        if daos_have_container "$cont"; then
            printf '  %-14s exists' "$cont"
        else
            printf '  %-14s MISSING -- daos container create --type=POSIX %s %s' \
                   "$cont" "$DAOS_POOL" "$cont"
        fi
        mountpoint -q "$mnt" && printf ', mounted here at %s' "$mnt"
        printf '\n'
    done
    (( ${#daos_conts[@]} )) || echo "  (none needed)"

    echo
    echo "roots:"
    printf '  %-14s %s\n' working     "$ABACUS_WORKING_ROOT"
    printf '  %-14s %s\n' output      "$ABACUS_OUTPUT_ROOT"
    printf '  %-14s %s\n' checkpoint  "$ABACUS_CHECKPOINT_ROOT"
    printf '  %-14s %s\n' resources   "$ABACUS_RESOURCE_ROOT"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    daos_status "$@"
fi

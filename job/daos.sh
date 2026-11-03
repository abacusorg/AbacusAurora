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
#   ABACUS_DAOS_CKPT_CONTAINERS=on
#                               one DAOS container per checkpoint, destroyed when the
#                               checkpoint retires (Abacus's CheckpointContainers; see
#                               abacus doc/checkpoints.md).  The checkpoint root then stays
#                               on flare -- it holds SCR's index and the links into the
#                               containers -- and `Checkpoints` is not mounted.  Default off.
#
# Also exported for aurora.def: ABACUS_DAOS_POOL (the pool the containers are made in) and
# ABACUS_CHECKPOINT_CONTAINERS (1 or 0, from the switch above).

DAOS_POOL=${ABACUS_DAOS_POOL:-AbacusAurora}
DAOS_CONT_OUTPUTS=${ABACUS_DAOS_CONT_OUTPUTS:-Outputs}
DAOS_CONT_CHECKPOINTS=${ABACUS_DAOS_CONT_CHECKPOINTS:-Checkpoints}
DAOS_CONT_RESOURCES=${ABACUS_DAOS_CONT_RESOURCES:-Resources}

FLARE_ROOT=/flare/Abacus/$USER
FLARE_RESOURCES=/flare/Abacus

# Our patched launch-dfuse.sh (for next-eval image)
DAOS_LAUNCH_DFUSE=$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/launch-dfuse.sh

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
    export ABACUS_DAOS_POOL=$DAOS_POOL
    export ABACUS_CHECKPOINT_CONTAINERS=0
    _is_on "${ABACUS_DAOS:-off}" || return 0   # the DAOS on/off default

    # Outputs comes along even when the outputs stay on flare: it hosts the working
    # directory.  With a container per checkpoint the checkpoint root stays on flare,
    # where Abacus keeps SCR's index and the links into the containers, so `Checkpoints`
    # is not needed at all.
    if _is_on "${ABACUS_DAOS_CKPT_CONTAINERS:-off}"; then   # the per-checkpoint default
        ABACUS_CHECKPOINT_CONTAINERS=1
    else
        daos_conts+=("$DAOS_CONT_CHECKPOINTS")
        ABACUS_CHECKPOINT_ROOT=$(daos_mountpoint "$DAOS_CONT_CHECKPOINTS")/$USER
    fi
    daos_conts+=("$DAOS_CONT_OUTPUTS")
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
#
# With $DAOS_CKPT_MAP set (see daos_ckpt_map), the same ssh per node also mounts that
# node's sim's checkpoint containers, so they cost no extra sweep.
daos_mount() {
    local specs=() cont map_args=()
    for cont; do specs+=("$DAOS_POOL:$cont"); done
    if [[ -n ${DAOS_CKPT_MAP:-} ]]; then
        map_args=(--ckpt-map "$(daos_ckpt_helper)" "$DAOS_POOL" "$DAOS_CKPT_MAP")
    fi
    "$DAOS_LAUNCH_DFUSE" ${map_args[@]+"${map_args[@]}"} "${specs[@]}"
}

# --- One container per checkpoint (ABACUS_DAOS_CKPT_CONTAINERS) ---------------------
# Abacus creates, mounts, unmounts and destroys them itself, mid-run.  The job's part is
# to have each sim's existing containers mounted on that sim's nodes before it starts,
# in the same sweep as the global containers.  All DAOS commands go through Abacus's
# helper, src/Util/ckpt-container.sh, which refuses to create or destroy anything that
# is not a ckpt-* label.

daos_ckpt_helper() { printf '%s/src/Util/ckpt-container.sh\n' "${ABACUS_BUILD%/}"; }

# The checkpoint containers a prefix links to, one label per line: the targets of its
# state_* and spare links that are /tmp/<pool>/ckpt-*.  The prefix is on flare, so this
# needs no DAOS mount.
daos_ckpt_labels() {
    local prefix=$1 link target
    for link in "$prefix"/state_* "$prefix"/spare; do
        [[ -L $link ]] || continue   # also skips an unmatched glob
        target=$(readlink "$link")
        if [[ $target =~ ^/tmp/[^/]+/(ckpt-[^/]+)(/|$) ]]; then
            echo "${BASH_REMATCH[1]}"
        fi
    done | sort -u
}

# Append "<host> <label>..." for every host in <hostfile>, the labels being the
# containers <prefix> links to.  The helper's `ensure` reads this.
daos_ckpt_map() {
    local prefix=$1 hostfile=$2 map=$3 labels host
    labels=$(daos_ckpt_labels "$prefix" | tr '\n' ' ')
    [[ -n $labels ]] || return 0
    while read -r host; do
        [[ -n $host ]] && printf '%s %s\n' "$host" "$labels"
    done < <(sort -u "$hostfile") >> "$map"
}

# A sim's CheckpointDirectory, from its par2 (plus any -P overrides), parsed in the job's
# environment, as onesim.sh does for OutputDirectory.
daos_ckpt_prefix() {
    local par2=$1; shift
    local pargs=() o
    for o; do pargs+=(-P "$o"); done
    python -m abacus.param "$par2" ${pargs[@]+"${pargs[@]}"} -o /dev/stdout 2>/dev/null \
        | awk -F'"' '/^CheckpointDirectory[[:space:]]*=/{print $2; exit}'
}

# Mount the given containers on THIS NODE only, at the per-user login mountpoint.
# daos_mount() drives launch-dfuse.sh over $PBS_NODEFILE and so needs an allocation;
# this is the single-node equivalent, for anything that runs on a login node.  Already
# mounted is success: the mounts are per-user and concurrent readers share them.
daos_login_mount() {
    local cont mnt i
    daos_preflight || return 1
    for cont; do
        mnt=$(daos_login_mountpoint "$cont")
        if mountpoint -q "$mnt"; then
            echo "already mounted: $mnt"
            continue
        fi
        if ! daos_have_container "$cont"; then
            echo "error: no container $DAOS_POOL:$cont" >&2
            return 1
        fi

        mkdir -p "$mnt"
        # Through daos_cli, not a bare dfuse: start-dfuse.sh needs the daos module's
        # environment (libfabric, the agent socket), which a login shell may not have.
        daos_cli start-dfuse.sh -m "$mnt" --pool "$DAOS_POOL" --cont "$cont" || return 1

        # dfuse daemonizes, so the mount appears a moment after the launcher returns.
        for i in $(seq 20); do
            mountpoint -q "$mnt" && break
            sleep 0.5
        done
        if ! mountpoint -q "$mnt"; then
            echo "error: dfuse did not mount $mnt" >&2
            return 1
        fi
        echo "mounted $DAOS_POOL:$cont at $mnt"
    done
}

# Tear down what daos_login_mount() made.  Unlike clean-dfuse.sh (which SIGKILLs every
# dfuse on every node) this touches only this user's mounts on this node, so it is safe
# to run while a job holds its own.
daos_login_unmount() {
    local cont mnt
    for cont; do
        mnt=$(daos_login_mountpoint "$cont")
        if mountpoint -q "$mnt"; then
            fusermount3 -u "$mnt"
            echo "unmounted $mnt"
        else
            echo "not mounted: $mnt"
        fi
        rmdir "$mnt" 2>/dev/null || true
    done
}

# Rewrite a DAOS path recorded elsewhere so it resolves here.  A parameter file is
# written on a compute node and so names daos_mountpoint(); on a shared login node
# the same container is at daos_login_mountpoint() instead.  Any other path -- flare,
# or a DAOS path already in login form -- passes through untouched.
daos_localize_path() {
    local p=$1
    if [[ -n ${PBS_NODEFILE:-} ]]; then printf '%s\n' "$p"; return; fi
    printf '%s\n' "${p/#\/tmp\/$DAOS_POOL\//\/tmp\/$USER\/$DAOS_POOL\/}"
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
    if (( ABACUS_CHECKPOINT_CONTAINERS )); then
        echo
        echo "one DAOS container per checkpoint: on (pool $DAOS_POOL; checkpoint root on flare)"
    fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    daos_status "$@"
fi

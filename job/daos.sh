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
#                               abacus doc/checkpoints.md).  The checkpoint root, which
#                               holds SCR's index and the links into the containers, is
#                               then on Outputs, and `Checkpoints` is not mounted.  Default off.
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
    # directory.  With a container per checkpoint it also hosts the checkpoint root,
    # where Abacus keeps SCR's index and the links into the containers, so `Checkpoints`
    # is not needed at all.
    if _is_on "${ABACUS_DAOS_CKPT_CONTAINERS:-off}"; then   # the per-checkpoint default
        ABACUS_CHECKPOINT_CONTAINERS=1
        ABACUS_CHECKPOINT_ROOT=$(daos_mountpoint "$DAOS_CONT_OUTPUTS")/$USER
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
daos_mount() {
    local specs=() cont
    for cont; do specs+=("$DAOS_POOL:$cont"); done
    "$DAOS_LAUNCH_DFUSE" "${specs[@]}"
}

# --- One container per checkpoint (ABACUS_DAOS_CKPT_CONTAINERS) ---------------------
# Abacus makes, fills and destroys them itself and needs only its restart candidates mounted:
# by daos_mount for a lone sim, else by onesim.sh, which also remounts them for a relaunch.

daos_ckpt_helper() { printf '%s/src/Util/ckpt-container.sh\n' "${ABACUS_BUILD%/}"; }

# The container a link in <prefix> points into, or nothing.
_daos_ckpt_label_of() {
    local target
    target=$(readlink "$1") || return 0
    [[ $target =~ ^/tmp/[^/]+/(ckpt-[^/]+)(/|$) ]] && echo "${BASH_REMATCH[1]}"
}

# The containers a sim can restart from, one per line: the newest state_NNNN's, which SCR_Init
# can rebuild from its cache, then the one <prefix>/flushed names, which SCR falls back to.
daos_ckpt_restart_labels() {
    local link step label newest flushed=
    newest=$(for link in "$1"/state_*; do
                 [[ -L $link && ${link##*/} =~ ^state_([0-9]+)$ ]] || continue   # or an unmatched glob
                 step=${BASH_REMATCH[1]}
                 label=$(_daos_ckpt_label_of "$link")
                 [[ -n $label ]] && echo "$step $label"
             done | sort -k1,1n | tail -1 | cut -d' ' -f2)
    link=$(readlink "$1/flushed" 2>/dev/null) && [[ $link == state_* && -L $1/$link ]] &&
        flushed=$(_daos_ckpt_label_of "$1/$link")
    [[ -n $newest ]] && echo "$newest"
    [[ -n $flushed && $flushed != "$newest" ]] && echo "$flushed"
    return 0
}

# daos_ckpt_restart_labels before daos_mount: through a mount of <prefix>'s container on this
# node alone, at the per-user path.
daos_ckpt_restart_labels_unmounted() {
    local prefix=$1 cont labels
    cont=${prefix#"$(daos_mountpoint '')"}
    [[ $cont != "$prefix" ]] || { daos_ckpt_restart_labels "$prefix"; return; }   # not on DAOS
    cont=${cont%%/*}
    daos_login_mount "$cont" >/dev/null || return 1
    labels=$(daos_ckpt_restart_labels "$(daos_login_path "$prefix")")
    daos_login_unmount "$cont" >/dev/null || true
    [[ -z $labels ]] || printf '%s\n' "$labels"
}

# Remount <label>s alone on <hostfile>'s hosts, and drop the space-separated <old> here, where
# daos_mount owns them.  The first host dumps its handles into <dir> for the rest to import;
# they live as long as its dfuse.
daos_ckpt_mount() {
    local hostfile=$1 dir=$2 old=$3 hosts label rc=0
    shift 3
    for label in $old; do
        mountpoint -q "$(daos_mountpoint "$label")" || continue
        bash "$(daos_ckpt_helper)" unmount "$DAOS_POOL" "$label" >/dev/null || rc=1
    done
    mapfile -t hosts < <(sort -u "$hostfile")
    (( ${#hosts[@]} && $# )) || return 1
    if _daos_ckpt_mount_on "${hosts[0]}" --dump-handles "$dir" "$@"; then
        if (( ${#hosts[@]} > 1 )); then
            _daos_ckpt_mount_on "$(IFS=,; echo "${hosts[*]:1}")" --read-handles "$dir" "$@" || rc=1
        fi
    else
        rc=1
    fi
    for label; do rm -f "$dir/.handles.$label"; done
    return $rc
}

# daos_ckpt_mount's remote half.  Under bash, since the login shell may be zsh (where an
# unmatched glob is an error); start-dfuse.sh exits 0 even when dfuse fails.
_daos_ckpt_mount_on() {
    local hosts=$1 mode=$2 dir=$3
    shift 3
    local script='helper=$1 pool=$2 mode=$3 dir=$4
shift 4
PATH=$PATH:/soft/daos/bin
for m in /tmp/"$pool"/ckpt-*; do
    mountpoint -q "$m" || continue
    bash "$helper" unmount "$pool" "${m##*/}" >/dev/null || exit 1
done
for label; do
    mnt=/tmp/$pool/$label hfile=$dir/.handles.$label
    mkdir -p "$mnt" || exit 1
    if [[ $mode == --dump-handles ]]; then rm -f "$hfile"; (umask 077 && : > "$hfile") || exit 1; fi
    start-dfuse.sh oneScratch --pool "$pool" --cont "$label" -m "$mnt" "$mode" "$hfile" \
        --disable-caching --disable-wb-cache
    for (( i = 0; i < 300; i++ )); do mountpoint -q "$mnt" && break; sleep 0.2; done
    if ! mountpoint -q "$mnt"; then
        echo "$(hostname -s): $pool:$label did not mount at $mnt" >&2; exit 1
    fi
    if [[ $mode == --dump-handles && ! -s $hfile ]]; then
        echo "$(hostname -s): dfuse wrote no handles to $hfile" >&2; exit 1
    fi
done'
    clush -S -w "$hosts" -f 208 -o "-o LogLevel=QUIET -o StrictHostKeyChecking=no" \
          "$(printf '%q ' bash -c "$script" ckpt-mount \
                   "$(daos_ckpt_helper)" "$DAOS_POOL" "$mode" "$dir" "$@")"
}

# 0 if every <label> is mounted on every host in <hostfile>.
daos_ckpt_mounted() {
    local hostfile=$1 label mnts=()
    shift
    for label; do mnts+=("$(daos_mountpoint "$label")"); done
    clush -S -w "$(sort -u "$hostfile" | paste -sd, -)" -f 208 \
          -o "-o LogLevel=QUIET -o StrictHostKeyChecking=no" \
          "$(printf '%q ' bash -c 'for m; do mountpoint -q "$m" || exit 1; done' ckpt-mounted \
                   "${mnts[@]}")" \
          >/dev/null 2>&1
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
# this is the single-node equivalent, for a login node or one node of a job before daos_mount.
# Already mounted is success: the mounts are per-user and concurrent readers share them.
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
    daos_login_path "$p"
}

# A path under a daos_mountpoint() rewritten to the same place under the
# daos_login_mountpoint(), wherever this runs.  Any other path passes through untouched.
daos_login_path() { printf '%s\n' "${1/#\/tmp\/$DAOS_POOL\//\/tmp\/$USER\/$DAOS_POOL\/}"; }

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
    if (( ABACUS_CHECKPOINT_CONTAINERS )); then
        echo
        echo "one DAOS container per checkpoint: on (pool $DAOS_POOL; checkpoint root on $DAOS_CONT_OUTPUTS)"
    fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    daos_status "$@"
fi

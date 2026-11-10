#!/bin/bash
# Delete the working files of simulations that have been post-processed --
# the checkpoint/, log/ and work/ directories, the FFTW wisdom file, and any
# archived failed attempts (<SimName>.old.N) -- then
# seal the SimDirectory: create an empty products/ and make everything
# read-only except products/, which stays user+group writable (and setgid, so
# that what a collaborator drops there keeps the sim's group).
#
# postprocess.done in the SimDirectory is the key: it is written by
# postprocessing.sh only after the outputs have been checked against their
# checksums and the logs archived into history.asdf and log.zip.  A sim without
# it is left completely alone -- the logs may be the only remaining record of
# what went wrong.
#
# Where they are comes from the sim's parameter file: aurora.def puts checkpoint/ and
# work/ (CheckpointDirectory, StateDirectory) under $ABACUS_CHECKPOINT_ROOT$/<SimName>
# and log/ under WorkingDirectory, $ABACUS_WORKING_ROOT$/<SimName>, while the
# SimDirectory is $ABACUS_OUTPUT_ROOT$/<SimName>.  With everything on flare those are
# all the SimDirectory.  With DAOS on they are on a DAOS container, and --daos mounts
# it and cleans them there; without --daos such a sim is skipped, with a warning.
# A *.par that cannot be read (no abacus env) means the SimDirectory, as before.
#
# Usage: cleanup_sims.sh [-n] [--daos] <simdir> [simdir ...]
#   -n       say what would be done, and touch nothing
#   --daos   clean the working files where the parameter file put them on DAOS,
#            mounting their containers first (across the allocation inside PBS,
#            per-user on a login node, left mounted as postprocessing.sh leaves it).
#            A sim on a pool other than $ABACUS_DAOS_POOL (default AbacusAurora) is
#            skipped: set that variable to clean it.
#
# Exits nonzero if any named sim was skipped, so that a sweep over many sims
# does not quietly leave some behind.

set -euo pipefail

usage() {
    echo "usage: cleanup_sims.sh [-n] [--daos] <simdir> [simdir ...]" >&2
    exit 2
}

dryrun=0
daos=0
simdirs=()
while (( $# )); do
    case $1 in
        -n)         dryrun=1; shift ;;
        --daos)     daos=1; shift ;;
        -h|--help)  usage ;;
        --)         shift; simdirs+=("$@"); break ;;
        -*)         echo "error: unknown option '$1'" >&2; usage ;;
        *)          simdirs+=("$1"); shift ;;
    esac
done
(( ${#simdirs[@]} )) || usage
set -- "${simdirs[@]}"

KEY=postprocess.done

# For daos_mount, daos_login_mount and daos_localize_path.  Sourcing only defines them.
source "$(dirname "${BASH_SOURCE[0]}")/daos.sh"

# Use scripts/daosrm for DAOS, which uses the intercept preload and runs in parallel
DAOSRM=$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/daosrm

# du is read-mostly metadata, where the interception library is worth ~1.9x on DAOS
# (23.6s -> 12.3s per 10k files) and is lost in the noise on flare, so every du gets
# it.  DAOS_PRELOAD alone is not enough: without the agent socket directory pil4dfs
# cannot reach the agent.  Resolved once here -- the module load costs ~0.5s.
if [[ -z ${DAOS_PRELOAD:-} || -z ${DAOS_AGENT_DRPC_DIR:-} ]]; then
    eval "$(bash -lc '{ module use /soft/modulefiles && module load daos; } >&2 &&
                      printf "DAOS_PRELOAD=%q\nDAOS_AGENT_DRPC_DIR=%q\n" \
                             "${DAOS_PRELOAD:-}" "${DAOS_AGENT_DRPC_DIR:-}"' 2>/dev/null)" || true
fi
export DAOS_PRELOAD DAOS_AGENT_DRPC_DIR

rm_rf() {
    if [[ $(df --output=fstype "$1" 2>/dev/null | tail -1) == fuse.daos ]]; then
        "$DAOSRM" -rf -- "$1"
    else
        rm -rf -- "$1"
    fi
}

# One DAOS container per checkpoint (ABACUS_DAOS_CKPT_CONTAINERS): a checkpoint directory
# then holds only links into the containers, so deleting it would leave the containers --
# the actual checkpoints -- with nothing pointing at them.  Every container linked from a
# directory is destroyed before the directory goes, through Abacus's helper, which refuses
# any label that is not ckpt-*.  Found via $ABACUS_CKPT_HELPER, else $ABACUS_BUILD, else
# the ABACUS_BUILD the sim's own job ran with (provenance/env.txt, written by onesim.sh).
CKPT_HELPER=${ABACUS_CKPT_HELPER:-${ABACUS_BUILD:+${ABACUS_BUILD%/}/src/Util/ckpt-container.sh}}

# The helper for the sim being cleaned ($src): $CKPT_HELPER if set, else its job's build.
ckpt_helper() {
    local build
    if [[ -n $CKPT_HELPER ]]; then
        echo "$CKPT_HELPER"
    elif build=$(sed -n 's/^ABACUS_BUILD=//p' "$src/provenance/env.txt" 2>/dev/null | head -1) &&
         [[ -n $build ]]; then
        echo "${build%/}/src/Util/ckpt-container.sh"
    fi
}

# "<pool> <label>" for every checkpoint container linked from anywhere under <path>.
container_links() {
    local l t
    find "$1" -type l 2>/dev/null | while read -r l; do
        t=$(readlink "$l")
        if [[ $t =~ ^/tmp/([^/]+)/(ckpt-[^/]+)(/|$) ]]; then
            echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
        fi
    done | sort -u
}

# Destroy the containers linked from under <path>.  Nonzero if any is left, in which case
# the caller must not delete <path>: its links are the only record of those containers.
destroy_containers() {
    local path=$1 pool label rc=0 helper
    helper=$(ckpt_helper)
    while read -r pool label; do
        [[ -n $label ]] || continue
        if (( dryrun )); then
            echo "  would destroy checkpoint container $pool:$label${helper:+ (with $helper)}"
        elif [[ -z $helper || ! -f $helper ]]; then
            echo "  warning: no ckpt-container.sh${helper:+ at $helper} to destroy $pool:$label (set ABACUS_BUILD or ABACUS_CKPT_HELPER)" >&2
            rc=1
        elif out=$(bash "$helper" destroy "$pool" "$label" 2>&1); then
            echo "  destroyed checkpoint container $pool:$label"
        else
            echo "  warning: could not destroy $pool:$label: $(tail -1 <<<"$out")" >&2
            rc=1
        fi
    done < <(container_links "$path")
    return $rc
}

# Delete one path, reporting its size first.  A symlink is left alone: rm would
# take the link and leave the data it points at, which looks like a cleanup but
# reclaims nothing.
remove() {
    local path=$1 kind=$2 size
    if [[ -L $path ]]; then
        echo "  warning: $(basename "$path") is a symlink; leaving it and its target" >&2
        return 1
    fi
    if [[ ! -e $path ]]; then
        echo "  $(basename "$path"): already gone"
        return 0
    fi
    if [[ $kind == dir && ! -d $path ]]; then
        echo "  warning: $(basename "$path") is not a directory; leaving it" >&2
        return 1
    fi
    if [[ $kind == dir ]] && ! destroy_containers "$path"; then
        echo "  warning: leaving $(basename "$path"): not every checkpoint container it links to was destroyed" >&2
        return 1
    fi
    size=$(LD_PRELOAD=${DAOS_PRELOAD:-} du -sh "$path" 2>/dev/null | cut -f1) || size='?'
    if (( dryrun )); then
        echo "  would delete $(basename "$path")  ($size)"
    else
        rm_rf "$path"
        echo "  deleted $(basename "$path")  ($size)"
    fi
    return 0
}

# SimName, WorkingDirectory, CheckpointDirectory, StateDirectory and LogDirectory, one per
# line, via Abacus's own parameter parser, as postprocessing.sh's sim_logdir() does.
# Nonzero unless there is exactly one *.par (or the abacus env is not loaded).
sim_dirs() {
    python3 - "$1" <<'ENDPY'
import sys
from pathlib import Path
from abacus.param import InputFile

pars = sorted(Path(sys.argv[1]).glob('*.par'))
if len(pars) != 1:
    sys.exit(1)
p = dict(InputFile(str(pars[0])))
for k in ('SimName', 'WorkingDirectory', 'CheckpointDirectory', 'StateDirectory', 'LogDirectory'):
    print(p.get(k, ''))
ENDPY
}

# Mount <cont> here once: across the allocation inside PBS, else per-user on this node.
declare -A daos_mounted=()
daos_ensure_mounted() {
    local cont=$1
    [[ -n ${daos_mounted[$cont]:-} ]] && return 0
    if [[ -n ${PBS_NODEFILE:-} ]]; then
        daos_mount "$cont" || return 1
    else
        daos_login_mount "$cont" || return 1
    fi
    daos_mounted[$cont]=1
}

# Set workdir, ckptdir, statedir and logdir for the sim in $src: the SimDirectory's own
# checkpoint/, work/ and log/ when everything is there, else (--daos) where its parameter
# file put them, mounted and localized.  Returns nonzero with the reason in $target_reason.
# Results by assignment, as a $(...) subshell would lose them.
resolve_targets() {
    local out dirs=() simname d pool cont
    workdir=$src ckptdir=$src/checkpoint statedir=$src/work logdir=$src/log
    target_reason=
    if ! out=$(sim_dirs "$src" 2>/dev/null); then
        (( daos )) || return 0
        target_reason="cannot read the paths from a *.par here (exactly one *.par, and the abacus env sourced?)"
        return 1
    fi
    mapfile -t dirs <<<"$out"
    simname=${dirs[0]:-}
    local w=${dirs[1]:-} c=${dirs[2]:-} s=${dirs[3]:-} l=${dirs[4]:-}

    if (( ! daos )); then
        # Unchanged unless the working directory is on DAOS, where nothing here can reach it.
        if [[ $w == /tmp/* && ! $w -ef $src ]]; then
            target_reason="its working files are under $w, on DAOS; rerun with --daos"
            return 1
        fi
        return 0
    fi

    # Only paths shaped the way aurora.def makes them, so a hand-edited or foreign
    # parameter file cannot point the deletes somewhere else.
    if [[ -z $simname || $w != */"$simname" || $c != */"$simname"/checkpoint ||
          $s != */"$simname"/work || $l != "$w"/log ]]; then
        target_reason="the *.par's directories are not <root>/$simname{,/checkpoint,/work,/log}"
        return 1
    fi
    for d in "$w" "$c" "$s"; do
        [[ $d =~ ^/tmp/([^/]+)/([^/]+)/ ]] || continue   # not on DAOS: flare, used as is
        pool=${BASH_REMATCH[1]} cont=${BASH_REMATCH[2]}
        if [[ $pool != "$DAOS_POOL" ]]; then
            target_reason="$d is on pool $pool; set ABACUS_DAOS_POOL=$pool to clean it"
            return 1
        fi
        if ! daos_ensure_mounted "$cont"; then
            target_reason="could not mount $pool:$cont"
            return 1
        fi
    done
    workdir=$(daos_localize_path "$w")
    ckptdir=$(daos_localize_path "$c")
    statedir=$(daos_localize_path "$s")
    logdir=$(daos_localize_path "$l")
}

# Remove <dir> if it is now empty and is not the SimDirectory: the per-sim directory on a
# root other than the outputs'.  Anything still in it is named and left.
remove_if_empty() {
    local dir=$1 left
    [[ -d $dir && ! $dir -ef $src ]] || return 0
    if (( dryrun )); then
        echo "  would remove $dir, if nothing else is left in it"
    elif rmdir -- "$dir" 2>/dev/null; then
        echo "  removed $dir"
    else
        left=$(ls -A -- "$dir" | head -5 | paste -sd' ' -)
        echo "  note: leaving $dir, which still holds: $left"
    fi
}

ncleaned=0 nskipped=0 nwarned=0
rc=0
nsim=0 ntotal=$#     # $# is the sim count: the options are gone, and the loop never shifts

for src; do
    src=${src%/}
    nsim=$((nsim + 1))
    echo "=== $(basename "$src") ($nsim of $ntotal) ==="

    if [[ ! -d $src ]]; then
        echo "  warning: not a directory: $src" >&2
        nskipped=$((nskipped + 1)); rc=1
        continue
    fi
    if [[ ! -e $src/$KEY ]]; then
        echo "  warning: no $KEY here; deleting nothing" >&2
        nskipped=$((nskipped + 1)); rc=1
        continue
    fi

    if ! resolve_targets; then
        echo "  warning: $target_reason; deleting nothing" >&2
        nskipped=$((nskipped + 1)); rc=1
        continue
    fi
    [[ $workdir -ef $src ]] || echo "  working files under $workdir"
    [[ $(dirname "$ckptdir") == "$workdir" ]] || echo "  checkpoints under $(dirname "$ckptdir")"

    failed=0
    remove "$ckptdir" dir || failed=1
    remove "$logdir" dir || failed=1
    remove "$statedir" dir || failed=1

    # fftw_<cpd>.wisdom, and any siblings from a run at another cpd.
    shopt -s nullglob
    wisdom=("$src"/fftw*wisdom)
    shopt -u nullglob
    if (( ${#wisdom[@]} == 0 )); then
        echo "  fftw*wisdom: already gone"
    else
        for w in "${wisdom[@]}"; do
            remove "$w" file || failed=1
        done
    fi

    # Prior failed attempts of this sim.  Abacus archives each root a directory hangs off
    # as <dir>.old.N, so on DAOS there are working ones too, and on a separate checkpoint
    # root a checkpoint.old.N and work.old.N; a checkpoint among them is links, whose
    # containers remove() destroys first.  sort -u: on one root the globs coincide.
    shopt -s nullglob
    mapfile -t attempts < <(printf '%s\n' "$src".old.[0-9]* "$workdir".old.[0-9]* \
                                          "$ckptdir".old.[0-9]* "$statedir".old.[0-9]* | sed '/^$/d' | sort -u)
    shopt -u nullglob
    if (( ${#attempts[@]} == 0 )); then
        echo "  *.old.N: already gone"
    else
        for a in "${attempts[@]}"; do
            remove "$a" dir || failed=1
        done
    fi

    if (( ! failed )); then
        [[ $(dirname "$ckptdir") == "$workdir" ]] || remove_if_empty "$(dirname "$ckptdir")"
        remove_if_empty "$workdir"
    fi

    # products/ is where anything derived from this sim goes from here on: it is
    # the one place left writable below.  mkdir -p is content with an existing
    # one, and does not need write permission on a SimDirectory already sealed
    # by an earlier run.
    if [[ -d $src/products ]]; then
        echo "  products/: already there"
    elif (( dryrun )); then
        echo "  would create products/"
    elif mkdir -p "$src/products"; then
        echo "  created products/"
    else
        echo "  warning: could not create products/" >&2
        failed=1
    fi

    # Seal it.  Not if something was left behind: rm needs write permission on
    # the containing directory, so locking now would make the leftover
    # undeletable until someone chmods by hand.  Leave it open, warn, and let a
    # rerun finish the job once the leftover has been sorted out.
    if (( failed )); then
        echo "  warning: something was left behind; leaving permissions alone" >&2
    elif (( dryrun )); then
        echo "  would make everything read-only, products/ user+group writable"
    # products/ is pruned rather than stripped and re-opened, so that a rerun
    # leaves whatever is already in there exactly as its owner left it.  Symlinks
    # are skipped too: chmod follows them, and the target is somebody else's.
    elif find "$src" -path "$src/products" -prune -o ! -type l -exec chmod a-w {} + &&
         chmod ug+w "$src/products"; then
        # setgid keeps the sim's group on whatever gets dropped into products/,
        # but the kernel refuses it to anyone who is not a member of that group.
        # That is a nicety to do without, not a reason to fail the seal.
        chmod g+s "$src/products" 2>/dev/null ||
            echo "  note: could not setgid products/; new files there get your default group"
        echo "  read-only, except products/"
    else
        echo "  warning: chmod incomplete; permissions may be half-set" >&2
        failed=1
    fi

    if (( failed )); then
        nwarned=$((nwarned + 1)); rc=1
    fi
    ncleaned=$((ncleaned + 1))
done

echo
verb=$( (( dryrun )) && echo 'would clean' || echo cleaned )
detail=$( (( nwarned )) && echo " ($nwarned with something left behind)" || true )
echo "$verb $ncleaned$detail, skipped $nskipped"
exit $rc

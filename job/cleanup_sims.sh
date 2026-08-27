#!/bin/bash
# Delete the working files of simulations that have been post-processed --
# the checkpoint/, log/ and work/ directories and the FFTW wisdom file -- then
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
# Note that these four live under WorkingDirectory, which aurora.def points at
# $ABACUS_WORKING_ROOT$/<SimName> while the SimDirectory is
# $ABACUS_OUTPUT_ROOT$/<SimName>.  When those two roots are the same, as they are
# for the runs this is written for, they are right here in the SimDirectory.
# When they are not, this reports each target as already gone and deletes
# nothing, which is the safe way to be wrong.
#
# Usage: cleanup_sims.sh [-n] <simdir> [simdir ...]
#   -n   say what would be done, and touch nothing
#
# Exits nonzero if any named sim was skipped, so that a sweep over many sims
# does not quietly leave some behind.

set -euo pipefail

usage() {
    echo "usage: cleanup_sims.sh [-n] <simdir> [simdir ...]" >&2
    exit 2
}

dryrun=0
while getopts ':n' opt; do
    case $opt in
        n) dryrun=1 ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))
(( $# )) || usage

KEY=postprocess.done

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
    size=$(du -sh "$path" 2>/dev/null | cut -f1) || size='?'
    if (( dryrun )); then
        echo "  would delete $(basename "$path")  ($size)"
    else
        rm -rf -- "$path"
        echo "  deleted $(basename "$path")  ($size)"
    fi
    return 0
}

ncleaned=0 nskipped=0 nwarned=0
rc=0
nsim=0 ntotal=$#     # $# is the sim count: getopts was shifted off, and the loop never shifts

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

    failed=0
    remove "$src/checkpoint" dir || failed=1
    remove "$src/log" dir || failed=1
    remove "$src/work" dir || failed=1

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

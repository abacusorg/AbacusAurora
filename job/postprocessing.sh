#!/bin/bash
# Post-process finished simulations: verify that the run reached the end and that
# every output file is the size its checksum record claims, then archive the logs.
#
# Given one or more SimDirectories, in order, per sim:
#
#   1. every rank's checksum file records exactly one maplog.  The MapForest is
#      dumped to one ASDF per rank exactly once, on the final NoForces step, so a
#      rank with no maplog line never got there.
#   2. the maplog files on disk are the size the checksums say.
#   3. history.asdf, and
#   4. log.zip -- both via archive-logs.sh, which already does them.
#   5. every other checksummed directory is the size the checksums say.  The list
#      of directories comes from the checksum records themselves, so timeslices,
#      group files and anything added later are covered without editing this.
#      `work` is the one exclusion -- it is the state, not an output.  See the
#      skip list at step 5.
#
# A failing step stops that sim; the remaining sims are still processed.
#
# Each sim's steps are recorded in a `postprocess` file in its SimDirectory,
# renamed to `postprocess.done` or `postprocess.failed` at the end.  A sim with
# postprocess.done is left alone -- delete that file to redo one.  A sim with
# postprocess.failed, or with a bare `postprocess` from an interrupted run, is
# also left alone unless -f is given.
#
# Deliberately not done here: deleting log/, checkpoint/, or the wisdom file.
# That is a separate cleanup script.
#
# Usage: postprocessing.sh [-f] <simdir> [simdir ...]
#   -f   re-run sims whose last attempt failed or was interrupted
#
# Environment:
#   ARCHIVE_LOGS   path to archive-logs.sh (default: beside this script)

set -euo pipefail

usage() {
    echo "usage: postprocessing.sh [-f] <simdir> [simdir ...]" >&2
    exit 2
}

force=0
while getopts ':f' opt; do
    case $opt in
        f) force=1 ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))
(( $# )) || usage

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ARCHIVE_LOGS=${ARCHIVE_LOGS:-$here/archive-logs.sh}
if [[ ! -x $ARCHIVE_LOGS ]]; then
    echo "error: no executable archive-logs.sh at $ARCHIVE_LOGS" >&2
    echo "       (set ARCHIVE_LOGS if it lives elsewhere)" >&2
    exit 1
fi

# `lfs find` answers from the MDS instead of stat()ing every file, which is what
# makes this affordable on a slice directory of tens of thousands of files.  GNU
# find is the fallback for a sim sitting on something other than Lustre.
if command -v lfs >/dev/null 2>&1; then
    findsizes() { lfs find "$1" -type f --printf '%s\t%p\n'; }
else
    findsizes() { find "$1" -type f -printf '%s\t%p\n'; }
fi

record=postprocess     # the in-progress record, relative to the SimDirectory

# Progress goes to the screen and to the record at once; the record is what
# survives to explain a postprocess.failed.
say() {
    printf '  %s\n' "$*"
    printf '%s\n' "$*" >> "$record"
}

# "<size> <path>" for everything on disk under $1, sorted by path then size.
ondisk_sizes() {
    findsizes "$1" | gawk '{print $1, $2}' | LC_ALL=C sort -k2,2 -k1,1
}

# The same, from the checksum records, whose lines are "<crc32> <size> <path
# relative to the SimDirectory>".  A restart appends to the same checksum files,
# so an output regenerated after the restart is recorded twice; -u drops the
# identical copies.  Two records for one path with *different* sizes are two
# distinct lines and still show up in the diff, which is the case worth seeing.
recorded_sizes() {
    gawk -v root="$1" 'NF >= 3 && ($3 == root || index($3, root "/") == 1) { print $2, $3 }' \
        "${cksums[@]}" | LC_ALL=C sort -u -k2,2 -k1,1
}

# Compare one top-level output name against its checksum records.
check_root() {
    local root=$1 diffout n nlines rc=0

    if [[ ! -e $root ]]; then
        say "  $root: recorded in the checksums but not present"
        return 1
    fi
    diffout=$(diff <(ondisk_sizes "$root") <(recorded_sizes "$root")) || rc=$?
    if (( rc == 0 )); then
        say "  ok: $root"
        return 0
    fi
    if (( rc > 1 )); then
        say "  $root: could not compare (diff exited $rc)"
        return 1
    fi

    # Count the paths that disagree, not the lines of diff: a size mismatch is two
    # lines about one file.
    n=$(printf '%s\n' "$diffout" | gawk '/^[<>]/ { seen[$3] } END { print length(seen) }')
    nlines=$(printf '%s\n' "$diffout" | gawk 'END { print NR }')
    say "  $root: $n file(s) disagree"
    say "    '<' is on disk at a size nothing recorded; '>' was recorded but is"
    say "    not on disk at that size"
    printf '%s\n' "$diffout" >> "$record"
    # gawk rather than head: head would close the pipe early, and with pipefail
    # that SIGPIPE would look like a failure of its own.
    printf '%s\n' "$diffout" | gawk 'NR <= 20 { print "    " $0 }'
    if (( nlines > 20 )); then
        echo "    ... $((nlines - 20)) more line(s), all of them in $PWD/$record"
    fi
    return 1
}

# The five steps, run with $PWD = the SimDirectory.  Returns nonzero at the first
# step that fails, having said why.
process_sim() {
    local f n root fflag='' bad=0 failed=0 checked=0
    local -a rank_cksums=() unrecorded=() roots=()

    # Deliberately not local: recorded_sizes reads it.
    shopt -s nullglob
    cksums=(checksums/col*/checksums.*.crc32)
    shopt -u nullglob

    # --- Step 1 -----------------------------------------------------------
    say "step 1: one maplog per rank"
    if (( ${#cksums[@]} == 0 )); then
        say "  no checksums/col*/checksums.*.crc32 files at all"
        return 1
    fi
    for f in "${cksums[@]}"; do
        # checksums<rank>.unrecorded.crc32 holds entries the IO thread could not
        # record as it went (the run logs a WARNING when it writes one).  It is
        # not a rank's own file, so it has no maplog of its own to account for --
        # but its records do count for the size checks below.
        case $f in
            *.unrecorded.crc32) unrecorded+=("$f") ;;
            *)                  rank_cksums+=("$f") ;;
        esac
    done
    if (( ${#unrecorded[@]} )); then
        for f in "${unrecorded[@]}"; do
            say "  warning: $f exists, so some checksums were not recorded incrementally"
        done
    fi
    if (( ${#rank_cksums[@]} == 0 )); then
        say "  every checksum file is an unrecorded one; no rank wrote its own"
        return 1
    fi
    for f in "${rank_cksums[@]}"; do
        # Distinct paths, so a restart's duplicate record still counts as one maplog.
        n=$(gawk 'NF >= 3 && $3 ~ /^maplogs\// { seen[$3] } END { print length(seen) }' "$f")
        if (( n != 1 )); then
            say "  $f records $n maplog files, expected 1"
            bad=$((bad + 1))
        fi
    done
    if (( bad )); then
        if (( bad == ${#rank_cksums[@]} )); then
            say "  no rank recorded a maplog; was this built without USE_TRACERS?"
        fi
        say "  $bad of ${#rank_cksums[@]} rank checksum files do not have exactly one maplog"
        return 1
    fi
    say "  ok: ${#rank_cksums[@]} rank checksum files, one maplog each"

    # --- Step 2 -----------------------------------------------------------
    say "step 2: maplog file sizes"
    check_root maplogs || return 1

    # --- Steps 3 and 4 ----------------------------------------------------
    # archive-logs.sh writes both history.asdf and log.zip, each via a .part file
    # and a rename.  -d names the destination root so that the archives land in
    # this SimDirectory, rather than in whatever OutputDirectory the parameter
    # file names -- which may not even be mounted here.
    say "steps 3+4: history.asdf and log.zip"
    if (( force )); then fflag=-f; fi
    # $fflag is deliberately unquoted: empty must expand to no argument at all.
    if "$ARCHIVE_LOGS" $fflag -d "$(dirname "$PWD")" "$PWD" 2>&1 |
            tee -a "$record" | sed 's/^/    /'; then
        say "  ok: history.asdf and log.zip"
    else
        say "  archive-logs.sh failed"
        return 1
    fi

    # --- Step 5 -----------------------------------------------------------
    # Every top-level name the checksums mention, so that a new kind of output is
    # checked the day it appears.  maplogs was step 2.
    say "step 5: the remaining checksummed output sizes"
    while IFS= read -r root; do
        roots+=("$root")
    done < <(gawk 'NF >= 3 { split($3, a, "/"); print a[1] }' "${cksums[@]}" |
                 LC_ALL=C sort -u)
    if (( ${#roots[@]} )); then
        for root in "${roots[@]}"; do
            # maplogs was step 2.
            #
            # work is the StateDirectory ($ABACUS_CHECKPOINT_ROOT/<SimName>/work per
            # aurora.def).  When the checkpoint and output roots coincide -- which they
            # do whenever the outputs are not on DAOS -- it sits inside the
            # OutputDirectory, so the checksum paths, which are recorded relative to
            # that, come out as "work/...".  Those records are not outputs and are not
            # expected to match: the state is rewritten every step, and slab sizes shift
            # as particles move between slabs, so a record from an earlier step
            # legitimately disagrees with what is on disk now.  Skip it rather than
            # reporting known-uninteresting disagreements.
            case $root in
                maplogs|work) continue ;;
            esac
            checked=$((checked + 1))
            check_root "$root" || failed=$((failed + 1))
        done
    fi
    # Unlike the earlier steps, this one checks every directory before giving up:
    # they are independent, and the whole picture is more useful than the first
    # directory that happens to be wrong.
    if (( failed )); then
        say "  $failed of $checked checksummed directories disagree"
        return 1
    fi
    say "  ok: $checked directories besides maplogs and work"
}

ndone=0 nskip=0 nfail=0
rc=0

for src; do
    src=${src%/}
    echo "=== $(basename "$src") ==="

    if [[ ! -d $src ]]; then
        echo "  error: not a directory: $src" >&2
        nfail=$((nfail + 1)); rc=1
        continue
    fi
    if [[ -e $src/postprocess.done ]]; then
        echo "  postprocess.done is already here; nothing to do"
        ndone=$((ndone + 1))
        continue
    fi
    for stale in postprocess.failed postprocess; do
        if [[ -e $src/$stale ]] && (( ! force )); then
            echo "  $stale is from an earlier run; skipping (pass -f to retry)" >&2
            nskip=$((nskip + 1)); rc=1
            continue 2
        fi
    done

    rm -f -- "$src/postprocess.failed"
    {
        echo "# postprocessing.sh"
        echo "sim:     $(cd -- "$src" && pwd)"
        echo "started: $(date -Is) on $(hostname) by ${USER:-$(id -un)}"
    } > "$src/postprocess"

    # A subshell so that the cd, and any step's exit, is contained to this sim.
    if ( cd -- "$src" && process_sim ); then
        echo "finished: $(date -Is)  all steps passed" >> "$src/postprocess"
        mv -f -- "$src/postprocess" "$src/postprocess.done"
        echo "  wrote postprocess.done"
        ndone=$((ndone + 1))
    else
        echo "finished: $(date -Is)  FAILED" >> "$src/postprocess"
        mv -f -- "$src/postprocess" "$src/postprocess.failed"
        echo "  wrote postprocess.failed" >&2
        nfail=$((nfail + 1)); rc=1
    fi
done

echo
echo "$ndone done, $nskip skipped needing -f, $nfail failed"
exit $rc

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
#   6. the per-rank checksum files are combined into one checksums/colNNN.crc32
#      per column, and the per-column directories removed.  Last, so that every
#      check above runs against the files the run actually wrote.
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
# The SimDirectory is the OutputDirectory: checksums/ and maplogs/ are written there
# (P.OutputDirectory in io_thread.cpp and timestep.cpp), as are the group files and
# slices.  log/ is not: it hangs off WorkingDirectory, which under --daos is a DAOS
# container while the outputs stay on flare.  Steps 3+4 therefore read LogDirectory
# out of the sim's parameter file rather than assuming <simdir>/log, and --daos
# mounts the container that holds it.
#
# Usage: postprocessing.sh [-f] [--daos] <simdir> [simdir ...]
#   -f       re-run sims whose last attempt failed or was interrupted
#   --daos   mount the DAOS containers first, and resolve the paths a parameter file
#            recorded on a compute node.  Inside a PBS allocation this mounts across
#            the allocation; on a login node it mounts per-user, for this node only,
#            and leaves the mount behind (concurrent runs share it -- daos.sh's
#            daos_login_unmount tears it down).
#
# Environment:
#   ARCHIVE_LOGS   path to archive-logs.sh (default: beside this script)

set -euo pipefail

usage() {
    echo "usage: postprocessing.sh [-f] [--daos] <simdir> [simdir ...]" >&2
    exit 2
}

force=0
daos=0
simdirs=()
while (( $# )); do
    case $1 in
        -f|--force) force=1; shift ;;
        --daos)     daos=1; shift ;;
        -h|--help)  usage ;;
        --)         shift; simdirs+=("$@"); break ;;
        -*)         echo "error: unknown option '$1'" >&2; usage ;;
        *)          simdirs+=("$1"); shift ;;
    esac
done
(( ${#simdirs[@]} )) || usage
set -- "${simdirs[@]}"

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# For daos_resolve/daos_mount/daos_login_mount and daos_localize_path.  Sourcing only
# defines them; nothing is mounted and no root is set until --daos asks.
source "$here/daos.sh"
ARCHIVE_LOGS=${ARCHIVE_LOGS:-$here/archive-logs.sh}
if [[ ! -x $ARCHIVE_LOGS ]]; then
    echo "error: no executable archive-logs.sh at $ARCHIVE_LOGS" >&2
    echo "       (set ARCHIVE_LOGS if it lives elsewhere)" >&2
    exit 1
fi

# Mount whatever holds the working directories.  Inside an allocation daos_mount
# covers every node and a parameter file's paths resolve verbatim; on a login node the
# mounts are per-user and at a different path, which daos_localize_path fixes up.
setup_daos() {
    (( daos )) || return 0
    ABACUS_DAOS=on daos_resolve
    # Only the Outputs container: it holds the working directory, hence log/, and also
    # the outputs themselves when ABACUS_DAOS_OUTPUTS=on.  Checkpoints is not needed --
    # output_records() deliberately ignores anything outside the SimDirectory, which is
    # exactly what the checkpoint records are.
    if [[ -n ${PBS_NODEFILE:-} ]]; then
        echo "mounting $DAOS_CONT_OUTPUTS across the allocation"
        daos_mount "$DAOS_CONT_OUTPUTS" || exit 1
    else
        echo "mounting $DAOS_CONT_OUTPUTS on this login node (per-user)"
        daos_login_mount "$DAOS_CONT_OUTPUTS" || exit 1
    fi
}
setup_daos

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

# The checksum records the size checks look at: the ones naming something inside
# the SimDirectory.  A run whose CheckpointDirectory is elsewhere records the
# invocation-end state write by a path that climbs out ("../../../../tmp/..."), and
# step 5 takes the first component of every path as a directory to check -- so that
# record becomes a root of "..", sending check_root over the entire parent directory,
# every other sim included.  Runs from 2026-08 and earlier recorded the state; newer
# ones do not.
output_records() {
    gawk 'NF >= 3 && $3 !~ /^(\.\.|\/)/' "${cksums[@]}"
}

# The same, from the checksum records, whose lines are "<crc32> <size> <path
# relative to the SimDirectory>".  A restart appends to the same checksum files and
# rewrites the outputs of the steps it redoes, so one path can carry several records
# with different sizes.  The file on disk is whatever the last writer left, so the
# last record is the one to compare against; earlier ones describe a version that no
# longer exists.  gawk reads the files in argument order, so a later assignment wins.
recorded_sizes() {
    output_records |
        gawk -v root="$1" '($3 == root || index($3, root "/") == 1) { sz[$3] = $2 }
                           END { for (path in sz) print sz[path], path }' |
        LC_ALL=C sort -k2,2 -k1,1
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

# The sim's LogDirectory, via Abacus's own parameter parser so that quoting and
# includes are handled the way the code handles them.  Mirrors sim_outputdir() in
# archive-logs.sh; empty output (or a nonzero exit) means "could not tell".
sim_logdir() {
    python3 - "$1" <<'ENDPY'
import sys
from pathlib import Path
from abacus.param import InputFile

simdir = Path(sys.argv[1])
pars = sorted(simdir.glob('*.par'))
if len(pars) != 1:
    sys.exit(1)
print(dict(InputFile(str(pars[0]))).get('LogDirectory', ''))
ENDPY
}

# Sets $logroot to the directory to hand archive-logs.sh (which looks for <arg>/log):
# the SimDirectory when the log is right there (everything on one filesystem), else
# wherever the parameter file says the log went.  Returns nonzero with the reason in
# $logroot_reason, because "no log here" and "the abacus env is not loaded" want
# different responses from a human.
#
# Results by assignment, not stdout: a $(...) call would run this in a subshell and
# the reason would be lost with it.  Deliberately not local in the caller.
logroot=
logroot_reason=
resolve_logroot() {
    local logdir root
    logroot= logroot_reason=
    [[ -d $PWD/log ]] && { logroot=$PWD; return 0; }

    if ! logdir=$(sim_logdir "$PWD" 2>/dev/null) || [[ -z $logdir ]]; then
        logroot_reason="no log/ here, and no LogDirectory readable from a *.par"
        logroot_reason+=" (exactly one *.par, and the abacus env sourced?)"
        return 1
    fi
    logdir=$(daos_localize_path "$logdir")

    # Strip the trailing /log rather than taking dirname: archive-logs.sh appends
    # /log to whatever it is given, so a LogDirectory that does not end in /log
    # would silently send it somewhere else.
    root=${logdir%/log}
    if [[ $root == "$logdir" ]]; then
        logroot_reason="LogDirectory does not end in /log: $logdir"
        return 1
    fi
    if [[ ! -d $root/log ]]; then
        logroot_reason="LogDirectory names $logdir, which is not present here"
        return 1
    fi
    logroot=$root
}

# The five steps, run with $PWD = the SimDirectory.  Returns nonzero at the first
# step that fails, having said why.
process_sim() {
    local f n root fflag='' bad=0 failed=0 checked=0
    local -a rank_cksums=() unrecorded=() merged=() roots=() coldirs=()

    # Deliberately not local: recorded_sizes reads it.
    shopt -s nullglob
    # Both layouts: the per-rank files a run writes, and the per-column files
    # step 6 leaves behind, so that -f can re-check an already-combined sim.
    cksums=(checksums/col*/checksums.*.crc32 checksums/col*.crc32)
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
        # On the basename: a case pattern is not a pathname glob, so its * matches /
        # too, and "checksums/col*.crc32" would swallow every per-rank file as though
        # step 6 had already run -- silently skipping the one-maplog-per-rank check.
        case ${f##*/} in
            *.unrecorded.crc32) unrecorded+=("$f") ;;
            col*.crc32)         merged+=("$f") ;;
            checksums.*.crc32)  rank_cksums+=("$f") ;;
            *)                  say "  ignoring unrecognized checksum file $f" ;;
        esac
    done
    if (( ${#unrecorded[@]} )); then
        for f in "${unrecorded[@]}"; do
            say "  warning: $f exists, so some checksums were not recorded incrementally"
        done
    fi
    if (( ${#rank_cksums[@]} )); then
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
    elif (( ${#merged[@]} )); then
        # Step 6 already combined this sim, so the per-rank files are gone and one
        # maplog *per rank* is no longer answerable -- a column file holds every rank's
        # records at once.  Check what survives: every column recorded some.
        for f in "${merged[@]}"; do
            n=$(gawk 'NF >= 3 && $3 ~ /^maplogs\// { seen[$3] } END { print length(seen) }' "$f")
            if (( n == 0 )); then
                say "  $f records no maplog files"
                bad=$((bad + 1))
            else
                say "  $f records $n maplogs (already combined; the per-rank count is not checkable)"
            fi
        done
        if (( bad )); then
            say "  $bad of ${#merged[@]} combined checksum files record no maplog"
            return 1
        fi
    else
        say "  every checksum file is an unrecorded one; no rank wrote its own"
        return 1
    fi

    # --- Step 2 -----------------------------------------------------------
    say "step 2: maplog file sizes"
    check_root maplogs || return 1

    # --- Steps 3 and 4 ----------------------------------------------------
    # archive-logs.sh writes both history.asdf and log.zip, each via a .part file
    # and a rename.  -d names the destination root so that the archives land in
    # this SimDirectory, rather than in whatever OutputDirectory the parameter
    # file names -- which may not even be mounted here.
    #
    # The positional argument is the log's parent, not this SimDirectory: with the
    # outputs on flare and the working directory on DAOS they are different roots.
    # Both use <SimName> as their last component, so archive-logs.sh's basename still
    # resolves -d to this SimDirectory.
    say "steps 3+4: history.asdf and log.zip"
    if ! resolve_logroot; then
        say "  $logroot_reason"
        (( daos )) || say "    the working directory may be on DAOS; retry with --daos"
        return 1
    fi
    [[ $logroot == "$PWD" ]] || say "  log from $logroot"
    if (( force )); then fflag=-f; fi
    # $fflag is deliberately unquoted: empty must expand to no argument at all.
    if "$ARCHIVE_LOGS" $fflag -d "$(dirname "$PWD")" "$logroot" 2>&1 |
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
    done < <(output_records | gawk '{ split($3, a, "/"); print a[1] }' |
                 LC_ALL=C sort -u)
    if (( ${#roots[@]} )); then
        for root in "${roots[@]}"; do
            if [[ $root == maplogs ]]; then continue; fi
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
    say "  ok: $checked directories besides maplogs"

    # --- Step 6 -----------------------------------------------------------
    # One file per column instead of one per rank.  Last, so the checks above ran
    # against what the run wrote.  Record order within a rank is preserved and no
    # path is written by two ranks, so concatenating cannot change which record is
    # the last for a path -- which is what recorded_sizes() relies on.
    say "step 6: combine the per-rank checksum files"
    shopt -s nullglob
    coldirs=(checksums/col*/)
    shopt -u nullglob
    if (( ${#coldirs[@]} == 0 )); then
        say "  ok: already combined"
        return 0
    fi
    local col out nin nout ncol=0
    for f in "${coldirs[@]}"; do
        col=$(basename "$f")
        out=checksums/$col.crc32
        if [[ -e $out ]]; then
            say "  $out exists while $f is still here; refusing to merge twice"
            return 1
        fi
        # Count first, and only unlink once the combined file is provably complete:
        # these records are the only description of what the run wrote.
        nin=$(cat -- "$f"checksums.*.crc32 | wc -l)
        cat -- "$f"checksums.*.crc32 > "$out.part"
        nout=$(wc -l < "$out.part")
        if (( nin != nout )); then
            say "  $col: combined $nout lines from $nin; leaving $f alone"
            rm -f -- "$out.part"
            return 1
        fi
        mv -f -- "$out.part" "$out"
        rm -rf -- "$f"
        ncol=$((ncol + 1))
        say "  $col: $nout records"
    done
    say "  ok: combined $ncol column(s)"
}

ndone=0 nskip=0 nfail=0
rc=0
nsim=0 ntotal=$#     # $# is the sim count: getopts was shifted off, and the loop never shifts

for src; do
    src=${src%/}
    nsim=$((nsim + 1))
    echo "=== $(basename "$src") ($nsim of $ntotal) ==="

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

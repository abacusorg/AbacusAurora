#!/bin/bash
# Quick checks on finished simulations: the size-and-completeness checks of
# postprocessing.sh (its steps 1, 2 and 5), without building history.asdf and
# log.zip and without combining the checksum files.  It reads the SimDirectory and
# changes nothing in it but its own record file.
#
# Given one or more SimDirectories, in order, per sim:
#
#   1. every rank's checksum file records exactly one maplog.  The MapForest is
#      dumped to one ASDF per rank exactly once, on the final NoForces step, so a
#      rank with no maplog line never got there.
#   2. the maplog files on disk are the size the checksums say.
#   5. every other checksummed directory is the size the checksums say.  The list
#      of directories comes from the checksum records themselves, so timeslices,
#      group files and anything added later are covered without editing this.
#
# The numbering is postprocessing.sh's, so that a message here means the same thing
# there.
#
# A failing step stops that sim; the remaining sims are still processed, and with
# -j several sims are processed at once.
#
# Each sim's steps are recorded in a `postprocess.checking` file in its
# SimDirectory, renamed to `postprocess.checked` or `postprocess.checkfailed` at the
# end.  A sim with postprocess.checked is left alone unless -f is given, as is one
# with postprocess.checkfailed or a bare postprocess.checking from an interrupted run.
#
# postprocessing.sh ignores all three files: it repeats these checks itself, and only
# its postprocess.done means a sim is finished.  Conversely a sim with
# postprocess.done is left alone here (its checksums are already combined), and one
# with a bare `postprocess` -- a full run in progress or interrupted -- is skipped
# unless -f is given, since that run's step 6 may combine the checksum files out from
# under these checks.
#
# Per column (-c), for a sim too big to check in one pass (post-check.pbs farms the
# columns out over nodes).  Each column's checksum records name exactly the files its
# ranks wrote, so the same three steps run on those records alone:
#
#   1. as above, over the column's rank checksum files.
#   2, 5. every file the column recorded is on disk at the recorded size -- one stat
#      per recorded file, not a listing of the directory.  An output directory kept per
#      column (a path component colNNN: maplogs/colNNN/, subsamples/z*/colNNN/) is
#      listed too, so a file in it that nothing recorded is caught, as above.
#
# What a column cannot check is a file nothing recorded in a directory the columns
# share (the group files, slices and light cones, whose names carry the column in three
# different formats).  postprocessing.sh's step 5 still catches those.
#
# A column's record is postcheck/colNNN.checking, renamed to colNNN.checked or
# colNNN.checkfailed, with the same skip rules as a whole sim's.  The whole-sim
# postprocess.checked is never written by -c.
#
# The SimDirectory is the OutputDirectory: checksums/ and maplogs/ are written there
# (P.OutputDirectory in io_thread.cpp and timestep.cpp), as are the group files and
# slices.  log/ is not needed here.
#
# Usage: post-check.sh [-f] [-j N] [-c COLS] [--daos] <simdir> [simdir ...]
#   -f       re-check sims that were already checked, failed, or were interrupted
#   -j N     process up to N sims (or sim-columns) at once. A parallel one's output is
#            held back and printed in one piece when it finishes, so that two cannot
#            interleave; its .checking record shows progress in the meantime.
#   -c COLS  check only these columns of each sim, one at a time: comma-separated
#            column numbers (the NNN of checksums/colNNN), and -c may repeat.
#   --daos   mount the DAOS Outputs container first, for sims whose outputs are on
#            DAOS (ABACUS_DAOS_OUTPUTS=on).  Inside a PBS allocation this mounts
#            across the allocation; on a login node it mounts per-user, for this node
#            only, and leaves the mount behind (daos.sh's daos_login_unmount tears it
#            down).

set -euo pipefail

usage() {
    echo "usage: post-check.sh [-f] [-j N] [-c COLS] [--daos] <simdir> [simdir ...]" >&2
    exit 2
}

force=0
daos=0
jobs=1
simdirs=()
colargs=()
while (( $# )); do
    case $1 in
        -f|--force) force=1; shift ;;
        --daos)     daos=1; shift ;;
        -h|--help)  usage ;;
        -j|--jobs)  (( $# >= 2 )) || { echo "error: $1 needs a count" >&2; usage; }
                    jobs=$2; shift 2 ;;
        -j*)        jobs=${1#-j}; shift ;;
        --jobs=*)   jobs=${1#--jobs=}; shift ;;
        -c|--column|--columns)
                    (( $# >= 2 )) || { echo "error: $1 needs column numbers" >&2; usage; }
                    colargs+=("$2"); shift 2 ;;
        -c*)        colargs+=("${1#-c}"); shift ;;
        --column=*|--columns=*)
                    colargs+=("${1#*=}"); shift ;;
        --)         shift; simdirs+=("$@"); break ;;
        -*)         echo "error: unknown option '$1'" >&2; usage ;;
        *)          simdirs+=("$1"); shift ;;
    esac
done
(( ${#simdirs[@]} )) || usage
if [[ ! $jobs =~ ^[1-9][0-9]*$ ]]; then
    echo "error: -j takes a positive integer, not '$jobs'" >&2
    usage
fi

# The columns, as the three-digit NNN of checksums/colNNN.  10# so that a leading zero
# is not read as octal ("008" is column 8, not an error).
columns=()
for arg in ${colargs[@]+"${colargs[@]}"}; do
    IFS=, read -r -a parts <<< "$arg"
    for c in ${parts[@]+"${parts[@]}"}; do
        if [[ ! $c =~ ^[0-9]+$ ]] || (( 10#$c > 999 )); then
            echo "error: -c takes column numbers 0-999, not '$c'" >&2
            usage
        fi
        columns+=("$(printf '%03d' $((10#$c)))")
    done
done
if (( ${#colargs[@]} )) && (( ! ${#columns[@]} )); then
    echo "error: -c named no columns" >&2
    usage
fi

# The work items, "<simdir> <column>" with the column empty for a whole sim.  A path
# with a space in it would be split here, but the size checks already assume none.
items=()
for src in "${simdirs[@]}"; do
    if (( ${#columns[@]} )); then
        for c in "${columns[@]}"; do items+=("${src%/} $c"); done
    else
        items+=("${src%/} ")
    fi
done

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# For daos_resolve/daos_mount/daos_login_mount.  Sourcing only defines them; nothing
# is mounted and no root is set until --daos asks.
source "$here/daos.sh"

# Mount the container that holds the outputs when ABACUS_DAOS_OUTPUTS=on.  Inside an
# allocation daos_mount covers every node; on a login node the mounts are per-user.
setup_daos() {
    (( daos )) || return 0
    ABACUS_DAOS=on daos_resolve
    # Only the Outputs container: it holds the outputs themselves when
    # ABACUS_DAOS_OUTPUTS=on.  Checkpoints is not needed --
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

# run_one() sets these per item, and process_sim() and its helpers read them:
#   record  the in-progress record, relative to the SimDirectory: postprocess.checking
#           for a whole sim -- not postprocessing.sh's `postprocess`, which that script
#           would take for an interrupted run of its own -- or postcheck/colNNN.checking
#   col     the column's NNN, or empty for a whole sim
record=
col=

# Progress goes to the screen and to the record at once; the record is what
# survives to explain a .checkfailed.
say() {
    printf '  %s\n' "$*"
    printf '%s\n' "$*" >> "$record"
}

# "<size> <path>" for everything on disk under $1, sorted by path then size.
ondisk_sizes() {
    if [[ -n $col ]]; then column_ondisk_sizes "$1"; return; fi
    findsizes "$1" | gawk '{print $1, $2}' | LC_ALL=C sort -k2,2 -k1,1
}

# The per-column version: "<size> <path>" for each file under $1 that this column
# recorded, stat()ed one by one, plus everything in any colNNN directory of this column
# under $1, which is this column's alone.  A recorded file that is missing simply has no
# line, which the comparison reports.  sort -u because a file in a colNNN directory
# turns up both ways.
column_ondisk_sizes() {
    local root=$1 d
    local -a coldirs=()
    while IFS= read -r d; do
        coldirs+=("$d")
    done < <(recorded_sizes "$root" |
                 gawk -v c="col$col" 'match($2, "(^|/)" c "/") {
                                          print substr($2, 1, RSTART + RLENGTH - 2) }' |
                 LC_ALL=C sort -u)
    {
        # stat's exit status is nonzero for a missing file; the comparison is what reports it.
        recorded_sizes "$root" | gawk '{ print $2 }' |
            xargs -r -d '\n' stat -c '%s %n' -- 2>/dev/null || true
        for d in ${coldirs[@]+"${coldirs[@]}"}; do
            if [[ -d $d ]]; then findsizes "$d" | gawk '{ print $1, $2 }'; fi
        done
    } | LC_ALL=C sort -u -k2,2 -k1,1
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

# Steps 1, 2 and 5, run with $PWD = the SimDirectory.  Returns nonzero at the first
# step that fails, having said why.
process_sim() {
    local f n root bad=0 failed=0 checked=0
    local -a rank_cksums=() unrecorded=() merged=() roots=()

    # Deliberately not local: recorded_sizes reads it.
    shopt -s nullglob
    # Both layouts: the per-rank files a run writes, and the per-column files
    # postprocessing.sh's step 6 leaves behind, so that -f can re-check an
    # already-combined sim.  Only this column's, with -c -- the [.] makes the combined
    # name a pattern, which nullglob drops when absent; a plain name it would keep.
    if [[ -n $col ]]; then
        cksums=(checksums/col$col/checksums.*.crc32 checksums/col$col[.]crc32)
    else
        cksums=(checksums/col*/checksums.*.crc32 checksums/col*.crc32)
    fi
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
        # postprocessing.sh's step 6 already combined this sim, so the per-rank files
        # are gone and one maplog *per rank* is no longer answerable -- a column file
        # holds every rank's records at once.  Check what survives: every column
        # recorded some.
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
}

ntotal=${#items[@]}

# One sim, or one column of one, start to finish, leaving $PWD alone.  Exits 0 if it
# checked out (or the sim was already fully post-processed), 1 if it failed, 2 if an
# earlier record is in the way.  Everything it prints belongs to this item alone,
# which is what lets -j hold it back and print it whole.
#
# record and col are deliberately local here and not in process_sim(): bash scoping is
# dynamic, so process_sim and its helpers see this item's values.
run_one() {
    local src=$1 col=$2 n=$3 stale label base record
    if [[ -n $col ]]; then
        label="$(basename "$src") col$col"
        base=postcheck/col$col
    else
        label=$(basename "$src")
        base=postprocess
    fi
    record=$base.checking
    echo "=== $label ($n of $ntotal) ==="

    if [[ ! -d $src ]]; then
        echo "  error: not a directory: $src" >&2
        return 1
    fi
    if [[ -n $col && ! -d $src/checksums/col$col && ! -e $src/checksums/col$col.crc32 ]]; then
        echo "  error: no column $col here (neither checksums/col$col/ nor checksums/col$col.crc32)" >&2
        return 1
    fi
    if [[ -e $src/postprocess.done ]] && (( ! force )); then
        echo "  postprocess.done is already here; nothing to do"
        return 0
    fi
    if [[ -e $src/$base.checked ]] && (( ! force )); then
        echo "  $base.checked is already here; nothing to do (pass -f to re-check)"
        return 0
    fi
    # A bare `postprocess` is postprocessing.sh's, running or interrupted: its step 6
    # could combine the checksum files while these checks read them.
    for stale in "$base.checkfailed" "$record" postprocess; do
        if [[ -e $src/$stale ]] && (( ! force )); then
            echo "  $stale is from an earlier run; skipping (pass -f to retry)" >&2
            return 2
        fi
    done

    [[ -z $col ]] || mkdir -p -- "$src/postcheck"
    rm -f -- "$src/$base.checkfailed" "$src/$base.checked"
    {
        echo "# post-check.sh (postprocessing.sh steps 1, 2, 5)"
        echo "sim:     $(cd -- "$src" && pwd)"
        [[ -z $col ]] || echo "column:  $col"
        echo "started: $(date -Is) on $(hostname) by ${USER:-$(id -un)}"
    } > "$src/$record"

    # A subshell so that the cd, and any step's exit, is contained to this item.
    if ( cd -- "$src" && process_sim ); then
        echo "finished: $(date -Is)  all checks passed" >> "$src/$record"
        mv -f -- "$src/$record" "$src/$base.checked"
        echo "  wrote $base.checked"
        return 0
    fi
    echo "finished: $(date -Is)  FAILED" >> "$src/$record"
    mv -f -- "$src/$record" "$src/$base.checkfailed"
    echo "  wrote $base.checkfailed" >&2
    return 1
}

ndone=0 nskip=0 nfail=0
rc=0
tally() {
    case $1 in
        0) ndone=$((ndone + 1)) ;;
        2) nskip=$((nskip + 1)); rc=1 ;;
        *) nfail=$((nfail + 1)); rc=1 ;;
    esac
}

if (( jobs == 1 )); then
    n=0
    for item in "${items[@]}"; do
        n=$((n + 1))
        status=0
        run_one "${item% *}" "${item##* }" "$n" || status=$?
        tally "$status"
    done
else
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/post-check.XXXXXX")
    trap 'rm -rf -- "$tmpdir"' EXIT
    declare -A pending=()   # item index -> launched but not yet reported
    nrunning=0

    # Block until at least one child has exited, then report every child that has
    # finished.  `wait -n` says that some child exited but not which one -- bash 4.4
    # has no `wait -n -p` -- so a child leaves its status behind in a file and we look
    # for the ones that appeared.  Reporting a child whose exit `wait` has not yet
    # collected only costs a later `wait -n` that returns at once.
    reap() {
        local idx status
        wait -n 2>/dev/null || true   # a child's nonzero exit is this item's news, not an error
        for idx in "${!pending[@]}"; do
            [[ -e $tmpdir/$idx.status ]] || continue
            status=$(< "$tmpdir/$idx.status")
            cat -- "$tmpdir/$idx.out"
            rm -f -- "$tmpdir/$idx.out" "$tmpdir/$idx.status"
            unset "pending[$idx]"
            nrunning=$((nrunning - 1))
            tally "$status"
        done
    }

    n=0
    for item in "${items[@]}"; do
        n=$((n + 1))
        while (( nrunning >= jobs )); do reap; done
        echo "--- started $(basename "${item% *}") ${item##* } ($n of $ntotal) ---"
        # The status file is written last, so its presence means the output file is
        # complete: reap() needs no other handshake.
        (
            status=0
            run_one "${item% *}" "${item##* }" "$n" > "$tmpdir/$n.out" 2>&1 || status=$?
            echo "$status" > "$tmpdir/$n.status"
        ) &
        pending[$n]=1
        nrunning=$((nrunning + 1))
    done
    while (( nrunning )); do reap; done
fi

echo
echo "$ndone checked, $nskip skipped needing -f, $nfail failed"
exit $rc

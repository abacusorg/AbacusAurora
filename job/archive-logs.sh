#!/bin/bash
# Archive a finished sim's logs into two files:
#
#   history.asdf   the per-step state and timing, gathered columnar by
#                  abacus.post.history
#   log.zip        the whole log directory, deflated
#
# They are written to the sim's own OutputDirectory, read from its parameter file.
#
# abacus.post.history holds one full copy of the timing data in memory (it prints
# the footprint before allocating).  That is nothing for a 15-node run, but a
# flagship sim wants a compute node rather than a login node.
#
# Usage: archive-logs.sh [-f] [-d DESTROOT] <simdir> [simdir ...]
#   -f            overwrite outputs that already exist
#   -d DESTROOT   write to DESTROOT/<basename> instead of to OutputDirectory

set -euo pipefail

usage() {
    echo "usage: archive-logs.sh [-f] [-d DESTROOT] <simdir> [simdir ...]" >&2
    exit 2
}

# The sim's OutputDirectory, via Abacus's own parameter parser so that quoting and
# includes are handled the way the code handles them.
sim_outputdir() {
    python3 - "$1" <<'ENDPY'
import sys
from pathlib import Path
from abacus.param import InputFile

simdir = Path(sys.argv[1])
pars = sorted(simdir.glob('*.par'))
if len(pars) != 1:
    sys.exit(1)
print(dict(InputFile(str(pars[0]))).get('OutputDirectory', ''))
ENDPY
}

force=0
destroot=
while getopts ':fd:' opt; do
    case $opt in
        f) force=1 ;;
        d) destroot=$OPTARG ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))
(( $# )) || usage

python -c 'import abacus.post.history' 2>/dev/null || {
    echo "error: abacus.post.history is not importable; source the abacus env first" >&2
    exit 1
}

rc=0
for src; do
    src=${src%/}
    logdir=$src/log
    echo "=== $(basename "$src") ==="
    if [[ ! -d $logdir ]]; then
        echo "  error: no log directory at $logdir" >&2
        rc=1
        continue
    fi

    if [[ -n $destroot ]]; then
        dst=$destroot/$(basename "$src")
        mkdir -p "$dst"
    else
        if ! dst=$(sim_outputdir "$src") || [[ -z $dst ]]; then
            echo "  error: could not read OutputDirectory from a *.par in $src; pass -d" >&2
            rc=1
            continue
        fi
        # Deliberately not created: a parameter file written on a compute node can
        # name a mount path that does not exist here, and creating it would quietly
        # put the archive on local disk instead of where the outputs actually are.
        if [[ ! -d $dst ]]; then
            echo "  error: OutputDirectory $dst does not exist here; pass -d" >&2
            rc=1
            continue
        fi
        echo "  destination from OutputDirectory: $dst"
    fi
    for out in history.asdf log.zip; do
        if [[ -e $dst/$out ]] && (( ! force )); then
            echo "  error: $dst/$out exists; pass -f to overwrite" >&2
            rc=1
            continue 2
        fi
    done

    # Write to a temporary name and rename, so an interrupted run cannot leave a
    # truncated archive looking like a complete one.
    echo "  gathering history from $logdir"
    python -m abacus.post.history "$src" -o "$dst/history.asdf.part"
    mv -f "$dst/history.asdf.part" "$dst/history.asdf"

    echo "  zipping $(du -sh "$logdir" | cut -f1) of logs"
    python3 - "$logdir" "$dst/log.zip.part" <<'PY'
import sys, zipfile
from pathlib import Path

src, out = Path(sys.argv[1]), Path(sys.argv[2])
files = sorted(f for f in src.rglob('*') if f.is_file())
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, allowZip64=True) as z:
    for f in files:
        z.write(f, f.relative_to(src.parent))
print(f"    {len(files)} files")
PY
    mv -f "$dst/log.zip.part" "$dst/log.zip"

    # du reports allocated blocks, which Lustre striping makes misleading for a
    # single file; report the byte count.
    for out in history.asdf log.zip; do
        echo "  wrote $dst/$out ($(stat -c%s "$dst/$out" | awk '{printf "%.1f MB", $1/1e6}'))"
    done
done
exit $rc

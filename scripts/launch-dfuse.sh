#!/bin/bash
# Patched copy of ALCF's /soft/daos/bin/launch-dfuse.sh (a symlink to
# launch-dfuse_user_clush.sh; md5 42ef04e2, 2026-04-21).  The per-container mount
# recipe is theirs, so `diff` this against /soft/daos/bin/launch-dfuse.sh after an
# image roll to see whether it has changed upstream.
#
# The patch: the remote mounts for every container go out in one clush sweep, one ssh
# per node, where ALCF runs a sweep per container, and each node starts its mounts
# concurrently and then checks them, failing this script if any is missing (ALCF's never
# fails).  clush reaches the nodes 208 at a time, so a sweep costs N/208 times the
# per-node time: ~1 s of ssh plus ~2 s for the overlapping dfuse starts (2026-10-06).
#
# ssh strips LD_*, so remote dfuse finds libfabric only through the linker cache.  If
# every node past the first fails with DER_HG(-1020), check /etc/ld.so.conf.d/libfabric.conf.
#
# Usage: launch-dfuse.sh <pool>:<container> [<pool>:<container> ...]
#
# Run on the head node of an allocation, by hand or from a job; job/daos.sh calls it
# from daos_mount.

set -euo pipefail

module use /soft/modulefiles
module load mpifileutils

BINDIR=/soft/daos/bin
NNODES=$(cat $PBS_NODEFILE | wc -l)

# One ssh per remote node starts every container's dfuse concurrently and waits for all.
# printf %q because the remote shell re-parses the string clush sends.
remote_cmd=""
mountpts=()

for mnt in "$@";
do

IFS=':' read -ra ids <<< ${mnt}

mountpt="/tmp/${ids[0]}/${ids[1]}"
mountpts+=("${mountpt}")

# mount dfuse on head node; the remote nodes make their mountpoints in their own ssh
mkdir -p ${mountpt}
hfile=$(mktemp /tmp/${USER}_handles.XXXXX)
dfuse --pool ${ids[0]} --cont ${ids[1]} -m ${mountpt} --dump-handles ${hfile} --disable-caching --disable-wb-cache

# copy handles to other nodes
# TODO: can we bundle 3 mpiexec dbcast into 1? dbcast only accepts 1 file, but we could tar it.
# However, the man page says that the file needs to be globally readable, which already isn't true
# in ALCF's version.
mpiexec --no-vni -np $(( NNODES * 2 )) -ppn 2 dbcast ${hfile} ${hfile} > /dev/null

remote_cmd+="$(printf '%q ' ${BINDIR}/start-dfuse.sh oneScratch \
     --pool "${ids[0]}" \
     --cont "${ids[1]}" \
     -m "${mountpt}" \
     --read-handles "${hfile}" \
     --disable-caching \
     --disable-wb-cache)& "

done

# start-dfuse.sh exits 0 even when dfuse fails, and the mountpoint already exists, so an
# unchecked failure would leave that node's ranks writing to its local /tmp instead.
remote_cmd="mkdir -p $(printf '%q ' "${mountpts[@]}"); ${remote_cmd}wait; bad=0; for m in $(printf '%q ' "${mountpts[@]}"); do mountpoint -q \$m || { echo \"\$m not mounted\"; bad=1; }; done; exit \$bad"

if [ $NNODES -gt 1 ];
then

  # start dfuse on all other nodes; -S because clush otherwise exits 0 whatever the
  # remote commands (or ssh itself) return
  tail -n +2 $PBS_NODEFILE > /tmp/${USER}_node_list
  clush -S --hostfile=/tmp/${USER}_node_list -f 208 -o "-o LogLevel=QUIET -o StrictHostKeyChecking=no" \
     "$remote_cmd"
fi


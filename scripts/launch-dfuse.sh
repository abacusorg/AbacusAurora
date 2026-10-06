#!/bin/bash
# Patched copy of ALCF's /soft/daos/bin/launch-dfuse.sh (a symlink to
# launch-dfuse_user_clush.sh; md5 42ef04e2, 2026-04-21).  The per-container mount
# recipe is theirs, so `diff` this against /soft/daos/bin/launch-dfuse.sh after an
# image roll to see whether it has changed upstream.
#
# The patch: the remote mounts for every container go out in one clush sweep, one ssh
# per node, where ALCF runs a sweep per container, and each node starts its mounts
# concurrently.  clush reaches the nodes 208 at a time, so a sweep costs N/208 times the
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

for mnt in "$@";
do

IFS=':' read -ra ids <<< ${mnt}

mountpt="/tmp/${ids[0]}/${ids[1]}"

# create mountpoint
mpiexec --no-vni -np $NNODES -ppn 1 mkdir -p ${mountpt}

# mount dfuse on head node
hfile=$(mktemp /tmp/${USER}_handles.XXXXX)
dfuse --pool ${ids[0]} --cont ${ids[1]} -m ${mountpt} --dump-handles ${hfile} --disable-caching --disable-wb-cache

# copy handles to other nodes
mpiexec --no-vni -np $(( NNODES * 2 )) -ppn 2 dbcast ${hfile} ${hfile} > /dev/null

remote_cmd+="$(printf '%q ' ${BINDIR}/start-dfuse.sh oneScratch \
     --pool "${ids[0]}" \
     --cont "${ids[1]}" \
     -m "${mountpt}" \
     --read-handles "${hfile}" \
     --disable-caching \
     --disable-wb-cache)& "

done
remote_cmd+="wait"

if [ $NNODES -gt 1 ];
then

  # start dfuse on all other nodes
  tail -n +2 $PBS_NODEFILE > /tmp/${USER}_node_list
  clush --hostfile=/tmp/${USER}_node_list -f 208 -o "-o LogLevel=QUIET -o StrictHostKeyChecking=no" \
     "$remote_cmd"
fi


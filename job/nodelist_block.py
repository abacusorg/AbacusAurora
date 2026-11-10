#!/usr/bin/env python3
"""
Reorder an Aurora node file so Abacus ranks are placed in compact rank blocks.

Abacus ranks form an [nx][nz] grid (Z fastest), placed ppn per node in
node-file order.  We sort the node list (by rack, chassis, slot, board,
node), cut the rank grid into blocks of --block-rows X rows x --block-z Z
ranks, shuffle the blocks (seeded), and give each block consecutive nodes
from the sorted list.  So each block is physically compact (about one
chassis), and neighboring blocks are scattered across racks, which spreads
the Manifest, Z-neighbor and transpose traffic over many rack pairs instead
of a few.

Blocks: take block-rows X rows (block-rows*nz consecutive ranks) and cut
them into chunks of block-z consecutive ranks; one chunk per row makes a
block.  When nz is a multiple of block-z (e.g. 225x80 with 5x4 blocks) the
blocks are plain rectangles.  When it is not, the chunk boundaries shift
from row to row and the blocks are sheared, e.g. nz = 75 with 4x4 blocks
(digits/letters = block):
    ix 0  0000111122223333...HHHHIII
    ix 1  I0000111122223333...HHHHII
    ix 2  II0000111122223333...HHHHI
    ix 3  III0000111122223333...HHHH
There the block that wraps in Z has 12 ranks.  A leftover group of fewer
than block-rows X rows (nx not a multiple of block-rows) gets shorter blocks.

Usage:
  nodelist_block.py --nx 225 --nz 80 --block-rows 5 --block-z 4 hostfile hostfile.block
  nodelist_block.py --nx 232 --nz 75 hostfile hostfile.block       # 4x4 blocks
Then give the output to mpiexec (--hostfile) with ppn ranks per node.
Nodes beyond nx*nz/ppn are appended, in sorted order, after the used ones.
"""

import argparse
import re
import sys

import numpy as np

name_re = re.compile(r'x(\d+)c(\d+)s(\d+)b(\d+)n(\d+)')


def read_nodes(fn):
    """Full hostnames, in file order, with duplicates dropped."""
    hosts, seen = [], set()
    with open(fn) as f:
        for line in f:
            if not line.strip() or line.lstrip().startswith('#'):
                continue
            host = line.split()[0]
            if host not in seen:
                seen.add(host)
                hosts.append(host)
    return hosts


def sort_key(host):
    m = name_re.fullmatch(host.split('.')[0])
    if not m:
        raise ValueError(f'Unrecognized node name: {host!r}')
    return tuple(int(g) for g in m.groups())


def rank_blocks(nx, nz, rows, chunk):
    """Block id of each rank (see the module docstring)."""
    block = np.empty(nx * nz, dtype=int)
    nblock = 0
    for x0 in range(0, nx, rows):
        size = min(rows, nx - x0) * nz
        ids = {}
        for s in range(0, size, chunk):
            r, iz0 = divmod(s, nz)
            b = (iz0 - (-r * nz) % chunk) // chunk
            if b not in ids:
                ids[b] = nblock
                nblock += 1
            block[x0 * nz + s: x0 * nz + min(s + chunk, size)] = ids[b]
    return block


def slot_blocks(nx, nz, ppn, rows, chunk):
    """Block id of each node slot (ranks ppn*k .. ppn*k+ppn-1)."""
    nnodes = -(-nx * nz // ppn)
    block = rank_blocks(nx, nz, rows, chunk)
    slot_block = block[::ppn][:nnodes]
    if not all((block[k * ppn:(k + 1) * ppn] == slot_block[k]).all() for k in range(nnodes)):
        raise ValueError('a node would straddle two blocks; need ppn to divide the block width')
    return slot_block


def block_fill(slot_block, seed):
    """slot_node[k] = position in the sorted node list for slot k: blocks in
    random order, each block's slots filled contiguously in slot order."""
    pos = np.random.default_rng(seed).permutation(slot_block.max() + 1)
    fill = np.lexsort((np.arange(len(slot_block)), pos[slot_block]))
    slot_node = np.empty(len(slot_block), dtype=int)
    slot_node[fill] = np.arange(len(slot_block))
    return slot_node


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('nodefile', help='input node file, one hostname per line')
    ap.add_argument('output', help='output node file, in rank-placement order')
    ap.add_argument('--nx', type=int, required=True, help='ranks in X (e.g. 225 for Flagship 9000)')
    ap.add_argument('--nz', type=int, required=True, help='ranks in Z, i.e. NumZRanks (e.g. 80)')
    ap.add_argument('--ppn', type=int, default=2, help='ranks per node')
    ap.add_argument('--block-rows', type=int, default=4, help='X rows per block (e.g. 5 for 225x80)')
    ap.add_argument('--block-z', type=int, default=4, help='Z ranks per block row')
    ap.add_argument('--seed', type=int, default=1)
    args = ap.parse_args()

    hosts = sorted(read_nodes(args.nodefile), key=sort_key)
    nnodes = -(-args.nx * args.nz // args.ppn)
    if len(hosts) < nnodes:
        sys.exit(f'Need {nnodes} nodes for {args.nx}x{args.nz} at {args.ppn}/node; '
                 f'{args.nodefile} has {len(hosts)}')

    slot_block = slot_blocks(args.nx, args.nz, args.ppn, args.block_rows, args.block_z)
    slot_node = block_fill(slot_block, args.seed)

    with open(args.output, 'w') as f:
        f.writelines(hosts[i] + '\n' for i in slot_node)
        f.writelines(h + '\n' for h in hosts[nnodes:])
    print(f'# wrote {len(hosts)} nodes to {args.output} ({args.block_rows}x{args.block_z} blocks '
          f'of {args.nx}x{args.nz} ranks, {slot_block.max() + 1} blocks, seed {args.seed})',
          file=sys.stderr)


if __name__ == '__main__':
    main()

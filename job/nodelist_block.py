#!/usr/bin/env python3
"""
Reorder an Aurora node file so Abacus ranks are placed in 4x4 rank blocks.

Abacus ranks form an [nx][nz] grid (Z fastest), placed ppn per node in
node-file order.  We sort the node list (by rack, chassis, slot, board,
node), cut the rank grid into sheared blocks of 4 X rows x 4 Z ranks (8
nodes at ppn=2), shuffle the blocks, and give each block consecutive nodes
from the sorted list.  So each block is physically compact (~ one chassis),
and neighboring blocks are scattered across racks.

Blocks: take 4 X rows (4*nz consecutive ranks) and cut them into chunks of
4 consecutive ranks.  With nz odd the chunk boundaries shift by one rank in
Z from row to row, so one chunk per row along that diagonal is a block,
e.g. for nz = 75 (digits/letters = block):
    ix 0  0000111122223333...HHHHIII
    ix 1  I0000111122223333...HHHHII
    ix 2  II0000111122223333...HHHHI
    ix 3  III0000111122223333...HHHH
The block that wraps in Z has 12 ranks; a leftover group of fewer than 4 X
rows (nx not a multiple of 4) gets shorter blocks.

Modes:
  random : blocks in seeded random order.
  spread : start from random and swap equal-size blocks to reduce the load
           on the worst rack pairs, scoring against generic "racks" of 32,
           48 and 64 consecutive nodes (each at two offsets).  Ignores the
           actual rack names; takes ~10-60 s.

Usage:
  abacus_block_nodes.py --nx 232 --nz 75 $PBS_NODEFILE nodes.mpi
  abacus_block_nodes.py --nx 62 --nz 35 --mode spread $PBS_NODEFILE nodes.mpi
Then give nodes.mpi to mpiexec (--hostfile) with 2 ranks per node.
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


def rank_blocks(nx, nz, rows=4, chunk=4):
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


def slot_blocks(nx, nz, ppn):
    """Block id of each node slot (ranks ppn*k .. ppn*k+ppn-1)."""
    nnodes = -(-nx * nz // ppn)
    block = rank_blocks(nx, nz)
    slot_block = block[::ppn][:nnodes]
    if not all((block[k * ppn:(k + 1) * ppn] == slot_block[k]).all() for k in range(nnodes)):
        raise ValueError('a node would straddle two blocks; need ppn to divide 4 and 4*nz')
    return slot_block


def block_fill(slot_block, seed):
    """slot_node[k] = position in the sorted node list for slot k: blocks in
    random order, each block's slots filled contiguously in slot order."""
    pos = np.random.default_rng(seed).permutation(slot_block.max() + 1)
    fill = np.lexsort((np.arange(len(slot_block)), pos[slot_block]))
    slot_node = np.empty(len(slot_block), dtype=int)
    slot_node[fill] = np.arange(len(slot_block))
    return slot_node


class RackLoad:
    """Directed rack-pair load (GB) for a rank -> rack map, summing:
    Manifest (30 GB to -X), Z-neighbor (20 GB each to +-Z), and the X and Z
    transposes (2 x 12 GB spread over the nx or nz peers)."""

    def __init__(self, nx, nz, multipole_gb=12, manifest_gb=30, zneighbor_gb=20):
        r = np.arange(nx * nz)
        self.ix, self.iz = np.divmod(r, nz)
        rank_of = lambda x, z: (x % nx) * nz + (z % nz)
        self.src = np.concatenate([r, r, r])
        self.dst = np.concatenate([rank_of(self.ix - 1, self.iz),
                                   rank_of(self.ix, self.iz + 1), rank_of(self.ix, self.iz - 1)])
        self.w = np.repeat([manifest_gb, zneighbor_gb, zneighbor_gb], nx * nz)
        self.wz, self.wx = 2 * multipole_gb / nz, 2 * multipole_gb / nx
        self.nx, self.nz = nx, nz

    def __call__(self, rr, nr):
        L = np.bincount(rr[self.src] * nr + rr[self.dst], weights=self.w,
                        minlength=nr * nr).reshape(nr, nr)
        Cz = np.bincount(self.ix * nr + rr, minlength=self.nx * nr).reshape(self.nx, nr)
        Cx = np.bincount(self.iz * nr + rr, minlength=self.nz * nr).reshape(self.nz, nr)
        L += self.wz * (Cz.T @ Cz) + self.wx * (Cx.T @ Cx)
        np.fill_diagonal(L, 0)
        return L


def spread_blocks(slot_node, slot_block, nx, nz, ppn, seed, iters=3000, windows=(32, 48, 64)):
    """Swap equal-size blocks to minimize sum(L**4) over rack-pair loads L,
    summed over generic rack maps (runs of w consecutive nodes, two offsets
    each).  Swapping equal-size blocks keeps every block contiguous."""
    rng = np.random.default_rng(seed + 1)
    n = np.arange(len(slot_node))
    node_racks = [(n + off) // w for w in windows for off in (0, w // 2)]
    load = RackLoad(nx, nz)
    slots_of = [np.flatnonzero(slot_block == b) for b in range(slot_block.max() + 1)]
    size = np.array([len(s) for s in slots_of])
    nr = [m.max() + 1 for m in node_racks]
    rank_slot = np.arange(nx * nz) // ppn

    def rank_racks():
        return [m[slot_node[rank_slot]] for m in node_racks]

    rr = rank_racks()
    Ls = [load(r, k) for r, k in zip(rr, nr)]
    cost = sum((L ** 4).sum() for L in Ls)
    start_max = max(L.max() for L in Ls)
    for it in range(iters):
        # Bias toward blocks feeding the currently hottest rack pair.
        k = int(np.argmax([L.max() for L in Ls]))
        a, b = np.unravel_index(np.argmax(Ls[k]), Ls[k].shape)
        hot = np.flatnonzero(rr[k] == (a if rng.random() < 0.5 else b))
        b1 = slot_block[rng.choice(hot) // ppn] if rng.random() < 0.7 else rng.integers(len(size))
        b2 = rng.choice(np.flatnonzero(size == size[b1]))
        if b2 == b1:
            continue
        s1, s2 = slots_of[b1], slots_of[b2]
        slot_node[s1], slot_node[s2] = slot_node[s2].copy(), slot_node[s1].copy()
        new_rr = rank_racks()
        new_Ls = [load(r, k) for r, k in zip(new_rr, nr)]
        new_cost = sum((L ** 4).sum() for L in new_Ls)
        if new_cost < cost:
            rr, Ls, cost = new_rr, new_Ls, new_cost
        else:
            slot_node[s1], slot_node[s2] = slot_node[s2].copy(), slot_node[s1].copy()
    print(f'# spread: worst generic rack pair {start_max:.0f} -> {max(L.max() for L in Ls):.0f} GB',
          file=sys.stderr)
    return slot_node


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('nodefile', help='input node file, one hostname per line')
    ap.add_argument('output', help='output node file, in rank-placement order')
    ap.add_argument('--nx', type=int, required=True, help='ranks in X (e.g. 232 Flagship, 62 DemiFlag)')
    ap.add_argument('--nz', type=int, required=True, help='ranks in Z (e.g. 75 Flagship, 35 DemiFlag)')
    ap.add_argument('--ppn', type=int, default=2, help='ranks per node')
    ap.add_argument('--mode', choices=('random', 'spread'), default='random')
    ap.add_argument('--seed', type=int, default=1)
    args = ap.parse_args()

    hosts = sorted(read_nodes(args.nodefile), key=sort_key)
    nnodes = -(-args.nx * args.nz // args.ppn)
    if len(hosts) < nnodes:
        sys.exit(f'Need {nnodes} nodes for {args.nx}x{args.nz} at {args.ppn}/node; '
                 f'{args.nodefile} has {len(hosts)}')

    slot_block = slot_blocks(args.nx, args.nz, args.ppn)
    slot_node = block_fill(slot_block, args.seed)
    if args.mode == 'spread':
        slot_node = spread_blocks(slot_node, slot_block, args.nx, args.nz, args.ppn, args.seed)

    with open(args.output, 'w') as f:
        f.writelines(hosts[i] + '\n' for i in slot_node)
        f.writelines(h + '\n' for h in hosts[nnodes:])
    print(f'# wrote {len(hosts)} nodes to {args.output} ({args.mode} 4x4 blocks, '
          f'{slot_block.max() + 1} blocks, {nnodes} nodes used)', file=sys.stderr)


if __name__ == '__main__':
    main()

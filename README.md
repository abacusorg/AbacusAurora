# AbacusAurora

This repository holds the parameter files and scripts that define the cosmologies, simulation inputs, and job orchestration for Abacus on Aurora.

## Repo structure

```text
AbacusAurora/
├── Cosmologies/           # cosmology specs (the AbacusSummit set)
│   ├── abacus_cosm000/    #   one dir per cosmology: cosm.def + CLASS transfer/power/ini
│   ├── abacus_cosm001/
│   ├── ...
│   ├── abacus_base.pre    #   shared CLASS precision presets
│   ├── cosmologies.csv    #   master table of cosmological parameters
│   └── make_cosm_def.py   #   CLASS.ini → cosm.def
├── Simulations/           # simulation specs
│   ├── aurora.def         #   Aurora site file (mpirun_cmd, core binding, I/O, dir layout)
│   ├── base.par2          #   Base Aurora parameter file, included by other par2 files
│   └── AuroraHighBase.par2  # example simulation parameter file
├── job/                   # job orchestration (run from a login node)
│   ├── hashrun.sh         #   launcher: build hash-keyed code, verify repo clean, qsub
│   ├── multisim.pbs       #   PBS batch job: split the allocation, launch each sim
│   ├── onesim.sh          #   per-sim monitor + restart-on-failure (not past the halt time)
│   ├── daos.sh            #   DAOS pool/containers, mount lifecycle, on/off switches
│   ├── nodeprep.sh        #   before the sims: reclaim leftover page cache on every node
│   ├── nodeprep.cpp       #   the tool it runs, built by hashrun.sh at submit
│   ├── test/              #   standalone tests for the job scripts (no MPI/DAOS needed)
│   ├── in/                #   (git-ignored) scratch for par2-list files fed to hashrun
│   └── out/<jobid>/       #   (git-ignored) per-job staged inputs, stdout/stderr, hostfiles
├── scripts/               # DAOS login-node mounts and derivative staging
├── README.md
└── LICENSE
```

To add cosmologies (CLASS products + `cosm.def`), see [`util/UserGuide_NewCosmologies.md`](util/UserGuide_NewCosmologies.md).

## Running jobs
`hashrun.sh` is the entry point to launching a job. Example:

```
./hashrun.sh -nps 8 -t 00:10 -P NumZRanks=2 b346251 in/list1 -q debug-scaling
```

This launches a 10-minute job with 8 nodes-per-sim using the par2 list in `in/list1`. The `-P NumZRanks=2` option is passed to `abacus.run`, and the `-q debug-scaling` option is passed to qsub. The script uses the b346251 Abacus git hash, building it if needed.

See `./hashrun.sh --help` for full usage.

The hash of this repo (the production repo) is recorded by the job scripts for provenance. To ensure that the hash actually corresponds to the job content, the job scripts enforce that no dirty content is present in the repo. Content that one expects to be dirty (like par2 file lists) should go in one of the git-ignored directories, usually `job/in/`. `job/out/` is also ignored.

## Environment variables

These are read by the job scripts rather than by Abacus. `hashrun.sh` reads the submit-time ones
itself, from the shell or from `-E`. The run-time ones must be given with `hashrun.sh -E KEY=VALUE`:
`qsub` passes the job nothing else from the shell, and `multisim.pbs` sources the `-E` values after
the Abacus build's `env.sh`, so they win over its defaults. Anything else given with `-E` (MPICH or
libfabric settings, say) goes to the ranks untouched.

| Variable | Default | When | Effect |
|---|---|---|---|
| `ABACUS_REPO` | `~/abacus` | submit (shell only) | the Abacus code repo `hashrun.sh` builds from |
| `ABACUS_STORE_ROOT` | `~/abacus-store` | submit (shell only) | where the hash-keyed builds are cached |
| `ABACUS_DAOS` | `off` | submit | put the checkpoints and the working directory on DAOS; `--daos`/`--no-daos` outrank it |
| `ABACUS_DAOS_OUTPUTS` | `off` | submit | with DAOS on, put the outputs there too |
| `ABACUS_DAOS_RESOURCES` | `on` | submit | with DAOS on, read the derivatives and wisdom from DAOS |
| `ABACUS_DAOS_POOL` | `AbacusAurora` | submit | the DAOS pool |
| `ABACUS_DAOS_CONT_CHECKPOINTS`, `_OUTPUTS`, `_RESOURCES` | `Checkpoints`, `Outputs`, `Resources` | submit | the DAOS container names |
| `ABACUS_DAOS_CKPT_CONTAINERS` | `off` | submit | with DAOS on, give each checkpoint its own container (see [DAOS](#daos)) |
| `ABACUS_DAOS_PRELOAD` | `on` | run | with DAOS on, `LD_PRELOAD` the DAOS interception library into the ranks |
| `ABACUS_MPIRUN_ARGS` | empty | run | extra `mpiexec` arguments; the scripts append `--hostfile`, and with DAOS on `--no-vni` and the preload |
| `ABACUS_EXCLUDE_NODES` | none | run | short host names, space- or comma-separated, kept out of every sim; they still count toward the request, so ask for spares with `-n` |
| `ABACUS_CORE_LIMIT` | `env.sh`'s (unlimited) | run | the ranks' core-dump limit, as for `ulimit -c`; `0` turns core dumps off |
| `ABACUS_NODEPREP` | `on` | run | before the sims, reclaim each node's leftover page cache (see [Node prep](#node-prep)); `check` only measures each node, for the short-node check; `off` skips both |
| `ABACUS_NODEPREP_NEED_DDR_GIB` | `330` | run | GiB in whole 2 MiB blocks a DDR socket must have after node prep (as found, with `check`); a node short of it runs only if the spares run out. `0` turns the check off |
| `ABACUS_NODEPREP_NEED_HBM_GIB` | `58` | run | the same for an HBM node |
| `ABACUS_NODEPREP_FAIL_SHORT` | `off` | run | `on` ends the job before the sims when a short node would have to run for want of spares, or nodeprep measured nothing |
| `ABACUS_GEMM_WARMUP` | `on` | run | at the end of the job, read the files the next job's PBS prologue test loads (see [Prologue warm-up](#prologue-warm-up)); `off` skips it |
| `ABACUS_GEMM_WARMUP_STAGGER` | `2` | run | whole seconds between the warm-ups of two of our nodes in one rack |
| `ONESIM_MAX_RESTARTS` | `3` | run | relaunches allowed per sim, however healthy each attempt looked; `0` never relaunches |
| `ONESIM_MAX_SLOW_RESTARTS` | none | run | relaunches allowed after failures that were not rapid, within `ONESIM_MAX_RESTARTS`; unset, only that bounds them. Such a sim often needs a parameter change, so the flagship runs with `1`. Rapid failures are capped at 2 in a row |
| `ONESIM_MIN_HEALTHY_SECONDS` | `14400` | run | an attempt that fails sooner than this is a rapid failure |
| `ONESIM_MIN_RELAUNCH_SECONDS` | `900` | run | refuse a relaunch with less than this left before the job's halt time |
| `ARCHIVE_LOGS` | `job/archive-logs.sh` | `postprocessing.sh` | the log-archiving script to run |

In turn, the scripts set these for `aurora.def` and Abacus:
- `ABACUS_WORKING_ROOT`, `ABACUS_OUTPUT_ROOT`, `ABACUS_CHECKPOINT_ROOT` and `ABACUS_RESOURCE_ROOT`:
  the storage roots (see [DAOS](#daos)).
- `NNODES` and `ABACUS_MPIRUN_ARGS`: for `mpirun_cmd`.
- `ABACUS_JOB_HALT_TIME`: when Abacus halts, the walltime less 10 minutes.
- `ABACUS_JOB_HALT_FILE`: `/flare/Abacus/HALT.<jobid>`; create it to halt every sim in the job.

## Node prep

Abacus backs its memory with transparent huge pages, which need whole free 2 MiB blocks. ALCF nodes
frequently have fragmented memory, left over from previous jobs. So before a job, we fill every
node's memory as much as we can then free it, triggering page cache reclaim and effectively
de-fragmenting the node.

Doesn't work with non-reclaimable memory, so we also record the amount of memory in non-fragmented
regions to `out/<jobid>/nodeprep.txt`. A DDR socket that comes out short of
`ABACUS_NODEPREP_NEED_DDR_GIB` gets a second pass that also shrinks the kernel's reclaimable caches.
A node still short after that, on a DDR socket or an HBM node (`ABACUS_NODEPREP_NEED_HBM_GIB`), is
moved behind the spares: ask for spares with `-n`, or it runs anyway, unless
`ABACUS_NODEPREP_FAIL_SHORT=on` ends the job first. The spares go to nodes short of HBM before
those short only of DDR.

`ABACUS_NODEPREP=check` fills and frees nothing: it measures every node as it arrived and moves the
short ones behind the spares the same way. Page cache that a check finds counts against a node,
since only a fill would reclaim it.

## Prologue warm-up

We observe that big jobs following Abacus jobs tend to fail their prologues. Our theory is that we're exerting enough memory pressure to evict kernel page cache, which causes the executables used in the prologue to be slow to load. In particular, there's a fat 800 MB `gemm.exe` executable that's served over NFS. If thousands of nodes are all asking for that file with a cold cache, could be trouble.

So to ameliorate this, we try to re-warm the `gemm.exe` cache at the end of our job in a staggered fasion (`ABACUS_GEMM_WARMUP`; `ABACUS_GEMM_WARMUP_STAGGER`).

## DAOS

Writing to DAOS can be enabled through `hashrun.sh --daos`. `hashrun.sh` requests the `daos_user_fs` PBS resource and
checks the containers are present; `multisim.pbs` mounts them on every node and points
Abacus's storage roots at them. These containers are created and destroyed by hand — the
job scripts never do it. Which directories go where:

| | root | container | with `--daos` |
|---|---|---|---|
| the state and the SCR prefix | `$ABACUS_CHECKPOINT_ROOT` | `Checkpoints` | DAOS |
| `status.log`, HALT file, logs | `$ABACUS_WORKING_ROOT` | `Outputs` | DAOS |
| outputs — slices, groups, lightcones, tracers | `$ABACUS_OUTPUT_ROOT` | `Outputs` | flare, unless `ABACUS_DAOS_OUTPUTS=on` |
| resources — `Derivatives/` and `Wisdom/` | `$ABACUS_RESOURCE_ROOT` | `Resources` | DAOS, unless `ABACUS_DAOS_RESOURCES=off` |

The DAOS mount point is `/tmp/<pool>/<container>/`. The working, output, and checkpoint
roots go to the subdirectory `$USER/<SimName>/`; the derivatives sit at the container
root, shared between users as they are on flare.

The `Outputs` container is mounted whenever DAOS is on, even with the outputs themselves
on flare, because it holds the working directory.

With `ABACUS_DAOS_CKPT_CONTAINERS=on`, each checkpoint goes in a container of its own,
`ckpt-<SimName>-<UTC time>`, which Abacus creates, fills and destroys as checkpoints retire
(see Abacus's `doc/checkpoints.md`). The checkpoint root, holding SCR's index and the links
into those containers, moves to `Outputs`, and `Checkpoints` is not mounted. Only a sim's
restart candidates are mounted: by `multisim.pbs` for a lone sim, else by `onesim.sh` before
its first launch, and again before each relaunch.

One consequence of the working root moving: with `--daos` the per-sim logs are inside the
container, so reading them from a login node needs `./scripts/daos-mount-login.sh`. The
job-wide halt file stays on flare either way.

To turn DAOS on, to widen it to the outputs and derivatives, and to force it off again:

```
./hashrun.sh --daos ...              # this job only: checkpoints on DAOS
export ABACUS_DAOS=on                # every submission from this shell
export ABACUS_DAOS_OUTPUTS=on        # widen to the outputs as well
export ABACUS_DAOS_RESOURCES=off     # read derivatives and wisdom from flare instead
./hashrun.sh --no-daos ...           # force off, whatever the default is
```

Any of these can also be set for one job with `hashrun.sh -E ABACUS_DAOS_RESOURCES=off`.

`./job/daos.sh` prints the current pool, containers, and resolved roots (doesn't mount anything).


### Resources

The `Resources` container mirrors the flare layout, so only the prefix differs between
the two backends:

```text
$ABACUS_RESOURCE_ROOT/Derivatives/deriv32_<CPD>_8_2_8/
$ABACUS_RESOURCE_ROOT/Wisdom/fftw_cpd<CPD>_zranks<N>.wisdom
```

To stage them from flare to DAOS outside of a job:

```
./scripts/daos-stage-resources.sh 1029 1125    # by CPD; no args lists what flare has
```

Wisdom is a few hundred KB and is keyed by (CPD, NumZRanks), so the whole directory is
synced on every run of the script. The derivatives are ~85 TB across all CPDs, hence the
explicit CPD arguments: the script stages `deriv32_<CPD>_8_2_8`, the set the sims read
for a single-precision build with the usual `Order`, `NearFieldRadius`, and
`DerivativeExpansionRadius`. Copy anything else by hand.

Like the containers themselves, the two top-level directories are made by hand, once:

```
./scripts/daos-mount-login.sh Resources
mkdir -p /tmp/$USER/$DAOS_POOL/Resources/{Derivatives,Wisdom}
./scripts/daos-umount-login.sh Resources
```

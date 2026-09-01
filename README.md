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
│   ├── onesim.sh          #   per-sim monitor + restart-on-failure
│   ├── nodehealth.py      #   blames a node for a crash and swaps in a spare
│   ├── daos.sh            #   DAOS pool/containers, mount lifecycle, on/off switches
│   ├── test/              #   offline tests for nodehealth (no Aurora needed)
│   ├── in/                #   (git-ignored) scratch for par2-list files fed to hashrun
│   └── out/<jobid>/       #   (git-ignored) per-job staged inputs, stdout/stderr, hostfiles
├── doc/                   # longer-form notes on how the job machinery works
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

A sim that dies is relaunched a few times by `onesim.sh`. If the crash can be pinned on a
particular node, that node is swapped for a spare before the relaunch — ask for spares
with `-x N`. See [`doc/node-replacement.md`](doc/node-replacement.md) for what counts as
evidence, and for why some crashes deliberately blame nobody.

The hash of this repo (the production repo) is recorded by the job scripts for provenance. To ensure that the hash actually corresponds to the job content, the job scripts enforce that no dirty content is present in the repo. Content that one expects to be dirty (like par2 file lists) should go in one of the git-ignored directories, usually `job/in/`. `job/out/` is also ignored.

## DAOS

Writing to DAOS can be enabled through `hashrun.sh --daos`. `hashrun.sh` requests the `daos_user_fs` PBS resource and
checks the containers are present; `multisim.pbs` mounts them on every node and points
Abacus's storage roots at them. Containers are created and destroyed by hand — the job
scripts never do it. Which directories go where:

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

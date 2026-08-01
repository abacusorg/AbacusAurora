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
│   └── make_cosm_def.py   #   regenerates the cosm.def files from the table
├── Simulations/           # simulation specs
│   ├── aurora.def         #   Aurora site file (mpirun_cmd, core binding, I/O, dir layout)
│   ├── base.par2          #   Base Aurora parameter file, included by other par2 files
│   └── AuroraHighBase.par2  # example simulation parameter file
├── job/                   # job orchestration (run from a login node)
│   ├── hashrun.sh         #   launcher: build hash-keyed code, verify repo clean, qsub
│   ├── multisim.pbs       #   PBS batch job: split the allocation, launch each sim
│   ├── onesim.sh          #   per-sim monitor + restart-on-failure
│   ├── daos.sh            #   DAOS pool/containers, mount lifecycle, on/off switches
│   ├── in/                #   (git-ignored) scratch for par2-list files fed to hashrun
│   └── out/<jobid>/       #   (git-ignored) per-job staged inputs, stdout/stderr, hostfiles
├── README.md
└── LICENSE
```

## Running jobs
`hashrun.sh` is the entry point to launching a job. Example:

```
./hashrun.sh -nps 8 -t 00:10 -P NumZRanks=2 b346251 in/list1 -q debug-scaling
```

This launches a 10-minute job with 8 nodes-per-sim using the par2 list in `in/list1`. The `-P NumZRanks=2` option is passed to `abacus.run`, and the `-q debug-scaling` option is passed to qsub. The script uses the b346251 Abacus git hash, building it if needed.

See `./hashrun.sh --help` for full usage.

The hash of this repo (the production repo) is recorded by the job scripts for provenance. To ensure that the hash actually corresponds to the job content, the job scripts enforce that no dirty content is present in the repo. Content that one expects to be dirty (like par2 file lists) should go in one of the git-ignored directories, usually `job/in/`. `job/out/` is also ignored.

## DAOS

Writing to DAOS can be enabled through `hashrun.sh --daos`. `hashrun.sh` requests the `daos_user_fs` PBS resource and
checks the containers are present; `multisim.pbs` mounts them on every node and points
Abacus's storage roots at them. Containers are created and destroyed by hand — the job
scripts never do it. Which directories go where:

| | root | container | with `--daos` |
|---|---|---|---|
| the state and the SCR prefix | `$ABACUS_CHECKPOINT_ROOT` | `Checkpoints` | DAOS |
| outputs — slices, groups, lightcones, tracers | `$ABACUS_OUTPUT_ROOT` | `Outputs` | flare, unless `ABACUS_DAOS_OUTPUTS=on` |
| logs, derivatives, wisdom | always flare | — | flare |

The DAOS mount point is `/tmp/<pool>/<container>/`, with outputs going to the subdirectory `$USER/<SimName>/`.

To turn DAOS on, to widen it to the outputs, and to force it off again:

```
./hashrun.sh --daos ...           # this job only: checkpoints on DAOS
export ABACUS_DAOS=on             # every submission from this shell
export ABACUS_DAOS_OUTPUTS=on     # widen to the outputs as well
./hashrun.sh --no-daos ...        # force off, whatever the default is
```

`./job/daos.sh` prints the current pool, containers, and resolved roots (doesn't mount anything).

# nodehealth tests

Two suites, neither of which needs Aurora, PBS, MPI or a built Abacus. Run both
before changing `job/nodehealth.py` or the failure path of `job/onesim.sh`:

```
python3 job/test/nodehealth/test_nodehealth.py     # the rules
bash    job/test/nodehealth/test_onesim.sh         # the shell wiring
```

## `test_nodehealth.py` — the diagnosis rules

Replays the `*.log` fixtures here — excerpts from seven production failures, as
collected, with backtrace frames elided — and asserts what each one should conclude:

| fixture | expected |
|---|---|
| `8766714_sim_{2,6,14}` | replace the host whose **shepherd died from signal 9**; the host reported as `rank N died from signal 15` is launcher teardown collateral and must survive |
| `8778470_sim_5` | replace `x4709c2s3b0n0`, the host PALS stopped getting ping replies from |
| `8766809_sim_{9,21}`, `8778478_sim_1` | a strike only. All three fire 0.3–0.8 s after the step-0 status row, i.e. at the start of step 1, on three different hosts across two jobs — a software signature, not hardware. Once two are in one job's ledger the systematic suppressor fires and the third blames nobody |

It also covers the repeat-offender escalation, `absolve`, the empty-pool abort,
sixteen concurrent claims against an eight-node pool, `order-nodes` quarantine
(including its refusal to leave the sims unplaceable), the FSSTALL exoneration,
peer accusation, and the correlated-job-event downgrade.

## `test_onesim.sh` — the shell wiring

Runs the real `onesim.sh` retry loop with a stub `python` that impersonates
`abacus.param` and `abacus.run` (and forwards everything else, i.e.
`nodehealth.py`, to the real interpreter). Checks that a blamed node is actually
swapped out and the sim relaunches on the new hostfile, that an empty pool aborts
instead of retrying onto a dead node, that a segfault relaunches unchanged, that
each attempt is diagnosed only from its own slice of `sim_<i>.out`, and that
running `onesim.sh` standalone — without `$ABACUS_SIM_LOG`, `$HOSTFILE_EXTRA` and
`$HASHRUN_OUT` — behaves exactly as it did before this feature existed.

## Adding a fixture

When a new failure signature turns up on Aurora, drop the relevant lines of
`sim_<i>.out` in here as `<jobid>_sim_<i>.log` and add a case. Check first what
the current rules make of it:

```
python3 job/nodehealth.py diagnose --log-slice job/test/nodehealth/<new>.log \
        --hostfile <a hostfile containing the named hosts>
```

`diagnose` writes no state, so it is safe to run against anything.

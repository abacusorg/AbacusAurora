# Adding new cosmologies

This guide produces, for each new cosmology `abacus_cosmNNN`:

| File | Role |
|------|------|
| `Cosmologies/abacus_cosmNNN/CLASS.ini` | CLASS parameters (thin file: densities, \(h\), \(A_s\), \(n_s\), DE, neutrinos) |
| `CLASS_power` | \(z=1\) \(P_{\mathrm{cb}}(k)\) for Zel’dovich ICs |
| `CLASS_transfer` | matching transfer function |
| `cosm.def` | Abacus snippet; `.par2` files `#include` this |
| a row in `Cosmologies/README.md` and `cosmologies.csv` | published parameter table |

Work from `util/`. Scripts expect that directory as CWD (they `chdir` into `../Cosmologies/` and back). Redirect long runs if you want a log, e.g. `python run_class.py ... > run_class.log 2>&1`.

## 1. CLASS (required)

Use [Willem Elbers’ CLASS fork](https://github.com/abacusorg/class_public) at commit **`6cf8e3`** (`6cf8e384`). Build **classy** from the same tree:

```bash
cd class_public/python && CC=gcc python setup.py install --user
```

`H0_search.py` calls classy. `run_class.py` calls the binary at **`~/class_public/class`** (hardcoded). If those two trees differ, the \(h\) that matches \(100\theta_s\) will not match the final \(P(k)\).

Precision files: `Cosmologies/abacus_base.pre` (production) and `abacus_base_fast.pre` (\(A_s\) calibration). The angular-scale target is CLASS **`theta_s_100()`** (sound-horizon angle at the visibility peak), measured from `util/abacus_base_full.ini`. That is **not** CAMB \(\theta_\ast\). For c000, \(100\theta_s \approx 1.041533\).


## 2. Run the pipeline

**Do not pass the full `emulator_grid` as `--table`.** `H0_search` **overwrites** `Cosmologies/README.txt` with that file. Use a small staging table that contains only the new rows.

`--force` **deletes** existing `abacus_cosmNNN/` product directories. Leave it off unless you intend to redo those cosmologies.

### Staging table

Either convert a glass `.dat` or write `|` rows by hand.

```bash
# DESI secondaries (cosm 200/201/210) — also inserts missing rows into emulator_grid
python desi_secondaries_to_grid.py

# Emulator grid with a per-cosmology theta_s *factor* (cosm 220–225, 230–261)
python emulator_core4_to_grid.py
```

Hand-written rows must use the exact TBD padding (`TBD   ` and ` 2.TBD e-9 `) or `H0_search` will not substitute \(h\)/\(A_s\). Leave `sigma8_*` empty. Neutrino convention for the current set: \(N_{\mathrm{ncdm}}=1\), \(\omega_{\mathrm{ncdm}}=0.00064420\).

```text
| root               | notes                    | omega_b | omega_cdm | h      | A_s       | n_s    | alpha_s | N_ur   | N_ncdm | omega_ncdm | w0_fld | wa_fld | sigma8_m | sigma8_cb |
| ------------------ | ------------------------ | ------- | --------- | ------ | --------- | ------ | ------- | ------ | ------ | ---------- |------- | ------ | -------- | --------- |
| abacus_cosm210     | DESI DR2+CMB LCDM        | 0.02247 |  0.1186   | TBD   | 2.TBD e-9 | 0.9740 | 0.000   | 2.0328 | 1      | 0.00064420 | -1.000 | 0.000 |           |           |
```

Glass `.dat` columns (whitespace-separated). DESI files have 9 columns; the emulator file adds a 10th **factor**, not CLASS \(100\theta_s\):

```text
#num  sigma8cb  ochh  ns  obhh  w0  wa  Nur  nrun  [theta_s_factor]
210   0.819722  0.1186  0.9740  0.02247  -1  0  2.0328  0
222   0.811355  0.1200  0.9649  0.02237  -1  0  2.0328  0  1.0200
```

### CLASS + \(h\) + \(A_s\)

```bash
cd util
python run_class.py --table ../Cosmologies/<staging_grid> --glass <glass.dat>
```

Defaults if you omit flags: `--table ../Cosmologies/desi_secondaries_grid`, `--glass desi_secondaries.dat`, global \(\theta_0\) (every cosm matches c000’s \(100\theta_s\)). Existing `abacus_cosm*/` dirs are skipped.

For the emulator grid (per-cosm \(\theta_s\) factor):

```bash
python emulator_core4_to_grid.py
python run_class.py \
  --table ../Cosmologies/emulator_core4_grid \
  --glass emulator_core4.dat \
  --per-cosm-theta
```

Never treat a glass value such as `1.0200` as CLASS \(\theta\). The last column is \(\theta_{\mathrm{def}} = \theta_0 \times \mathrm{factor}\) with \(\theta_0\) from `abacus_base_full.ini`. Without `--per-cosm-theta`, every cosm uses global \(\theta_0\). The `|` table has no \(\theta\) column.

`run_class.py` then: solves TBD \(h\) → writes `README.txt` → CLASS (fast, if \(A_s\) is still dummy) → rescale \(A_s\) to glass \(\sigma_{8,\mathrm{cb}}\) → full CLASS → write measured \(\sigma_8\) and rename outputs to `CLASS_*`. It **stops** on a nonzero CLASS or `write_s8` exit. It does **not** write `cosm.def`.

Top-level `Cosmologies/abacus_cosmNNN.ini` files are working copies. Keepers live **inside** `abacus_cosmNNN/`. If a run dies mid-block, those parent-level `.ini` files may remain; they are duplicates of `CLASS.ini` and are not used by Abacus.

### Publish the table

```bash
python merge_readme_txt_to_md.py --csv ../Cosmologies/cosmologies.csv
```

This updates matching `| abacus_cosmNNN |` rows in `README.md` and `cosmologies.csv`. New roots are **appended** (not sorted by cosm number).

### `cosm.def` (Abacus)

```bash
cd ../Cosmologies
python make_cosm_def.py abacus_cosmNNN   # several dirs allowed
```

`make_cosm_def.py` reads `CLASS.ini` and writes Abacus names:

```text
H0 = 100*h
Omega_M      = (omega_b + omega_cdm + sum(omega_ncdm)) / h^2
Omega_Smooth = sum(omega_ncdm) / h^2
Omega_K = 0.0
Omega_DE = 1.0-@Omega_M@
w0, wa   <- w0_fld, wa_fld
ZD_Pk_filename = "$PAR2_DIR$/CLASS_power"
ZD_Pk_file_redshift = 1.0
```

(`CLASS_power` is CLASS output `z2`, i.e. \(z=1\), from `z_pk = 0,1,3,7,49`.) Aurora `.par2` files `#include` this file, e.g. `"../Cosmologies/abacus_cosmNNN/cosm.def"`.

## 3. Checklist

- [ ] `CLASS_power` exists (\(z=1\) \(P_{\mathrm{cb}}\))
- [ ] `cosm.def` exists; the `.par2` `#include`s it
- [ ] `README.md` / `cosmologies.csv` row has filled \(h\), \(A_s\), \(\sigma_8\)
- [ ] \(A_s\) is not the dummy `2.00001e-09`
- [ ] Measured \(\sigma_{8,\mathrm{cb}}\) within ~few\(\times10^{-4}\) of the glass target
- [ ] If `--per-cosm-theta`: \(|100\theta_s - \theta_0\times\mathrm{factor}| \lesssim 2\times10^{-5}\)
- [ ] classy and `~/class_public/class` are the same commit


---

## FAQ

### Should I run `H0_search` (leave \(h\) as TBD)?

**Yes** for Abacus: match CLASS \(100\theta_s\) to the c000 (or per-cosm) target. A paper or “emulator space” \(h\) typically differs by a few \(\times0.1\%\). Put a numeric \(h\) in the `|` row to skip the bisection.

### Is \(A_s\) calibration only for emulator cosmologies?

**No.** Any row whose \(A_s\) is still the dummy (`2.TBD e-9` → `2.00001e-09`) is tagged `With A_s calibration` and gets a fast CLASS run plus rescaling so \(\sigma_{8,\mathrm{cb}}\) matches glass `sigma8cb` (2nd column, matched by cosm number). `run_class.py` always uses that glass path (`from_emulator=1`). If \(A_s\) is already a physical number, calibration is skipped.

CLASS is run twice when calibrating: **fast** to fix \(A_s\), then **full** (`abacus_base.pre`) for IC \(P(k)\) / transfer.

### Why doesn’t `emulator_grid` list \(\sigma_8\)?

It is an input design table (often TBD \(h\)/\(A_s\)). Amplitude **targets** are in the glass `.dat`. **Measured** \(\sigma_8\) appear after CLASS in `README.txt` / `README.md` / `cosmologies.csv`.

### Recovery

- Mid-block CLASS failure after \(h\) is already filled: `repair_core4_as.py` redos \(A_s\) + full CLASS + `cosm.def` without re-bisecting \(h\).
- Emulator \(\theta_s\) check: `python validate_core4_theta.py`.
- Do not use `glass_to_grid.py` here (Summit leftover: `emulator_glass.dat`, cosm>115 cut).
- Do not run `H0_search.py` standalone for a small block; its default table is the full `emulator_grid`.

---

## Appendix: what `run_class.py` does

| Step | Action |
|------|--------|
| A | Staging `|` rows with TBD \(h\)/\(A_s\) |
| B | `H0_search`: classy on `abacus_base_full.ini` → \(\theta_0\); copy `--table` → `README.txt`; bisect \(h\in[0.55,0.85]\) (spacing \(10^{-5}\), \(|\Delta 100\theta_s|<10^{-5}\)) |
| C | `table_to_ini`: every `README.txt` row → `Cosmologies/<root>.ini` |
| D–F | Fast CLASS + `calibrate_A_s.py` + `table_to_ini` again, if the ini comment has `With A_s calibration` |
| G | Full CLASS + `abacus_base.pre` |
| H | `write_s8.py`: replace last two table columns with measured \(\sigma_8\); rename → `CLASS_*` |
| I | `merge_readme_txt_to_md.py --csv …` (you run this) |
| J | `make_cosm_def.py` (you run this) |

`H0_search` writes \(h\) as four decimals (`6.4f`). Dummy \(A_s\) after the bisection is `2.00001e-09`. Temporary `util/abacus_cosmNNN/` dirs from the bisection are deleted. `write_s8` aborts if `<root>.out` has no `sigma8=` (usually a killed CLASS).

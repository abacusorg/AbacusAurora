# Adding new cosmologies for AbacusAurora

Guide to append new cosmologies to `Cosmologies/abacus_cosmNNN/{CLASS.ini,CLASS_power,CLASS_transfer,cosm.def}` and update the parameter table.

## CLASS version

Use Willem Elbers' CLASS fork at commit **`6cf8e3`**:

- Repo: https://github.com/abacusorg/class_public   
- Python wrapper **classy** must be built from the **same** tree (`cd class_public/python && CC=gcc python setup.py install --user`)

`H0_search.py` uses classy; `run_class.py` shells out to the `class` binary. Mismatched versions make \(\theta_s\) targeting inconsistent with the final \(P(k)\).

Shared physics/precision: `Cosmologies/abacus_base.pre` (full) and `abacus_base_fast.pre` (A_s calibration). Target \(\theta_\star\): `util/abacus_base_full.ini`.

## Procedure

Use `run_class.py` to run the entire pipeline. Everything runs with CWD = `util/`, and the scripts `os.chdir` into
`../Cosmologies/` and back — they are position-dependent, so keep the two-directory layout.

**Step 0 (optional).** Design the grid: `emulator_glass.sm` → `emulator_glass.dat`, then
`glass_to_grid.py` splices rows with `TBD`s into `Cosmologies/emulator_grid`.
Or just hand-write the `|` rows in `emulator_grid`.

**Step 1.** Run `run_class.py` in `util/`. This script sequences H0_search → table_to_ini → (optional A_s calibrate) → full CLASS → write_s8. Prefer it over running each individual script by hand.

Notes: 
1. everything runs with CWD = `util/`, and the scripts `os.chdir` into
`../Cosmologies/` and back — they are position-dependent, so keep the two-directory layout.
2. Existing `abacus_cosm*/` directories are **skipped** (not overwritten) unless you pass `--force`.

**Individual steps (skip if you run `run_class.py`):**
**Run `H0_search.main()`** — solves for `h`.
* Runs CLASS on `util/abacus_base_full.ini` to get the target `100*theta_s`.
* Copies `Cosmologies/emulator_grid` → **`Cosmologies/README.txt`** (the working table).
* For each row whose `h` is the `TBD` sentinel: bisection over `h ∈ [0.55, 0.85]` on a
  grid of spacing `1e-5`, tolerance `1e-5` in `100*theta_s`, base precision
  `abacus_bisection_fast.pre`. ~15 CLASS calls per cosmology.
* Writes the solved `h` (and the still-`TBD` `A_s`) back into `README.txt` in place, then
  deletes its scratch directory.

**`table_to_ini.main()`** — table → `Cosmologies/<root>.ini`, one per row.
Rows whose `A_s` is still the sentinel get the marker comment `# With A_s calibration, <notes>`
in the ini; that comment is the flag Step 3 looks for.

**For each cosmology**:
1. `mkdir <root>`, copy the ini in.
2. If the ini says `With A_s calibration`:
   * run CLASS with `abacus_base_fast.pre` → `<root>.out`;
   * `calibrate_A_s.py <root> <from_emulator>` scrapes `sigma8=` for `baryons+cdm` out of
     `<root>.out`, rescales `A_s`, and writes it into `README.txt`;
   * re-run `table_to_ini.main()` so the ini picks up the new `A_s`.
   * The **target** `sigma8_cb` comes from one of two places, selected by the `from_emulator`
     flag hard-coded near the top of `run_class.py`:
     - `from_emulator = 1`: column 1 of `emulator_glass.dat`, matched on cosmology number
       (asserts number > 115);
     - `from_emulator = 0`: the `sigma8_cb` of `abacus_cosm000` from the table — i.e. "hold
       sigma8_cb at the baseline value", which is what the c100–c115 derivative grid wants.
3. Run CLASS at full precision with `abacus_base.pre` → `<root>.out`.
4. `write_s8.py <root>` appends the measured `sigma8_m` and `sigma8_cb` to the `README.txt` row
   and renames the three keeper files to `CLASS.ini` / `CLASS_power` / `CLASS_transfer`.

**Step 2 (manual).** 
Merge the finished `Cosmologies/README.txt` rows back into `README.md`
(and append to `cosmologies.csv` by hand).

**Step 3 (Aurora specific).** 
cd ../Cosmologies
for d in abacus_cosm200 abacus_cosm201 abacus_cosm210; do
  python make_cosm_def.py "$d"
done

This will write the `cosm.def` files to `../Cosmologies/abacus_cosmNNN/`, which follow Aurora parameter convention:
```
H0 = 100*h
Omega_M      = (omega_b + omega_cdm + sum(omega_ncdm)) / h^2
Omega_Smooth = sum(omega_ncdm) / h^2
Omega_K = 0, Omega_DE = 1 - Omega_M
w0, wa   <- w0_fld, wa_fld
ZD_Pk_filename = "$PAR2_DIR$/CLASS_power",  ZD_Pk_file_redshift = 1.0
```

Aurora's `.par2` files then `#include "../Cosmologies/abacus_cosmNNN/cosm.def"`.
---

## What each step does (manual map)

| Step | Script / action | Purpose |
|------|-----------------|--------|
| A | Add `|` rows with **`h = TBD   `**, **`A_s =  2.TBD e-9 `** (exact spaces) | Input params; leave `sigma8_*` empty |
| B | `H0_search` (via `run_class`) | Bisect \(h\) so \(100\theta_s\) matches `abacus_base_full.ini` (~1.041533). Writes working `Cosmologies/README.txt` |
| C | `table_to_ini` | `README.txt` → `Cosmologies/<root>.ini` |
| D | CLASS + `abacus_base_fast.pre` | Only if ini comment has `With A_s calibration` (TBD \(A_s\)) |
| E | `calibrate_A_s.py` | Rescale \(A_s\) to a **target** \(\sigma_{8,\mathrm{cb}}\) |
| F | `table_to_ini` again | Pick up new \(A_s\) into the ini |
| G | CLASS + `abacus_base.pre` | Production spectra (pk_ref precision) |
| H | `write_s8.py` | Append **measured** \(\sigma_{8,\mathrm{m}}\), \(\sigma_{8,\mathrm{cb}}\) to `README.txt`; rename → `CLASS.ini` / `CLASS_power` / `CLASS_transfer` |
| I | Merge into `README.md` | Prefer `merge_readme_txt_to_md.py` (manual paste is fine if careful) |
| J | `make_cosm_def.py <dir>` | `CLASS.ini` → `cosm.def` for `#include` from `.par2` |

---

## Answers to common choices

### Should I run `H0_search`?

- **Yes (Abacus default):** keep \(h\) as TBD. Matches Summit/Aurora angular-scale convention (\(\theta_\star\)). Paper or “emulator space” \(h\) values will shift by a few ×0.1%.
- **No:** put a numeric \(h\) in the `|` row. `H0_search` skips that row. Use only if you intentionally freeze an external \(h\).

### Is `calibrate_A_s` only for emulator cosmologies?

**No.** It runs for **any** row that still has TBD \(A_s\) (ini tagged `With A_s calibration`).

Target \(\sigma_{8,\mathrm{cb}}\) comes from:

- `from_emulator=1` (Aurora DESI default): column 1 of a glass `.dat` (e.g. `desi_secondaries.dat`), matched by cosm number  
- `from_emulator=0`: match `abacus_cosm000`’s table \(\sigma_{8,\mathrm{cb}}\)

If \(A_s\) is already numeric in the table, calibration is skipped.

### Why run CLASS twice?

1. **Fast** — measure \(\sigma_8\) cheaply → fix \(A_s\).  
2. **Full (`abacus_base.pre`)** — final \(P(k)\) / transfer for ICs.

If \(A_s\) is already fixed, only the full run runs.

### Why doesn’t `emulator_grid` show \(\sigma_8\)?

`emulator_grid` is an **input** design table (often TBD \(h\)/\(A_s\)). Targets for amplitude live in the glass `.dat`. **Measured** \(\sigma_8\) appear only after CLASS, in `README.txt` / `README.md`.

### What does `write_s8` do?

Records measured \(\sigma_8\) on the working table and renames CLASS outputs to the Abacus keeper names (`CLASS_*`). Without it you only have raw `*.z2_pk_cb.dat` / `*.z2_tk.dat`.

---

## Input formats

**Glass `.dat`** (like `desi_secondaries.dat`):

```text
#num  sigma8cb  ochh  ns  obhh  w0  wa  Nur  nrun
200   0.819697  ...
```

Convert with a splice script (see `desi_secondaries_to_grid.py`) into `|` rows with TBD \(h\)/\(A_s\). Insert new rows immediately after the last `| abacus_cosm…` table line in `emulator_grid`

**Or** hand-edit a small staging `|` table and pass `--table` to `run_class.py` so you do not reprocess every historical TBD row in `emulator_grid`.

---

## Checklist before sims

- [ ] `Cosmologies/abacus_cosmNNN/CLASS_power` exists (z=1 \(P_{\mathrm{cb}}\))  
- [ ] `cosm.def` present; `.par2` `#include`s it  
- [ ] Row in `README.md` with filled \(h\), \(A_s\), \(\sigma_8\)  
- [ ] Measured \(\sigma_{8,\mathrm{cb}}\) within ~few×10⁻⁴ of target (typical after fast→full)  
- [ ] Same CLASS commit for classy and `class` binary  

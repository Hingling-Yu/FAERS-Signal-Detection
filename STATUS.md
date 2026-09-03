# FAERS Signal Detection — Status

## Current State: Phase 1.2 — SQL Warehouse ⏳ READY TO RUN

**Last updated:** 2026-09-03

### Phase 1.1 — SAS Import Pipeline ✅ COMPLETE
- ✅ Charter v2 written (4-phase structure, GLP-1 focus)
- ✅ Data audited — 10 data quality issues documented (DQ1–DQ10)
- ✅ SAS execution environment: SAS OnDemand for Academics (browser)
- ✅ DQ3 fixed: renamed `faers_ascii_2025Q4` → `faers_ascii_2025q4`
- ✅ DQ8 fixed: deleted `Thumbs.db` from `faers_ascii_2026q1/ASCII/`
- ✅ Project subdirectories created
- ✅ `sas/00_config.sas` — libnames, paths, quarter vars, GLP-1 drug list, Evans thresholds, PROC FORMAT
- ✅ `sas/macros/import_faers_table.sas` — parameterized import macro (DQ1/DQ4/DQ5/DQ6)
- ✅ `sas/01_import_clean.sas` — imports 7 tables × 4 quarters, DELETE filtering (DQ2), deduplication
- ✅ `python/01_verify_raw_widths.py` — independent row count + field width verification
- ✅ `.gitignore` written and verified
- ✅ All FAERS data uploaded to SAS ODA (including 214MB DRUG files)

### Gate 1: PASSED (all 3 criteria)
- **Row counts:** SAS log "GATE 1 ROW COUNTS PASSED - all 32 files match expected" + Python independent verification 32/32
- **Field widths:** 44 character columns = 33 AT_CAP (FDA source truncation) + 11 OK (headroom), 0 TRUNCATED. 0 ragged rows
- **Dedup rate:** DEMO 6.93% (within 5–15% expected range). Breakdown: 4,432 deleted cases + 109,515 duplicate versions

### CLEAN Dataset Row Counts
| Table | Rows |
|-------|------|
| DEMO | 1,529,536 |
| DRUG | 6,299,773 |
| REAC | 4,983,301 |
| INDI | 4,206,546 |
| OUTC | 1,127,292 |
| THER | 1,486,320 |
| RPSR | 44,521 |

### Known Anomaly (investigated, confirmed correct)
RPSR dropped only 1 row (0.0022%) vs 8–14% for other tables. Root cause: all 44,042 RPSR primaryids point to caseversion=1 initial reports with 0% revision rate in the 4-quarter window. No higher versions = nothing to deduplicate.

### Bug Fixed
`01_import_clean.sas` section 8: `CATS()` stripped trailing space in SQL concatenation, generating invalid token `asage_cod`. Fixed with `CATX()`. Impact: only `qc_field_widths.csv`; CLEAN datasets unaffected.

### Phase 1.2 — SQL Warehouse ✅ CODE COMPLETE (not yet run)
- ✅ `sas/01b_export_csv.sas` — exports 8 CLEAN datasets to CSV with pinned column order, batch plan for 5GB quota, shape assertion
- ✅ `sql/01_ddl.sql` — database + 2 users (faers_app / faers_ro) + 9 tables + indexes + ref_glp1_drug reference table
- ✅ `sql/02_load.sql` — LOAD DATA with NULLIF mapping for strict mode + Gate 1 MySQL verification (row counts, referential integrity, DELETE exclusion, value sanity, primaryid width)
- ✅ `sql/03_queries.sql` — 3 views (v_demo_enriched, v_case_outcome, v_glp1_cases) + materialised GLP-1 cohort (glp1_ps_case) + 20 analytical queries across 7 sections
- ✅ Column contract machine-verified: SAS export ↔ DDL ↔ LOAD DATA column names and order three-way consistent
- ✅ CHARTER §7 folder structure updated (01b_export_csv.sas + output/csv/)

### Design Decisions (Phase 1.2)
- **glp1_ps_case is a materialised table, not a view.** LIKE with leading wildcard cannot use indexes on 6.3M drug rows. Materialised once into ~100K indexed rows; cost: must rerun 03_queries.sql §3 after every reload.
- **No FK constraints.** Read-only analytical warehouse; referential integrity enforced upstream by SAS pipeline and verified by 02_load.sql §5.2.
- **GLP-1 matching: SQL uses LIKE '%SEMAGLUTIDE%', SAS uses exact IN list.** Decision: align SAS to SQL (widen to FIND/CONTAINS) after Q3.2 confirms no false positives. See Open Items.

### Open Items
1. **GLP-1 matching alignment** — Run Q3.2 after MySQL load to see which prod_ai strings the wildcard catches beyond exact match. If no false positives, widen SAS 00_config.sas to match. (Coco)
2. **Sub-table cross-quarter duplicates** — Run Q1.2 after MySQL load. Expect 0. If non-zero, add dedup step to 01_import_clean.sas for child tables. (Coco)

### Execution Checklist (Angel)
1. Change two `CHANGE_ME` passwords in `sql/01_ddl.sql`
2. Run `01_ddl.sql` as root
3. `SET GLOBAL local_infile = 1;` as root
4. Run `sas/01b_export_csv.sas` on SAS ODA in batches, download CSVs to `output/csv/`
5. Run `02_load.sql` via sed pipeline (see file header)
6. Run `03_queries.sql` — review Q1.2 and Q3.2 results, report back

## Next Step

**→ Angel runs the execution checklist above (Phase 1.2)**
**→ Then Phase 2: Signal Detection Engine**
- `sas/macros/calc_prr.sas` — PRR + 95% CI macro
- `sas/macros/calc_ror.sas` — ROR + 95% CI macro
- `sas/02_signal_engine.sas` — full-database PRR/ROR on all drug–reaction pairs
- `sas/02_positive_controls.sas` — validate against 6 known drug–reaction pairs

## Blockers

None.

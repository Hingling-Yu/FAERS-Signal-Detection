# FAERS Signal Detection — Project Charter

## 1. Project Identity

| Field | Value |
|---|---|
| Project Code | FAERS-SD |
| Owner | Hingling Yu |
| Start Date | 2026-09-02 (planning); execution starts after SAS ODA setup |
| Target Completion | 21 calendar days from execution start |
| Repository | `~/Claude/Projects/FAERS-Signal-Detection` |
| Tech Stack | SAS (primary, via SAS OnDemand for Academics) · MySQL · Tableau |
| Analytical Focus | GLP-1 receptor agonists (semaglutide / tirzepatide / liraglutide / dulaglutide) |

## 2. Purpose

**Business goal:** Build a portfolio project that demonstrates SAS programming + pharmacovigilance analytical thinking, filling the gap between "SAS certified" and "I can do drug safety signal detection."

**Target roles (priority order):**

1. PV Case Processor — FAERS/MedDRA familiarity is the differentiator
2. Drug Safety Data Analyst — signal detection methodology (PRR/ROR) + clinical interpretation
3. RWE Analyst — real-world data pipeline skills transfer directly

**What this project proves to a hiring manager:**

- Can ingest and clean FDA adverse event data at scale (~1.6M cases, 22M+ rows)
- Knows FAERS table structure, MedDRA coding, case versioning, deduplication
- Can build disproportionality signal detection engine (PRR, ROR) in SAS
- Can do focused drug class analysis with subgroup stratification and time trends
- Can independently replicate FDA safety findings and identify potential emerging signals
- Can present findings to non-technical stakeholders via Tableau

**Resume bullet (target):**

> Analyzed 1.6M FDA adverse event reports across 4 quarters to detect safety signals for GLP-1 receptor agonists using SAS; independently replicated FDA's pancreatitis signal for semaglutide and identified [X] emerging signals in patients over 65, with PRR increasing from [a] to [b] over the study period.

## 3. Analytical Focus: Why GLP-1 Receptor Agonists

- Ozempic / Wegovy / Mounjaro are the most prescribed new drug class globally
- FDA is actively updating safety labels (pancreatitis, thyroid C-cell tumors, gastroparesis, suicidal ideation)
- 2025Q3–2026Q2 covers the peak prescribing period — FAERS data will be rich
- Clinically relevant topic that any pharma interviewer will immediately recognize
- Allows head-to-head comparison (newer semaglutide/tirzepatide vs older liraglutide/dulaglutide)

## 4. Data Source

**FDA FAERS Quarterly Data Extract** — publicly available ASCII files from https://fis.fda.gov/extensions/FPD-QDE-FAERS/FPD-QDE-FAERS.html

| Quarter | DEMO | DRUG | REAC | INDI | OUTC | THER | RPSR |
|---|---|---|---|---|---|---|---|
| 2025 Q3 | 438,512 | 2,148,451 | 1,535,133 | 1,310,274 | 343,251 | 514,480 | 11,107 |
| 2025 Q4 | 385,288 | 1,815,349 | 1,349,105 | 1,168,789 | 289,721 | 454,746 | 10,694 |
| 2026 Q1 | 397,224 | 1,703,210 | 1,330,675 | 1,139,940 | 291,580 | 404,946 | 11,426 |
| 2026 Q2 | 422,459 | 1,627,225 | 1,394,751 | 1,124,333 | 303,705 | 326,027 | 11,295 |
| **Total** | **1,643,483** | **7,294,235** | **5,609,664** | **4,743,336** | **1,228,257** | **1,700,199** | **44,522** |

*Row counts exclude header row. `$`-delimited ASCII, 7-bit clean, no encoding issues.*

### Table Schema

| Table | Cols | Key Fields | What It Contains |
|---|---|---|---|
| DEMO | 25 | primaryid, caseid, caseversion, age, sex, reporter_country | One row per report version — demographics + metadata |
| DRUG | 20 | primaryid, drug_seq, role_cod, drugname, prod_ai, route | Drugs per case; role_cod = PS/SS/C/I |
| REAC | 4 | primaryid, pt (MedDRA Preferred Term) | Adverse reactions per case |
| INDI | 4 | primaryid, indi_drug_seq, indi_pt | Indication for each drug |
| OUTC | 3 | primaryid, outc_cod | Outcome: DE (death), HO (hospitalization), etc. |
| THER | 7 | primaryid, dsg_drug_seq, start_dt, end_dt, dur | Therapy dates and duration |
| RPSR | 3 | primaryid, rpsr_cod | Report source |
| DELETE | 1 | caseid | Retracted cases — must exclude |

### Data Quality Notes (from Coco audit 2026-09-02)

Hard constraints for code. Every item must be handled explicitly.

| # | Issue | Severity | How to Handle |
|---|---|---|---|
| DQ1 | **DRUG table uses CRLF** (\\r\\n), all others use LF. `dose_freq` has trailing \\r on every row + header. | High | Strip \\r: `dose_freq = compress(dose_freq, '0D'x);` |
| DQ2 | **DELETE files: 3 of 4 have leading empty/space line** (Q3/Q4/Q2; Q1 clean). | High | Filter with `^[0-9]+$`. These are caseid, not primaryid. |
| DQ3 | **Folder name inconsistency**: `faers_ascii_2025Q4` uppercase Q, others lowercase. | Medium | Rename to `2025q4` before coding. |
| DQ4 | **Incomplete dates in THER**: 6-digit (YYYYMM) and 4-digit (YYYY) alongside 8-digit. | High | Parse by length: 8→date, 6→first of month, 4→first of year, else missing. |
| DQ5 | **Missing = empty string** (`$$`), not NULL. | Medium | Convert to `.` (SAS) / `NULL` (MySQL) at import. |
| DQ6 | **Embedded TABs** in DRUG text fields (213 rows total) and 1–2 DEMO rows/quarter. | Low | Harmless for `$` import; strip in cleaning. |
| DQ7 | **2026Q2 caseid 26012757 appears twice** (caseversion 6 and 7). | Info | Expected. Dedup handles it. |
| DQ8 | **Thumbs.db** in 2026q1/ASCII/. | Trivial | Delete or .gitignore. |
| DQ9 | **3 shared PDFs** (ASC_NTS, Readme, FAQs) identical across quarters. Per-table PDFs differ. | Info | Keep one copy in `docs/fda_notes/`. |
| DQ10 | **Data at project root**, not in `raw-data/`. | Setup | Rename folders into `raw-data/` as Phase 0 step. |

**Verified clean:** 22M+ rows all have correct column counts. No embedded `$`. No schema drift across quarters.

## 5. Scope

### In Scope

- Full-database import, deduplication, and cleaning pipeline in SAS
- PRR/ROR signal detection engine with reusable macros
- GLP-1 receptor agonist deep dive: signal profile, drug comparison, subgroup analysis, time trends
- Positive control validation against known drug–reaction pairs
- Cross-reference with FDA safety communications / label updates
- Limitations discussion (reporting bias, Weber effect, no denominator data)
- Tableau dashboard focused on GLP-1 findings
- Portfolio case study + STAR interview stories

### Out of Scope

- EBGM / Bayesian methods
- MedDRA hierarchy beyond PT level (no SMQ/HLT — would need license)
- Other data sources (claims, EHR)
- NLP on narrative text
- Real-time pipeline / automation
- Python visualization scripts (Tableau handles all viz)

## 6. Deliverables

| # | Deliverable | Format | Purpose |
|---|---|---|---|
| D1 | SAS data pipeline (import + clean + dedup) | `.sas` files | Proves SAS data handling |
| D2 | SAS signal detection engine (PRR/ROR macros) | `.sas` files | Core analytical capability |
| D3 | SAS GLP-1 analysis programs (7 programs) | `.sas` files | **The main show** — analytical SAS code |
| D4 | MySQL schema + load scripts | `.sql` files | SQL skills |
| D5 | QC reports (import, cleaning, positive controls) | `.csv` | Methodology rigor |
| D6 | GLP-1 signal results table | `.csv` | Analytical output |
| D7 | Tableau dashboard | Tableau Public | Interactive findings presentation |
| D8 | Case study | `Case_Study_EN.md` | Portfolio piece |
| D9 | STAR interview stories | `interview_prep/` | 3–5 stories from this project |

## 7. Folder Structure

```
FAERS-Signal-Detection/
├── CLAUDE.md
├── CHARTER.md
├── STATUS.md
├── LOG.md                            # Decision log (append-only)
│
├── raw-data/                         # Original FAERS ASCII (read-only)
│   ├── 2025q3/ASCII/*.txt + Deleted/
│   ├── 2025q4/                       # Renamed from faers_ascii_2025Q4
│   ├── 2026q1/
│   └── 2026q2/
│
├── sas/                              # All SAS programs
│   ├── 00_config.sas                 #   Libname, paths, global settings
│   ├── 01_import_clean.sas           #   Import all 7 tables + clean + dedup
│   ├── 02_signal_engine.sas          #   Full-database PRR/ROR run
│   ├── 02_positive_controls.sas      #   Validation against known signals
│   ├── 03_glp1_extract.sas           #   Extract GLP-1 subset from full DB
│   ├── 03_glp1_signal_profile.sas    #   Full signal table for GLP-1 class
│   ├── 03_glp1_drug_compare.sas      #   Semaglutide vs liraglutide head-to-head
│   ├── 03_glp1_subgroup.sas          #   Stratified PRR by age/sex/country
│   ├── 03_glp1_time_trend.sas        #   PRR by quarter, trend analysis
│   ├── 03_glp1_validation.sas        #   Check against FDA known label signals
│   ├── 03_glp1_report.sas           #   ODS PDF/HTML formatted report
│   └── macros/
│       ├── import_faers_table.sas    #   Reusable import macro
│       ├── calc_prr.sas              #   PRR + 95% CI
│       └── calc_ror.sas              #   ROR + 95% CI
│
├── sql/                              # MySQL (supporting role)
│   ├── 01_ddl.sql                    #   CREATE TABLE
│   ├── 02_load.sql                   #   LOAD DATA from SAS output
│   └── 03_queries.sql                #   Ad-hoc analysis queries
│
├── output/
│   ├── tables/                       #   Signal tables, exports
│   ├── figures/                      #   Any SAS SGPLOT output
│   ├── logs/                         #   SAS .log files
│   └── qc/                           #   QC reports
│
├── dashboard/
│   └── FAERS_GLP1_Signal_Detection.twbx
│
├── docs/
│   ├── fda_notes/                    #   One copy of ASC_NTS/Readme/FAQs PDFs
│   └── data_dictionary.md            #   FAERS field reference
│
└── portfolio/
    ├── Case_Study_EN.md
    └── screenshots/
```

### Naming Conventions

- SAS: `{phase}_{description}.sas` — e.g. `03_glp1_subgroup.sas`
- SQL: `{order}_{action}.sql`
- Output: `{table}_{description}.csv` or `fig_{description}.png`
- No spaces; lowercase with underscores

## 8. Phased Execution Plan

### Phase 1: Data Pipeline (Day 1–5)

**Goal:** All data imported, cleaned, deduplicated, and loaded into SAS datasets + MySQL.

**SAS programs:**

| Program | What It Does |
|---|---|
| `00_config.sas` | Libname assignments, file paths, format definitions for SAS ODA environment |
| `macros/import_faers_table.sas` | Parameterized macro: reads any FAERS table × any quarter. Handles DQ1 (CRLF), DQ5 (empty→missing), DQ4 (date parsing) |
| `01_import_clean.sas` | Calls import macro for all 7 tables × 4 quarters. Applies DELETE files (DQ2 filter). Deduplicates by caseid (keep max caseversion). Drug name standardization (prod_ai → UPCASE TRIM). Outputs clean datasets + QC row-count report |

**SQL scripts:**

| Script | What It Does |
|---|---|
| `01_ddl.sql` | CREATE TABLE for all 7 tables with proper types, indexes on primaryid/caseid |
| `02_load.sql` | LOAD DATA from SAS-exported CSVs into MySQL |

**SAS execution flow:** Coco writes .sas in VS Code repo → Angel copies to SAS Studio (browser) → runs → downloads output CSVs + .log back to `output/`

**Gate 1:** Source .txt row count = SAS dataset row count = MySQL row count, per table per quarter. Dedup rate 5–15%. Zero truncated fields. QC report reviewed.

---

### Phase 2: Signal Detection Engine (Day 6–9)

**Goal:** PRR/ROR calculation validated against known signals. Engine ready for targeted analysis.

**SAS programs:**

| Program | What It Does |
|---|---|
| `macros/calc_prr.sas` | Macro: takes drug–reaction 2×2 counts, returns PRR + 95% CI + chi-square |
| `macros/calc_ror.sas` | Macro: same for ROR + 95% CI |
| `02_signal_engine.sas` | Builds 2×2 contingency tables for all drug (prod_ai) × reaction (pt) pairs in full DB. Calls PRR/ROR macros. Applies Evans criteria (PRR≥2, χ²≥4, N≥3). Outputs full signal table |
| `02_positive_controls.sas` | Defines 5–8 known drug–reaction pairs. LEFT JOINs against signal table. Reports detected/missed with actual PRR/ROR values. **All must be detected or engine has a bug** |

**Positive control list:**

| Drug (prod_ai) | Expected Reaction (pt) | Source |
|---|---|---|
| ATORVASTATIN / SIMVASTATIN | Rhabdomyolysis | Well-established |
| CIPROFLOXACIN / LEVOFLOXACIN | Tendon rupture | FDA Black Box 2008 |
| SEMAGLUTIDE | Pancreatitis | FDA label, also Phase 3 bridge |
| ISOTRETINOIN | Depression | Well-established |
| METHOTREXATE | Hepatotoxicity | Well-established |
| WARFARIN | Haemorrhage | Well-established |

**Gate 2:** All positive controls detected. PRR/ROR values in plausible range (compare to published literature values where available).

---

### ⭐ Phase 3: GLP-1 Deep Dive (Day 10–16)

**Goal:** Complete safety signal analysis of GLP-1 receptor agonists. This phase produces the portfolio story AND the bulk of SAS analytical code.

**Target drugs (by prod_ai):**

| Drug | Brand Names | Status |
|---|---|---|
| SEMAGLUTIDE | Ozempic, Wegovy, Rybelsus | Newer, highest volume |
| TIRZEPATIDE | Mounjaro, Zepbound | Newest, dual GIP/GLP-1 |
| LIRAGLUTIDE | Victoza, Saxenda | Older comparator |
| DULAGLUTIDE | Trulicity | Older comparator |

**SAS programs (7 programs — the main show):**

| Program | What It Does | What It Proves |
|---|---|---|
| `03_glp1_extract.sas` | Filters DRUG by GLP-1 prod_ai values + role_cod='PS'. JOINs DEMO, REAC, INDI, OUTC. Creates analytical dataset | Multi-table JOIN, subsetting, analytical dataset design |
| `03_glp1_signal_profile.sas` | Runs PRR/ROR on GLP-1 subset. Top signals per drug. Full signal table output | Core signal detection applied to focused drug class |
| `03_glp1_drug_compare.sas` | Head-to-head: semaglutide vs liraglutide — same reactions, PRR side-by-side. PROC TRANSPOSE + merge | Data reshaping, comparative analysis |
| `03_glp1_subgroup.sas` | Stratified PRR by age_grp (≤45 / 46–64 / ≥65), sex (M/F), reporter_country (US/non-US). BY-group processing | Stratified epidemiological analysis — real PV workflow |
| `03_glp1_time_trend.sas` | PRR per quarter for top 10 GLP-1 signals. Identifies increasing / stable / decreasing trends | Longitudinal surveillance capability |
| `03_glp1_validation.sas` | Builds known_signals dataset from FDA label info. LEFT JOIN vs detected signals. Flags: independently replicated / missed / novel (not on label) | Method validation + finding identification |
| `03_glp1_report.sas` | PROC REPORT + ODS HTML/PDF. Formatted tables with conditional highlighting (PRR>5 red, 2–5 yellow). Footnotes with methodology summary | ODS reporting — what PV teams actually deliver |

**Day-by-day:**

| Day | Work | Key Question Being Answered |
|---|---|---|
| 10 | Write + run `03_glp1_extract.sas` and `03_glp1_signal_profile.sas` | "What is the overall safety signal landscape for GLP-1s?" |
| 11 | Write + run `03_glp1_drug_compare.sas` | "Does semaglutide have different risks than liraglutide?" |
| 12 | Write + run `03_glp1_validation.sas` | "Can my method independently replicate what FDA already found?" |
| 13 | Write + run `03_glp1_subgroup.sas` | "Are signals driven by a specific age/sex group?" |
| 14 | Write + run `03_glp1_time_trend.sas` | "Are any signals getting stronger or emerging over time?" |
| 15 | Write + run `03_glp1_report.sas` + synthesize findings | "What's the story? What are the 3–5 key findings?" |
| 16 | Finalize signal table + export for Tableau + draft findings summary | All data ready for Phase 4 |

**FDA signals to validate against (known GLP-1 label items):**

- Pancreatitis (acute) — all GLP-1s
- Thyroid C-cell tumors (medullary thyroid carcinoma) — boxed warning
- Gastroparesis / ileus — semaglutide, emerging concern
- Acute kidney injury — reported post-marketing
- Gallbladder-related events (cholelithiasis, cholecystitis) — label warning
- Suicidal ideation — EMA investigating, FDA reviewing

**Gate 3:** ≥4 of 6 FDA-known signals independently detected. At least 1 finding with subgroup or time-trend nuance worth reporting. Findings documented with specific numbers (PRR value, CI, N, affected subgroup).

---

### Phase 4: Ship It (Day 17–21)

**Goal:** Dashboard live, case study written, STAR stories harvested, resume updated.

| Day | Work | Output |
|---|---|---|
| 17–18 | Tableau dashboard: GLP-1 signal explorer (filterable by drug, reaction, quarter, subgroup) | Tableau Public link |
| 19 | Case study: problem → data → method → findings → implications → limitations | `Case_Study_EN.md` |
| 20 | STAR stories: extract 3–5 from project decisions and findings | Added to `interview_prep/` |
| 21 | Resume bullets + GitHub README (if public) + final review | Ship |

**Case study structure:**

1. **Why this matters** — GLP-1 prescribing surge + evolving safety profile
2. **What I did** — 1.6M cases, SAS pipeline, PRR/ROR engine, focused analysis
3. **What I found** — 3–5 specific findings with numbers
4. **What it means** — clinical implications, limitations, what I'd do next
5. **Technical appendix** — key SAS code snippets, methodology

**Gate 4:** Dashboard loads, filters work, numbers match signal table. Case study passes the "non-technical person understands it" test. Resume bullets have specific metrics. 3+ STAR stories pass "so what?" test.

## 9. SAS Code Portfolio Summary

When complete, the repo contains **~15 SAS programs** spanning three skill levels:

| Category | Programs | What They Demonstrate |
|---|---|---|
| **Infrastructure** | `00_config`, `01_import_clean`, 3 macros | Data engineering: import, cleaning, dedup, parameterized macros |
| **Engine** | `02_signal_engine`, `02_positive_controls` | Algorithm implementation: PRR/ROR, 2×2 tables, validation |
| **Analysis** | `03_glp1_*` (7 programs) | **Analytical thinking**: subsetting, stratification, comparison, trends, ODS reporting |

This progression — from plumbing to engine to analysis — mirrors what a real PV/drug safety team builds. The Phase 3 programs are what a hiring manager would actually read.

## 10. Risk Register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| SAS ODA storage limit (5GB) | Low | Medium | FAERS raw = ~1.4GB, leaves room. Clean intermediate files between runs |
| GLP-1 cases too few for stable PRR | Low | High | GLP-1s are high-volume; if N<3 for a reaction, report but flag |
| No MedDRA license for hierarchy | Known | Low | Stay at PT level; acknowledge in limitations |
| Scope creep into Bayesian/NLP | Medium | Medium | CHARTER "Out of Scope" is the wall |
| Perfectionism stalls Phase 4 | High | High | Case study time-boxed to 2 days, no exceptions |
| SAS ODA downtime | Low | Medium | Save code locally in repo; re-upload when back |

## 11. Success Criteria

This project is done when:

1. **SAS pipeline runs end-to-end** (import → clean → signal → GLP-1 analysis → report)
2. **Positive controls validated** — ≥5 known signals detected correctly
3. **GLP-1 analysis has ≥3 specific findings** with numbers (PRR, CI, N, subgroup)
4. **At least 1 FDA-known signal independently replicated**
5. **Tableau dashboard** live on Tableau Public, focused on GLP-1
6. **Case study** written, readable by non-technical audience
7. **3+ STAR stories** documented
8. **Resume** has a bullet with specific metric from this project

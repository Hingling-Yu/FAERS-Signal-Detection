-- ===========================================================================
-- 03_queries.sql - Warehouse views and analytical queries
--
-- Scope boundary (deliberate, and worth stating up front)
-- ---------------------------------------------------------------------------
--   This file does NOT compute PRR, ROR, chi-square or any other
--   disproportionality statistic. That work belongs to the SAS engine
--   (sas/02_signal_engine.sas), which owns the 2x2 contingency tables, the
--   confidence intervals and the Evans criteria.
--
--   What SQL owns here is everything upstream and downstream of that
--   calculation: the warehouse, the ad-hoc multi-table exploration a PV
--   analyst does before deciding what to test, and the wide views Tableau
--   connects to. Counts and simple proportions are descriptive - they
--   describe what was reported, they do not test whether it was reported
--   disproportionately. Keeping that line visible is part of the method.
--
-- Prerequisites
--   sql/01_ddl.sql and sql/02_load.sql have both been run.
--
-- Run
--   /usr/local/mysql/bin/mysql -u faers_app -p faers < sql/03_queries.sql
--
--   In practice this file is read query by query rather than executed whole.
--   Sections 2 and 3 do create persistent objects, so run those once before
--   working interactively in the rest.
--
-- Contents
--   1  Warehouse profile and data-integrity checks
--   2  Helper views       - normalised demographics, pivoted outcomes
--   3  GLP-1 cohort       - materialised cohort + v_glp1_cases for Tableau
--   4  Data exploration   - source, country, age, reporter distributions
--   5  Multi-table joins  - drug x outcome and drug x reaction cross-tabs
--   6  Window functions   - per-drug ranking, Pareto, quarter-over-quarter
--   7  Tableau handoff
--
-- Author:   Hingling Yu
-- Created:  2026-09-03
-- ===========================================================================

USE faers;


-- ###########################################################################
-- 1. WAREHOUSE PROFILE AND INTEGRITY
-- ###########################################################################

-- ---------------------------------------------------------------------------
-- Q1.1  What is actually in the warehouse, and how do rows relate to cases?
--
-- Business question: before quoting any number to a stakeholder, how many
-- distinct cases does each table cover, and how many rows does an average
-- case generate? The rows-per-case ratio is the sanity check that catches a
-- botched join later - a case carries roughly 4 drugs and 3 reactions, so a
-- query returning 40 drug rows for one case means the join fanned out.
-- ---------------------------------------------------------------------------
SELECT 'demo' AS table_name, COUNT(*) AS rows_total,
       COUNT(DISTINCT primaryid) AS distinct_reports,
       COUNT(DISTINCT caseid)    AS distinct_cases,
       ROUND(COUNT(*) / COUNT(DISTINCT caseid), 2) AS rows_per_case FROM demo
UNION ALL
SELECT 'drug', COUNT(*), COUNT(DISTINCT primaryid), COUNT(DISTINCT caseid),
       ROUND(COUNT(*) / COUNT(DISTINCT caseid), 2) FROM drug
UNION ALL
SELECT 'reac', COUNT(*), COUNT(DISTINCT primaryid), COUNT(DISTINCT caseid),
       ROUND(COUNT(*) / COUNT(DISTINCT caseid), 2) FROM reac
UNION ALL
SELECT 'indi', COUNT(*), COUNT(DISTINCT primaryid), COUNT(DISTINCT caseid),
       ROUND(COUNT(*) / COUNT(DISTINCT caseid), 2) FROM indi
UNION ALL
SELECT 'outc', COUNT(*), COUNT(DISTINCT primaryid), COUNT(DISTINCT caseid),
       ROUND(COUNT(*) / COUNT(DISTINCT caseid), 2) FROM outc
UNION ALL
SELECT 'ther', COUNT(*), COUNT(DISTINCT primaryid), COUNT(DISTINCT caseid),
       ROUND(COUNT(*) / COUNT(DISTINCT caseid), 2) FROM ther
UNION ALL
SELECT 'rpsr', COUNT(*), COUNT(DISTINCT primaryid), COUNT(DISTINCT caseid),
       ROUND(COUNT(*) / COUNT(DISTINCT caseid), 2) FROM rpsr;


-- ---------------------------------------------------------------------------
-- Q1.2  Does any child table carry the same report twice?
--
-- Business question: the SAS pipeline deduplicated DEMO to one row per case,
-- then filtered the child tables to surviving primaryids - it never
-- deduplicated the child tables themselves. If the same primaryid was
-- published in two quarterly extracts, its drug and reaction rows would now
-- be doubled, and every case count built on those tables would be inflated.
--
-- Expect 0 rows. A non-zero result is a real finding, not a nuisance: it
-- means COUNT(DISTINCT primaryid) is mandatory everywhere and the SAS
-- pipeline needs a dedup step on the child tables.
-- ---------------------------------------------------------------------------
SELECT 'drug' AS table_name, COUNT(*) AS reports_in_multiple_quarters FROM (
    SELECT primaryid FROM drug GROUP BY primaryid HAVING COUNT(DISTINCT quarter) > 1
) t
UNION ALL
SELECT 'reac', COUNT(*) FROM (
    SELECT primaryid FROM reac GROUP BY primaryid HAVING COUNT(DISTINCT quarter) > 1
) t
UNION ALL
SELECT 'outc', COUNT(*) FROM (
    SELECT primaryid FROM outc GROUP BY primaryid HAVING COUNT(DISTINCT quarter) > 1
) t;


-- ---------------------------------------------------------------------------
-- Q1.3  How complete is each field that the analysis depends on?
--
-- Business question: which demographic variables can actually carry a
-- stratified analysis? A subgroup breakdown on a field that is 60 pct missing
-- is not a finding, it is an artefact of who bothers to fill in the form.
-- This table is what justifies the subgroup choices in CHARTER Phase 3.
-- ---------------------------------------------------------------------------
SELECT 'sex'              AS field, COUNT(*) AS n_cases,
       SUM(sex              IS NULL) AS n_missing,
       ROUND(100.0 * SUM(sex IS NULL) / COUNT(*), 1) AS pct_missing FROM demo
UNION ALL SELECT 'age',              COUNT(*), SUM(age IS NULL),
       ROUND(100.0 * SUM(age IS NULL) / COUNT(*), 1) FROM demo
UNION ALL SELECT 'age_cod',          COUNT(*), SUM(age_cod IS NULL),
       ROUND(100.0 * SUM(age_cod IS NULL) / COUNT(*), 1) FROM demo
UNION ALL SELECT 'age_grp',          COUNT(*), SUM(age_grp IS NULL),
       ROUND(100.0 * SUM(age_grp IS NULL) / COUNT(*), 1) FROM demo
UNION ALL SELECT 'wt',               COUNT(*), SUM(wt IS NULL),
       ROUND(100.0 * SUM(wt IS NULL) / COUNT(*), 1) FROM demo
UNION ALL SELECT 'reporter_country', COUNT(*), SUM(reporter_country IS NULL),
       ROUND(100.0 * SUM(reporter_country IS NULL) / COUNT(*), 1) FROM demo
UNION ALL SELECT 'occp_cod',         COUNT(*), SUM(occp_cod IS NULL),
       ROUND(100.0 * SUM(occp_cod IS NULL) / COUNT(*), 1) FROM demo
UNION ALL SELECT 'event_dt',         COUNT(*), SUM(event_dt IS NULL),
       ROUND(100.0 * SUM(event_dt IS NULL) / COUNT(*), 1) FROM demo
ORDER BY pct_missing DESC;


-- ---------------------------------------------------------------------------
-- Q1.4  Which age units does FAERS actually use, and how often is the unit
--       missing while the value is present?
--
-- Business question: age in FAERS is a number plus a unit code, and treating
-- the number as years is the single most common way to corrupt a
-- pharmacovigilance age analysis - an infant reported as "6 MON" becomes a
-- six-year-old. This query sizes each unit before section 2 normalises them.
-- ---------------------------------------------------------------------------
SELECT COALESCE(age_cod, '(missing)') AS age_cod,
       COUNT(*)                       AS n_cases,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_all,
       SUM(age IS NOT NULL)           AS n_with_age_value,
       ROUND(MIN(age), 1)             AS min_value,
       ROUND(MAX(age), 1)             AS max_value
FROM   demo
GROUP  BY age_cod
ORDER  BY n_cases DESC;


-- ###########################################################################
-- 2. HELPER VIEWS
--
-- Two views that every downstream query reuses. Defining the age
-- normalisation and the outcome pivot once means an analyst cannot
-- accidentally use two different definitions of "elderly" or "serious" in the
-- same report - which is exactly how two slides end up disagreeing.
-- ###########################################################################

-- ---------------------------------------------------------------------------
-- v_demo_enriched - demographics with age normalised to years and the
--                   analysis bands the SAS side uses
--
-- Age conversion follows the FAERS age_cod code list:
--   DEC decade, YR year, MON month, WK week, DY day, HR hour
--
-- Two documented judgement calls:
--
--   1. A missing age_cod with a present age is read as years. FDA's spec
--      requires the unit whenever the value is given, so a blank unit is a
--      data-entry gap rather than a different unit; years is both the modal
--      value and the conservative reading. Q1.4 quantifies how many cases
--      this affects - if it is more than a percent or two, report the
--      sensitivity.
--
--   2. Anything resolving above 120 years is set to NULL. These are keying
--      errors (a birth year typed into the age field), not supercentenarians,
--      and leaving them in would drag every mean age upward.
--
-- Bands match the agegrpf format in sas/00_config.sas (<=45, 46-64, >=65) so
-- a MySQL count and a SAS count of the same subgroup can be reconciled
-- directly. is_pediatric is carried separately rather than as a fourth band,
-- because splitting the bands would break that reconciliation.
--
-- Performance note: the derived table below means MySQL materialises this
-- view rather than merging it into the calling query, so every query that
-- touches it makes one pass over demo's 1.5M rows - a second or two locally,
-- fine for ad-hoc work. It is not fine behind a live Tableau connection that
-- re-runs on every filter change, which is what the extract table in Q7.2 is
-- there to solve.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_demo_enriched AS
SELECT b.primaryid,
       b.caseid,
       b.quarter,
       b.sex,
       b.age,
       b.age_cod,
       b.age_grp,
       b.age_years,
       CASE WHEN b.age_years IS NULL THEN 'Unknown'
            WHEN b.age_years <= 45   THEN '<=45'
            WHEN b.age_years <= 64   THEN '46-64'
            ELSE                          '>=65'
       END                                                  AS age_band,
       CASE WHEN b.age_years IS NULL THEN NULL
            WHEN b.age_years < 18    THEN 1 ELSE 0
       END                                                  AS is_pediatric,
       b.reporter_country,
       b.occr_country,
       CASE WHEN b.reporter_country = 'US'  THEN 'US'
            WHEN b.reporter_country IS NULL THEN 'Unknown'
            ELSE 'Non-US'
       END                                                  AS report_region,
       b.occp_cod,
       CASE b.occp_cod
            WHEN 'MD' THEN 'Physician'
            WHEN 'PH' THEN 'Pharmacist'
            WHEN 'OT' THEN 'Other health professional'
            WHEN 'RN' THEN 'Nurse'
            WHEN 'CN' THEN 'Consumer'
            WHEN 'LW' THEN 'Lawyer'
            ELSE 'Not reported'
       END                                                  AS reporter_type,
       -- Consumer and lawyer reports carry different evidential weight from
       -- clinician reports; PV teams routinely stratify on this.
       CASE WHEN b.occp_cod IN ('MD', 'PH', 'OT', 'RN') THEN 1 ELSE 0 END
                                                            AS hcp_report,
       b.rept_cod,
       b.i_f_code,
       b.e_sub,
       b.mfr_sndr,
       b.event_dt,
       b.event_dt_prec,
       b.fda_dt,
       b.init_fda_dt,
       b.wt,
       b.wt_cod
FROM (
    -- Outer layer applies the plausibility bound. Two derived tables rather
    -- than one, so the conversion CASE is written exactly once: SQL cannot
    -- reference a SELECT alias from a sibling expression, and a copy-pasted
    -- eight-branch CASE is the kind of thing that drifts out of sync on the
    -- next edit.
    SELECT a.*,
           CASE WHEN a.age_years_raw BETWEEN 0 AND 120
                THEN a.age_years_raw ELSE NULL END           AS age_years
    FROM (
        SELECT d.*,
               CASE
                    WHEN d.age IS NULL            THEN NULL
                    WHEN UPPER(d.age_cod) = 'DEC' THEN d.age * 10
                    WHEN UPPER(d.age_cod) = 'YR'  THEN d.age
                    WHEN UPPER(d.age_cod) = 'MON' THEN d.age / 12
                    WHEN UPPER(d.age_cod) = 'WK'  THEN d.age / 52.1775
                    WHEN UPPER(d.age_cod) = 'DY'  THEN d.age / 365.25
                    WHEN UPPER(d.age_cod) = 'HR'  THEN d.age / 8766
                    WHEN d.age_cod IS NULL        THEN d.age   -- judgement call 1
                    ELSE NULL
               END                                           AS age_years_raw
        FROM demo d
    ) a
) b;


-- ---------------------------------------------------------------------------
-- v_case_outcome - one row per case with the outcome codes pivoted to flags
--
-- FAERS stores outcomes as up to seven rows per case. Every downstream
-- question ("how many of these cases were fatal", "what share were
-- hospitalised") needs them as columns, and doing that pivot inline in each
-- query is where inconsistent definitions creep in.
--
-- Seriousness: FAERS only writes an outcome row when a regulatory
-- seriousness criterion was met, so the presence of any row is the working
-- definition of a serious case. Absence means "not serious OR not reported" -
-- the two are indistinguishable in this dataset, and that limitation belongs
-- in the case study.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_case_outcome AS
SELECT primaryid,
       MAX(CASE WHEN outc_cod = 'DE' THEN 1 ELSE 0 END) AS out_death,
       MAX(CASE WHEN outc_cod = 'LT' THEN 1 ELSE 0 END) AS out_life_threat,
       MAX(CASE WHEN outc_cod = 'HO' THEN 1 ELSE 0 END) AS out_hospital,
       MAX(CASE WHEN outc_cod = 'DS' THEN 1 ELSE 0 END) AS out_disability,
       MAX(CASE WHEN outc_cod = 'CA' THEN 1 ELSE 0 END) AS out_congenital,
       MAX(CASE WHEN outc_cod = 'RI' THEN 1 ELSE 0 END) AS out_intervention,
       MAX(CASE WHEN outc_cod = 'OT' THEN 1 ELSE 0 END) AS out_other_serious,
       COUNT(DISTINCT outc_cod)                         AS n_outcome_codes
FROM   outc
GROUP  BY primaryid;


-- ###########################################################################
-- 3. GLP-1 COHORT
-- ###########################################################################

-- ---------------------------------------------------------------------------
-- glp1_ps_case - the cohort, materialised
--
-- Why a table and not a view. Identifying the cohort means matching
-- ref_glp1_drug.ai_pattern against drug.prod_ai with LIKE '%...%'. A leading
-- wildcard cannot use the idx_drug_ai_role index, so every evaluation is a
-- full scan of 6.3M drug rows. As a view, Tableau would pay that cost on
-- every filter change. Materialised once into roughly a hundred thousand
-- indexed rows, everything downstream is instant.
--
-- REFRESH: rerun this whole block after any reload of the drug table, or the
-- cohort silently reflects the previous load.
--
-- Cohort definition (matches CHARTER Phase 3):
--   role_cod = 'PS'  - primary suspect only. Concomitant drugs are present on
--                      the case for a different reason and including them
--                      would attribute every reaction on a polypharmacy case
--                      to the GLP-1.
--   prod_ai LIKE '%<molecule>%' - catches multi-ingredient products, which
--                      FAERS stores backslash-separated. See the matching
--                      note in 01_ddl.sql section 3: this is intentionally
--                      broader than the exact IN list in sas/00_config.sas,
--                      and Q3.2 measures the difference.
--
-- Grain: one row per (report, molecule). A case naming two GLP-1s as primary
-- suspect produces two rows, so always count with COUNT(DISTINCT primaryid).
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS glp1_ps_case;

CREATE TABLE glp1_ps_case (
    primaryid        BIGINT       NOT NULL,
    caseid           BIGINT       NOT NULL,
    drug_label       VARCHAR(20)  NOT NULL COMMENT 'Canonical molecule from ref_glp1_drug',
    generation       VARCHAR(20)  NOT NULL COMMENT 'newer or comparator',
    quarter          CHAR(6)      NOT NULL COMMENT 'From demo - the quarter of the surviving report version',
    n_drug_records   INT          NOT NULL COMMENT 'PS drug rows matching this molecule on this report',
    prod_ai_example  VARCHAR(500) NULL     COMMENT 'One raw prod_ai string, to show what actually matched',
    n_drugs_on_case  INT          NULL     COMMENT 'All drug rows on the report, any role - polypharmacy proxy',
    n_reactions      INT          NULL     COMMENT 'Distinct PT count on the report',
    glp1_indication  VARCHAR(100) NULL     COMMENT 'Indication recorded against the GLP-1 drug_seq',
    PRIMARY KEY (primaryid, drug_label),
    KEY idx_glp1_label     (drug_label),
    KEY idx_glp1_caseid    (caseid),
    KEY idx_glp1_qtr_label (quarter, drug_label),
    KEY idx_glp1_gen       (generation)
) ENGINE=InnoDB
  COMMENT='GLP-1 primary-suspect cohort; rebuild after every reload of drug';

INSERT INTO glp1_ps_case
    (primaryid, caseid, drug_label, generation, quarter, n_drug_records, prod_ai_example)
SELECT dr.primaryid,
       dm.caseid,
       g.drug_label,
       g.generation,
       dm.quarter,
       COUNT(*),
       MIN(dr.prod_ai)
FROM   drug dr
JOIN   ref_glp1_drug g ON dr.prod_ai LIKE g.ai_pattern
JOIN   demo dm         ON dm.primaryid = dr.primaryid
WHERE  dr.role_cod = 'PS'
GROUP  BY dr.primaryid, dm.caseid, g.drug_label, g.generation, dm.quarter;

-- Context columns, added by UPDATE rather than as correlated subqueries in a
-- view: computing them once over the cohort beats recomputing them per row on
-- every dashboard interaction.
UPDATE glp1_ps_case c
JOIN  (SELECT primaryid, COUNT(*) AS n FROM drug GROUP BY primaryid) x
      ON x.primaryid = c.primaryid
SET   c.n_drugs_on_case = x.n;

UPDATE glp1_ps_case c
JOIN  (SELECT primaryid, COUNT(DISTINCT pt) AS n FROM reac GROUP BY primaryid) x
      ON x.primaryid = c.primaryid
SET   c.n_reactions = x.n;

-- Indication is joined on (primaryid, drug_seq) - the link that ties an INDI
-- row to the specific drug it was recorded for. MIN() picks one when several
-- are listed; for GLP-1s this is nearly always type 2 diabetes versus weight
-- management, and Q3.3 shows the full distribution rather than relying on the
-- single value stored here.
UPDATE glp1_ps_case c
JOIN  (SELECT dr.primaryid, g.drug_label, MIN(i.indi_pt) AS indi_pt
       FROM   drug dr
       JOIN   ref_glp1_drug g ON dr.prod_ai LIKE g.ai_pattern
       JOIN   indi i          ON i.primaryid = dr.primaryid
                             AND i.indi_drug_seq = dr.drug_seq
       WHERE  dr.role_cod = 'PS'
       GROUP  BY dr.primaryid, g.drug_label) x
      ON x.primaryid = c.primaryid AND x.drug_label = c.drug_label
SET   c.glp1_indication = x.indi_pt;

ANALYZE TABLE glp1_ps_case;


-- ---------------------------------------------------------------------------
-- Q3.1  How large is the cohort, per molecule?
--
-- Business question: is there enough volume behind each GLP-1 to support a
-- head-to-head comparison, or will the older comparators be too thin? This is
-- the number that decides whether CHARTER's semaglutide-vs-liraglutide
-- analysis is viable.
-- ---------------------------------------------------------------------------
SELECT c.drug_label,
       c.generation,
       r.brand_names,
       COUNT(DISTINCT c.primaryid)                          AS n_reports,
       COUNT(DISTINCT c.caseid)                             AS n_cases,
       ROUND(AVG(c.n_reactions), 1)                         AS avg_reactions,
       ROUND(AVG(c.n_drugs_on_case), 1)                     AS avg_drugs_on_case,
       MIN(c.quarter)                                       AS first_quarter,
       MAX(c.quarter)                                       AS last_quarter
FROM   glp1_ps_case c
JOIN   ref_glp1_drug r ON r.drug_label = c.drug_label
GROUP  BY c.drug_label, c.generation, r.brand_names
ORDER  BY n_reports DESC;


-- ---------------------------------------------------------------------------
-- Q3.2  How much does the LIKE cohort add over an exact-match cohort?
--
-- Business question: the SQL cohort matches prod_ai with a wildcard while the
-- SAS config matches it exactly, so the two will not agree. Before anyone
-- notices the discrepancy in a review, quantify it: which prod_ai strings are
-- picked up only by the wildcard, and how many reports do they carry?
--
-- These are combination and compounded products. The right answer is a
-- decision, not a default - if they should be excluded, tighten ai_pattern in
-- ref_glp1_drug; if they belong, widen the SAS list to match.
-- ---------------------------------------------------------------------------
SELECT g.drug_label,
       dr.prod_ai                                           AS raw_prod_ai,
       COUNT(DISTINCT dr.primaryid)                         AS n_reports
FROM   drug dr
JOIN   ref_glp1_drug g ON dr.prod_ai LIKE g.ai_pattern
WHERE  dr.role_cod = 'PS'
  AND  dr.prod_ai <> g.drug_label          -- anything that is not a clean exact match
GROUP  BY g.drug_label, dr.prod_ai
ORDER  BY n_reports DESC
LIMIT  40;


-- ---------------------------------------------------------------------------
-- Q3.3  What were these drugs being taken for?
--
-- Business question: a GLP-1 prescribed for weight management sits in a
-- different population from one prescribed for type 2 diabetes - younger,
-- more often female, fewer comorbidities. Any signal that differs between the
-- two indications is a confounding story before it is a safety story, and
-- this is the query that surfaces it.
-- ---------------------------------------------------------------------------
-- The percentage denominator is computed in a CTE rather than with a window
-- function over the grouped rows: MySQL evaluates window functions after
-- HAVING, so a windowed total would silently exclude the small indications
-- the HAVING drops, and the column would no longer be a share of the cohort.
WITH indi_counts AS (
    SELECT c.drug_label,
           COALESCE(c.glp1_indication, '(not reported)') AS indication,
           COUNT(DISTINCT c.primaryid)                   AS n_reports
    FROM   glp1_ps_case c
    GROUP  BY c.drug_label, COALESCE(c.glp1_indication, '(not reported)')
),
drug_total AS (
    SELECT drug_label, SUM(n_reports) AS n_all
    FROM   indi_counts GROUP BY drug_label
)
SELECT i.drug_label,
       i.indication,
       i.n_reports,
       ROUND(100.0 * i.n_reports / t.n_all, 1) AS pct_within_drug
FROM   indi_counts i
JOIN   drug_total  t ON t.drug_label = i.drug_label
WHERE  i.n_reports >= 50
ORDER  BY i.drug_label, i.n_reports DESC;


-- ---------------------------------------------------------------------------
-- v_glp1_cases - THE TABLEAU VIEW
--
-- One wide row per (report x molecule x reported reaction), carrying
-- demographics, the reaction term, the pivoted outcome flags and the case
-- context. This is the single object the dashboard connects to, so that
-- Tableau does no joining of its own and every worksheet shares one
-- definition of age band, seriousness and reporter type.
--
-- Grain and counting rule
--   A case with 5 reactions and 1 GLP-1 produces 5 rows. Therefore:
--       case counts    -> COUNT(DISTINCT primaryid)
--       reaction counts-> COUNT(*) or COUNT(DISTINCT reaction_pt)
--       any rate       -> distinct cases in the numerator AND denominator
--   Getting this wrong is the classic FAERS dashboard error: it inflates
--   fatality rates for drugs whose cases happen to list more reactions.
--
--   In Tableau, set the default aggregation for primaryid to
--   COUNT DISTINCT once at the data-source level rather than per worksheet.
--
-- Reactions are LEFT JOINed: a handful of reports carry no reaction row, and
-- dropping them would quietly shrink the case denominator.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_glp1_cases AS
SELECT
    -- keys and cohort
    c.primaryid,
    c.caseid,
    c.drug_label,
    c.generation,
    r.brand_names,
    c.quarter,
    c.prod_ai_example,
    c.glp1_indication,

    -- demographics, normalised in v_demo_enriched
    d.sex,
    d.age_years,
    d.age_band,
    d.is_pediatric,
    d.reporter_country,
    d.report_region,
    d.reporter_type,
    d.hcp_report,
    d.rept_cod,
    d.i_f_code,

    -- dates
    d.event_dt,
    d.event_dt_prec,
    d.fda_dt,

    -- the reaction (view grain)
    rc.pt                                                    AS reaction_pt,

    -- outcomes, pivoted in v_case_outcome. COALESCE to 0 because a report
    -- with no outc row is not serious-unknown at the flag level - it simply
    -- has no outcome code, and NULL would break SUM() in Tableau.
    COALESCE(o.out_death, 0)                                 AS out_death,
    COALESCE(o.out_life_threat, 0)                           AS out_life_threat,
    COALESCE(o.out_hospital, 0)                              AS out_hospital,
    COALESCE(o.out_disability, 0)                            AS out_disability,
    COALESCE(o.out_congenital, 0)                            AS out_congenital,
    COALESCE(o.out_intervention, 0)                          AS out_intervention,
    COALESCE(o.out_other_serious, 0)                         AS out_other_serious,
    CASE WHEN o.primaryid IS NULL THEN 0 ELSE 1 END          AS serious_case,

    -- case context
    c.n_reactions,
    c.n_drugs_on_case,
    CASE WHEN c.n_drugs_on_case >= 5 THEN 1 ELSE 0 END       AS polypharmacy_case
FROM       glp1_ps_case  c
JOIN       ref_glp1_drug r  ON r.drug_label = c.drug_label
JOIN       v_demo_enriched d ON d.primaryid = c.primaryid
LEFT JOIN  reac          rc ON rc.primaryid = c.primaryid
LEFT JOIN  v_case_outcome o ON o.primaryid = c.primaryid;


-- Shape check on the view before pointing Tableau at it.
SELECT COUNT(*)                        AS view_rows,
       COUNT(DISTINCT primaryid)       AS distinct_reports,
       COUNT(DISTINCT reaction_pt)     AS distinct_reaction_terms,
       ROUND(COUNT(*) / COUNT(DISTINCT primaryid), 2) AS rows_per_report
FROM   v_glp1_cases;


-- ###########################################################################
-- 4. DATA EXPLORATION
-- ###########################################################################

-- ---------------------------------------------------------------------------
-- Q4.1  How did reporting volume and seriousness move across the four
--       quarters?
--
-- Business question: is the database itself stable over the study window? A
-- quarter with an unusual volume or an unusual serious share is a reporting
-- artefact that would masquerade as a time trend in the Phase 3 analysis.
-- This is the baseline any trend claim has to be read against.
-- ---------------------------------------------------------------------------
SELECT d.quarter,
       COUNT(*)                                             AS n_cases,
       SUM(o.primaryid IS NOT NULL)                         AS n_serious,
       ROUND(100.0 * SUM(o.primaryid IS NOT NULL) / COUNT(*), 1) AS pct_serious,
       SUM(COALESCE(o.out_death, 0))                        AS n_fatal,
       ROUND(100.0 * SUM(COALESCE(o.out_death, 0)) / COUNT(*), 2) AS pct_fatal,
       ROUND(100.0 * SUM(d.reporter_country = 'US') / COUNT(*), 1) AS pct_us,
       ROUND(100.0 * SUM(d.hcp_report) / COUNT(*), 1)       AS pct_hcp_reported
FROM   v_demo_enriched d
LEFT   JOIN v_case_outcome o ON o.primaryid = d.primaryid
GROUP  BY d.quarter
ORDER  BY d.quarter;


-- ---------------------------------------------------------------------------
-- Q4.2  Where do the reports come from?
--
-- Business question: FAERS is dominated by US reports, and country mix drives
-- everything downstream - reporting culture, litigation-driven spikes,
-- which products are even on the market. Before comparing two drugs, check
-- they are not being reported from different countries.
-- ---------------------------------------------------------------------------
SELECT COALESCE(reporter_country, '(not reported)')          AS reporter_country,
       COUNT(*)                                              AS n_cases,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)    AS pct_of_all,
       ROUND(100.0 * SUM(COUNT(*)) OVER (ORDER BY COUNT(*) DESC)
             / SUM(COUNT(*)) OVER (), 2)                     AS cumulative_pct
FROM   demo
GROUP  BY reporter_country
ORDER  BY n_cases DESC
LIMIT  25;


-- ---------------------------------------------------------------------------
-- Q4.3  Who sent the report in, where a source was recorded?
--
-- Business question: report source separates spontaneous consumer reports
-- from study and literature reports, which have very different evidential
-- weight. The catch is that rpsr is populated on only about 3 pct of cases -
-- so this query reports against the populated subset and states the coverage
-- explicitly, rather than quietly dividing by 1.5M and reporting near-zero
-- percentages that would be read as "nobody reports from studies".
-- ---------------------------------------------------------------------------
SELECT COALESCE(r.rpsr_cod, '(none)')                        AS rpsr_cod,
       CASE r.rpsr_cod
            WHEN 'FGN' THEN 'Foreign'
            WHEN 'SDY' THEN 'Study'
            WHEN 'LIT' THEN 'Literature'
            WHEN 'CSM' THEN 'Consumer'
            WHEN 'HP'  THEN 'Health professional'
            WHEN 'UF'  THEN 'User facility'
            WHEN 'DT'  THEN 'Distributor'
            WHEN 'OTH' THEN 'Other'
            ELSE 'Unmapped'
       END                                                   AS source_label,
       COUNT(DISTINCT r.primaryid)                           AS n_cases,
       ROUND(100.0 * COUNT(DISTINCT r.primaryid)
             / (SELECT COUNT(*) FROM rpsr), 1)               AS pct_of_sourced,
       ROUND(100.0 * COUNT(DISTINCT r.primaryid)
             / (SELECT COUNT(*) FROM demo), 3)               AS pct_of_all_cases
FROM   rpsr r
GROUP  BY r.rpsr_cod
ORDER  BY n_cases DESC;


-- ---------------------------------------------------------------------------
-- Q4.4  What does the age and sex distribution look like, and does
--       seriousness track with age?
--
-- Business question: FAERS has no denominator - we never know how many people
-- took the drug - so the age profile of the reports is the closest available
-- proxy for who is being exposed. If GLP-1 signals later concentrate in the
-- over-65 group, this is the table that says whether that is a real
-- concentration or just where the reports are.
-- ---------------------------------------------------------------------------
SELECT d.age_band,
       COALESCE(d.sex, '(not reported)')                     AS sex,
       COUNT(*)                                              AS n_cases,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)    AS pct_of_all,
       ROUND(AVG(d.age_years), 1)                            AS mean_age_years,
       SUM(o.primaryid IS NOT NULL)                          AS n_serious,
       ROUND(100.0 * SUM(o.primaryid IS NOT NULL) / COUNT(*), 1) AS pct_serious,
       ROUND(100.0 * SUM(COALESCE(o.out_death, 0)) / COUNT(*), 2) AS pct_fatal
FROM   v_demo_enriched d
LEFT   JOIN v_case_outcome o ON o.primaryid = d.primaryid
GROUP  BY d.age_band, d.sex
ORDER  BY FIELD(d.age_band, '<=45', '46-64', '>=65', 'Unknown'), n_cases DESC;


-- ---------------------------------------------------------------------------
-- Q4.5  Which drugs generate the most primary-suspect reports overall?
--
-- Business question: two things at once. It confirms the warehouse behaves
-- like FAERS is known to behave - the top of this list should be dominated by
-- the biologics and the high-volume chronic therapies - and it puts the GLP-1
-- volume in context against the whole database.
--
-- Note the runtime: this groups 6.3M drug rows on a 500-character column, so
-- expect tens of seconds. It is a one-off profiling query, not something to
-- put behind a dashboard.
-- ---------------------------------------------------------------------------
SELECT dr.prod_ai,
       COUNT(DISTINCT dr.primaryid)                          AS n_reports,
       COUNT(DISTINCT dr.caseid)                             AS n_cases
FROM   drug dr
WHERE  dr.role_cod = 'PS'
  AND  dr.prod_ai IS NOT NULL
GROUP  BY dr.prod_ai
ORDER  BY n_reports DESC
LIMIT  25;


-- ###########################################################################
-- 5. MULTI-TABLE JOINS - drug x outcome and drug x reaction cross-tabs
-- ###########################################################################

-- ---------------------------------------------------------------------------
-- Q5.1  Drug x outcome cross-tab for the GLP-1 class
--       (demo + drug + outc, via the cohort table)
--
-- Business question: of the reports naming each GLP-1 as primary suspect,
-- what share ended in death, hospitalisation or another serious outcome? This
-- is the first table a safety reviewer asks for, and it frames every
-- disproportionality result that follows.
--
-- Read it as descriptive, not comparative. A higher fatal share for one
-- molecule may reflect an older, sicker treated population rather than a
-- higher risk - which is precisely why the PRR/ROR work happens in SAS with
-- a proper comparator, and why the columns below are labelled "share of
-- reports" rather than "rate".
-- ---------------------------------------------------------------------------
SELECT c.drug_label,
       c.generation,
       COUNT(DISTINCT c.primaryid)                           AS n_reports,
       COUNT(DISTINCT CASE WHEN o.primaryid IS NOT NULL THEN c.primaryid END)
                                                             AS n_serious,
       ROUND(100.0 * COUNT(DISTINCT CASE WHEN o.primaryid IS NOT NULL THEN c.primaryid END)
             / COUNT(DISTINCT c.primaryid), 1)               AS pct_serious,
       ROUND(100.0 * COUNT(DISTINCT CASE WHEN o.out_death        = 1 THEN c.primaryid END)
             / COUNT(DISTINCT c.primaryid), 2)               AS pct_death,
       ROUND(100.0 * COUNT(DISTINCT CASE WHEN o.out_life_threat  = 1 THEN c.primaryid END)
             / COUNT(DISTINCT c.primaryid), 2)               AS pct_life_threat,
       ROUND(100.0 * COUNT(DISTINCT CASE WHEN o.out_hospital     = 1 THEN c.primaryid END)
             / COUNT(DISTINCT c.primaryid), 2)               AS pct_hospital,
       ROUND(100.0 * COUNT(DISTINCT CASE WHEN o.out_disability   = 1 THEN c.primaryid END)
             / COUNT(DISTINCT c.primaryid), 2)               AS pct_disability,
       ROUND(100.0 * COUNT(DISTINCT CASE WHEN o.out_intervention = 1 THEN c.primaryid END)
             / COUNT(DISTINCT c.primaryid), 2)               AS pct_intervention
FROM   glp1_ps_case c
LEFT   JOIN v_case_outcome o ON o.primaryid = c.primaryid
GROUP  BY c.drug_label, c.generation
ORDER  BY n_reports DESC;


-- ---------------------------------------------------------------------------
-- Q5.2  The full four-table join: demo + drug + reac + outc
--       Reaction x outcome severity, per GLP-1 molecule
--
-- Business question: which reported reactions are the ones that actually put
-- people in hospital or kill them? A term can be common and benign (nausea)
-- or rare and lethal - ranking by volume alone hides that, and this is the
-- table that separates the two. It is also the shortlist that Phase 3 feeds
-- into the SAS engine for disproportionality testing.
--
-- Written against the base tables rather than v_glp1_cases so the join path
-- is explicit: demo supplies the case, drug identifies the exposure, reac the
-- event, outc the severity.
-- ---------------------------------------------------------------------------
SELECT c.drug_label,
       rc.pt                                                 AS reaction_pt,
       COUNT(DISTINCT c.primaryid)                            AS n_reports,
       COUNT(DISTINCT CASE WHEN o.out_death   = 1 THEN c.primaryid END) AS n_fatal,
       ROUND(100.0 * COUNT(DISTINCT CASE WHEN o.out_death   = 1 THEN c.primaryid END)
             / COUNT(DISTINCT c.primaryid), 1)                AS pct_fatal,
       COUNT(DISTINCT CASE WHEN o.out_hospital = 1 THEN c.primaryid END) AS n_hospitalised,
       ROUND(100.0 * COUNT(DISTINCT CASE WHEN o.out_hospital = 1 THEN c.primaryid END)
             / COUNT(DISTINCT c.primaryid), 1)                AS pct_hospitalised,
       ROUND(AVG(d.age_years), 1)                             AS mean_age_years,
       ROUND(100.0 * SUM(d.sex = 'F') / COUNT(*), 1)          AS pct_female
FROM       glp1_ps_case   c
JOIN       v_demo_enriched d ON d.primaryid = c.primaryid
JOIN       reac           rc ON rc.primaryid = c.primaryid
LEFT  JOIN v_case_outcome  o ON o.primaryid = c.primaryid
WHERE  rc.pt IS NOT NULL
GROUP  BY c.drug_label, rc.pt
HAVING n_reports >= 30            -- below this the percentages are noise
ORDER  BY c.drug_label, n_fatal DESC, n_reports DESC;


-- ---------------------------------------------------------------------------
-- Q5.3  Do the GLP-1 reactions of interest concentrate in a subgroup?
--
-- Business question: CHARTER lists six FDA-known GLP-1 safety topics. Before
-- running stratified PRR in SAS, check whether the raw case counts already
-- cluster in one age band, one sex or one region. A signal that lives
-- entirely in one subgroup is a different clinical story from one spread
-- evenly, and it is worth knowing which before choosing the strata.
--
-- The LIKE list is deliberately generous: MedDRA has several PTs per concept
-- (pancreatitis, pancreatitis acute, pancreatitis necrotising), and at PT
-- level with no MedDRA licence for SMQ grouping, pattern matching is the
-- available substitute. CHARTER records that limitation.
-- ---------------------------------------------------------------------------
SELECT CASE
            WHEN rc.pt LIKE '%PANCREATITIS%'                     THEN 'Pancreatitis'
            WHEN rc.pt LIKE '%THYROID%'                          THEN 'Thyroid'
            WHEN rc.pt LIKE '%GASTROPARESIS%'
              OR rc.pt LIKE '%ILEUS%'                            THEN 'Gastroparesis / ileus'
            WHEN rc.pt LIKE '%CHOLELITH%'
              OR rc.pt LIKE '%CHOLECYST%'
              OR rc.pt LIKE '%GALLBLADDER%'                      THEN 'Gallbladder'
            WHEN rc.pt LIKE '%RENAL%' OR rc.pt LIKE '%KIDNEY%'   THEN 'Renal'
            WHEN rc.pt LIKE '%SUICID%'                           THEN 'Suicidality'
       END                                                       AS topic,
       c.drug_label,
       d.age_band,
       d.report_region,
       COUNT(DISTINCT c.primaryid)                               AS n_reports,
       ROUND(100.0 * SUM(d.sex = 'F') / COUNT(*), 1)             AS pct_female,
       COUNT(DISTINCT CASE WHEN o.out_death = 1 THEN c.primaryid END) AS n_fatal
FROM       glp1_ps_case   c
JOIN       v_demo_enriched d ON d.primaryid = c.primaryid
JOIN       reac           rc ON rc.primaryid = c.primaryid
LEFT  JOIN v_case_outcome  o ON o.primaryid = c.primaryid
WHERE  rc.pt LIKE '%PANCREATITIS%'  OR rc.pt LIKE '%THYROID%'
    OR rc.pt LIKE '%GASTROPARESIS%' OR rc.pt LIKE '%ILEUS%'
    OR rc.pt LIKE '%CHOLELITH%'     OR rc.pt LIKE '%CHOLECYST%'
    OR rc.pt LIKE '%GALLBLADDER%'   OR rc.pt LIKE '%RENAL%'
    OR rc.pt LIKE '%KIDNEY%'        OR rc.pt LIKE '%SUICID%'
GROUP  BY topic, c.drug_label, d.age_band, d.report_region
HAVING n_reports >= 10
ORDER  BY topic, n_reports DESC;


-- ---------------------------------------------------------------------------
-- Q5.4  What else is on these cases?
--
-- Business question: co-reported drugs are the main confounder in spontaneous
-- report data. If insulin or metformin appears on most GLP-1 pancreatitis
-- cases, that is a competing explanation the case study has to address rather
-- than discover in an interview.
-- ---------------------------------------------------------------------------
SELECT c.drug_label,
       co.prod_ai                                            AS co_reported_drug,
       co.role_cod,
       COUNT(DISTINCT c.primaryid)                           AS n_reports,
       ROUND(100.0 * COUNT(DISTINCT c.primaryid)
             / (SELECT COUNT(DISTINCT x.primaryid)
                FROM   glp1_ps_case x
                WHERE  x.drug_label = c.drug_label), 1)      AS pct_of_drug_cohort
FROM   glp1_ps_case c
JOIN   drug co ON co.primaryid = c.primaryid
JOIN   ref_glp1_drug g ON g.drug_label = c.drug_label
WHERE  co.prod_ai IS NOT NULL
  AND  co.prod_ai NOT LIKE g.ai_pattern      -- exclude the GLP-1 itself
GROUP  BY c.drug_label, co.prod_ai, co.role_cod
HAVING n_reports >= 100
ORDER  BY c.drug_label, n_reports DESC;


-- ###########################################################################
-- 6. WINDOW FUNCTIONS
-- ###########################################################################

-- ---------------------------------------------------------------------------
-- Q6.1  Top 10 reported reactions for each GLP-1 molecule
--
-- Business question: what does each drug's reported safety profile actually
-- look like? ROW_NUMBER partitioned by molecule gives a clean top-N per group
-- in one pass - the alternative, four separate LIMIT 10 queries stitched
-- together, does not scale past four drugs and cannot be filtered as a unit.
--
-- The denominator is distinct reports in the cohort, not the sum of reaction
-- counts: a case listing eight reactions must not contribute eight times to
-- its own denominator.
-- ---------------------------------------------------------------------------
WITH drug_total AS (
    SELECT drug_label, COUNT(DISTINCT primaryid) AS n_cohort_reports
    FROM   glp1_ps_case
    GROUP  BY drug_label
),
drug_pt AS (
    SELECT c.drug_label,
           rc.pt,
           COUNT(DISTINCT c.primaryid) AS n_reports
    FROM   glp1_ps_case c
    JOIN   reac rc ON rc.primaryid = c.primaryid
    WHERE  rc.pt IS NOT NULL
    GROUP  BY c.drug_label, rc.pt
),
ranked AS (
    SELECT p.drug_label,
           p.pt,
           p.n_reports,
           t.n_cohort_reports,
           ROW_NUMBER() OVER (PARTITION BY p.drug_label ORDER BY p.n_reports DESC, p.pt) AS rn
    FROM   drug_pt p
    JOIN   drug_total t ON t.drug_label = p.drug_label
)
SELECT drug_label,
       rn                                                    AS rank_in_drug,
       pt                                                    AS reaction_pt,
       n_reports,
       n_cohort_reports,
       ROUND(100.0 * n_reports / n_cohort_reports, 1)        AS pct_of_drug_reports
FROM   ranked
WHERE  rn <= 10
ORDER  BY drug_label, rn;


-- ---------------------------------------------------------------------------
-- Q6.2  How concentrated is each drug's reporting? (Pareto)
--
-- Business question: is the safety picture driven by a handful of terms, or
-- is it a long tail? A drug where 20 PTs cover 80 pct of reports has a
-- focused profile that a dashboard can show directly; a long tail means the
-- dashboard needs grouping to be readable. The running total answers it in
-- one pass with SUM() OVER an ordered window.
-- ---------------------------------------------------------------------------
WITH drug_pt AS (
    SELECT c.drug_label, rc.pt, COUNT(DISTINCT c.primaryid) AS n_reports
    FROM   glp1_ps_case c
    JOIN   reac rc ON rc.primaryid = c.primaryid
    WHERE  rc.pt IS NOT NULL
    GROUP  BY c.drug_label, rc.pt
)
SELECT drug_label,
       ROW_NUMBER() OVER w                                   AS pt_rank,
       pt                                                    AS reaction_pt,
       n_reports,
       SUM(n_reports)   OVER w                               AS running_reports,
       ROUND(100.0 * SUM(n_reports) OVER w
             / SUM(n_reports) OVER (PARTITION BY drug_label), 1)
                                                             AS cumulative_pct_of_mentions
FROM   drug_pt
-- No explicit frame on w: ROW_NUMBER does not accept one, and the ORDER BY
-- includes pt, which makes every row's sort key unique. With no ties, the
-- default RANGE frame and an explicit ROWS frame produce the same running
-- total - so one window definition serves both functions.
WINDOW w AS (PARTITION BY drug_label ORDER BY n_reports DESC, pt)
ORDER  BY drug_label, pt_rank
LIMIT  120;


-- ---------------------------------------------------------------------------
-- Q6.3  How is reporting volume moving quarter over quarter?
--
-- Business question: is any GLP-1's reporting accelerating? LAG gives the
-- previous quarter on the same row, so the change and the percent change come
-- out without a self-join.
--
-- Two caveats that belong on the slide, not in a footnote:
--   * quarter here is the quarter of the surviving report version. A case
--     first submitted in 2025Q3 and revised in 2026Q1 counts in 2026Q1,
--     which shifts volume toward later quarters.
--   * FAERS has no denominator. Rising counts may be rising prescriptions,
--     rising awareness, or the Weber effect - never assume rising risk.
-- ---------------------------------------------------------------------------
WITH quarterly AS (
    SELECT drug_label,
           quarter,
           COUNT(DISTINCT primaryid) AS n_reports
    FROM   glp1_ps_case
    GROUP  BY drug_label, quarter
)
SELECT drug_label,
       quarter,
       n_reports,
       LAG(n_reports)  OVER w                                AS prev_quarter_reports,
       n_reports - LAG(n_reports) OVER w                     AS change_vs_prev,
       ROUND(100.0 * (n_reports - LAG(n_reports) OVER w)
             / NULLIF(LAG(n_reports) OVER w, 0), 1)          AS pct_change,
       SUM(n_reports)  OVER (PARTITION BY drug_label
                             ORDER BY quarter
                             ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                                                             AS cumulative_reports,
       ROUND(100.0 * n_reports
             / SUM(n_reports) OVER (PARTITION BY quarter), 1) AS pct_of_class_that_quarter
FROM   quarterly
WINDOW w AS (PARTITION BY drug_label ORDER BY quarter)
ORDER  BY drug_label, quarter;


-- ---------------------------------------------------------------------------
-- Q6.4  Head-to-head: which reactions rank differently between the newer
--       agents and the older comparators?
--
-- Business question: this is the CHARTER Phase 3 comparison in descriptive
-- form. Ranking each reaction within each molecule and then setting the ranks
-- side by side surfaces the terms that are prominent for one drug and not the
-- other - the shortlist worth taking into the SAS head-to-head, where a
-- proper comparator-based statistic can be computed.
--
-- Rank difference is used rather than a ratio of shares on purpose: it is
-- ordinal, so it cannot be misread as an effect size.
-- ---------------------------------------------------------------------------
WITH drug_total AS (
    SELECT drug_label, COUNT(DISTINCT primaryid) AS n_cohort
    FROM   glp1_ps_case GROUP BY drug_label
),
drug_pt AS (
    SELECT c.drug_label, rc.pt, COUNT(DISTINCT c.primaryid) AS n_reports
    FROM   glp1_ps_case c
    JOIN   reac rc ON rc.primaryid = c.primaryid
    WHERE  rc.pt IS NOT NULL
    GROUP  BY c.drug_label, rc.pt
),
ranked AS (
    SELECT p.drug_label,
           p.pt,
           p.n_reports,
           ROUND(100.0 * p.n_reports / t.n_cohort, 2)                       AS pct_of_cohort,
           RANK() OVER (PARTITION BY p.drug_label ORDER BY p.n_reports DESC) AS rnk
    FROM   drug_pt p
    JOIN   drug_total t ON t.drug_label = p.drug_label
)
SELECT s.pt                                                  AS reaction_pt,
       s.rnk                                                 AS semaglutide_rank,
       s.n_reports                                           AS semaglutide_reports,
       s.pct_of_cohort                                       AS semaglutide_pct,
       l.rnk                                                 AS liraglutide_rank,
       l.n_reports                                           AS liraglutide_reports,
       l.pct_of_cohort                                       AS liraglutide_pct,
       l.rnk - s.rnk                                         AS rank_gap_favouring_sema
FROM       ranked s
LEFT  JOIN ranked l ON l.pt = s.pt AND l.drug_label = 'LIRAGLUTIDE'
WHERE  s.drug_label = 'SEMAGLUTIDE'
  AND  s.rnk <= 40
ORDER  BY rank_gap_favouring_sema DESC, s.rnk;


-- ###########################################################################
-- 7. TABLEAU HANDOFF
-- ###########################################################################

-- ---------------------------------------------------------------------------
-- Q7.1  Connection check - point Tableau at faers_ro and this view.
--
-- Connection settings:
--   Server    127.0.0.1        Port 3306
--   Database  faers            Table  v_glp1_cases
--   User      faers_ro         (SELECT only - see 01_ddl.sql section 0)
--
-- Reminder from the view header: set primaryid's default aggregation to
-- COUNT DISTINCT at the data-source level. The view's grain is one row per
-- reaction, so a plain COUNT counts reactions and every case-level rate comes
-- out inflated.
-- ---------------------------------------------------------------------------
SELECT * FROM v_glp1_cases LIMIT 20;


-- ---------------------------------------------------------------------------
-- Q7.2  Optional: materialise the view as an extract table.
--
-- A Tableau live connection to v_glp1_cases re-runs three joins on every
-- filter change. That is fine for a few hundred thousand rows locally, but if
-- the dashboard feels sluggish - or if it has to be published to Tableau
-- Public, which cannot reach a local MySQL at all - snapshot it instead.
--
-- For Tableau Public the practical route is: run this, export the table to
-- CSV, and build the packaged workbook (.twbx) on that extract.
-- ---------------------------------------------------------------------------
-- DROP TABLE IF EXISTS glp1_tableau_extract;
-- CREATE TABLE glp1_tableau_extract AS SELECT * FROM v_glp1_cases;
-- ALTER TABLE glp1_tableau_extract
--     ADD KEY idx_ext_drug (drug_label),
--     ADD KEY idx_ext_pt   (reaction_pt(60)),
--     ADD KEY idx_ext_qtr  (quarter);
-- SELECT COUNT(*) AS extract_rows FROM glp1_tableau_extract;

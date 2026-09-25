-- ===========================================================================
-- 04_reporter_type.sql - Who reported the case? Reporter occupation by cohort
--
-- Why this file exists
-- ---------------------------------------------------------------------------
--   Two of this project's headline signals sit next to active US litigation:
--   semaglutide / NAION and dulaglutide / gastroparesis. A disproportionality
--   statistic cannot tell the difference between a drug that causes an event
--   and a plaintiff firm that files a batch of reports about it. The reporter
--   occupation field is the cheapest available probe of that second
--   explanation: occp_cod = 'LW' marks a report submitted by a lawyer.
--
--   A raw lawyer share is uninterpretable on its own - "8% of these cases
--   came from lawyers" is only high or low against something. So the file
--   reports six cohorts, two of interest and four as nested baselines:
--
--     1  SEMAGLUTIDE + NAION                  signal under scrutiny
--     2  DULAGLUTIDE + gastroparesis group    signal under scrutiny
--     3  SEMAGLUTIDE - all cases              same drug, any event
--     4  DULAGLUTIDE - all cases              same drug, any event
--     5  GLP-1 cohort - all four molecules    same drug class
--     6  FAERS - all cases                    the whole warehouse
--
--   Read 1 against 3 against 5 against 6, and the excess (if any) is
--   attributable to the event rather than to the drug or to FAERS at large.
--
--   Cohorts 1 and 2 are additionally cut by quarter. A US MDL consolidating
--   these claims was established in December 2025, mid-2025Q4; if litigation
--   is driving the reports, the lawyer share should step up across that
--   boundary. December sits in the last month of 2025Q4, so that quarter is
--   labelled separately rather than folded into either side - calling it
--   "pre" would hide the first month of MDL-driven filing, and calling it
--   "post" would credit the MDL with two quarters it had not yet reached.
--
-- What this file does NOT do
-- ---------------------------------------------------------------------------
--   Nothing. It is read-only by construction: SELECT statements only, no
--   CREATE, DROP, UPDATE or INSERT, and it is meant to be run as faers_ro.
--   It creates no views and no tables, so it can be re-run at any time
--   without touching the warehouse or invalidating any SAS output.
--
--   It also draws no causal conclusion. A high lawyer share is evidence of
--   stimulated reporting, not proof of it, and a low one does not clear a
--   signal - solicited reports can reach FDA through a consumer or a treating
--   physician and would be coded CN or MD. The number bounds one confounder;
--   it does not settle the question.
--
-- occp_cod values, and the two that are absent
-- ---------------------------------------------------------------------------
--   FDA's own ASCII documentation overlaps on this field: older extracts
--   define OT as "other health-professional", newer ones add HP and demote
--   OT to a generic "other". This extract (2025Q3-2026Q2) contains MD, PH,
--   HP, CN, LW and blanks - no OT and no RN rows at all. Both are kept in the
--   reference list below so they surface as explicit zeros, which is a more
--   useful result than a silently missing row: it documents that the absence
--   was checked rather than overlooked. Nothing in the analysis turns on the
--   OT / HP labelling, since OT has no rows to label.
--
--   Blank occp_cod is the largest single group in FAERS (roughly 37% of all
--   cases) and is reported as '(not reported)' rather than dropped. Dropping
--   it would inflate every other share by about half, and the missingness is
--   not random - it tracks the reporting channel, so it belongs in the table.
--
-- Grain and the denominator
-- ---------------------------------------------------------------------------
--   One case = one row of demo. In this warehouse demo is 1:1:1 on
--   primaryid / caseid (1,529,536 of each), because the SAS pipeline already
--   kept the latest version of each case and removed the DELETE-file
--   retractions, so COUNT(*) over the joined cohort is a case count.
--
--   glp1_ps_case has grain (report, molecule): a case naming two GLP-1s as
--   primary suspect appears twice. Cohort 5 therefore selects DISTINCT
--   primaryid; cohorts 1-4 are already one row per case because each is
--   filtered to a single molecule.
--
--   pct_of_cohort is a within-cohort column percentage: the shares in one
--   (cohort, slice) sum to 100. It is descriptive - it says who reported, not
--   whether they reported disproportionately.
--
-- Event definitions, and why they are spelled out here
-- ---------------------------------------------------------------------------
--   NAION           PT 'Optic ischaemic neuropathy', the single CORE term
--                   used by the Category D reference set in
--                   sas/03_glp1_validation.sas. FAERS carries no PT literally
--                   named NAION.
--   Gastroparesis   the 6-PT GASTROPARESIS group from sas/00_ref_pt_group.sas,
--                   the same grouping behind the dulaglutide finding in
--                   sas/03_glp1_report.sas. Note that the PTs 'Gastroparesis'
--                   and 'Gastric emptying decreased' do not occur in this
--                   extract; the term reporters actually use is 'Impaired
--                   gastric emptying'.
--
--   Both lists are inlined rather than joined to a reference table, because
--   those references live in SAS datasets on SAS ODA and have no MySQL
--   counterpart. That is a duplication of the definition, so it is a thing to
--   keep in step: if either reference changes, this file has to be edited to
--   match, and the PT lists below are the only place to edit.
--
-- Prerequisites
--   sql/01_ddl.sql, sql/02_load.sql and section 3 of sql/03_queries.sql
--   (which materialises glp1_ps_case) have all been run.
--
-- Run - this is the command that produces the deliverable
--   The file emits exactly ONE result set, so its tab-separated batch output
--   converts straight to CSV. A second query here would emit a second header
--   row into the middle of the file, so keep it to one.
--
--     /usr/local/mysql/bin/mysql -u faers_ro --batch --raw faers \
--         < sql/04_reporter_type.sql \
--       | python3 -c 'import sys, csv; w = csv.writer(sys.stdout); \
--           w.writerows(l.rstrip("\n").split("\t") for l in sys.stdin)' \
--       > output/tables/reporter_type_check.csv
--
--   Credentials come from ~/.my.cnf, so no -p is needed. --raw stops MySQL
--   escaping the output; none of these columns contain tabs or newlines.
--
-- WARNING - occp_cod completeness is not stable across these four quarters
-- ---------------------------------------------------------------------------
--   Run over the whole warehouse, the field shifts sharply in the last
--   quarter of the window:
--
--       quarter    cases    blank occp_cod    CN       HP       LW
--       2025Q3   391,622    68,008  (17%)   148,569   78,927    2,315
--       2025Q4   345,568    68,076  (20%)   119,134   73,250    1,765
--       2026Q1   369,888   126,755  (34%)   100,378   49,468    3,447
--       2026Q2   422,458   304,676  (72%)    11,998    4,054   10,747
--
--   Consumer and other-health-professional reports do not plausibly collapse
--   by an order of magnitude in one quarter while total volume rises. This is
--   a property of the 2026Q2 extract - a recently loaded quarter whose
--   occupation coding is largely still blank - not a change in who reports.
--
--   The consequence for this analysis is specific and it cuts both ways. Every
--   non-blank share is computed against a denominator that includes those
--   blanks, so all of MD%, CN%, HP% and LW% are deflated in 2026Q2 relative to
--   the earlier quarters. But the lawyer count itself also rises FAERS-wide
--   over the same window (2,315 -> 10,747), so a rising lawyer share inside a
--   cohort is not by itself evidence of anything cohort-specific. This is why
--   the quarterly block below covers all six cohorts: the only defensible read
--   of a cohort's quarterly lawyer share is as a ratio to cohort 6 in the same
--   quarter. Comparing a cohort's 2026Q2 share with its own 2025Q3 share
--   measures the extract as much as it measures the litigation.
--
-- Output   output/tables/reporter_type_check.csv
--          6 cohorts x 8 reporter categories                  =  48 rows
--        + 6 cohorts x 4 quarters x 8 reporter categories      = 192 rows
--                                                               --------
--                                                               240 rows
--
-- Author:   Hingling Yu
-- Created:  2026-09-24
-- ===========================================================================

USE faers;

WITH
-- The reporter dimension. Spelled out as a literal list rather than taken
-- from the data, so that categories with no cases appear as zeros and the row
-- order is the analytical one (clinicians, then consumer, then lawyer, then
-- missing) instead of alphabetical.
occp_ref AS (
    SELECT 'MD'     AS occp_cod, 'Physician'                AS reporter_label, 'Healthcare professional' AS reporter_group, 1 AS occp_ord
    UNION ALL SELECT 'PH',       'Pharmacist',              'Healthcare professional', 2
    UNION ALL SELECT 'HP',       'Other health professional','Healthcare professional', 3
    UNION ALL SELECT 'RN',       'Registered nurse',        'Healthcare professional', 4
    UNION ALL SELECT 'OT',       'Other',                   'Other',                   5
    UNION ALL SELECT 'CN',       'Consumer',                'Consumer',                6
    UNION ALL SELECT 'LW',       'Lawyer',                  'Lawyer',                  7
    UNION ALL SELECT '(blank)',  '(not reported)',          'Not reported',            8
),

-- One row per case, with the blank occupation turned into a real category so
-- it survives the GROUP BY and the LEFT JOIN below.
case_base AS (
    SELECT primaryid,
           quarter,
           COALESCE(NULLIF(occp_cod, ''), '(blank)') AS occp_cod
    FROM   demo
),

-- Reports carrying each event of interest. DISTINCT because a report can list
-- the same PT twice, and in the gastroparesis case can list two PTs from the
-- group - either would otherwise double-count the case.
naion_report AS (
    SELECT DISTINCT primaryid
    FROM   reac
    WHERE  pt = 'Optic ischaemic neuropathy'
),
gastro_report AS (
    SELECT DISTINCT primaryid
    FROM   reac
    WHERE  pt IN ('Impaired gastric emptying',
                  'Gastrointestinal hypomotility',
                  'Gastric hypomotility',
                  'Gastrointestinal motility disorder',
                  'Gastric dilatation',
                  'Diabetic gastroparesis')
),

-- The six cohorts, stacked. Every branch yields (cohort_id, cohort,
-- primaryid) at one row per case, which is what makes the single GROUP BY
-- downstream correct for all of them.
cohort_case AS (
    SELECT 1 AS cohort_id, '1 SEMAGLUTIDE + NAION' AS cohort, c.primaryid
    FROM   glp1_ps_case c
    JOIN   naion_report n ON n.primaryid = c.primaryid
    WHERE  c.drug_label = 'SEMAGLUTIDE'

    UNION ALL
    SELECT 2, '2 DULAGLUTIDE + gastroparesis', c.primaryid
    FROM   glp1_ps_case c
    JOIN   gastro_report g ON g.primaryid = c.primaryid
    WHERE  c.drug_label = 'DULAGLUTIDE'

    UNION ALL
    SELECT 3, '3 SEMAGLUTIDE - all events', c.primaryid
    FROM   glp1_ps_case c
    WHERE  c.drug_label = 'SEMAGLUTIDE'

    UNION ALL
    SELECT 4, '4 DULAGLUTIDE - all events', c.primaryid
    FROM   glp1_ps_case c
    WHERE  c.drug_label = 'DULAGLUTIDE'

    -- DISTINCT: grain of glp1_ps_case is (report, molecule), so a case naming
    -- two GLP-1s as primary suspect is present twice here and nowhere else.
    UNION ALL
    SELECT 5, '5 GLP-1 class - all four molecules', DISTINCT_PID.primaryid
    FROM   (SELECT DISTINCT primaryid FROM glp1_ps_case) DISTINCT_PID

    UNION ALL
    SELECT 6, '6 FAERS - all cases', d.primaryid
    FROM   demo d
),

-- The cohort dimension, so that the cross join below can manufacture a row
-- for every (cohort, reporter) pair including the empty ones.
cohort_dim AS (
    SELECT DISTINCT cohort_id, cohort FROM cohort_case
),

-- Cases per cohort x quarter x reporter. Everything reported below is an
-- aggregate of this one table.
counted AS (
    SELECT cc.cohort_id,
           cc.cohort,
           b.quarter,
           b.occp_cod,
           COUNT(*) AS n_cases
    FROM   cohort_case cc
    JOIN   case_base b ON b.primaryid = cc.primaryid
    GROUP  BY cc.cohort_id, cc.cohort, b.quarter, b.occp_cod
),

-- `counted` is cut by quarter, so the full-window block needs it collapsed
-- across quarters first. Joining `counted` directly on (cohort, reporter)
-- would return one row per quarter and silently quadruple the output.
counted_all AS (
    SELECT cohort_id, occp_cod, SUM(n_cases) AS n_cases
    FROM   counted
    GROUP  BY cohort_id, occp_cod
),

-- Cohort totals, used as the percentage denominator. Kept as a separate CTE
-- rather than a window function over `counted` so that the zero-filled rows
-- produced by the LEFT JOIN still get a denominator.
cohort_total AS (
    SELECT cohort_id, SUM(n_cases) AS cohort_n_cases
    FROM   counted
    GROUP  BY cohort_id
),
cohort_qtr_total AS (
    SELECT cohort_id, quarter, SUM(n_cases) AS cohort_n_cases
    FROM   counted
    GROUP  BY cohort_id, quarter
),

-- Block A - all six cohorts over the full 2025Q3-2026Q2 window.
overall AS (
    SELECT d.cohort_id,
           d.cohort,
           'ALL QUARTERS'           AS slice,
           'all quarters'           AS period_vs_mdl,
           o.occp_cod,
           o.reporter_label,
           o.reporter_group,
           COALESCE(c.n_cases, 0)   AS n_cases,
           t.cohort_n_cases,
           ROUND(100.0 * COALESCE(c.n_cases, 0) / t.cohort_n_cases, 2) AS pct_of_cohort,
           0                        AS slice_ord,
           o.occp_ord
    FROM       cohort_dim   d
    CROSS JOIN occp_ref     o
    JOIN       cohort_total t ON t.cohort_id = d.cohort_id
    LEFT JOIN  counted_all  c ON c.cohort_id = d.cohort_id
                             AND c.occp_cod  = o.occp_cod
),

-- Block B - every cohort cut by quarter, so the lawyer share can be read
-- across the December 2025 MDL boundary. All six rather than just the two of
-- interest, because a quarterly number needs a quarterly baseline for exactly
-- the reason the full-window number does - and here it needs it more, since
-- occp_cod completeness is not stable across these four quarters (see the
-- 2026Q2 warning in the header). A rise in the lawyer share inside a cohort
-- means nothing until it is compared with the rise in cohort 6 over the same
-- quarters.
--
-- Quarters come from a fixed list for the same reason the reporter categories
-- do: a quarter with no cases at all in a cohort should read 0, not vanish.
qtr_dim AS (
    SELECT '2025Q3' AS quarter, 'pre-MDL' AS period_vs_mdl, 1 AS slice_ord
    UNION ALL SELECT '2025Q4', 'MDL quarter (established Dec 2025)', 2
    UNION ALL SELECT '2026Q1', 'post-MDL', 3
    UNION ALL SELECT '2026Q2', 'post-MDL', 4
),
by_quarter AS (
    SELECT d.cohort_id,
           d.cohort,
           q.quarter                AS slice,
           q.period_vs_mdl,
           o.occp_cod,
           o.reporter_label,
           o.reporter_group,
           COALESCE(c.n_cases, 0)   AS n_cases,
           COALESCE(t.cohort_n_cases, 0) AS cohort_n_cases,
           CASE WHEN COALESCE(t.cohort_n_cases, 0) = 0 THEN NULL
                ELSE ROUND(100.0 * COALESCE(c.n_cases, 0) / t.cohort_n_cases, 2)
           END                      AS pct_of_cohort,
           q.slice_ord,
           o.occp_ord
    FROM       cohort_dim d
    CROSS JOIN qtr_dim    q
    CROSS JOIN occp_ref   o
    LEFT JOIN  cohort_qtr_total t ON t.cohort_id = d.cohort_id
                                 AND t.quarter   = q.quarter
    LEFT JOIN  counted    c ON c.cohort_id = d.cohort_id
                           AND c.quarter   = q.quarter
                           AND c.occp_cod  = o.occp_cod
)

SELECT cohort_id,
       cohort,
       slice,
       period_vs_mdl,
       occp_cod,
       reporter_label,
       reporter_group,
       n_cases,
       cohort_n_cases,
       pct_of_cohort
FROM ( SELECT * FROM overall
       UNION ALL
       SELECT * FROM by_quarter ) stacked
ORDER BY cohort_id, slice_ord, occp_ord;

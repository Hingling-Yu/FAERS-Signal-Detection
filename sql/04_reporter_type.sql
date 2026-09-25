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
--   Every cohort is additionally cut by quarter, so that a quarterly lawyer
--   share can be read against the same quarter's baseline.
--
-- The two MDLs, and why the period label is per cohort
-- ---------------------------------------------------------------------------
--   These two events are consolidated in two SEPARATE federal MDLs, filed
--   almost two years apart, both in E.D. Pa. Dates and scope are taken from
--   the JPML transfer orders themselves, not from secondary coverage:
--
--     MDL 3094  In re: GLP-1 RAs Products Liability Litigation
--               Transfer order filed 2024-02-02 (Doc. 145).
--               Scope: plaintiffs who "suffered gastroparesis, ileus,
--               intestinal obstruction or pseudo-obstruction, or other
--               gastrointestinal injury". Named products include Trulicity
--               (dulaglutide) and Mounjaro (tirzepatide) alongside the Novo
--               Nordisk semaglutide products. Eli Lilly moved to be excluded
--               and the Panel refused - "the claims against Eli Lilly alone
--               are sufficiently numerous and complex that they qualify for
--               centralized treatment" - so dulaglutide GI claims are inside
--               this MDL, not outside it.
--               https://www.jpml.uscourts.gov/sites/jpml/files/MDL-3094-Transfer_Order-1-24.pdf
--
--     MDL 3163  In re: GLP-1 RAs Non-Arteritic Anterior Ischemic Optic
--               Neuropathy (NAION) Products Liability Litigation
--               Transfer order filed 2025-12-15 (Doc. 49).
--               https://www.jpml.uscourts.gov/sites/jpml/files/MDL-3163-Transfer_Order-12-25.pdf
--
--   A single period label cannot serve both, and applying the NAION date to
--   the gastroparesis cohort would be simply wrong, so period_vs_mdl is
--   assigned per cohort by the cohort_mdl CTE below:
--
--     cohort 1  MDL 3163 governs. 2025-12-15 falls in 2025Q4, sixteen days
--               before the quarter ends, so that quarter is labelled as the
--               boundary rather than folded into either side: calling it
--               "pre" would hide the first filings, calling it "post" would
--               credit the MDL with a quarter it barely reached.
--     cohort 2  MDL 3094 governs, and it predates this data window by about
--               eighteen months. ALL FOUR QUARTERS ARE POST-MDL. There is no
--               pre-MDL dulaglutide baseline anywhere in this extract.
--     cohorts   Event-unrestricted, so both dockets apply to different cases
--     3, 4, 5   inside the same cohort and no single pre/post line exists.
--               Labelled 'n/a - multiple MDLs apply' rather than guessed at.
--     cohort 6  Whole-warehouse baseline, no MDL relevance.
--
--   The consequence for cohort 2 is a real limit on what these numbers can
--   answer, and it is worth stating plainly: because the window opens well
--   after MDL 3094 was filed, this data CANNOT test whether the MDL caused
--   the lawyer dominance in dulaglutide gastroparesis reports. It can only
--   show that the dominance is present in every quarter observed. Reading the
--   2025Q3 figure as a pre-litigation baseline would be a straightforward
--   error of fact.
--
-- What this file does NOT do
-- ---------------------------------------------------------------------------
--   Nothing. It is read-only by construction: SELECT statements only, no
--   CREATE, DROP, UPDATE or INSERT, and it is meant to be run as faers_ro.
--   It creates no views and no tables, so it can be re-run at any time
--   without touching the warehouse or invalidating any SAS output.
--
--   It also draws no causal conclusion, and occp_cod = 'LW' is narrower than
--   "litigation-related" in a way that governs how every number here can be
--   read. LW marks the reports a lawyer submitted DIRECTLY to FDA - that is
--   all it marks. An attorney-solicited report that reaches FDA through the
--   claimant or their treating physician is coded CN or MD and is invisible
--   to this field, as is any report routed through the manufacturer. So a
--   high LW share is strong evidence of litigation-channel reporting, while a
--   low one does not establish the absence of it: it bounds the directly
--   attributable portion only. Neither direction settles causation.
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
-- Reconciliation - cohort 1 is 627 cases here and 625 in the SAS validation
-- ---------------------------------------------------------------------------
--   The difference is not a SQL-versus-SAS discrepancy. It is a documented
--   difference between two SAS steps, and this file matches the one that is
--   right for a reporter-mix question:
--
--     627   sql/04 (this file), and glp1_base_signals.csv from
--           02_signal_engine, glp1_compare_sema_tirz.csv, glp1_age_dependent.csv
--     625   glp1_validation_detail.csv from 03_glp1_validation only
--
--   Cause. 03_glp1_validation.sas joins its reference PTs to the signal table
--   under SINGLE_INGREDIENT = 1. GLP1_SIGNALS is keyed on prod_ai, so
--   'SEMAGLUTIDE' and 'PYRIDOXINE\SEMAGLUTIDE' are two rows both carrying
--   drug_label SEMAGLUTIDE; without that restriction one reference PT would
--   match several prod_ai rows and the group counts would double. The
--   restriction is correct there and is explained in that file's own comments.
--
--   It is a whole-cohort restriction, not a NAION one: the same table reports
--   n_drug = 35,651 against 35,705 in the base engine, and 35,705 - 35,651 =
--   54 is exactly the count of semaglutide PS reports whose prod_ai is a
--   backslash-joined combination product rather than the bare molecule.
--
--   The two NAION cases are those combination products - both compounded
--   semaglutide-plus-B-vitamin, and both consumer-reported:
--
--     primaryid 258599151   2025Q3   CN   PYRIDOXINE\SEMAGLUTIDE
--     primaryid 264407581   2026Q1   CN   CYANOCOBALAMIN\SEMAGLUTIDE
--
--   So it is neither a dedup artefact nor a PT-matching difference, and
--   nothing here was tuned to make the numbers agree. This file deliberately
--   keeps all 627: compounded semaglutide reaches patients through telehealth
--   and compounding pharmacies rather than a prescription for a branded
--   product, which is a reporting channel this analysis is specifically about,
--   so dropping those cases would remove the very cases most likely to differ.
--
--   The choice is immaterial to every conclusion. On 625 the shares move by
--   at most a quarter of a point - lawyer 1.91% -> 1.92%, consumer 25.84% ->
--   25.60% - because 2 cases out of 627 cannot move a percentage. Anyone
--   reconciling this CSV against glp1_validation_detail.csv should expect the
--   2-case gap and read it as the single-ingredient restriction, not an error.
--
-- What the numbers came out as - stated at the limit of what LW supports
-- ---------------------------------------------------------------------------
--   Dulaglutide + gastroparesis, full window: 73.7% of cases were submitted
--   directly by a lawyer, against 21.4% for dulaglutide across all events,
--   1.3% for the GLP-1 class and 1.2% for FAERS at large. By quarter the share
--   is 87.3 / 93.8 / 60.2 / 97.8 percent, which is 38x to 184x the same
--   quarter's FAERS baseline throughout. Direct lawyer submission is the
--   dominant reporting channel for this drug-event pair in every quarter
--   observed. As set out above, all four quarters post-date MDL 3094, so these
--   figures describe a litigation-saturated window rather than a change across
--   the start of one.
--
--   Semaglutide + NAION, full window: 1.9% of cases (12 of 627) came directly
--   from a lawyer, and 41.0% from a health professional, against 0.06% and
--   16.9% respectively for semaglutide across all events. By quarter the
--   lawyer share runs 0.00 / 0.90 / 3.57 / 2.08 percent, peaking at 3.8x the
--   same quarter's FAERS baseline in 2026Q1 - the first full quarter after
--   MDL 3163 - then falling to 0.8x, below baseline, in 2026Q2.
--
--   What that supports, precisely: few NAION reports were submitted directly
--   by lawyers, and the health-professional share is more than twice that of
--   semaglutide reports generally. What it does NOT support is a claim that
--   the NAION signal is clinician-driven rather than litigation-driven. LW
--   captures direct lawyer submissions only, so attorney-solicited reports
--   filed by the claimant or their physician sit inside the CN and MD counts
--   and cannot be separated out with this field. A low LW share bounds the
--   directly attributable portion; it does not characterise the signal's
--   origin. Separating those channels would need rpsr (report source) or the
--   litigation-referral flags, which the FAERS public extract does not carry.
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
-- Output   output/tables/reporter_type_check.csv - 11 columns
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

-- Which MDL governs which cohort. See the header for the transfer orders this
-- is taken from. has_period = 0 marks the cohorts where no single pre/post
-- line exists, so that the quarterly block labels them 'n/a' instead of
-- silently applying one MDL's date to cases belonging to the other.
cohort_mdl AS (
    SELECT 1 AS cohort_id, 'MDL 3163 - NAION, filed 2025-12-15'          AS mdl_docket, 1 AS has_period
    UNION ALL SELECT 2, 'MDL 3094 - GI injuries, filed 2024-02-02',         1
    UNION ALL SELECT 3, 'n/a - MDL 3094 and MDL 3163 both apply',           0
    UNION ALL SELECT 4, 'n/a - MDL 3094 and MDL 3163 both apply',           0
    UNION ALL SELECT 5, 'n/a - MDL 3094 and MDL 3163 both apply',           0
    UNION ALL SELECT 6, 'n/a - whole-warehouse baseline',                   0
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
           m.mdl_docket,
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
    JOIN       cohort_mdl   m ON m.cohort_id = d.cohort_id
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
-- Two period columns, because the two MDLs split these quarters differently:
-- p_3163 for the NAION docket (filed 2025-12-15, inside 2025Q4) and p_3094 for
-- the GI docket (filed 2024-02-02, before the window opens, so every quarter
-- is post). cohort_mdl picks which one applies; neither is applied to a cohort
-- where both dockets are in play.
qtr_dim AS (
    SELECT '2025Q3' AS quarter, 1 AS slice_ord,
           'pre-MDL'                            AS p_3163,
           'post-MDL (filed 2024-02-02)'        AS p_3094
    UNION ALL SELECT '2025Q4', 2,
           'MDL quarter (filed 2025-12-15)',    'post-MDL (filed 2024-02-02)'
    UNION ALL SELECT '2026Q1', 3,
           'post-MDL',                          'post-MDL (filed 2024-02-02)'
    UNION ALL SELECT '2026Q2', 4,
           'post-MDL',                          'post-MDL (filed 2024-02-02)'
),
by_quarter AS (
    SELECT d.cohort_id,
           d.cohort,
           q.quarter                AS slice,
           m.mdl_docket,
           CASE WHEN m.has_period = 0 THEN 'n/a - see mdl_docket'
                WHEN d.cohort_id  = 1 THEN q.p_3163
                ELSE q.p_3094
           END                      AS period_vs_mdl,
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
    JOIN       cohort_mdl m ON m.cohort_id = d.cohort_id
    LEFT JOIN  cohort_qtr_total t ON t.cohort_id = d.cohort_id
                                 AND t.quarter   = q.quarter
    LEFT JOIN  counted    c ON c.cohort_id = d.cohort_id
                           AND c.quarter   = q.quarter
                           AND c.occp_cod  = o.occp_cod
)

SELECT cohort_id,
       cohort,
       slice,
       mdl_docket,
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

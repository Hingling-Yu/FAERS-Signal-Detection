-- ===========================================================================
-- 01_ddl.sql - FAERS MySQL warehouse schema
--
-- Purpose:  Physical model for the CLEAN datasets produced by the SAS
--           pipeline. This layer is not a second implementation of the SAS
--           work - it is the query and reporting surface:
--
--             SAS   owns import, cleaning, deduplication and the PRR/ROR
--                   signal engine (statistics stay in SAS)
--             MySQL owns the warehouse, ad-hoc multi-table exploration, and
--                   the views that Tableau connects to
--
-- Target:   MySQL 8.0.39 (local). Requires MySQL 8.0+ for window functions
--           and CTEs used in 03_queries.sql.
--
-- Run:      /usr/local/mysql/bin/mysql -u root -p < sql/01_ddl.sql
--
--           Use the bundled client at /usr/local/mysql/bin/mysql, not the
--           `mysql` first on PATH - that one ships with Anaconda (8.4.x) and
--           negotiates authentication differently against this 8.0 server.
--
-- Column contract:
--           Column order below matches sas/01b_export_csv.sas exactly, so
--           sql/02_load.sql can load positionally. Change one, change both.
--
-- Author:   Hingling Yu
-- Created:  2026-09-03
-- ===========================================================================


-- ===========================================================================
-- 0. DATABASE AND DEDICATED USER
-- ---------------------------------------------------------------------------
-- The project never runs as root. A dedicated account scoped to a single
-- schema means a mistyped DELETE cannot reach the mysql system tables, and it
-- is the credential that gets handed to Tableau.
--
-- BEFORE RUNNING: replace the placeholder password below. Do not commit a
-- real password - .gitignore already excludes *.env, so keep the working
-- value in a local .env file and out of this script.
-- ===========================================================================

CREATE DATABASE IF NOT EXISTS faers
    CHARACTER SET utf8mb4
    COLLATE       utf8mb4_0900_ai_ci;

-- Application account: full rights inside `faers`, nothing outside it.
CREATE USER IF NOT EXISTS 'faers_app'@'localhost'
    IDENTIFIED BY 'Yxl779900?';
GRANT ALL PRIVILEGES ON faers.* TO 'faers_app'@'localhost';

-- Read-only account for Tableau. A dashboard has no reason to hold write
-- rights, and a separate credential makes the connection auditable.
CREATE USER IF NOT EXISTS 'faers_ro'@'localhost'
    IDENTIFIED BY 'Yxl779900?';
GRANT SELECT ON faers.* TO 'faers_ro'@'localhost';

FLUSH PRIVILEGES;

USE faers;


-- ===========================================================================
-- 1. DESIGN NOTES
-- ---------------------------------------------------------------------------
-- Types
--   primaryid   BIGINT, not INT. FAERS primaryid is caseid concatenated with
--               caseversion and reaches 12-13 digits, well past INT's
--               2,147,483,647 ceiling. Getting this wrong silently clamps
--               every id to the maximum and destroys all joins.
--   caseid      BIGINT for the same reason and for join-type consistency;
--               a BIGINT-to-INT join forces a conversion that can bypass the
--               index.
--   nda_num     VARCHAR, not numeric. "022122" carries a meaningful leading
--               zero that a numeric column would erase. Same reasoning as the
--               SAS import.
--   age, wt     DECIMAL, not FLOAT. FAERS reports ages such as 0.5 (months
--               expressed in years elsewhere in the pipeline); binary floats
--               would make GROUP BY on age unreliable.
--   dates       DATE. The SAS side already resolved partial dates to the
--               first of the period and recorded what was actually reported
--               in the matching *_prec column, so no precision is lost here:
--               filter on *_prec = 'D' when only exact dates will do.
--
-- Character lengths
--   Taken from the LENGTH declarations in sas/macros/import_faers_table.sas,
--   which came from a full scan of all four quarters. Several fields sit at
--   their cap because the FDA truncates at the source (prod_ai and lit_ref at
--   500, drugname at 255, dose_vbm at 300) - that is documented in the Gate 1
--   field-width report, not a defect here.
--
-- Charset
--   utf8mb4 database-wide. The extract is 7-bit clean today, so ascii would
--   index more compactly, but one non-ASCII character in a future quarter
--   would fail the load outright. utf8mb4 costs prefix indexes instead, which
--   is the cheaper problem.
--
-- Primary keys
--   DEMO gets a natural PK on primaryid: the SAS dedup keeps exactly one row
--   per caseid, which makes both primaryid and caseid unique, and asserting
--   that here turns a silent dedup regression into a failed load.
--   The child tables get a surrogate AUTO_INCREMENT PK instead. FAERS
--   genuinely contains repeated child rows - the same reaction reported twice
--   on one case - so any natural key would be a lie that aborts the load.
--   InnoDB creates a hidden 6-byte row id when no PK is declared anyway, so
--   an explicit BIGINT PK costs about two bytes a row and buys a stable
--   handle for spot-checking individual rows.
--
-- Indexes
--   Every table is indexed on primaryid (the join key to DEMO) and caseid
--   (case-level rollups). Composite indexes target the access patterns that
--   03_queries.sql actually uses, leading with the selective column.
--   prod_ai is indexed on its first 100 characters: the full 500-character
--   column would be a 2,000-byte key in utf8mb4, and no FAERS active
--   ingredient string needs 100 characters to be distinguished.
-- ===========================================================================


-- ===========================================================================
-- 2. TABLES
-- ---------------------------------------------------------------------------
-- Dropped in reverse dependency order. There are no FK constraints (see the
-- note after RPSR), so order is cosmetic, but it keeps the script re-runnable
-- and readable.
-- ===========================================================================

DROP VIEW  IF EXISTS v_glp1_cases;
DROP VIEW  IF EXISTS v_case_outcome;
DROP VIEW  IF EXISTS v_demo_enriched;
DROP TABLE IF EXISTS glp1_ps_case;
DROP TABLE IF EXISTS ref_glp1_drug;
DROP TABLE IF EXISTS rpsr;
DROP TABLE IF EXISTS ther;
DROP TABLE IF EXISTS outc;
DROP TABLE IF EXISTS indi;
DROP TABLE IF EXISTS reac;
DROP TABLE IF EXISTS drug;
DROP TABLE IF EXISTS demo;
DROP TABLE IF EXISTS deleted_cases;


-- ---------------------------------------------------------------------------
-- 2.1 deleted_cases - retracted case IDs (FAERS DELETE files, DQ2)
--
-- Loaded for provenance, not for filtering: the SAS pipeline already removed
-- these cases before writing CLEAN.DEMO. Keeping the list lets a reviewer
-- confirm the exclusion held, which is exactly the question an auditor asks.
-- Expected rows: the deduplicated union of the four quarterly DELETE files.
-- ---------------------------------------------------------------------------
CREATE TABLE deleted_cases (
    caseid  BIGINT NOT NULL COMMENT 'Retracted FAERS case identifier',
    PRIMARY KEY (caseid)
) ENGINE=InnoDB
  COMMENT='Cases retracted by FDA across 2025Q3-2026Q2; excluded upstream in SAS';


-- ---------------------------------------------------------------------------
-- 2.2 demo - one row per surviving case (post-DELETE, post-dedup)
-- Expected rows: 1,529,536
-- ---------------------------------------------------------------------------
CREATE TABLE demo (
    primaryid           BIGINT        NOT NULL COMMENT 'Report version id = caseid + caseversion',
    caseid              BIGINT        NOT NULL COMMENT 'FAERS case identifier',
    caseversion         SMALLINT      NULL     COMMENT 'Highest version retained by SAS dedup',
    quarter             CHAR(6)       NOT NULL COMMENT 'Source extract, e.g. 2025Q3',

    i_f_code            CHAR(1)       NULL     COMMENT 'I = initial report, F = follow-up',
    rept_cod            VARCHAR(5)    NULL     COMMENT 'EXP / PER / DIR report type',
    auth_num            VARCHAR(70)   NULL,
    mfr_num             VARCHAR(70)   NULL     COMMENT 'Manufacturer report number',
    mfr_sndr            VARCHAR(70)   NULL     COMMENT 'Reporting organisation',
    lit_ref             VARCHAR(500)  NULL     COMMENT 'Literature citation; FDA truncates at 500',

    age                 DECIMAL(12,3) NULL     COMMENT 'Raw age value; unit is in age_cod',
    age_cod             VARCHAR(3)    NULL     COMMENT 'DEC YR MON WK DY HR',
    age_grp             CHAR(1)       NULL     COMMENT 'FDA banding: N I C T A E',
    sex                 CHAR(1)       NULL     COMMENT 'M F UNK',
    e_sub               CHAR(1)       NULL     COMMENT 'Y if submitted electronically',
    wt                  DECIMAL(12,3) NULL     COMMENT 'Raw weight; unit is in wt_cod',
    wt_cod              VARCHAR(3)    NULL     COMMENT 'KG LBS GMS',
    to_mfr              CHAR(1)       NULL,
    occp_cod            VARCHAR(2)    NULL     COMMENT 'Reporter occupation: MD PH OT CN LW RN',
    reporter_country    VARCHAR(25)   NULL,
    occr_country        VARCHAR(5)    NULL     COMMENT 'Country where the event occurred',

    event_dt            DATE          NULL     COMMENT 'Adverse event onset',
    mfr_dt              DATE          NULL     COMMENT 'Date manufacturer first received the report',
    init_fda_dt         DATE          NULL     COMMENT 'Date FDA first received the case',
    fda_dt              DATE          NULL     COMMENT 'Date FDA received this version',
    rept_dt             DATE          NULL     COMMENT 'Date reported to the manufacturer',

    event_dt_prec       CHAR(1)       NULL     COMMENT 'D day, M month, Y year, X unparseable, NULL not reported',
    mfr_dt_prec         CHAR(1)       NULL,
    init_fda_dt_prec    CHAR(1)       NULL,
    fda_dt_prec         CHAR(1)       NULL,
    rept_dt_prec        CHAR(1)       NULL,

    PRIMARY KEY (primaryid),
    UNIQUE  KEY uq_demo_caseid          (caseid),
    KEY         idx_demo_quarter        (quarter),
    KEY         idx_demo_country_qtr    (reporter_country, quarter),
    KEY         idx_demo_agegrp         (age_grp),
    KEY         idx_demo_occp           (occp_cod),
    KEY         idx_demo_fda_dt         (fda_dt)
) ENGINE=InnoDB
  COMMENT='FAERS demographics, deduplicated to one row per case';


-- ---------------------------------------------------------------------------
-- 2.3 drug - drugs reported on each case
-- Expected rows: 6,299,773 (the largest table; index choices matter most here)
-- ---------------------------------------------------------------------------
CREATE TABLE drug (
    drug_pk             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    primaryid           BIGINT        NOT NULL,
    caseid              BIGINT        NOT NULL,
    drug_seq            INT           NULL     COMMENT 'Joins to indi.indi_drug_seq and ther.dsg_drug_seq',
    quarter             CHAR(6)       NOT NULL,

    role_cod            VARCHAR(2)    NULL     COMMENT 'PS primary suspect, SS secondary, C concomitant, I interacting',
    drugname            VARCHAR(255)  NULL     COMMENT 'As reported (brand or generic); upcased in SAS',
    prod_ai             VARCHAR(500)  NULL     COMMENT 'Active ingredient; multi-ingredient products are backslash-separated',
    val_vbm             CHAR(1)       NULL,
    route               VARCHAR(50)   NULL,
    dose_vbm            VARCHAR(300)  NULL     COMMENT 'Verbatim dose text',
    cum_dose_chr        VARCHAR(10)   NULL,
    cum_dose_unit       VARCHAR(10)   NULL,
    dechal              CHAR(1)       NULL     COMMENT 'Dechallenge: Y N U D',
    rechal              CHAR(1)       NULL     COMMENT 'Rechallenge: Y N U D',
    lot_num             VARCHAR(40)   NULL,
    nda_num             VARCHAR(20)   NULL     COMMENT 'Character on purpose - leading zeros are meaningful',
    dose_amt            DECIMAL(18,4) NULL,
    dose_unit           VARCHAR(10)   NULL,
    dose_form           VARCHAR(70)   NULL,
    dose_freq           VARCHAR(12)   NULL     COMMENT 'CRLF stripped upstream (DQ1)',
    exp_dt              DATE          NULL,
    exp_dt_prec         CHAR(1)       NULL,

    PRIMARY KEY (drug_pk),
    KEY idx_drug_pid_seq   (primaryid, drug_seq),
    KEY idx_drug_caseid    (caseid),
    -- The workhorse index for this project: every GLP-1 query filters on the
    -- active ingredient and then narrows to primary-suspect rows.
    KEY idx_drug_ai_role   (prod_ai(100), role_cod),
    -- Reverse order for the opposite pattern: "all primary suspect drugs on
    -- these cases", where role_cod is the filter and primaryid the join key.
    KEY idx_drug_role_pid  (role_cod, primaryid),
    KEY idx_drug_name      (drugname(60)),
    KEY idx_drug_quarter   (quarter)
) ENGINE=InnoDB
  COMMENT='FAERS drug records; one row per drug per case';


-- ---------------------------------------------------------------------------
-- 2.4 reac - adverse reactions, MedDRA Preferred Term level
-- Expected rows: 4,983,301
-- ---------------------------------------------------------------------------
CREATE TABLE reac (
    reac_pk             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    primaryid           BIGINT        NOT NULL,
    caseid              BIGINT        NOT NULL,
    quarter             CHAR(6)       NOT NULL,

    pt                  VARCHAR(100)  NULL     COMMENT 'MedDRA Preferred Term',
    drug_rec_act        VARCHAR(100)  NULL     COMMENT 'Reaction recurrence on re-administration',

    PRIMARY KEY (reac_pk),
    KEY idx_reac_pid    (primaryid),
    KEY idx_reac_caseid (caseid),
    -- Leading with pt serves both "how often is this term reported" counts and
    -- "which cases reported it" lookups, and covers the join key without a
    -- table read.
    KEY idx_reac_pt_pid (pt, primaryid)
) ENGINE=InnoDB
  COMMENT='FAERS reactions at MedDRA PT level (no SMQ/HLT - no MedDRA licence)';


-- ---------------------------------------------------------------------------
-- 2.5 indi - indication for each drug
-- Expected rows: 4,206,546
-- ---------------------------------------------------------------------------
CREATE TABLE indi (
    indi_pk             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    primaryid           BIGINT        NOT NULL,
    caseid              BIGINT        NOT NULL,
    indi_drug_seq       INT           NULL     COMMENT 'Matches drug.drug_seq on the same case',
    quarter             CHAR(6)       NOT NULL,

    indi_pt             VARCHAR(100)  NULL     COMMENT 'Indication, MedDRA PT',

    PRIMARY KEY (indi_pk),
    KEY idx_indi_pid_seq (primaryid, indi_drug_seq),
    KEY idx_indi_caseid  (caseid),
    KEY idx_indi_pt      (indi_pt(60))
) ENGINE=InnoDB
  COMMENT='FAERS indications; joins to drug on (primaryid, drug_seq)';


-- ---------------------------------------------------------------------------
-- 2.6 outc - case outcomes
-- Expected rows: 1,127,292
--
-- Presence of any outc row is the working definition of a serious case in
-- 03_queries.sql: FAERS only records an outcome code when one of the
-- regulatory seriousness criteria was met.
-- ---------------------------------------------------------------------------
CREATE TABLE outc (
    outc_pk             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    primaryid           BIGINT        NOT NULL,
    caseid              BIGINT        NOT NULL,
    quarter             CHAR(6)       NOT NULL,

    outc_cod            VARCHAR(2)    NULL     COMMENT 'DE LT HO DS CA RI OT',

    PRIMARY KEY (outc_pk),
    KEY idx_outc_pid      (primaryid),
    KEY idx_outc_caseid   (caseid),
    KEY idx_outc_cod_pid  (outc_cod, primaryid)
) ENGINE=InnoDB
  COMMENT='FAERS outcomes; one row per outcome code per case';


-- ---------------------------------------------------------------------------
-- 2.7 ther - therapy start/stop dates and duration
-- Expected rows: 1,486,320
-- ---------------------------------------------------------------------------
CREATE TABLE ther (
    ther_pk             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    primaryid           BIGINT        NOT NULL,
    caseid              BIGINT        NOT NULL,
    dsg_drug_seq        INT           NULL     COMMENT 'Matches drug.drug_seq on the same case',
    quarter             CHAR(6)       NOT NULL,

    start_dt            DATE          NULL,
    end_dt              DATE          NULL,
    dur                 DECIMAL(12,3) NULL     COMMENT 'Reported duration; unit is in dur_cod',
    dur_cod             VARCHAR(3)    NULL     COMMENT 'YR MON WK DAY HR MIN',

    -- Partial dates are common here (DQ4): roughly 20 pct of start_dt values
    -- were reported as YYYYMM or YYYY. Filter on *_prec = 'D' for any
    -- time-to-onset work.
    start_dt_prec       CHAR(1)       NULL,
    end_dt_prec         CHAR(1)       NULL,

    PRIMARY KEY (ther_pk),
    KEY idx_ther_pid_seq (primaryid, dsg_drug_seq),
    KEY idx_ther_caseid  (caseid),
    KEY idx_ther_start   (start_dt)
) ENGINE=InnoDB
  COMMENT='FAERS therapy dates; joins to drug on (primaryid, drug_seq)';


-- ---------------------------------------------------------------------------
-- 2.8 rpsr - report source
-- Expected rows: 44,521
--
-- Sparse by design: only about 3 pct of cases carry a source code, so treat
-- this as an attribute of a subset, never as a denominator.
-- ---------------------------------------------------------------------------
CREATE TABLE rpsr (
    rpsr_pk             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    primaryid           BIGINT        NOT NULL,
    caseid              BIGINT        NOT NULL,
    quarter             CHAR(6)       NOT NULL,

    rpsr_cod            VARCHAR(3)    NULL     COMMENT 'FGN SDY LIT CSM HP UF DT OTH',

    PRIMARY KEY (rpsr_pk),
    KEY idx_rpsr_pid    (primaryid),
    KEY idx_rpsr_caseid (caseid),
    KEY idx_rpsr_cod    (rpsr_cod)
) ENGINE=InnoDB
  COMMENT='FAERS report source; populated on roughly 3 pct of cases';


-- ---------------------------------------------------------------------------
-- No FOREIGN KEY constraints, deliberately.
--
-- Two reasons. First, this is a read-only analytical warehouse rebuilt by a
-- full reload, not a transactional system - there is no path by which a child
-- row is inserted against a missing parent outside of a load bug, and the
-- verification block in 02_load.sql tests for exactly that. Second, FK checks
-- would add an index probe per row across 18M child rows during LOAD DATA,
-- for a guarantee the SAS pipeline already enforced when it filtered every
-- child table to surviving primaryids.
-- ---------------------------------------------------------------------------


-- ===========================================================================
-- 3. REFERENCE DATA
-- ---------------------------------------------------------------------------
-- The GLP-1 drug list lives in a table rather than being repeated as a
-- literal in every query. Adding a fifth molecule later becomes one INSERT
-- instead of an edit in a dozen places, and the class definition becomes a
-- reviewable artefact.
--
-- Matching note:
--   FAERS stores multi-ingredient products as backslash-separated strings,
--   e.g. 'SEMAGLUTIDE\CYANOCOBALAMIN' for compounded formulations, so an
--   equality test on prod_ai drops them without warning. The LIKE patterns
--   below match on substring instead.
--
--   sas/00_config.sas originally used an exact IN list and so selected a
--   narrower cohort. Q3.2 in 03_queries.sql listed exactly what the wildcard
--   adds; reviewed 2026-09-03, all genuine GLP-1 combination and compounded
--   products with no false positives, and the SAS side was widened to a
--   FIND-based substring match to match. The two layers now select the same
--   cohort and their case counts should reconcile - Q3.2 is retained as the
--   standing check that they still do.
-- ===========================================================================

CREATE TABLE ref_glp1_drug (
    drug_label   VARCHAR(20)  NOT NULL COMMENT 'Canonical molecule name used in all outputs',
    ai_pattern   VARCHAR(50)  NOT NULL COMMENT 'LIKE pattern matched against drug.prod_ai',
    generation   VARCHAR(20)  NOT NULL COMMENT 'newer or comparator - drives head-to-head analysis',
    brand_names  VARCHAR(120) NULL     COMMENT 'For dashboard labels and interview context',
    PRIMARY KEY (drug_label)
) ENGINE=InnoDB
  COMMENT='GLP-1 receptor agonist class definition (CHARTER section 3)';

INSERT INTO ref_glp1_drug (drug_label, ai_pattern, generation, brand_names) VALUES
    ('SEMAGLUTIDE', '%SEMAGLUTIDE%', 'newer',      'Ozempic / Wegovy / Rybelsus'),
    ('TIRZEPATIDE', '%TIRZEPATIDE%', 'newer',      'Mounjaro / Zepbound'),
    ('LIRAGLUTIDE', '%LIRAGLUTIDE%', 'comparator', 'Victoza / Saxenda'),
    ('DULAGLUTIDE', '%DULAGLUTIDE%', 'comparator', 'Trulicity');


-- ===========================================================================
-- 4. VERIFY
-- ===========================================================================

SELECT table_name,
       engine,
       table_collation
FROM   information_schema.tables
WHERE  table_schema = 'faers'
ORDER  BY table_name;

SELECT table_name,
       index_name,
       GROUP_CONCAT(column_name ORDER BY seq_in_index) AS columns,
       MAX(non_unique) = 0                             AS is_unique
FROM   information_schema.statistics
WHERE  table_schema = 'faers'
GROUP  BY table_name, index_name
ORDER  BY table_name, index_name;

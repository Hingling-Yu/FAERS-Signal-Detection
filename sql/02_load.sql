-- ===========================================================================
-- 02_load.sql - Load the SAS CSV export into the FAERS warehouse
--
-- Prerequisites
--   1. sql/01_ddl.sql has been run (schema + faers_app user exist)
--   2. sas/01b_export_csv.sas has been run on SAS ODA and the eight CSVs
--      downloaded into a single local directory
--
-- HOW TO RUN
-- ---------------------------------------------------------------------------
-- This file contains a __CSV_DIR__ placeholder instead of a hard-coded path,
-- so it stays portable when the repo moves. Substitute it at run time and
-- pipe straight into the client - nothing is written to disk, so there is no
-- generated copy to accidentally commit.
--
-- From the repo root:
--
--   sed "s|__CSV_DIR__|$(pwd)/output/csv|g" sql/02_load.sql \
--     | /usr/local/mysql/bin/mysql --local-infile=1 -u faers_app -p faers
--
-- Why each piece:
--   sed "s|...|...|g"        - `|` as the delimiter, because the replacement
--                              is a path full of `/`
--   $(pwd)                   - resolves to wherever the repo currently lives;
--                              LOAD DATA needs an absolute path and MySQL has
--                              no variable substitution for file names
--   --local-infile=1         - opts the CLIENT in to reading local files.
--                              MySQL 8 disables this on both sides by default
--                              because a hostile server could otherwise ask a
--                              client for arbitrary files. The server side is
--                              enabled by the SET GLOBAL below.
--   /usr/local/mysql/bin/... - the 8.0 client that ships with the server. The
--                              `mysql` first on PATH is Anaconda's 8.4.x
--                              build and authenticates differently.
--
-- SERVER-SIDE PREREQUISITE (run once, as root - faers_app has no SUPER):
--
--   /usr/local/mysql/bin/mysql -u root -p -e "SET GLOBAL local_infile = 1;"
--
-- That setting resets when mysqld restarts. To make it permanent, add
-- `local_infile=1` under [mysqld] in the server config.
--
-- Expected runtime: 10-25 minutes total, dominated by drug (6.3M rows).
--
-- IF IT STOPS PART WAY
--   The mysql client aborts on the first error, so a failure in one LOAD
--   leaves every table after it empty and the script exits before the
--   verification block ever runs. Always read section 5's row counts before
--   treating a load as done - silence is not success here.
--
--   To resume rather than restart, run one section at a time. Each LOAD in
--   section 3 is self-contained and its table is truncated in section 2, so
--   re-running a single table is safe:
--
--     sed "s|__CSV_DIR__|$(pwd)/output/csv|g" sql/02_load.sql > /tmp/load.sql
--     # then paste the section you need, or:
--     /usr/local/mysql/bin/mysql --local-infile=1 -u faers_app -p faers \
--       -e "TRUNCATE TABLE drug;" 
--     # ... followed by that table's LOAD DATA from /tmp/load.sql
--
--   Add --force to run the whole file through and collect every error at
--   once instead of stopping at the first.
--
-- Author:   Hingling Yu
-- Created:  2026-09-03
-- ===========================================================================

USE faers;


-- ===========================================================================
-- 1. SESSION SETTINGS
-- ---------------------------------------------------------------------------
-- unique_checks / foreign_key_checks off: no FK constraints exist and the
-- only UNIQUE keys are on tables whose uniqueness the SAS dedup already
-- guarantees. Turning them off skips a per-row probe across 19M rows.
--
-- autocommit is deliberately NOT changed. Each LOAD DATA is a single
-- statement and therefore already a single transaction - setting
-- autocommit = 0 around it commits no less often and buys nothing, while
-- leaving a transaction open across statements if the script stops early.
--
-- Strict SQL mode stays ON, deliberately. It is what turns a malformed date
-- or an over-long string into a hard error instead of a silently truncated
-- value - exactly the class of bug that is invisible until the analysis is
-- already wrong. Every empty field is mapped to NULL explicitly below rather
-- than relaxing the mode to let MySQL coerce '' into 0 or 0000-00-00.
--
-- What actually governs whether the 6.3M-row drug load survives is InnoDB
-- sizing, not transaction settings. Check before a first run:
--
--   SELECT @@innodb_buffer_pool_size / 1024 / 1024 AS buffer_pool_mb;
--
-- The macOS default is 128 MB. A single LOAD DATA of 6.3M rows against that
-- can exhaust the lock table (ERROR 1206) or crawl. Raising it to 2-4 GB for
-- the duration of the load is the fix; see the appendix for the alternative
-- if the server config cannot be changed.
-- ===========================================================================

SET SESSION unique_checks      = 0;
SET SESSION foreign_key_checks = 0;

SELECT @@sql_mode                          AS sql_mode_in_effect,
       @@local_infile                      AS server_local_infile,
       @@innodb_buffer_pool_size/1024/1024 AS buffer_pool_mb;


-- ===========================================================================
-- 2. TRUNCATE - make the load idempotent
--
-- TRUNCATE, not DELETE: it resets the AUTO_INCREMENT counters so a reload
-- produces the same surrogate keys, and it does not build an 19M-row undo log.
-- ===========================================================================

TRUNCATE TABLE deleted_cases;
TRUNCATE TABLE demo;
TRUNCATE TABLE drug;
TRUNCATE TABLE reac;
TRUNCATE TABLE indi;
TRUNCATE TABLE outc;
TRUNCATE TABLE ther;
TRUNCATE TABLE rpsr;


-- ===========================================================================
-- 3. LOAD
-- ---------------------------------------------------------------------------
-- CSV contract, produced by sas/01b_export_csv.sas:
--   ,  delimited, `"` used only where a value contains , or "
--   one header row
--   LF line endings (SAS ODA is Linux)
--   dates already YYYY-MM-DD
--   every missing value, numeric or character, is an empty field
--
-- ESCAPED BY '' - the single most important clause in this file
-- ---------------------------------------------------------------------------
--   MySQL's LOAD DATA is not an RFC 4180 CSV reader. On top of quote
--   handling it also applies backslash escape processing - and FAERS uses the
--   backslash as the separator between the active ingredients of a
--   combination product:
--
--       prod_ai = 'EMPAGLIFLOZIN\METFORMIN HYDROCHLORIDE'
--
--   Left at the default, MySQL silently ate that backslash across 344,323
--   drug rows, merging two ingredient names into one that does not exist.
--   The 19,472 values containing the sequence \N were additionally at risk
--   of being read as SQL NULL.
--
--   It also lost whole rows. PROC EXPORT quotes any value containing a comma,
--   so a dose_vbm ending in a backslash came out as "...\" - and MySQL read
--   that closing quote as an escaped literal quote, never closed the field,
--   and swallowed the following lines until it found another quote. Five such
--   values cost 38 drug rows on the first load, with no error raised.
--
--   ESCAPED BY '' turns escape processing off entirely. That is the correct
--   setting for PROC EXPORT output, which escapes an embedded quote by
--   doubling it ("") - a convention MySQL still honours inside an enclosed
--   field - and never uses the backslash as an escape. With this clause a
--   backslash is data, which is all it ever was.
--
--   Section 5.7 is the check that this held. Row counts cannot catch a
--   stripped backslash, so without it the corruption is invisible.
--
-- Why every column is read into a @variable and then SET
-- ---------------------------------------------------------------------------
--   PROC EXPORT writes a missing numeric as an empty field. Under strict mode
--   an empty string bound directly to a BIGINT, DECIMAL or DATE column is an
--   error, and under a relaxed mode it would become 0 or 0000-00-00 - a
--   fabricated value that reads as real data downstream. NULLIF(@v,'') is the
--   one mapping that preserves "not reported" as NULL, which is what DQ5
--   requires and what every COUNT and AVG below depends on.
--
--   NOT NULL columns (primaryid, caseid, quarter) are assigned directly. If
--   one is ever empty the load fails loudly, which is the correct outcome.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 3.1 deleted_cases
-- ---------------------------------------------------------------------------
LOAD DATA LOCAL INFILE '__CSV_DIR__/deleted_cases.csv'
INTO TABLE deleted_cases
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES  TERMINATED BY '\n'
IGNORE 1 LINES
(caseid);


-- ---------------------------------------------------------------------------
-- 3.2 demo  (31 columns)
-- ---------------------------------------------------------------------------
LOAD DATA LOCAL INFILE '__CSV_DIR__/demo.csv'
INTO TABLE demo
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES  TERMINATED BY '\n'
IGNORE 1 LINES
(primaryid, caseid, @caseversion, quarter,
 @i_f_code, @rept_cod, @auth_num, @mfr_num, @mfr_sndr, @lit_ref,
 @age, @age_cod, @age_grp, @sex, @e_sub, @wt, @wt_cod, @to_mfr,
 @occp_cod, @reporter_country, @occr_country,
 @event_dt, @mfr_dt, @init_fda_dt, @fda_dt, @rept_dt,
 @event_dt_prec, @mfr_dt_prec, @init_fda_dt_prec, @fda_dt_prec, @rept_dt_prec)
SET caseversion      = NULLIF(@caseversion, ''),
    i_f_code         = NULLIF(@i_f_code, ''),
    rept_cod         = NULLIF(@rept_cod, ''),
    auth_num         = NULLIF(@auth_num, ''),
    mfr_num          = NULLIF(@mfr_num, ''),
    mfr_sndr         = NULLIF(@mfr_sndr, ''),
    lit_ref          = NULLIF(@lit_ref, ''),
    age              = NULLIF(@age, ''),
    age_cod          = NULLIF(@age_cod, ''),
    age_grp          = NULLIF(@age_grp, ''),
    sex              = NULLIF(@sex, ''),
    e_sub            = NULLIF(@e_sub, ''),
    wt               = NULLIF(@wt, ''),
    wt_cod           = NULLIF(@wt_cod, ''),
    to_mfr           = NULLIF(@to_mfr, ''),
    occp_cod         = NULLIF(@occp_cod, ''),
    reporter_country = NULLIF(@reporter_country, ''),
    occr_country     = NULLIF(@occr_country, ''),
    event_dt         = NULLIF(@event_dt, ''),
    mfr_dt           = NULLIF(@mfr_dt, ''),
    init_fda_dt      = NULLIF(@init_fda_dt, ''),
    fda_dt           = NULLIF(@fda_dt, ''),
    rept_dt          = NULLIF(@rept_dt, ''),
    event_dt_prec    = NULLIF(@event_dt_prec, ''),
    mfr_dt_prec      = NULLIF(@mfr_dt_prec, ''),
    init_fda_dt_prec = NULLIF(@init_fda_dt_prec, ''),
    fda_dt_prec      = NULLIF(@fda_dt_prec, ''),
    rept_dt_prec     = NULLIF(@rept_dt_prec, '');


-- ---------------------------------------------------------------------------
-- 3.3 drug  (22 columns) - the slow one, roughly 6.3M rows
-- drug_pk is AUTO_INCREMENT and is deliberately absent from the column list.
-- ---------------------------------------------------------------------------
LOAD DATA LOCAL INFILE '__CSV_DIR__/drug.csv'
INTO TABLE drug
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES  TERMINATED BY '\n'
IGNORE 1 LINES
(primaryid, caseid, @drug_seq, quarter,
 @role_cod, @drugname, @prod_ai, @val_vbm, @route, @dose_vbm,
 @cum_dose_chr, @cum_dose_unit, @dechal, @rechal, @lot_num, @nda_num,
 @dose_amt, @dose_unit, @dose_form, @dose_freq, @exp_dt, @exp_dt_prec)
SET drug_seq      = NULLIF(@drug_seq, ''),
    role_cod      = NULLIF(@role_cod, ''),
    drugname      = NULLIF(@drugname, ''),
    prod_ai       = NULLIF(@prod_ai, ''),
    val_vbm       = NULLIF(@val_vbm, ''),
    route         = NULLIF(@route, ''),
    dose_vbm      = NULLIF(@dose_vbm, ''),
    cum_dose_chr  = NULLIF(@cum_dose_chr, ''),
    cum_dose_unit = NULLIF(@cum_dose_unit, ''),
    dechal        = NULLIF(@dechal, ''),
    rechal        = NULLIF(@rechal, ''),
    lot_num       = NULLIF(@lot_num, ''),
    nda_num       = NULLIF(@nda_num, ''),
    dose_amt      = NULLIF(@dose_amt, ''),
    dose_unit     = NULLIF(@dose_unit, ''),
    dose_form     = NULLIF(@dose_form, ''),
    dose_freq     = NULLIF(@dose_freq, ''),
    exp_dt        = NULLIF(@exp_dt, ''),
    exp_dt_prec   = NULLIF(@exp_dt_prec, '');


-- ---------------------------------------------------------------------------
-- 3.4 reac  (5 columns)
-- ---------------------------------------------------------------------------
LOAD DATA LOCAL INFILE '__CSV_DIR__/reac.csv'
INTO TABLE reac
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES  TERMINATED BY '\n'
IGNORE 1 LINES
(primaryid, caseid, quarter, @pt, @drug_rec_act)
SET pt           = NULLIF(@pt, ''),
    drug_rec_act = NULLIF(@drug_rec_act, '');


-- ---------------------------------------------------------------------------
-- 3.5 indi  (5 columns)
-- ---------------------------------------------------------------------------
LOAD DATA LOCAL INFILE '__CSV_DIR__/indi.csv'
INTO TABLE indi
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES  TERMINATED BY '\n'
IGNORE 1 LINES
(primaryid, caseid, @indi_drug_seq, quarter, @indi_pt)
SET indi_drug_seq = NULLIF(@indi_drug_seq, ''),
    indi_pt       = NULLIF(@indi_pt, '');


-- ---------------------------------------------------------------------------
-- 3.6 outc  (4 columns)
-- ---------------------------------------------------------------------------
LOAD DATA LOCAL INFILE '__CSV_DIR__/outc.csv'
INTO TABLE outc
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES  TERMINATED BY '\n'
IGNORE 1 LINES
(primaryid, caseid, quarter, @outc_cod)
SET outc_cod = NULLIF(@outc_cod, '');


-- ---------------------------------------------------------------------------
-- 3.7 ther  (10 columns)
-- ---------------------------------------------------------------------------
LOAD DATA LOCAL INFILE '__CSV_DIR__/ther.csv'
INTO TABLE ther
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES  TERMINATED BY '\n'
IGNORE 1 LINES
(primaryid, caseid, @dsg_drug_seq, quarter,
 @start_dt, @end_dt, @dur, @dur_cod, @start_dt_prec, @end_dt_prec)
SET dsg_drug_seq  = NULLIF(@dsg_drug_seq, ''),
    start_dt      = NULLIF(@start_dt, ''),
    end_dt        = NULLIF(@end_dt, ''),
    dur           = NULLIF(@dur, ''),
    dur_cod       = NULLIF(@dur_cod, ''),
    start_dt_prec = NULLIF(@start_dt_prec, ''),
    end_dt_prec   = NULLIF(@end_dt_prec, '');


-- ---------------------------------------------------------------------------
-- 3.8 rpsr  (4 columns)
-- ---------------------------------------------------------------------------
LOAD DATA LOCAL INFILE '__CSV_DIR__/rpsr.csv'
INTO TABLE rpsr
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES  TERMINATED BY '\n'
IGNORE 1 LINES
(primaryid, caseid, quarter, @rpsr_cod)
SET rpsr_cod = NULLIF(@rpsr_cod, '');


-- ===========================================================================
-- 4. RESTORE SESSION SETTINGS
-- ===========================================================================

SET SESSION unique_checks      = 1;
SET SESSION foreign_key_checks = 1;

-- AFTER THIS LOAD: rerun section 3 of sql/03_queries.sql.
-- glp1_ps_case is a materialised cohort built from drug, and TRUNCATE above
-- did not touch it - so until it is rebuilt it describes the previous load
-- while every view on top of it reports the new one.


-- ===========================================================================
-- 5. VERIFICATION - this is the MySQL half of Gate 1
-- ---------------------------------------------------------------------------
-- The expected counts are the CLEAN dataset row counts from
-- output/qc/qc_clean_pipeline.csv. Matching here proves the CSV round trip
-- lost nothing, which is the third leg of the Gate 1 chain:
--     source .txt  =  SAS dataset  =  MySQL table
-- ===========================================================================

-- 5.1 Row counts against the SAS pipeline
SELECT 'demo' AS table_name, COUNT(*) AS mysql_rows, 1529536 AS expected_rows FROM demo
UNION ALL SELECT 'drug', COUNT(*), 6299773 FROM drug
UNION ALL SELECT 'reac', COUNT(*), 4983301 FROM reac
UNION ALL SELECT 'indi', COUNT(*), 4206546 FROM indi
UNION ALL SELECT 'outc', COUNT(*), 1127292 FROM outc
UNION ALL SELECT 'ther', COUNT(*), 1486320 FROM ther
UNION ALL SELECT 'rpsr', COUNT(*),   44521 FROM rpsr;

-- Same thing as a pass/fail verdict, so nobody has to diff seven numbers by eye
SELECT CASE WHEN SUM(ABS(diff)) = 0 THEN 'GATE 1 (MySQL) PASSED'
            ELSE CONCAT('GATE 1 (MySQL) FAILED on ', SUM(diff <> 0), ' table(s)')
       END AS verdict
FROM (
    SELECT COUNT(*) - 1529536 AS diff FROM demo
    UNION ALL SELECT COUNT(*) - 6299773 FROM drug
    UNION ALL SELECT COUNT(*) - 4983301 FROM reac
    UNION ALL SELECT COUNT(*) - 4206546 FROM indi
    UNION ALL SELECT COUNT(*) - 1127292 FROM outc
    UNION ALL SELECT COUNT(*) - 1486320 FROM ther
    UNION ALL SELECT COUNT(*) -   44521 FROM rpsr
) t;

-- 5.2 Referential integrity - every child row must have a parent in demo.
-- Should return zero rows. A non-zero result means the CSV export and the
-- load went out of sync, since the SAS pipeline filtered every child table to
-- surviving primaryids.
SELECT 'drug' AS child_table, COUNT(*) AS orphan_rows
FROM   drug c LEFT JOIN demo d ON d.primaryid = c.primaryid
WHERE  d.primaryid IS NULL
UNION ALL
SELECT 'reac', COUNT(*) FROM reac c LEFT JOIN demo d ON d.primaryid = c.primaryid WHERE d.primaryid IS NULL
UNION ALL
SELECT 'indi', COUNT(*) FROM indi c LEFT JOIN demo d ON d.primaryid = c.primaryid WHERE d.primaryid IS NULL
UNION ALL
SELECT 'outc', COUNT(*) FROM outc c LEFT JOIN demo d ON d.primaryid = c.primaryid WHERE d.primaryid IS NULL
UNION ALL
SELECT 'ther', COUNT(*) FROM ther c LEFT JOIN demo d ON d.primaryid = c.primaryid WHERE d.primaryid IS NULL
UNION ALL
SELECT 'rpsr', COUNT(*) FROM rpsr c LEFT JOIN demo d ON d.primaryid = c.primaryid WHERE d.primaryid IS NULL;

-- 5.3 The DELETE exclusion held: no retracted case survived into demo.
-- Should return 0.
SELECT COUNT(*) AS retracted_cases_still_present
FROM   demo d
JOIN   deleted_cases x ON x.caseid = d.caseid;

-- 5.4 Value sanity - catches the failure mode where empty strings became
-- zeros or epoch dates instead of NULL.
SELECT COUNT(*)                                                   AS demo_rows,
       SUM(age IS NULL)                                           AS age_null,
       SUM(age = 0)                                               AS age_zero_suspicious,
       SUM(sex IS NULL)                                           AS sex_null,
       SUM(fda_dt IS NULL)                                        AS fda_dt_null,
       MIN(fda_dt)                                                AS fda_dt_min,
       MAX(fda_dt)                                                AS fda_dt_max,
       COUNT(DISTINCT quarter)                                    AS quarters
FROM   demo;

-- 5.5 primaryid survived as a full-width integer rather than being clipped by
-- an INT column or rendered in scientific notation on the SAS side.
SELECT MIN(primaryid)             AS min_primaryid,
       MAX(primaryid)             AS max_primaryid,
       MAX(LENGTH(primaryid))     AS max_digits,
       COUNT(DISTINCT primaryid)  AS distinct_primaryid,
       COUNT(*)                   AS rows_total
FROM   demo;

-- 5.7 Backslash integrity - the check that row counts cannot make.
--
-- A silently stripped backslash changes no row count, so this is the only
-- evidence that ESCAPED BY '' did its job. FAERS separates the active
-- ingredients of a combination product with a backslash, so losing it merges
-- two ingredient names into one nonexistent one.
--
-- Expected, counted directly from output/csv/drug.csv:
--     prod_ai  containing a backslash   343,753
--     drugname containing a backslash   147,673
-- A result of 0 means escape processing was still on and the load must be
-- redone. Anything else non-matching means the CSV changed.
SELECT SUM(INSTR(prod_ai,  '\\') > 0) AS prod_ai_with_backslash,
       SUM(INSTR(drugname, '\\') > 0) AS drugname_with_backslash,
       343753                           AS prod_ai_expected,
       147673                           AS drugname_expected
FROM   drug;

-- One concrete example, readable at a glance. prod_ai should come back as
-- 'EMPAGLIFLOZIN\METFORMIN HYDROCHLORIDE', not run together.
SELECT primaryid, drugname, prod_ai
FROM   drug
WHERE  drugname = 'SYNJARDY'
LIMIT  3;

-- 5.8 Physical size, for planning. drug should dominate.
SELECT table_name,
       table_rows                                              AS approx_rows,
       ROUND(data_length   / 1024 / 1024, 1)                   AS data_mb,
       ROUND(index_length  / 1024 / 1024, 1)                   AS index_mb,
       ROUND((data_length + index_length) / 1024 / 1024, 1)    AS total_mb
FROM   information_schema.tables
WHERE  table_schema = 'faers'
ORDER  BY data_length + index_length DESC;


-- ===========================================================================
-- APPENDIX - faster reload pattern, if the load ever becomes the bottleneck
-- ---------------------------------------------------------------------------
-- Secondary indexes are declared in 01_ddl.sql because that is where a reader
-- expects to find the physical design. The cost is that InnoDB maintains six
-- index trees while loading 6.3M drug rows.
--
-- If a reload needs to be faster, drop the secondary indexes first and
-- rebuild them afterwards - InnoDB sorts and bulk-builds an index far faster
-- than it maintains one row by row. The primary key stays, since dropping it
-- would rewrite the clustered table.
--
--   ALTER TABLE drug
--       DROP INDEX idx_drug_pid_seq,
--       DROP INDEX idx_drug_caseid,
--       DROP INDEX idx_drug_ai_role,
--       DROP INDEX idx_drug_role_pid,
--       DROP INDEX idx_drug_name,
--       DROP INDEX idx_drug_quarter;
--
--   -- ... run the drug LOAD DATA from section 3.3 ...
--
--   ALTER TABLE drug
--       ADD KEY idx_drug_pid_seq  (primaryid, drug_seq),
--       ADD KEY idx_drug_caseid   (caseid),
--       ADD KEY idx_drug_ai_role  (prod_ai(100), role_cod),
--       ADD KEY idx_drug_role_pid (role_cod, primaryid),
--       ADD KEY idx_drug_name     (drugname(60)),
--       ADD KEY idx_drug_quarter  (quarter);
--
-- Also worth checking before a large reload:
--   SELECT @@innodb_buffer_pool_size / 1024 / 1024 AS buffer_pool_mb;
-- The macOS default is 128 MB. Raising it to a few GB for the duration of the
-- load makes a larger difference than any of the above.
-- ===========================================================================

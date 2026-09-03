/*****************************************************************************
 * 01_import_clean.sas - FAERS import, DELETE filtering, and deduplication
 *
 * Purpose:  Phase 1 data pipeline. Imports all 7 FAERS tables across all 4
 *           quarters, removes retracted cases, deduplicates to one row per
 *           case, standardizes drug names, and writes QC reports.
 *
 * Inputs:   &RAW_PATH/<quarter folder>/ASCII/<TABLE><SUFFIX>.txt   (28 files)
 *           &RAW_PATH/<quarter folder>/Deleted/DELETE<SUFFIX>.txt  (4 files)
 *
 * Outputs:  CLEAN.DEMO DRUG REAC INDI OUTC THER RPSR   analytical datasets
 *           CLEAN.DELETED_CASES                        retracted caseid list
 *           &OUT_QC/qc_import_rowcounts.csv            Gate 1 evidence
 *           &OUT_QC/qc_clean_pipeline.csv              dedup / filter audit
 *           &OUT_QC/qc_field_widths.csv                field width review
 *
 * DQ coverage (CHARTER.md section 4):
 *   DQ1 DQ4 DQ5 DQ6  handled inside %import_faers_table
 *   DQ2  DELETE files - leading blank line filtered by the digits-only rule
 *   DQ7  duplicate caseid across quarters - resolved by the dedup step
 *
 * SETUP NOTE - read before the first run
 *   The quarter folders sit directly under &BASE (faers_ascii_2025q3/, ...),
 *   so &RAW_PATH is &BASE and no RAW libref is used - the raw ASCII is read
 *   through INFILE, not through a library. The preflight in section 2
 *   validates every path this program actually reads.
 *
 * Runtime:  roughly 15-30 minutes on SAS ODA for all 32 files.
 *
 * Author:   Hingling Yu
 * Created:  2026-09-02
 *****************************************************************************/

/*==========================================================================
  1. SETUP
  ==========================================================================*/

/* The only hard-coded path in the project. Everything else derives from
   &BASE, which 00_config.sas defines. */
%include "/home/u64291357/mydata/sas/00_config.sas";

%include "&SAS_PATH./macros/import_faers_table.sas";

/* 00_config.sas turns SYMBOLGEN and MPRINT on, which is useful when
   debugging a single macro call but produces an unreadable log across 32
   file imports. Turn them off for the batch, restore at the end. */
options nosymbolgen nomprint;

/* Storage: SAS ODA allows 5 GB and the raw ASCII alone is 1.4 GB. These
   datasets are dominated by blank-padded character fields (prod_ai is $500
   but most values are far shorter), which is exactly what RLE compression
   targets. COMPRESS=YES typically cuts these files by 70% or more at a small
   CPU cost. If space still runs short, switch to COMPRESS=BINARY - better
   ratio, roughly 3x slower to write. */
options compress=yes;


/*==========================================================================
  2. PREFLIGHT - fail before a 20-minute batch, not during it
  ==========================================================================*/
%macro preflight;
    %local i ok folder;
    %let ok = 1;

    %do i = 1 %to &N_QUARTERS;
        %let folder = &&Q&i._FOLDER;
        %if %sysfunc(fileexist(&RAW_PATH./&folder./ASCII)) = 0 %then %do;
            %put ERROR: Missing raw data folder: &RAW_PATH./&folder./ASCII;
            %let ok = 0;
        %end;
        %if %sysfunc(fileexist(&RAW_PATH./&folder./Deleted)) = 0 %then %do;
            %put ERROR: Missing Deleted folder: &RAW_PATH./&folder./Deleted;
            %let ok = 0;
        %end;
    %end;

    %if %sysfunc(libref(clean)) ne 0 %then %do;
        %put ERROR: Libref CLEAN is not assigned. Check &BASE./output/clean exists.;
        %let ok = 0;
    %end;

    %if &ok = 0 %then %do;
        %put ERROR: Preflight failed - nothing was imported. Fix the paths above.;
        %abort cancel;
    %end;

    %put NOTE: Preflight passed - all quarter folders and the CLEAN library found.;
%mend preflight;

%preflight


/*==========================================================================
  3. EXPECTED ROW COUNTS (Gate 1 reference)
  --------------------------------------------------------------------------
  Source of truth: CHARTER.md section 4, independently verified against the
  raw files with `wc -l` minus the header row. The import is compared against
  these numbers rather than eyeballed.
  ==========================================================================*/
data work.qc_expected;
    length table $8 quarter $6 expected_rows 8;
    infile datalines dlm=',' truncover;
    input table $ quarter $ expected_rows;
    datalines;
DEMO,2025Q3,438512
DEMO,2025Q4,385288
DEMO,2026Q1,397224
DEMO,2026Q2,422459
DRUG,2025Q3,2148451
DRUG,2025Q4,1815349
DRUG,2026Q1,1703210
DRUG,2026Q2,1627225
REAC,2025Q3,1535133
REAC,2025Q4,1349105
REAC,2026Q1,1330675
REAC,2026Q2,1394751
INDI,2025Q3,1310274
INDI,2025Q4,1168789
INDI,2026Q1,1139940
INDI,2026Q2,1124333
OUTC,2025Q3,343251
OUTC,2025Q4,289721
OUTC,2026Q1,291580
OUTC,2026Q2,303705
THER,2025Q3,514480
THER,2025Q4,454746
THER,2026Q1,404946
THER,2026Q2,326027
RPSR,2025Q3,11107
RPSR,2025Q4,10694
RPSR,2026Q1,11426
RPSR,2026Q2,11295
DELETE,2025Q3,4947
DELETE,2025Q4,4497
DELETE,2026Q1,6135
DELETE,2026Q2,4217
;
run;


/*==========================================================================
  4. DELETE FILES (DQ2)
  --------------------------------------------------------------------------
  Format: plain text, one caseid per line, no header, no delimiter. Three of
  the four files open with a line containing a single space character, so a
  naive line count over-reports by one. The digits-only rule below is what
  CHARTER DQ2 specifies.

  These are caseid values (8 digits), NOT primaryid. They are applied to DEMO
  before deduplication, so retracted cases never reach the child tables.
  ==========================================================================*/
%macro import_delete_file(qnum=);
    %local folder suffix qtr path dsid nobs rc;

    %let folder = &&Q&qnum._FOLDER;
    %let suffix = &&Q&qnum._SUFFIX;
    %let qtr    = %sysfunc(compress(&&Q&qnum._LABEL));
    %let path   = &RAW_PATH./&folder./Deleted/DELETE&suffix..txt;

    %if %sysfunc(fileexist(&path)) = 0 %then %do;
        %put ERROR: [import_delete_file] File not found: &path;
        %return;
    %end;

    data work.del_&suffix;
        length quarter $6 caseid 8 _raw $32;
        infile "&path" truncover lrecl=64;
        input _raw $32.;

        _raw = strip(compress(_raw, '090D0A'x));

        if _raw = '' then delete;                  /* the blank leading line */
        if notdigit(trim(_raw)) > 0 then delete;   /* keep digits-only lines */

        caseid = input(_raw, ?? best12.);
        if missing(caseid) then delete;

        quarter = "&qtr";
        keep quarter caseid;
    run;

    %let dsid = %sysfunc(open(work.del_&suffix));
    %let nobs = %sysfunc(attrn(&dsid, NLOBS));
    %let rc   = %sysfunc(close(&dsid));

    proc sql noprint;
        insert into work.qc_import
            set table = "DELETE", quarter = "&qtr",
                dataset = "WORK.DEL_&suffix", rows_read = &nobs, seconds = .;
    quit;

    %put NOTE: [import_delete_file] &qtr - &nobs valid case IDs.;
%mend import_delete_file;


/*==========================================================================
  5. IMPORT DRIVER
  ==========================================================================*/
%macro import_all;
    %local i j tbl setlist;

    /* QC accumulator, created up front so DELETE rows can append to it */
    data work.qc_import;
        length table $8 quarter $6 dataset $41 rows_read 8 seconds 8;
        stop;
    run;

    /* --- 5a. DELETE files: import, stack, dedupe across quarters ---------
       A case retracted in one quarter stays retracted, so the union of all
       four files is the exclusion list. Cross-quarter repeats are expected
       and are removed by NODUPKEY. */
    %let setlist =;
    %do i = 1 %to &N_QUARTERS;
        %import_delete_file(qnum=&i)
        %let setlist = &setlist work.del_&&Q&i._SUFFIX;
    %end;

    data work.deleted_all;
        set &setlist;
    run;

    proc sort data=work.deleted_all out=clean.deleted_cases(keep=caseid) nodupkey;
        by caseid;
    run;

    proc datasets library=work nolist;
        delete deleted_all %do i = 1 %to &N_QUARTERS; del_&&Q&i._SUFFIX %end;;
    quit;

    /* --- 5b. DEMO first: it defines which reports survive ---------------- */
    %let setlist =;
    %do i = 1 %to &N_QUARTERS;
        %import_faers_table(table=DEMO, qnum=&i, qc=work.qc_import)
        %let setlist = &setlist work.DEMO_&&Q&i._SUFFIX;
    %end;

    data work.demo_all;
        set &setlist;
    run;

    proc datasets library=work nolist;
        delete %do i = 1 %to &N_QUARTERS; DEMO_&&Q&i._SUFFIX %end;;
    quit;

    /* --- 5c. Child tables: import and stack one table at a time, so peak
           WORK usage stays near the size of the largest single table ------ */
    %do j = 1 %to 6;
        %let tbl = %scan(DRUG REAC INDI OUTC THER RPSR, &j);
        %let setlist =;

        %do i = 1 %to &N_QUARTERS;
            %import_faers_table(table=&tbl, qnum=&i, qc=work.qc_import)
            %let setlist = &setlist work.&tbl._&&Q&i._SUFFIX;
        %end;

        data work.&tbl._all;
            set &setlist;

            %if &tbl = DRUG %then %do;
                /* Drug name standardization. Done in place rather than into
                   new columns: prod_ai is $500 and duplicating it across
                   7.3M rows is real storage against a 5 GB quota. The import
                   macro has already stripped whitespace and control chars,
                   so UPCASE is all that remains. */
                prod_ai  = upcase(prod_ai);
                drugname = upcase(drugname);
            %end;
        run;

        proc datasets library=work nolist;
            delete %do i = 1 %to &N_QUARTERS; &tbl._&&Q&i._SUFFIX %end;;
        quit;
    %end;

%mend import_all;

%import_all


/*==========================================================================
  6. CLEANING - remove retracted cases, then deduplicate
  --------------------------------------------------------------------------
  FAERS ships one row per report VERSION, not per case. A case revised in a
  later quarter appears again with a higher caseversion, and 2026Q2 even
  carries two versions of caseid 26012757 within a single quarter (DQ7).

  Rule: keep the highest caseversion per caseid. Ties break on the later
  fda_dt, then the higher primaryid, so the result is deterministic and does
  not depend on input order.
  ==========================================================================*/

/* --- 6a. Drop retracted cases (DQ2) --------------------------------------
   Hash lookup rather than NOT IN: one pass over 1.6M DEMO rows against a
   ~20K key set, and no risk of PROC SQL re-evaluating the subquery. */
data work.demo_live;
    if _n_ = 1 then do;
        declare hash del(dataset: 'clean.deleted_cases');
        del.definekey('caseid');
        del.definedone();
    end;
    set work.demo_all;
    if del.check() ne 0;      /* keep rows NOT on the retraction list */
run;

/* --- 6b. Deduplicate to one row per case (DQ7) ---------------------------*/
proc sort data=work.demo_live;
    by caseid descending caseversion descending fda_dt descending primaryid;
run;

data clean.demo;
    set work.demo_live;
    by caseid;
    if first.caseid;
run;

/* --- 6c. Surviving report keys -------------------------------------------
   Child tables join on primaryid. Filtering them to the primaryids that
   survived in DEMO applies the DELETE exclusion and the dedup in one step,
   and also drops orphan child rows whose parent report is absent. */
proc sql noprint;
    create table work.keep_pid as
        select primaryid from clean.demo;
quit;

/* --- 6d. Filter each child table -----------------------------------------
   A hash lookup keeps this to one pass over each child table. The key set is
   about 1.3M 8-byte numerics, so the hash needs roughly 150 MB - comfortable
   on SAS ODA. If MEMSIZE is ever exceeded, replace with a sort of the child
   table by primaryid and a merge against work.keep_pid. */
%macro filter_children;
    %local j tbl;
    %do j = 1 %to 6;
        %let tbl = %scan(DRUG REAC INDI OUTC THER RPSR, &j);

        data clean.&tbl;
            if _n_ = 1 then do;
                declare hash pid(dataset: 'work.keep_pid');
                pid.definekey('primaryid');
                pid.definedone();
            end;
            set work.&tbl._all;
            if pid.check() = 0;
        run;

        proc datasets library=work nolist;
            delete &tbl._all;
        quit;
    %end;
%mend filter_children;

%filter_children

proc datasets library=work nolist;
    delete demo_all demo_live;
quit;


/*==========================================================================
  7. QC REPORT 1 - import row counts vs expected (Gate 1)
  ==========================================================================*/

/* The bulk data is written. Everything below is small QC tables, where RLE
   compression costs more overhead than it saves. */
options compress=no;

proc sql;
    create table work.qc_rowcounts as
        select  coalesce(e.table, a.table)     as table    length=8,
                coalesce(e.quarter, a.quarter) as quarter  length=6,
                e.expected_rows,
                a.rows_read                    as imported_rows,
                a.rows_read - e.expected_rows  as difference,
                case
                    when a.rows_read is null            then 'MISSING'
                    when a.rows_read = e.expected_rows  then 'PASS'
                    else 'FAIL'
                end                            as status   length=7,
                a.seconds
        from      work.qc_expected as e
        full join work.qc_import   as a
               on e.table = a.table and e.quarter = a.quarter
        order by table, quarter;
quit;


/*==========================================================================
  8. QC REPORT 2 - character field widths
  --------------------------------------------------------------------------
  Lists every character field whose longest surviving value reaches its
  declared length. This is a REVIEW list, not a pass/fail test, because
  several fields legitimately sit at their cap:

    - FDA truncates at the source: lit_ref and prod_ai at 500, drugname at
      255, dose_vbm at 300, auth_num / mfr_num / mfr_sndr at 70.
    - Short code fields are full by nature: outc_cod $2 holds 'DE', role_cod
      $2 holds 'PS', rpsr_cod $3 holds 'CSM'.

  What matters is a field appearing here that is NOT on that list - that
  would mean the import truncated real data. The declared lengths came from
  a full scan of the raw text before any SAS code was written, so nothing
  unexpected should show up.
  ==========================================================================*/
%macro check_field_widths;
    %local j tbl nchar maxlist;

    data work.qc_widths;
        length table $8 variable $32 declared_len 8 max_used 8;
        stop;
    run;

    %do j = 1 %to 7;
        %let tbl = %scan(DEMO DRUG REAC INDI OUTC THER RPSR, &j);

        proc contents data=clean.&tbl out=work._c(keep=name type length) noprint;
        run;

        proc sql noprint;
            select count(*) into :nchar trimmed
                from work._c where type = 2;
        quit;

        %if &nchar > 0 %then %do;
            /* Builds one aggregate per character column:
                   max(lengthn(age_cod)) as age_cod, ...

               CATX, not CATS: CATS strips leading AND trailing blanks from
               every argument including the literals, so cats('... as ', name)
               emits "as age_cod" as "asage_cod" - an invalid token that makes
               the CREATE TABLE below fail with a syntax error. CATX inserts
               its own delimiter between the pieces, so the keyword AS always
               stands alone.

               LENGTHN, not LENGTH: LENGTH returns 1 for an all-blank value,
               which would overstate usage on empty columns. */
            proc sql noprint;
                select catx(' ', cats('max(lengthn(', name, '))'), 'as', name)
                    into :maxlist separated by ', '
                    from work._c where type = 2;
            quit;

            /* _m is rebuilt per table. Dropping it first means a failed
               query cannot leave the previous table's results in place for
               the transpose to pick up and silently mislabel. */
            proc datasets library=work nolist nowarn;
                delete _m _mt;
            quit;

            proc sql;
                create table work._m as select &maxlist from clean.&tbl;
            quit;

            /* One clear message beats the 20-line cascade that PROC TRANSPOSE
               and the INSERT produce when _m is missing. */
            %if %sysfunc(exist(work._m)) = 0 %then %do;
                %put ERROR: [check_field_widths] Width query failed for &tbl - table skipped.;
            %end;
            %else %do;
                proc transpose data=work._m
                               out=work._mt(rename=(col1=max_used)) name=variable;
                run;

                proc sql;
                    insert into work.qc_widths
                        select "&tbl", t.variable, c.length, t.max_used
                        from work._mt as t
                            inner join work._c as c
                                on upcase(t.variable) = upcase(c.name)
                        where t.max_used >= c.length;
                quit;
            %end;
        %end;
    %end;

    proc datasets library=work nolist nowarn;
        delete _c _m _mt;
    quit;
%mend check_field_widths;

%check_field_widths


/*==========================================================================
  9. QC REPORT 3 - cleaning pipeline audit
  --------------------------------------------------------------------------
  For DEMO, rows_removed is retractions plus deduplication - the "dedup rate"
  Gate 1 expects to land in the 5-15 pct band. For the child tables it is the
  number of rows whose parent report did not survive, plus any orphans.
  ==========================================================================*/
%macro pipeline_audit;
    %local j tbl imp fin;

    data work.qc_pipeline;
        length table $8 rows_imported 8 rows_final 8 rows_removed 8 pct_removed 8;
        stop;
    run;

    %do j = 1 %to 7;
        %let tbl = %scan(DEMO DRUG REAC INDI OUTC THER RPSR, &j);

        proc sql noprint;
            select sum(expected_rows) into :imp trimmed
                from work.qc_expected where table = "&tbl";
            select count(*) into :fin trimmed
                from clean.&tbl;
        quit;

        proc sql;
            insert into work.qc_pipeline
                set table         = "&tbl",
                    rows_imported = &imp,
                    rows_final    = &fin,
                    rows_removed  = %eval(&imp - &fin),
                    pct_removed   = %sysevalf(100 * (&imp - &fin) / &imp);
        quit;
    %end;
%mend pipeline_audit;

%pipeline_audit


/*==========================================================================
  10. EXPORT QC + CONSOLE SUMMARY
  ==========================================================================*/
proc export data=work.qc_rowcounts
            outfile="&OUT_QC./qc_import_rowcounts.csv" dbms=csv replace;
run;

proc export data=work.qc_pipeline
            outfile="&OUT_QC./qc_clean_pipeline.csv" dbms=csv replace;
run;

proc export data=work.qc_widths
            outfile="&OUT_QC./qc_field_widths.csv" dbms=csv replace;
run;

title2 "Gate 1 - import row counts vs expected";
proc print data=work.qc_rowcounts noobs label;
    var table quarter expected_rows imported_rows difference status seconds;
    format expected_rows imported_rows comma12. seconds 8.1;
run;

title2 "Gate 1 - cleaning pipeline (DEMO reduction should land in 5-15 pct)";
proc print data=work.qc_pipeline noobs label;
    format rows_imported rows_final rows_removed comma12. pct_removed 6.2;
run;

title2 "Review - character fields at their declared length (see section 8)";
proc print data=work.qc_widths noobs label;
run;
title2;

/* Fail loudly if any file did not match its expected row count. The field
   width report is informational and deliberately not part of this verdict. */
%macro gate1_verdict;
    %local nfail;
    proc sql noprint;
        select count(*) into :nfail trimmed
            from work.qc_rowcounts where status ne 'PASS';
    quit;

    %put NOTE: ==========================================================;
    %if &nfail = 0 %then %do;
        %put NOTE: GATE 1 ROW COUNTS PASSED - all 32 files match expected.;
        %put NOTE: Now review the dedup rate and the field width report.;
    %end;
    %else %do;
        %put ERROR: GATE 1 FAILED - &nfail table/quarter counts do not match.;
        %put ERROR- See &OUT_QC./qc_import_rowcounts.csv;
    %end;
    %put NOTE: ==========================================================;
%mend gate1_verdict;

%gate1_verdict

/* Restore the debugging options that 00_config.sas set */
options symbolgen mprint;

%put NOTE: 01_import_clean.sas complete. Clean datasets are in the CLEAN library.;

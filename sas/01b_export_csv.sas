/*****************************************************************************
 * 01b_export_csv.sas - Export CLEAN datasets to CSV for the MySQL warehouse
 *
 * Purpose:  Bridge between the SAS analytical layer and the MySQL reporting
 *           layer. Writes one CSV per CLEAN dataset with a pinned column
 *           order that matches sql/01_ddl.sql exactly, so sql/02_load.sql can
 *           LOAD DATA without a per-column mapping that drifts over time.
 *
 * Inputs:   CLEAN.DEMO DRUG REAC INDI OUTC THER RPSR DELETED_CASES
 *           (produced by 01_import_clean.sas)
 *
 * Outputs:  &BASE/output/csv/<table>.csv   one header row + data
 *           &OUT_QC/qc_csv_export.csv      rows and bytes written per table
 *
 * Manual step after this program:
 *   Download the CSVs from SAS Studio to the local repo, then run
 *   sql/02_load.sql. See the STORAGE section below before running.
 *
 * -----------------------------------------------------------------------
 * STORAGE - read this first
 * -----------------------------------------------------------------------
 *   SAS ODA allows 5 GB. The raw ASCII (~1.4 GB) and the compressed CLEAN
 *   library already occupy most of it, and the full CSV set is roughly
 *   2.2 GB uncompressed - DRUG alone is around 1.2 GB. Exporting everything
 *   in one run will very likely hit the quota.
 *
 *   Recommended: run in batches, downloading and deleting between them.
 *
 *     Batch 1  %export_clean_csv(tables=DEMO OUTC RPSR DELETED_CASES)
 *     Batch 2  %export_clean_csv(tables=REAC INDI THER)
 *     Batch 3  %export_clean_csv(tables=DRUG)
 *
 *   After downloading a batch, delete the files from
 *   &BASE/output/csv in the SAS Studio file browser before the next batch.
 *
 * -----------------------------------------------------------------------
 * CSV CONTRACT (must stay in sync with sql/01_ddl.sql)
 * -----------------------------------------------------------------------
 *   Delimiter        ,
 *   Quoting          PROC EXPORT quotes only values containing , or "
 *   Header           yes, one row (MySQL side uses IGNORE 1 LINES)
 *   Line ending      LF (SAS ODA is Linux)
 *   Missing numeric  empty field -> MySQL side maps with NULLIF(@v,'')
 *   Missing char     empty field -> same treatment
 *   Dates            YYYY-MM-DD via YYMMDD10., directly castable to MySQL DATE
 *   IDs              BEST16. so a 12-13 digit primaryid never renders in
 *                    scientific notation, which BEST12. would do
 *   Backslash        DATA, not an escape character. FAERS separates the
 *                    active ingredients of a combination product with it
 *                    ('EMPAGLIFLOZIN\METFORMIN HYDROCHLORIDE'), and 344,323
 *                    DRUG rows carry one. The MySQL side must therefore load
 *                    with ESCAPED BY '' - see sql/02_load.sql section 3. At
 *                    the MySQL default those backslashes are eaten and, where
 *                    a quoted value ends in one, whole rows are lost.
 *
 * Author:   Hingling Yu
 * Created:  2026-09-03
 *****************************************************************************/

%include "/home/u64291357/mydata/sas/00_config.sas";

/* One CSV export is a single long-running step; the macro trace from
   00_config.sas adds nothing here and buries the row counts. */
options nosymbolgen nomprint;


/*==========================================================================
  1. OUTPUT DIRECTORY

  SAS ODA runs with XCMD disabled, so there is no shelling out to mkdir.
  DCREATE is the supported in-language equivalent and is a no-op when the
  directory already exists.
  ==========================================================================*/
%let CSV_PATH = &BASE./output/csv;

%macro _ensure_csv_dir;
    %local rc;
    %if %sysfunc(fileexist(&CSV_PATH)) = 0 %then %do;
        %let rc = %sysfunc(dcreate(csv, &BASE./output));
        %if %length(&rc) = 0 %then %do;
            %put ERROR: Could not create &CSV_PATH - create it in the SAS Studio file browser.;
            %abort cancel;
        %end;
        %put NOTE: Created &CSV_PATH;
    %end;
    %else %put NOTE: Using existing &CSV_PATH;
%mend _ensure_csv_dir;

%_ensure_csv_dir


/*==========================================================================
  2. COLUMN CONTRACT

  Column order is declared once, here, and is the single source of truth
  shared with sql/01_ddl.sql. The order is deliberate rather than the SAS
  PDV order: keys first, then the source quarter, then the payload. That
  makes the DDL readable and makes a mismatch obvious on inspection.

  NVARS is asserted after each view is built. If a future change to the
  import macro adds or drops a column, this program stops instead of
  silently writing a CSV whose shape no longer matches the DDL.
  ==========================================================================*/
%macro _cols(tbl);
%if       &tbl = DEMO %then %do;
primaryid caseid caseversion quarter i_f_code rept_cod auth_num mfr_num
mfr_sndr lit_ref age age_cod age_grp sex e_sub wt wt_cod to_mfr occp_cod
reporter_country occr_country event_dt mfr_dt init_fda_dt fda_dt rept_dt
event_dt_prec mfr_dt_prec init_fda_dt_prec fda_dt_prec rept_dt_prec
%end;
%else %if &tbl = DRUG %then %do;
primaryid caseid drug_seq quarter role_cod drugname prod_ai val_vbm route
dose_vbm cum_dose_chr cum_dose_unit dechal rechal lot_num nda_num dose_amt
dose_unit dose_form dose_freq exp_dt exp_dt_prec
%end;
%else %if &tbl = REAC %then %do;
primaryid caseid quarter pt drug_rec_act
%end;
%else %if &tbl = INDI %then %do;
primaryid caseid indi_drug_seq quarter indi_pt
%end;
%else %if &tbl = OUTC %then %do;
primaryid caseid quarter outc_cod
%end;
%else %if &tbl = THER %then %do;
primaryid caseid dsg_drug_seq quarter start_dt end_dt dur dur_cod
start_dt_prec end_dt_prec
%end;
%else %if &tbl = RPSR %then %do;
primaryid caseid quarter rpsr_cod
%end;
%else %if &tbl = DELETED_CASES %then %do;
caseid
%end;
%mend _cols;

/* Expected column count per table - the assertion target */
%macro _ncols(tbl);
%if       &tbl = DEMO          %then %do; 31 %end;
%else %if &tbl = DRUG          %then %do; 22 %end;
%else %if &tbl = REAC          %then %do;  5 %end;
%else %if &tbl = INDI          %then %do;  5 %end;
%else %if &tbl = OUTC          %then %do;  4 %end;
%else %if &tbl = THER          %then %do; 10 %end;
%else %if &tbl = RPSR          %then %do;  4 %end;
%else %if &tbl = DELETED_CASES %then %do;  1 %end;
%else %do; 0 %end;
%mend _ncols;


/*==========================================================================
  3. EXPORT MACRO
  --------------------------------------------------------------------------
  Parameters
    tables   Space-separated list of CLEAN datasets to export.
             Default is all eight. See the STORAGE note in the header for
             why you probably want to pass a subset.
    outdir   Optional override for &CSV_PATH.
  ==========================================================================*/
%macro export_clean_csv(tables=DEMO DRUG REAC INDI OUTC THER RPSR DELETED_CASES,
                        outdir=);

    %local i tbl nt collist want dsid nvar nobs rc t0 elapsed path;

    %if %length(&outdir) = 0 %then %let outdir = &CSV_PATH;

    /* Export log, created once per session and appended across batches, so
       a three-batch run still produces one complete QC report at the end. */
    %if %sysfunc(exist(work.csv_export_log)) = 0 %then %do;
        data work.csv_export_log;
            length table $16 csv_file $64 rows 8 columns 8 seconds 8;
            stop;
        run;
    %end;

    %let nt = %sysfunc(countw(&tables));

    %do i = 1 %to &nt;
        %let tbl = %upcase(%scan(&tables, &i));

        %if %sysfunc(exist(clean.&tbl)) = 0 %then %do;
            %put ERROR: [export_clean_csv] CLEAN.&tbl does not exist - skipped.;
            %put ERROR- Run 01_import_clean.sas first.;
        %end;
        %else %do;

            %let collist = %_cols(&tbl);
            %let want    = %_ncols(&tbl);
            %let t0      = %sysfunc(datetime());

            /*--------------------------------------------------------------
              A DATA STEP VIEW, not a physical copy: the CSV is already the
              second copy of the data and the quota has no room for a third.
              RETAIN before SET is the idiomatic way to pin column order -
              the SET overwrites every value on each iteration, so RETAIN
              here does nothing except fix the position in the PDV.
            --------------------------------------------------------------*/
            data work._exp_&tbl / view=work._exp_&tbl;
                retain &collist;
                set clean.&tbl;
                keep &collist;

                /* BEST16. not the BEST12. default: primaryid runs to 12-13
                   digits and BEST12. would emit 2.50701E11, which MySQL
                   would then load as a truncated or NULL BIGINT.
                   DELETED_CASES is the one table with no primaryid, so its
                   FORMAT is written separately rather than guarded inline. */
                %if &tbl = DELETED_CASES %then %do;
                    format caseid best16.;
                %end;
                %else %do;
                    format primaryid caseid best16.;
                    %if &tbl = DEMO %then %do; format caseversion   best16.; %end;
                    %if &tbl = DRUG %then %do; format drug_seq      best16.; %end;
                    %if &tbl = INDI %then %do; format indi_drug_seq best16.; %end;
                    %if &tbl = THER %then %do; format dsg_drug_seq  best16.; %end;
                %end;
            run;

            /*--------------------------------------------------------------
              Shape assertion - the contract check described in section 2.
            --------------------------------------------------------------*/
            %let dsid = %sysfunc(open(work._exp_&tbl));
            %let nvar = %sysfunc(attrn(&dsid, NVARS));
            %let rc   = %sysfunc(close(&dsid));

            %if &nvar ne &want %then %do;
                %put ERROR: [export_clean_csv] &tbl column count is &nvar, expected &want..;
                %put ERROR- CLEAN.&tbl no longer matches the CSV contract in section 2.;
                %put ERROR- Update the _cols and _ncols macros AND sql/01_ddl.sql together, then rerun.;
            %end;
            %else %do;

                %let path = &outdir./%lowcase(&tbl).csv;
                %put NOTE: [export_clean_csv] &tbl -> &path;

                proc export data=work._exp_&tbl
                            outfile="&path"
                            dbms=csv replace;
                    putnames=yes;
                run;

                %let dsid    = %sysfunc(open(clean.&tbl));
                %let nobs    = %sysfunc(attrn(&dsid, NLOBS));
                %let rc      = %sysfunc(close(&dsid));
                %let elapsed = %sysfunc(round(%sysevalf(%sysfunc(datetime()) - &t0), 0.1));

                proc sql noprint;
                    insert into work.csv_export_log
                        set table    = "&tbl",
                            csv_file = "%lowcase(&tbl).csv",
                            rows     = &nobs,
                            columns  = &nvar,
                            seconds  = &elapsed;
                quit;

                %put NOTE: [export_clean_csv] &tbl done - &nobs rows, &nvar cols, &elapsed.s;
            %end;

            proc datasets library=work nolist nowarn;
                delete _exp_&tbl / memtype=view;
            quit;

        %end;
    %end;

%mend export_clean_csv;


/*==========================================================================
  4. RUN

  Default is all eight tables. To run the batched plan from the header,
  comment this out and uncomment one batch at a time.
  ==========================================================================*/
%export_clean_csv

/* %export_clean_csv(tables=DEMO OUTC RPSR DELETED_CASES) */
/* %export_clean_csv(tables=REAC INDI THER)               */
/* %export_clean_csv(tables=DRUG)                         */


/*==========================================================================
  5. QC - rows and bytes written

  File size is read in a DATA step rather than through %SYSFUNC: FINFO's
  option name is the literal string 'File Size (bytes)', whose embedded
  parentheses are awkward to pass through the macro parser but trivial to
  quote in DATA step syntax.
  ==========================================================================*/
data work.qc_csv_export;
    set work.csv_export_log;
    length path $256;
    path = "&CSV_PATH./" || strip(csv_file);

    rc  = filename('_csvf', path);
    fid = fopen('_csvf');
    if fid > 0 then do;
        bytes = input(finfo(fid, 'File Size (bytes)'), best32.);
        rc    = fclose(fid);
    end;
    else bytes = .;
    rc = filename('_csvf');

    mb = bytes / (1024 * 1024);
    drop rc fid path;
    format rows comma12. bytes comma16. mb comma10.1 seconds 8.1;
    label rows    = 'Rows'
          columns = 'Columns'
          bytes   = 'Bytes'
          mb      = 'MB'
          seconds = 'Seconds';
run;

proc export data=work.qc_csv_export
            outfile="&OUT_QC./qc_csv_export.csv" dbms=csv replace;
run;

title2 "CSV export for MySQL load";
proc print data=work.qc_csv_export noobs label;
    var table csv_file rows columns mb seconds;
    sum mb;
run;
title2;

/*==========================================================================
  6. EXPECTED ROW COUNTS (cross-check against section 5 output)
  --------------------------------------------------------------------------
    DEMO             1,529,536      OUTC             1,127,292
    DRUG             6,299,773      THER             1,486,320
    REAC             4,983,301      RPSR                44,521
    INDI             4,206,546      DELETED_CASES   union of the 4 DELETE
                                                    files, deduplicated
  These same numbers are asserted again on the MySQL side by the
  verification block at the end of sql/02_load.sql.
  ==========================================================================*/

options symbolgen mprint;

%put NOTE: 01b_export_csv.sas complete. Download &CSV_PATH. then run sql/02_load.sql.;

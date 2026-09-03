/*****************************************************************************
 * macros/import_faers_table.sas - Reusable FAERS ASCII import macro
 *
 * Purpose:  Import any one FAERS table for any one quarter from the raw
 *           $-delimited ASCII extract into a SAS dataset, applying the
 *           data-quality fixes documented in CHARTER.md section 4.
 *
 * Requires: 00_config.sas must be %include-d first (uses &RAW_PATH and the
 *           Q1..Q4 _FOLDER / _SUFFIX / _LABEL macro variables).
 *
 * DQ handling implemented here:
 *   DQ1  CRLF in DRUG  -> all character variables are stripped of CR/LF
 *   DQ4  Partial dates -> 8/6/4-digit dates parsed, precision flag retained
 *   DQ5  Empty = ''    -> DSD maps empty fields to missing (. for numeric)
 *   DQ6  Embedded TABs -> stripped from all character variables
 *
 * DQ2 (DELETE files) and DQ7 (dedup) are handled in 01_import_clean.sas,
 * because they operate across tables rather than within a single file.
 *
 * Author:   Hingling Yu
 * Created:  2026-09-02
 *****************************************************************************/


/*==========================================================================
  HELPER: %_faers_parse_dt - partial-date parser (DQ4)
  --------------------------------------------------------------------------
  FAERS dates are YYYYMMDD strings, but incomplete dates occur: YYYYMM and
  YYYY. Verified distribution across all 4 quarters (22M rows):

      THER.start_dt : 1,123,888 x 8-digit | 282,894 x 6-digit
                        129,041 x 4-digit | 164,376 empty
      THER.end_dt   :   600,775 x 8-digit |  87,822 x 6-digit
                         48,756 x 4-digit | 962,846 empty
      DEMO dates and DRUG.exp_dt : 8-digit or empty only

  Rule (CHARTER DQ4): 8 -> exact date, 6 -> first of month,
                      4 -> first of year, anything else -> missing.

  Imputing to the first of the period is the conservative PV convention: it
  never invents a date later than the reported period. The companion
  <var>_prec flag records what was actually reported, so downstream duration
  or latency calculations can exclude imputed values.

      D   = day known
      M   = month known, day imputed
      Y   = year known, month and day imputed
      X   = present but unparseable (e.g. an impossible date like 20250230)
      ' ' = not reported

  Usage:  %_faers_parse_dt(event_dt)
          reads character event_dt_c, writes numeric event_dt + event_dt_prec
  ==========================================================================*/
%macro _faers_parse_dt(var);
    select (lengthn(&var._c));
        when (8) do;
            &var       = input(&var._c, ?? yymmdd8.);
            &var._prec = 'D';
        end;
        when (6) do;
            &var       = input(cats(&var._c, '01'), ?? yymmdd8.);
            &var._prec = 'M';
        end;
        when (4) do;
            &var       = input(cats(&var._c, '0101'), ?? yymmdd8.);
            &var._prec = 'Y';
        end;
        otherwise do;
            &var       = .;
            &var._prec = ' ';
        end;
    end;
    /* Present in the source but not a valid date - flag it, do not hide it */
    if missing(&var) and lengthn(&var._c) > 0 then &var._prec = 'X';
%mend _faers_parse_dt;


/*==========================================================================
  MAIN MACRO: %import_faers_table
  --------------------------------------------------------------------------
  Parameters
    table     Required. One of DEMO DRUG REAC INDI OUTC THER RPSR.
    qnum      Required. Quarter index 1-4 as defined in 00_config.sas
              (1 = 2025q3, 2 = 2025q4, 3 = 2026q1, 4 = 2026q2).
    out       Optional. Output dataset. Default WORK.<table>_<suffix>,
              e.g. WORK.DEMO_25Q3.
    raw_root  Optional. Overrides &RAW_PATH for a non-standard layout.
    qc        Optional. QC accumulator dataset; one row is appended per call
              (table, quarter, rows read, elapsed seconds).
              Default WORK.QC_IMPORT.

  Example
    %import_faers_table(table=DEMO, qnum=1);
    %import_faers_table(table=DRUG, qnum=3, out=work.drug_26q1);
  ==========================================================================*/
%macro import_faers_table(table=, qnum=, out=, raw_root=, qc=work.qc_import);

    %local tbl folder suffix qtr qlabel path dsid nobs rc t0 elapsed;

    /*----------------------------------------------------------------------
      1. Validate parameters - fail loudly and early rather than producing a
         silently empty dataset 20 minutes into a batch run.
      ----------------------------------------------------------------------*/
    %let tbl = %upcase(&table);

    %if %length(&tbl) = 0 or %length(&qnum) = 0 %then %do;
        %put ERROR: [import_faers_table] TABLE= and QNUM= are both required.;
        %return;
    %end;

    %if %sysfunc(indexw(DEMO DRUG REAC INDI OUTC THER RPSR, &tbl)) = 0 %then %do;
        %put ERROR: [import_faers_table] Unknown table "&tbl".;
        %put ERROR- Valid values: DEMO DRUG REAC INDI OUTC THER RPSR.;
        %return;
    %end;

    %if %sysfunc(indexw(1 2 3 4, &qnum)) = 0 %then %do;
        %put ERROR: [import_faers_table] QNUM must be 1, 2, 3 or 4 (got "&qnum").;
        %return;
    %end;

    /*----------------------------------------------------------------------
      2. Resolve paths from the quarter macro variables in 00_config.sas.
         &&Q&qnum._LABEL is "2025 Q3"; compressing the blank gives a compact
         6-character key ("2025Q3") that sorts chronologically and is safe to
         use as a BY variable and in exported file names.
      ----------------------------------------------------------------------*/
    %let folder = &&Q&qnum._FOLDER;
    %let suffix = &&Q&qnum._SUFFIX;
    %let qlabel = &&Q&qnum._LABEL;
    %let qtr    = %sysfunc(compress(&qlabel));

    %if %length(&raw_root) = 0 %then %let raw_root = &RAW_PATH;
    %if %length(&out)      = 0 %then %let out      = work.&tbl._&suffix;

    %let path = &raw_root./&folder./ASCII/&tbl.&suffix..txt;

    %if %sysfunc(fileexist(&path)) = 0 %then %do;
        %put ERROR: [import_faers_table] File not found:;
        %put ERROR- &path;
        %put ERROR- Check &&RAW_PATH and that the quarter folder was uploaded.;
        %return;
    %end;

    %put NOTE: [import_faers_table] &tbl / &qlabel -> &out;
    %let t0 = %sysfunc(datetime());

    /*----------------------------------------------------------------------
      3. Read the file.

         INFILE options and why each one is needed:
           dlm='$'    FAERS field delimiter.
           dsd        Consecutive delimiters ($$) become missing instead of
                      being collapsed. This is what implements DQ5.
                      Safe here: a full scan of all 28 files found zero
                      double-quote characters, so DSD quote handling cannot
                      mis-parse a field.
           truncover  A short final field reads as-is instead of pulling in
                      the next line. Needed because REAC and THER rows
                      legitimately end on an empty field.
           firstobs=2 Skip the header row.
           lrecl=2000 Longest observed line is 769 bytes (DRUG); 2000 leaves
                      headroom without wasting buffer space.

         Character lengths below come from a full scan of all 4 quarters (max
         observed width) plus modest headroom, so a future quarter does not
         truncate. Gate 1 requires zero truncated fields.
      ----------------------------------------------------------------------*/
    data &out;

        length quarter $6;

        %if &tbl = DEMO %then %do;
            length
                primaryid        8    caseid           8    caseversion      8
                i_f_code        $1
                event_dt_c      $8    mfr_dt_c        $8    init_fda_dt_c   $8
                fda_dt_c        $8    rept_dt_c       $8
                rept_cod        $5    auth_num       $70    mfr_num        $70
                mfr_sndr       $70    lit_ref       $500
                age              8    age_cod         $3    age_grp         $1
                sex             $1    e_sub           $1    wt               8
                wt_cod          $3    to_mfr          $1    occp_cod        $2
                reporter_country $25  occr_country    $5
                event_dt         8    mfr_dt           8    init_fda_dt      8
                fda_dt           8    rept_dt          8
                event_dt_prec   $1    mfr_dt_prec     $1    init_fda_dt_prec $1
                fda_dt_prec     $1    rept_dt_prec    $1
            ;
            infile "&path" dlm='$' dsd truncover firstobs=2 lrecl=2000;
            input
                primaryid        : best12.
                caseid           : best12.
                caseversion      : best12.
                i_f_code         : $1.
                event_dt_c       : $8.
                mfr_dt_c         : $8.
                init_fda_dt_c    : $8.
                fda_dt_c         : $8.
                rept_cod         : $5.
                auth_num         : $70.
                mfr_num          : $70.
                mfr_sndr         : $70.
                lit_ref          : $500.
                age              : best12.
                age_cod          : $3.
                age_grp          : $1.
                sex              : $1.
                e_sub            : $1.
                wt               : best12.
                wt_cod           : $3.
                rept_dt_c        : $8.
                to_mfr           : $1.
                occp_cod         : $2.
                reporter_country : $25.
                occr_country     : $5.
            ;
        %end;

        %else %if &tbl = DRUG %then %do;
            /* DQ1 lives here: this file is CRLF, so every row - and the
               header - carries a trailing CR on dose_freq. The character
               scrub in step 4 removes it. */
            length
                primaryid        8    caseid           8    drug_seq         8
                role_cod        $2    drugname      $255    prod_ai       $500
                val_vbm         $1    route          $50    dose_vbm      $300
                cum_dose_chr   $10    cum_dose_unit  $10
                dechal          $1    rechal          $1    lot_num        $40
                exp_dt_c        $8    nda_num        $20    dose_amt         8
                dose_unit      $10    dose_form      $70    dose_freq      $12
                exp_dt           8    exp_dt_prec     $1
            ;
            infile "&path" dlm='$' dsd truncover firstobs=2 lrecl=2000;
            input
                primaryid        : best12.
                caseid           : best12.
                drug_seq         : best12.
                role_cod         : $2.
                drugname         : $255.
                prod_ai          : $500.
                val_vbm          : $1.
                route            : $50.
                dose_vbm         : $300.
                cum_dose_chr     : $10.
                cum_dose_unit    : $10.
                dechal           : $1.
                rechal           : $1.
                lot_num          : $40.
                exp_dt_c         : $8.
                nda_num          : $20.
                dose_amt         : best12.
                dose_unit        : $10.
                dose_form        : $70.
                dose_freq        : $12.
            ;
            /* nda_num stays CHARACTER on purpose: values such as "022122"
               carry a meaningful leading zero that a numeric read destroys.
               cum_dose_chr also stays character, matching the FDA spec name,
               even though all 129,270 populated values scanned as numeric. */
        %end;

        %else %if &tbl = REAC %then %do;
            length primaryid 8 caseid 8 pt $100 drug_rec_act $100;
            infile "&path" dlm='$' dsd truncover firstobs=2 lrecl=2000;
            input primaryid : best12. caseid : best12.
                  pt : $100. drug_rec_act : $100.;
        %end;

        %else %if &tbl = INDI %then %do;
            length primaryid 8 caseid 8 indi_drug_seq 8 indi_pt $100;
            infile "&path" dlm='$' dsd truncover firstobs=2 lrecl=2000;
            input primaryid : best12. caseid : best12.
                  indi_drug_seq : best12. indi_pt : $100.;
        %end;

        %else %if &tbl = OUTC %then %do;
            length primaryid 8 caseid 8 outc_cod $2;
            infile "&path" dlm='$' dsd truncover firstobs=2 lrecl=2000;
            input primaryid : best12. caseid : best12. outc_cod : $2.;
        %end;

        %else %if &tbl = THER %then %do;
            length
                primaryid      8     caseid       8     dsg_drug_seq  8
                start_dt_c    $8     end_dt_c    $8     dur           8
                dur_cod       $3
                start_dt       8     end_dt       8
                start_dt_prec $1     end_dt_prec $1
            ;
            infile "&path" dlm='$' dsd truncover firstobs=2 lrecl=2000;
            input primaryid : best12. caseid : best12. dsg_drug_seq : best12.
                  start_dt_c : $8. end_dt_c : $8.
                  dur : best12. dur_cod : $3.;
        %end;

        %else %if &tbl = RPSR %then %do;
            length primaryid 8 caseid 8 rpsr_cod $3;
            infile "&path" dlm='$' dsd truncover firstobs=2 lrecl=2000;
            input primaryid : best12. caseid : best12. rpsr_cod : $3.;
        %end;

        quarter = "&qtr";

        /*------------------------------------------------------------------
          4. Character scrub - DQ1 (CR/LF) and DQ6 (embedded TAB).

          Applied to every character variable rather than just dose_freq: the
          CR only appears on the last field today, but a blanket scrub costs
          one pass and cannot be defeated by a future column reorder.
          '09'x = TAB, '0D'x = CR, '0A'x = LF.
        ------------------------------------------------------------------*/
        array _chr {*} _character_;
        do _i = 1 to dim(_chr);
            _chr{_i} = strip(compress(_chr{_i}, '090D0A'x));
        end;
        drop _i;

        /*------------------------------------------------------------------
          5. Date parsing - DQ4. Runs after the scrub so a stray CR can never
             corrupt the length test that drives the parse.
        ------------------------------------------------------------------*/
        %if &tbl = DEMO %then %do;
            %_faers_parse_dt(event_dt)
            %_faers_parse_dt(mfr_dt)
            %_faers_parse_dt(init_fda_dt)
            %_faers_parse_dt(fda_dt)
            %_faers_parse_dt(rept_dt)
            format event_dt mfr_dt init_fda_dt fda_dt rept_dt yymmdd10.;
            drop event_dt_c mfr_dt_c init_fda_dt_c fda_dt_c rept_dt_c;
        %end;
        %else %if &tbl = DRUG %then %do;
            %_faers_parse_dt(exp_dt)
            format exp_dt yymmdd10.;
            drop exp_dt_c;
        %end;
        %else %if &tbl = THER %then %do;
            %_faers_parse_dt(start_dt)
            %_faers_parse_dt(end_dt)
            format start_dt end_dt yymmdd10.;
            drop start_dt_c end_dt_c;
        %end;

        label
            primaryid = 'Unique report version identifier'
            caseid    = 'FAERS case identifier'
            quarter   = 'Source quarter';
    run;

    /*----------------------------------------------------------------------
      6. QC accounting - one row per import, consumed by 01_import_clean.sas
      ----------------------------------------------------------------------*/
    %let dsid    = %sysfunc(open(&out));
    %let nobs    = %sysfunc(attrn(&dsid, NLOBS));
    %let rc      = %sysfunc(close(&dsid));
    %let elapsed = %sysfunc(round(%sysevalf(%sysfunc(datetime()) - &t0), 0.1));

    %if %sysfunc(exist(&qc)) = 0 %then %do;
        data &qc;
            length table $8 quarter $6 dataset $41 rows_read 8 seconds 8;
            stop;
        run;
    %end;

    proc sql noprint;
        insert into &qc
            set table     = "&tbl",
                quarter   = "&qtr",
                dataset   = "%upcase(&out)",
                rows_read = &nobs,
                seconds   = &elapsed;
    quit;

    %put NOTE: [import_faers_table] &tbl / &qlabel done - &nobs rows in &elapsed.s;

%mend import_faers_table;

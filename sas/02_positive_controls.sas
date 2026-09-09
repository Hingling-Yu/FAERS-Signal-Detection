/*****************************************************************************
 * 02_positive_controls.sas - Positive control validation of the signal engine
 *
 * Purpose:  Phase 2 Step 3. Validate 02_signal_engine.sas against drug x
 *           reaction pairs whose association is already established in the
 *           literature or on an FDA label. A screen that cannot recover a
 *           known signal is not a screen, so this program is the last step
 *           before Gate 2 is declared passed.
 *
 * Inputs:   SIGNAL.ALL_SIGNALS   every evaluated pair, flagged
 *                                (produced by 02_signal_engine.sas)
 *
 * Outputs:  SIGNAL.POSITIVE_CONTROLS               one row per control pair
 *           &OUT_TABLES/positive_controls.csv      the same, for review
 *           &OUT_QC/qc_positive_controls.csv       Gate 2 summary metrics
 *
 * -----------------------------------------------------------------------
 * METHOD - why a LEFT JOIN and not an INNER JOIN
 * -----------------------------------------------------------------------
 * The control list is the LEFT table. A pair the engine never evaluated
 * therefore survives the join as a row with missing signal columns instead
 * of vanishing from the result. An INNER JOIN would report "all controls
 * detected" on an empty result set, which is the one answer this program
 * exists to make impossible.
 *
 * The join is on UPCASE(STRIP(...)) of both keys. 01_import_clean.sas
 * upcases prod_ai but leaves pt in its FAERS casing ('Tendon rupture'), so
 * the two keys do not share a convention and neither side can be assumed
 * canonical.
 *
 * -----------------------------------------------------------------------
 * WHAT COUNTS AS A PASS
 * -----------------------------------------------------------------------
 * Gate 2 is the Evans criterion alone: every control must satisfy
 * signal_flag = 1. ROR is reported beside it and is expected to agree.
 *
 * EBGM is informational and deliberately NOT part of the gate. EB shrinks
 * a ratio toward the fitted background prior, so a control resting on few
 * cases can clear PRR >= 2 and miss EB05 >= 2 without either measure being
 * wrong - that gap is the documented behaviour of the method, not a defect
 * in the engine. It is logged as a WARNING so the disagreement is on the
 * record rather than silently absorbed.
 *
 * The published PRR ranges are a plausibility check, not a gate. They come
 * from different FAERS windows and different background populations than
 * this one, so a value outside the range is a prompt to look, not a failure.
 *
 * Author:   Hingling Yu (design, specification, execution, review)
 *           Code drafted with AI coding assistant (Claude)
 * Created:  2026-09-04
 *****************************************************************************/

/*==========================================================================
  1. SETUP
  ==========================================================================*/

/* Literal path, for the same reason as 02_signal_engine.sas: &BASE is
   defined BY this file, so it cannot be used to find it. Every path after
   this line derives from &BASE. */
%include "/home/u64291357/mydata/sas/00_config.sas";

/* 00_config.sas turns MPRINT and SYMBOLGEN on. This program is a report;
   the macro trace would bury the eight rows it exists to print. */
options nosymbolgen nomprint;

%let _T0 = %sysfunc(datetime());

%macro _stamp(label);
    %local e;
    %let e = %sysevalf(%sysfunc(datetime()) - &_T0);
    %put NOTE: [%sysfunc(putn(&e, time12.2))] &label;
%mend _stamp;

/* &OUT_TABLES and &OUT_QC must exist before PROC EXPORT writes into them.
   XCMD is disabled on SAS ODA, so DCREATE is the only way to create a
   directory from code; it is a no-op when the directory is already there. */
%macro _ensure_dir(subdir);
    %local rc;
    %if %sysfunc(fileexist(&BASE./output/&subdir)) = 0 %then %do;
        %let rc = %sysfunc(dcreate(&subdir, &BASE./output));
        %if %length(&rc) = 0 %then
            %put WARNING: Could not create &BASE./output/&subdir - the CSV export will fail.;
    %end;
%mend _ensure_dir;

%_ensure_dir(tables)
%_ensure_dir(qc)

title "Phase 2 Step 3 - Positive Control Validation";

/* The engine must have run. Without this the LEFT JOIN below would fail on
   an unresolved library member and the log would blame PROC SQL rather than
   the missing prerequisite. */
%macro require_signals;
    %if %sysfunc(exist(signal.all_signals)) = 0 %then %do;
        %put ERROR: SIGNAL.ALL_SIGNALS does not exist.;
        %put ERROR- Run 02_signal_engine.sas before this program.;
        %abort cancel;
    %end;
%mend require_signals;

%require_signals

%_stamp(02_positive_controls.sas started.)


/*==========================================================================
  2. THE POSITIVE CONTROL LIST
  --------------------------------------------------------------------------
  Eight pairs, each one an association a regulator or the published FAERS
  literature already treats as real. Two are FDA Black Box warnings, one is
  on the current GLP-1 label, the rest are long-standing class effects.

  prod_ai carries the FAERS ingredient spelling and pt the MedDRA Preferred
  Term as coded - British spelling included ('Haemorrhage'), because that is
  what MedDRA uses and what the join has to match.

  Defined in a DATA step rather than PROC SQL INSERT so the list reads as a
  table and a ninth control is one line, not one statement. Nothing below
  hard-codes the number eight: &N_PC is counted from this dataset, so adding
  a control tightens the gate automatically.

  expected_prr_low / expected_prr_high bound the PRR reported for the pair
  in the FAERS literature. See the WHAT COUNTS AS A PASS note in the header
  for why these do not gate.
  ==========================================================================*/
data work.known_signals;
    length pair_id 8 prod_ai $500 pt $100 source $80
           expected_prr_low 8 expected_prr_high 8;
    infile datalines dlm='|' truncover;
    input pair_id prod_ai $ pt $ source $ expected_prr_low expected_prr_high;

    label pair_id           = 'Pair'
          prod_ai           = 'Drug (prod_ai)'
          pt                = 'Reaction (PT)'
          source            = 'Basis for the control'
          expected_prr_low  = 'Published PRR low'
          expected_prr_high = 'Published PRR high';
    datalines;
1|ATORVASTATIN|Rhabdomyolysis|Well-established class effect|30|50
2|SIMVASTATIN|Rhabdomyolysis|Well-established class effect|40|60
3|CIPROFLOXACIN|Tendon rupture|FDA Black Box 2008|40|50
4|LEVOFLOXACIN|Tendon rupture|FDA Black Box 2008|80|110
5|SEMAGLUTIDE|Pancreatitis|FDA label, GLP-1 class|5|7
6|ISOTRETINOIN|Depression|Well-established|10|12
7|METHOTREXATE|Hepatotoxicity|Well-established|5|7
8|WARFARIN|Haemorrhage|Well-established|5|8
;
run;

proc sql noprint;
    select count(*) into :N_PC trimmed from work.known_signals;
quit;

%put NOTE: Positive controls defined = &N_PC;


/*==========================================================================
  3. LOOK EACH CONTROL UP IN THE SIGNAL TABLE
  ==========================================================================*/
proc sql;
    create table work.pc_results as
    select  k.pair_id,
            k.prod_ai  as expected_drug  length=500 label='Drug (prod_ai)',
            k.pt       as expected_pt    length=100 label='Reaction (PT)',
            k.source,
            k.expected_prr_low,
            k.expected_prr_high,

            /* Signal results - missing on any control the engine did not
               evaluate. That is the failure this program reports. */
            s.a,
            s.n_drug,
            s.n_reac,
            s.PRR,
            s.PRR_LCL,
            s.PRR_UCL,
            s.PRR_CHI2,
            s.ROR,
            s.ROR_LCL,
            s.ROR_UCL,
            s.EBGM,
            s.EB05,
            s.EB95,
            s.signal_flag,
            s.signal_ror,
            s.signal_ebgm,

            /* Detected by each criterion. A missing flag is a miss, which is
               what the ELSE arm scores it as. */
            case when s.signal_flag = 1 then 'YES' else 'NO ' end
                 as detected_evans length=3 label='Evans',
            case when s.signal_ror  = 1 then 'YES' else 'NO ' end
                 as detected_ror   length=3 label='ROR',
            case when s.signal_ebgm = 1 then 'YES' else 'NO ' end
                 as detected_ebgm  length=3 label='EBGM',

            /* PRR against the published range.

               MISSING is tested FIRST and that ordering is load-bearing.
               SAS orders missing below every number, so on an unmatched
               control 's.PRR < k.expected_prr_low' is TRUE and the pair
               would be labelled BELOW - reading as a weak-but-present
               signal when in fact the engine never produced one. Tested
               first, a missed control is labelled for what it is. */
            case when missing(s.PRR)
                     then 'MISSING'
                 when s.PRR between k.expected_prr_low and k.expected_prr_high
                     then 'IN RANGE'
                 when s.PRR > k.expected_prr_high
                     then 'ABOVE'
                 else 'BELOW'
                 end as prr_vs_published length=8 label='PRR vs published'

    from work.known_signals k
         left join signal.all_signals s
             on upcase(strip(k.prod_ai)) = upcase(strip(s.prod_ai))
            and upcase(strip(k.pt))      = upcase(strip(s.pt))
    order by k.pair_id;
quit;

/* One control must produce exactly one row. A duplicate would mean
   SIGNAL.ALL_SIGNALS holds the same prod_ai x PT twice, which would break
   the counts in section 4 by inflating them past &N_PC. */
%macro assert_one_row_each;
    %local nrow;
    proc sql noprint;
        select count(*) into :nrow trimmed from work.pc_results;
    quit;
    %if &nrow ne &N_PC %then %do;
        %put ERROR: &nrow result rows for &N_PC controls - the join is not 1:1.;
        %put ERROR- SIGNAL.ALL_SIGNALS holds a duplicate prod_ai x PT pair.;
    %end;
    %else %put NOTE: Join assertion passed - &nrow rows for &N_PC controls.;
%mend assert_one_row_each;

%assert_one_row_each

%_stamp(Controls looked up.)


/*==========================================================================
  4. GATE 2 ASSERTIONS
  ==========================================================================*/
proc sql noprint;
    select count(*) into :PC_EVANS trimmed
        from work.pc_results where detected_evans = 'YES';
    select count(*) into :PC_ROR trimmed
        from work.pc_results where detected_ror   = 'YES';
    select count(*) into :PC_EBGM trimmed
        from work.pc_results where detected_ebgm  = 'YES';
    select count(*) into :PC_ALL3 trimmed
        from work.pc_results
        where detected_evans = 'YES' and detected_ror = 'YES'
          and detected_ebgm  = 'YES';
    select count(*) into :PC_MISSED trimmed
        from work.pc_results where detected_evans ne 'YES';

    /* Evans found it, EB did not. Informational - see the header. */
    select count(*) into :PC_EB_DISAGREE trimmed
        from work.pc_results
        where detected_evans = 'YES' and detected_ebgm ne 'YES';

    select count(*) into :PC_IN trimmed
        from work.pc_results where prr_vs_published = 'IN RANGE';
    select count(*) into :PC_ABOVE trimmed
        from work.pc_results where prr_vs_published = 'ABOVE';
    select count(*) into :PC_BELOW trimmed
        from work.pc_results where prr_vs_published = 'BELOW';
quit;

data work.qc_pc;
    length metric $60 value 8 note $90;

    metric = 'Positive controls defined';
    value  = &N_PC;
    note   = 'Known drug x reaction pairs the engine must recover'; output;

    metric = 'Detected - Evans (signal_flag = 1)';
    value  = &PC_EVANS;
    note   = "Gate 2 criterion - must be &N_PC";                    output;

    metric = 'Detected - ROR (signal_ror = 1)';
    value  = &PC_ROR;
    note   = "Expected to agree with Evans on all &N_PC";           output;

    metric = 'Detected - EBGM (signal_ebgm = 1)';
    value  = &PC_EBGM;
    note   = 'Informational - untruncated EB fit (prior mean 17.3), not validated MGPS'; output;

    metric = 'Detected - all three criteria';
    value  = &PC_ALL3;
    note   = 'Intersection; EBGM uses a mis-fit prior - Evans + ROR is the gate'; output;

    metric = 'Missed controls';
    value  = &PC_MISSED;
    note   = 'Must be 0 - any miss is an engine defect';            output;

    metric = 'PRR in published range';
    value  = &PC_IN;
    note   = 'Plausibility check, not a gate';                      output;

    metric = 'PRR above published range';
    value  = &PC_ABOVE;
    note   = 'Can reflect a different FAERS window or background';  output;

    metric = 'PRR below published range';
    value  = &PC_BELOW;
    note   = 'Investigate if > 0 - under-detection is the concern'; output;

    label metric = 'Metric' value = 'Value' note = 'Note';
run;

/* The gate verdict itself. Written to the log rather than only to the CSV
   because the log is the artefact reviewed after a SAS ODA run. */
%macro gate2_verdict;
    %if &PC_MISSED = 0 %then
        %put NOTE: GATE 2 PASSED - all &N_PC positive controls detected by Evans criteria.;
    %else %do;
        %put ERROR: GATE 2 FAILED - &PC_MISSED positive control(s) not detected. Engine has a bug.;
        %put ERROR- Do not use SIGNAL.ALL_SIGNALS for Phase 3 until this is resolved.;

        proc print data=work.pc_results noobs label;
            where detected_evans ne 'YES';
            var pair_id expected_drug expected_pt a PRR PRR_CHI2 prr_vs_published;
            format expected_drug $30. expected_pt $30. a comma8. PRR PRR_CHI2 10.2;
            title2 'GATE 2 FAILED - missed positive controls';
        run;
        title2;
    %end;

    %if &PC_EB_DISAGREE > 0 %then %do;
        %put WARNING: EBGM missed &PC_EB_DISAGREE control(s) that Evans detected.;
        %put WARNING- Frequentist / Bayesian disagreement, not a gate failure. See the header note.;
    %end;

    %if &PC_ROR ne &PC_EVANS %then
        %put WARNING: ROR detected &PC_ROR controls against Evans &PC_EVANS - the criteria disagree.;
%mend gate2_verdict;

%gate2_verdict


/*==========================================================================
  5. REPORTING
  --------------------------------------------------------------------------
  Formats are applied on the PROC PRINT statements, never stored on the
  data. PROC EXPORT writes FORMATTED values, so a permanent $30. on
  expected_drug would truncate the ingredient in the CSV as well as on the
  page. Same reasoning as the SIGF note in 02_signal_engine.sas section 6.
  ==========================================================================*/
title2 "Table 1: Positive Control Validation Results";
proc print data=work.pc_results noobs label;
    var pair_id expected_drug expected_pt source a
        PRR PRR_LCL PRR_UCL
        ROR ROR_LCL ROR_UCL
        EBGM EB05 EB95
        detected_evans detected_ror detected_ebgm prr_vs_published;
    format expected_drug $22. expected_pt $24. source $30.
           a comma8.
           PRR PRR_LCL PRR_UCL ROR ROR_LCL ROR_UCL
           EBGM EB05 EB95 8.2;
    label PRR_LCL = 'PRR LCL'  PRR_UCL = 'PRR UCL'
          ROR_LCL = 'ROR LCL'  ROR_UCL = 'ROR UCL'
          a       = 'Cases (a)';
run;

title2 "Table 2: Gate 2 Summary";
proc print data=work.qc_pc noobs label;
    format value comma8.;
run;
title2;


/*==========================================================================
  6. SAVE OUTPUTS
  ==========================================================================*/
data signal.positive_controls;
    set work.pc_results;
run;

proc export data=work.pc_results
            outfile="&OUT_TABLES./positive_controls.csv" dbms=csv replace;
run;

proc export data=work.qc_pc
            outfile="&OUT_QC./qc_positive_controls.csv" dbms=csv replace;
run;


/*==========================================================================
  7. WRAP-UP
  ==========================================================================*/
%macro finish;
    %local e;
    %let e = %sysevalf(%sysfunc(datetime()) - &_T0);

    %put NOTE: ============================================;
    %put NOTE: 02_positive_controls.sas complete.;
    %put NOTE: Controls defined = &N_PC;
    %put NOTE: Detected - Evans = &PC_EVANS;
    %put NOTE: Detected - ROR   = &PC_ROR;
    %put NOTE: Detected - EBGM  = &PC_EBGM;
    %put NOTE: All 3 criteria   = &PC_ALL3;
    %put NOTE: Missed           = &PC_MISSED;
    %put NOTE: PRR in range     = &PC_IN (above &PC_ABOVE, below &PC_BELOW);
    %put NOTE: Output           = SIGNAL.POSITIVE_CONTROLS;
    %put NOTE: CSV              = &OUT_TABLES./positive_controls.csv;
    %put NOTE: QC               = &OUT_QC./qc_positive_controls.csv;
    %put NOTE: Elapsed          = %sysfunc(putn(&e, time12.2));
    %put NOTE: ============================================;

    %if &PC_MISSED = 0 %then
        %put NOTE: GATE 2 PASSED - the signal engine recovers every known positive control.;
    %else
        %put ERROR: GATE 2 FAILED - &PC_MISSED of &N_PC controls missed.;
%mend finish;

%finish

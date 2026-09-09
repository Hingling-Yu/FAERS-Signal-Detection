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
 * Outputs:  SIGNAL.POSITIVE_CONTROLS                   one row per positive control pair
 *           &OUT_TABLES/positive_controls.csv           the same, for review
 *           &OUT_TABLES/negative_controls.csv           negative control results
 *           &OUT_QC/qc_positive_negative_controls.csv   Gate 2 + specificity metrics
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
 * Negative controls (specificity) must ALL show signal_flag = 0. A false
 * positive on a known non-association means the engine over-fires. Pairs
 * that are absent from ALL_SIGNALS (NOT EVAL) are acceptable - they simply
 * had too few reports to be evaluated, which is not a specificity failure.
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
  ==========================================================================*/
data work.known_signals;
    length pair_id 8 prod_ai $500 pt $100 source $80;
    infile datalines dlm='|' truncover;
    input pair_id prod_ai $ pt $ source $;

    label pair_id           = 'Pair'
          prod_ai           = 'Drug (prod_ai)'
          pt                = 'Reaction (PT)'
          source            = 'Basis for the control';
    datalines;
1|ATORVASTATIN|Rhabdomyolysis|Well-established class effect
2|SIMVASTATIN|Rhabdomyolysis|Well-established class effect
3|CIPROFLOXACIN|Tendon rupture|FDA Black Box 2008
4|LEVOFLOXACIN|Tendon rupture|FDA Black Box 2008
5|SEMAGLUTIDE|Pancreatitis|FDA label, GLP-1 class
6|ISOTRETINOIN|Depression|Well-established
7|METHOTREXATE|Hepatotoxicity|Well-established
8|WARFARIN|Haemorrhage|Well-established
;
run;

proc sql noprint;
    select count(*) into :N_PC trimmed from work.known_signals;
quit;

%put NOTE: Positive controls defined = &N_PC;


/*==========================================================================
  2b. NEGATIVE CONTROL LIST
  --------------------------------------------------------------------------
  Known non-associations where the engine should NOT fire. These pairs use
  drugs already in the positive list (so we know they have FAERS volume) but
  map them to reactions they do not cause. A signal_flag = 1 on any of these
  is a false positive.

  Selection rationale:
  - Each drug appears in the positive controls, so report volume is adequate
  - Each PT is biologically unrelated to the drug's mechanism
  - None appears on the drug's label, in class-effect literature, or in
    FDA safety communications
  ==========================================================================*/
data work.negative_controls;
    length neg_id 8 prod_ai $500 pt $100 rationale $120;
    infile datalines dlm='|' truncover;
    input neg_id prod_ai $ pt $ rationale $;

    label neg_id     = 'Pair'
          prod_ai    = 'Drug (prod_ai)'
          pt         = 'Reaction (PT)'
          rationale  = 'Why this is a non-association';
    datalines;
1|ATORVASTATIN|Pancreatitis|Statins have no pancreatic mechanism; pancreatitis is a GLP-1 and gallstone association
2|CIPROFLOXACIN|Alopecia|Fluoroquinolones have no hair-loss mechanism; alopecia is a chemotherapy and retinoid effect
3|SEMAGLUTIDE|Rhabdomyolysis|No known mechanism linking GLP-1 agonists to skeletal muscle breakdown
4|WARFARIN|Depression|Anticoagulants have no CNS mechanism for mood disorders
5|ISOTRETINOIN|Haemorrhage|Retinoids have no anticoagulant mechanism
6|METHOTREXATE|Insomnia|MTX is an antimetabolite with no CNS sleep-wake mechanism
;
run;

proc sql noprint;
    select count(*) into :N_NC trimmed from work.negative_controls;
quit;

%put NOTE: Negative controls defined = &N_NC;


/*==========================================================================
  3. LOOK EACH CONTROL UP IN THE SIGNAL TABLE
  ==========================================================================*/
proc sql;
    create table work.pc_results as
    select  k.pair_id,
            k.prod_ai  as expected_drug  length=500 label='Drug (prod_ai)',
            k.pt       as expected_pt    length=100 label='Reaction (PT)',
            k.source,

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
                 as detected_ebgm  length=3 label='EBGM'

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
  3b. LOOK EACH NEGATIVE CONTROL UP IN THE SIGNAL TABLE
  ==========================================================================*/
proc sql;
    create table work.nc_results as
    select  n.neg_id,
            n.prod_ai  as expected_drug  length=500 label='Drug (prod_ai)',
            n.pt       as expected_pt    length=100 label='Reaction (PT)',
            n.rationale,

            s.a,
            s.n_drug,
            s.n_reac,
            s.PRR,
            s.PRR_CHI2,
            s.signal_flag,
            s.signal_ror,

            case when s.signal_flag = 1 then 'FALSE POS'
                 when missing(s.signal_flag) then 'NOT EVAL'
                 else 'CORRECT'
                 end as nc_result length=9 label='Negative control result'

    from work.negative_controls n
         left join signal.all_signals s
             on upcase(strip(n.prod_ai)) = upcase(strip(s.prod_ai))
            and upcase(strip(n.pt))      = upcase(strip(s.pt))
    order by n.neg_id;
quit;

%_stamp(Negative controls looked up.)


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
            var pair_id expected_drug expected_pt a PRR PRR_CHI2;
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


/*--------------------------------------------------------------------------
  4b. NEGATIVE CONTROL METRICS
  --------------------------------------------------------------------------*/
proc sql noprint;
    select count(*) into :NC_FP trimmed
        from work.nc_results where nc_result = 'FALSE POS';
    select count(*) into :NC_CORRECT trimmed
        from work.nc_results where nc_result = 'CORRECT';
    select count(*) into :NC_NOTEVAL trimmed
        from work.nc_results where nc_result = 'NOT EVAL';
quit;

/* Append negative control metrics to the QC dataset */
data work.qc_nc;
    length metric $60 value 8 note $90;

    metric = 'Negative controls defined';
    value  = &N_NC;
    note   = 'Known non-associations the engine should NOT flag'; output;

    metric = 'Negative controls correct (not flagged)';
    value  = &NC_CORRECT;
    note   = "Specificity check - should be &N_NC";              output;

    metric = 'Negative controls false positive';
    value  = &NC_FP;
    note   = 'Must be 0 - a flagged non-association means over-firing'; output;

    metric = 'Negative controls not evaluated';
    value  = &NC_NOTEVAL;
    note   = 'Pair absent from ALL_SIGNALS - low volume, acceptable'; output;

    label metric = 'Metric' value = 'Value' note = 'Note';
run;

/* Merge positive and negative QC into one dataset */
data work.qc_pc;
    set work.qc_pc work.qc_nc;
run;

%macro nc_verdict;
    %if &NC_FP = 0 %then
        %put NOTE: NEGATIVE CONTROLS PASSED - 0 false positives out of &N_NC pairs.;
    %else %do;
        %put WARNING: &NC_FP of &N_NC negative controls flagged as signals (false positives).;

        proc print data=work.nc_results noobs label;
            where nc_result = 'FALSE POS';
            var neg_id expected_drug expected_pt a PRR PRR_CHI2;
            format expected_drug $30. expected_pt $30. a comma8. PRR PRR_CHI2 10.2;
            title2 'NEGATIVE CONTROL - false positive details';
        run;
        title2;
    %end;
%mend nc_verdict;

%nc_verdict


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
        detected_evans detected_ror detected_ebgm;
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

title2 "Table 3: Negative Control Validation Results";
proc print data=work.nc_results noobs label;
    var neg_id expected_drug expected_pt rationale a
        PRR PRR_CHI2 signal_flag nc_result;
    format expected_drug $22. expected_pt $24. rationale $50.
           a comma8. PRR PRR_CHI2 8.2;
    label PRR_CHI2 = 'Chi-sq'
          a        = 'Cases (a)';
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

proc export data=work.nc_results
            outfile="&OUT_TABLES./negative_controls.csv" dbms=csv replace;
run;

proc export data=work.qc_pc
            outfile="&OUT_QC./qc_positive_negative_controls.csv" dbms=csv replace;
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
    %put NOTE: --- Negative Controls ---;
    %put NOTE: Neg controls defined  = &N_NC;
    %put NOTE: Correct (not flagged) = &NC_CORRECT;
    %put NOTE: False positives       = &NC_FP;
    %put NOTE: Not evaluated         = &NC_NOTEVAL;
    %put NOTE: Neg CSV               = &OUT_TABLES./negative_controls.csv;
    %put NOTE: Output           = SIGNAL.POSITIVE_CONTROLS;
    %put NOTE: CSV              = &OUT_TABLES./positive_controls.csv;
    %put NOTE: QC               = &OUT_QC./qc_positive_negative_controls.csv;
    %put NOTE: Elapsed          = %sysfunc(putn(&e, time12.2));
    %put NOTE: ============================================;

    %if &PC_MISSED = 0 %then
        %put NOTE: GATE 2 PASSED - the signal engine recovers every known positive control.;
    %else
        %put ERROR: GATE 2 FAILED - &PC_MISSED of &N_PC controls missed.;
%mend finish;

%finish

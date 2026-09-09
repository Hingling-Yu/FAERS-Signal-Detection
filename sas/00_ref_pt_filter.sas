/*****************************************************************************
 * 00_ref_pt_filter.sas - Non-clinical PT classification
 *
 * Purpose:  Reference data and rules. Classifies every MedDRA Preferred Term
 *           into one clinical category or one of six non-clinical ones, so
 *           Phase 3 programs can lead their DISPLAY tables with genuine
 *           adverse events while keeping every row in the full datasets.
 *           %include it AFTER 00_config.sas in any program that ranks or
 *           publishes a PT-level table.
 *
 * Creates:  %pt_category(var)      SQL CASE expression, the classifier
 *           WORK.REF_NOISE_PTS     the explicit-list PTs, for audit and QC
 *
 * -----------------------------------------------------------------------
 * WHY THIS FILE EXISTS
 * -----------------------------------------------------------------------
 * 03_glp1_signal_profile.sas ranks by PRR. PRR rewards disproportionality,
 * and the most disproportionate terms a mass-tort drug class attracts are
 * often not adverse events at all. On the 2026-09-09 run, 96 of the 767
 * single-ingredient Evans signals - 73 distinct PTs - were medication
 * errors, device complaints, product quality reports, dosing mistakes,
 * unrelated surgical history or litigation-intake artefacts. They took
 * ranks 1 to 4 of TIRZEPATIDE's top 20 and rank 3 of SEMAGLUTIDE's.
 *
 * 'Intercepted product selection error' at PRR 606 is a true statement about
 * FAERS and a useless statement about tirzepatide. 'Corrective lens user' at
 * PRR 105 is the fingerprint of a law firm filing batches of intake forms,
 * not a drug effect. A reader who opens glp1_top_signals.csv should see the
 * pharmacology first.
 *
 * -----------------------------------------------------------------------
 * RULES, NOT A LOOKUP TABLE
 * -----------------------------------------------------------------------
 * %pt_category expands to a CASE expression rather than joining a lookup
 * table, because the non-clinical vocabulary grows with every quarter. A
 * table would have to be re-audited each load; a keyword rule classifies
 * 'Intercepted wrong patient selected' the first time it appears.
 *
 * The explicit lists exist only where no keyword can work. Nothing in the
 * string 'Corrective lens user' or 'Weight loss poor' marks it as
 * non-clinical - that judgement comes from knowing the class and the
 * litigation around it, so it is written down rather than inferred.
 *
 * -----------------------------------------------------------------------
 * TWO JUDGEMENT CALLS WORTH ARGUING WITH
 * -----------------------------------------------------------------------
 * 1. NO BLANKET 'ends with operation' RULE. The extract contains thirteen
 *    '... operation' PTs. Twelve are unrelated surgical history - bunion,
 *    knee, toe, cataract. One, 'Gallbladder operation', is a real GLP-1
 *    class effect: cholecystectomy is how gallbladder disease presents in a
 *    safety database, and 'Cholecystectomy' and 'Cholelithiasis' are Evans
 *    signals here on their own. A suffix rule would have deleted a labelled
 *    effect to save typing twelve names, so the procedures are enumerated.
 *
 * 2. LACK_OF_EFFICACY IS ITS OWN CATEGORY. 'Weight loss poor' - 1,108
 *    SEMAGLUTIDE cases, PRR 176, rank 2 before this filter - is not a
 *    dosing error and not a safety event. It is a treatment-failure report.
 *    Filing it under DOSING_ERROR would put a wrong label in a QC table a
 *    reviewer reads. The filtering outcome is identical either way; only
 *    the category name differs, and this one is defensible out loud.
 *
 * -----------------------------------------------------------------------
 * WHAT THIS FILTER DOES NOT DO
 * -----------------------------------------------------------------------
 * It removes nothing. SIGNAL.GLP1_SIGNALS, glp1_signals.csv and every
 * quarterly trend row keep all classifications, and pt_category travels
 * with them as a column. Only the top-N tables and the printed report
 * tables filter on it, and every program states its filtered and unfiltered
 * counts in QC. A reviewer who wants the medication-error signals reads the
 * same CSV with a different WHERE clause.
 *
 * Author:   Hingling Yu (design, specification, execution, review)
 *           Code drafted with AI coding assistant (Claude)
 * Created:  2026-09-09
 *****************************************************************************/

/*==========================================================================
  1. THE EXPLICIT NOISE-PT LIST
  --------------------------------------------------------------------------
  Audit copy of the PTs that section 2 classifies by name rather than by
  keyword. Nothing reads this table at run time - the macro carries its own
  literals so it works in a program that never includes this DATA step -
  but the list has to exist somewhere a reviewer can read and challenge it,
  and a hard-coded list buried in a CASE expression is not that place.

  Every PT here was observed in the 2026-09-09 signal profile occupying a
  rank a clinical event should have held.
  ==========================================================================*/
data work.ref_noise_pts;
    length pt $100 noise_category $25 why $80;

    /* DLM with list input, not a $CHARw. informat: a formatted read takes
       fixed columns and would swallow the delimiter along with the padding. */
    infile datalines dlm='|' truncover;
    input pt $ noise_category $ why $;

    label pt             = 'MedDRA Preferred Term'
          noise_category = 'Assigned non-clinical category'
          why            = 'Why a keyword rule cannot classify it';
    datalines;
Corrective lens user|LITIGATION_FINGERPRINT|Legal intake form field, not an event
Skin pressure mark|LITIGATION_FINGERPRINT|Intake observation, not an event
Skin laxity|LITIGATION_FINGERPRINT|Cosmetic sequela of weight loss, intake artefact
Weight loss poor|LACK_OF_EFFICACY|Treatment failure, not a safety event
Therapeutic response changed|LACK_OF_EFFICACY|Efficacy term, reads as clinical
Off label use|MED_ERROR|Use issue, no error keyword in the string
Off label use of device|DEVICE|Use issue, device grain
Product use in unapproved indication|MED_ERROR|Use issue, no error keyword
Drug use for unknown indication|MED_ERROR|Reporting gap, not an event
Intentional product misuse|MED_ERROR|Use issue, no error keyword
Product confusion|MED_ERROR|Use issue, no error keyword
Wrong technique in product usage process|MED_ERROR|Administration error, no keyword
Product administered at inappropriate site|MED_ERROR|Administration error, no keyword
Product administered to patient of inappropriate age|MED_ERROR|Administration error
Multiple use of single-use product|MED_ERROR|Administration error, no keyword
Injury associated with device|DEVICE|Device grain, no Device prefix
Sleeve gastrectomy|PROCEDURE_NOISE|Bariatric history, not a drug effect
Abdominal panniculectomy|PROCEDURE_NOISE|Post-weight-loss surgery, not an event
Intraocular lens implant|PROCEDURE_NOISE|Cataract surgery history
Hernia repair|PROCEDURE_NOISE|Surgical history
Umbilical hernia repair|PROCEDURE_NOISE|Surgical history
Rotator cuff repair|PROCEDURE_NOISE|Surgical history
Bunion operation|PROCEDURE_NOISE|Surgical history
Cardiac operation|PROCEDURE_NOISE|Surgical history
Cataract operation|PROCEDURE_NOISE|Surgical history
Eye operation|PROCEDURE_NOISE|Surgical history
Eyelid operation|PROCEDURE_NOISE|Surgical history
Haemorrhoid operation|PROCEDURE_NOISE|Surgical history
Knee operation|PROCEDURE_NOISE|Surgical history
Meniscus operation|PROCEDURE_NOISE|Surgical history
Nasal septal operation|PROCEDURE_NOISE|Surgical history
Skin operation|PROCEDURE_NOISE|Surgical history
Spinal operation|PROCEDURE_NOISE|Surgical history
Toe operation|PROCEDURE_NOISE|Surgical history
;
run;

%put NOTE: [pt_filter] WORK.REF_NOISE_PTS built - the audit copy of the explicit lists.;


/*==========================================================================
  2. THE CLASSIFIER
  --------------------------------------------------------------------------
  %pt_category(var) expands to a SQL CASE expression. VAR is the name of the
  column holding the PT, qualified if the query needs it: %pt_category(s.pt).

  PROC SQL ONLY. The expansion is a CASE, which a DATA step cannot evaluate.
  Where a DATA step needs the column, compute it in the PROC SQL step that
  builds the table and let it travel as data.

  Do not reference it with CALCULATED in the same query's WHERE clause -
  PROC SQL does not allow that. Classify in one step, filter in the next.

  RULE ORDER MATTERS - first match wins:

    1  LITIGATION_FINGERPRINT   named list; nothing in the string says it
    2  LACK_OF_EFFICACY         named list; efficacy, not safety
    3  PROCEDURE_NOISE          named list; see JUDGEMENT CALL 1 above
    4  MED_ERROR                'Intercepted' or 'Medication error' prefix,
                                any string containing 'error', the named
                                use-issue terms, 'Inappropriate schedule'
    5  PRODUCT_QUALITY          counterfeit, recalled, expired, contaminated,
                                packaging, labelling, quality complaints
    6  DOSING_ERROR             any 'dose', 'titration', 'dosage form' or
                                'formulation administered' term left over
    7  DEVICE                   'Device' prefix, plus the named device terms
    8  CLINICAL_AE              everything else - the default, and the only
                                category the top tables keep

  DOSING before DEVICE is deliberate. 'Incorrect dose administered by device'
  and 'Drug dose omission by device' are dosing mistakes that happen to name
  the delivery route; the dose is the informative half. The 'Device' PREFIX
  rule then catches the true device grain - defect, failure, leakage - and
  nothing else.
  ==========================================================================*/
%macro pt_category(var);
    case
        /* 1. Litigation intake artefacts. */
        when upcase(strip(&var)) in (
                 'CORRECTIVE LENS USER',
                 'SKIN PRESSURE MARK',
                 'SKIN LAXITY'
             ) then 'LITIGATION_FINGERPRINT'

        /* 2. Treatment failure. Not a safety event; see JUDGEMENT CALL 2. */
        when upcase(strip(&var)) in (
                 'WEIGHT LOSS POOR',
                 'THERAPEUTIC RESPONSE CHANGED',
                 'DRUG INEFFECTIVE',
                 'DRUG EFFECT DECREASED',
                 'THERAPEUTIC PRODUCT EFFECT DECREASED'
             ) then 'LACK_OF_EFFICACY'

        /* 3. Surgical and procedural history. Enumerated, never by suffix -
              'Gallbladder operation' is a class effect and stays clinical. */
        when upcase(strip(&var)) in (
                 'SLEEVE GASTRECTOMY',
                 'ABDOMINAL PANNICULECTOMY',
                 'INTRAOCULAR LENS IMPLANT',
                 'HERNIA REPAIR',
                 'UMBILICAL HERNIA REPAIR',
                 'ROTATOR CUFF REPAIR',
                 'BUNION OPERATION',
                 'CARDIAC OPERATION',
                 'CATARACT OPERATION',
                 'EYE OPERATION',
                 'EYELID OPERATION',
                 'HAEMORRHOID OPERATION',
                 'KNEE OPERATION',
                 'MENISCUS OPERATION',
                 'NASAL SEPTAL OPERATION',
                 'SKIN OPERATION',
                 'SPINAL OPERATION',
                 'TOE OPERATION'
             ) then 'PROCEDURE_NOISE'

        /* 4. Medication and use errors. The 'error' contains-rule carries
              most of the family - dispensing, prescribing, titration,
              dosing - so only the errorless use issues need naming. */
        when find(&var, 'Intercepted', 'i')      = 1 then 'MED_ERROR'
        when find(&var, 'Medication error', 'i') = 1 then 'MED_ERROR'
        when find(&var, 'error', 'i')            > 0 then 'MED_ERROR'
        when find(&var, 'Inappropriate schedule', 'i') = 1 then 'MED_ERROR'
        when upcase(strip(&var)) in (
                 'OFF LABEL USE',
                 'PRODUCT USE IN UNAPPROVED INDICATION',
                 'DRUG USE FOR UNKNOWN INDICATION',
                 'INTENTIONAL PRODUCT MISUSE',
                 'PRODUCT CONFUSION',
                 'WRONG TECHNIQUE IN PRODUCT USAGE PROCESS',
                 'PRODUCT ADMINISTERED AT INAPPROPRIATE SITE',
                 'PRODUCT ADMINISTERED TO PATIENT OF INAPPROPRIATE AGE',
                 'MULTIPLE USE OF SINGLE-USE PRODUCT'
             ) then 'MED_ERROR'

        /* 5. Product quality complaints. */
        when find(&var, 'counterfeit', 'i')          > 0 then 'PRODUCT_QUALITY'
        when find(&var, 'Recalled product', 'i')     > 0 then 'PRODUCT_QUALITY'
        when find(&var, 'Expired product', 'i')      > 0 then 'PRODUCT_QUALITY'
        when find(&var, 'Product quality', 'i')      > 0 then 'PRODUCT_QUALITY'
        when find(&var, 'contamination', 'i')        > 0 then 'PRODUCT_QUALITY'
        when find(&var, 'Product packaging', 'i')    > 0 then 'PRODUCT_QUALITY'
        when find(&var, 'Product label', 'i')        > 0 then 'PRODUCT_QUALITY'
        when find(&var, 'Product information', 'i')  > 0 then 'PRODUCT_QUALITY'
        when find(&var, 'Product communication', 'i')> 0 then 'PRODUCT_QUALITY'
        when find(&var, 'Product design', 'i')       > 0 then 'PRODUCT_QUALITY'
        when find(&var, 'compounding quality', 'i')  > 0 then 'PRODUCT_QUALITY'

        /* 6. Dosing mistakes the error keyword missed. Before DEVICE on
              purpose - see the note in the section header. */
        when find(&var, 'dose', 'i')                     > 0 then 'DOSING_ERROR'
        when find(&var, 'titration', 'i')                > 0 then 'DOSING_ERROR'
        when find(&var, 'dosage form', 'i')              > 0 then 'DOSING_ERROR'
        when find(&var, 'formulation administered', 'i') > 0 then 'DOSING_ERROR'

        /* 7. Device grain. Prefix only, so 'Injury associated with device'
              is named and 'Incorrect dose administered by device' is not
              stolen from DOSING_ERROR. */
        when find(&var, 'Device', 'i') = 1 then 'DEVICE'
        when upcase(strip(&var)) in (
                 'INJURY ASSOCIATED WITH DEVICE',
                 'OFF LABEL USE OF DEVICE'
             ) then 'DEVICE'

        /* 8. A genuine adverse event. */
        else 'CLINICAL_AE'
    end
%mend pt_category;


/*==========================================================================
  3. QC - WHAT THE RULES ACTUALLY CAUGHT
  --------------------------------------------------------------------------
  Informational, and skipped when the signal table is not built yet, so the
  file can be %included by a program that runs before it.

  The classification is materialised into a work table first rather than
  filtered inline. PROC SQL cannot reference a CALCULATED column from WHERE,
  and repeating a fifty-line CASE in the WHERE clause to work around that
  would put the rules in two places that could drift apart.
  ==========================================================================*/
%macro _qc_pt_filter;
    %if %sysfunc(exist(signal.glp1_signals)) %then %do;

        proc sql;
            create table work._pt_classified as
                select  %pt_category(pt) as pt_category length=25
                            label='PT classification',
                        pt,
                        signal_flag,
                        single_ingredient
                from    signal.glp1_signals;
        quit;

        proc sql;
            create table work._pt_filter_qc as
                select   pt_category,
                         count(*)                      as n_pairs
                             label='Pairs',
                         sum(signal_flag)              as n_evans
                             label='Evans signals',
                         count(distinct pt)            as n_distinct_pts
                             label='Distinct PTs'
                from     work._pt_classified
                group by pt_category
                order by (pt_category = 'CLINICAL_AE') desc, pt_category;
        quit;

        title2 'PT filter - classification of every GLP-1 signal pair';
        proc print data=work._pt_filter_qc noobs label;
            format n_pairs n_evans n_distinct_pts comma12.;
            label pt_category = 'Category';
        run;
        title2;

        /* The list a reviewer challenges. Restricted to the population the
           top table draws from, because a non-clinical PT that is not an
           Evans signal was never going to be displayed anyway. */
        title2 'PT filter - non-clinical PTs that are single-ingredient Evans signals';
        proc sql;
            select   pt_category    label='Category',
                     pt             label='MedDRA Preferred Term',
                     count(*)       label='Molecules'  format=comma8.
            from     work._pt_classified
            where    pt_category ne 'CLINICAL_AE'
              and    signal_flag = 1
              and    single_ingredient = 1
            group by pt_category, pt
            order by pt_category, pt;
        quit;
        title2;

        proc datasets library=work nolist;
            delete _pt_classified _pt_filter_qc;
        quit;
    %end;
    %else %put NOTE: [pt_filter] SIGNAL.GLP1_SIGNALS not found - QC skipped.;
%mend _qc_pt_filter;

%_qc_pt_filter

%put NOTE: ============================================;
%put NOTE: 00_ref_pt_filter.sas loaded.;
%put NOTE: %nrstr(%pt_category)(var) available - PROC SQL only, returns a CASE.;
%put NOTE: Categories: CLINICAL_AE MED_ERROR DOSING_ERROR DEVICE;
%put NOTE:             PRODUCT_QUALITY PROCEDURE_NOISE LITIGATION_FINGERPRINT;
%put NOTE:             LACK_OF_EFFICACY;
%put NOTE: ============================================;

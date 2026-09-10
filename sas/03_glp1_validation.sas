/*****************************************************************************
 * 03_glp1_validation.sas - GLP-1 signal validation against regulatory history
 *
 * Purpose:  Phase 3 Step 6. Ask a harder question than "does the engine find
 *           anything": does it find what regulators already found, miss what
 *           they investigated and dismissed, and surface what they only
 *           recognised during our data window. Every measure compared here
 *           was computed by 02_signal_engine.sas; this program computes no
 *           2x2 table of its own.
 *
 * Inputs:   SIGNAL.GLP1_SIGNALS   GLP-1 prod_ai x PT pairs, all measures
 *                                 (built by 03_glp1_signal_profile.sas)
 *           %pt_category()        from 00_ref_pt_filter.sas
 *
 * Outputs:  SIGNAL.GLP1_VALIDATION           group-level verdict, 12 rows
 *           SIGNAL.GLP1_VALIDATION_BY_DRUG   group x molecule rollup
 *           SIGNAL.GLP1_VALIDATION_DETAIL    every reference PT x molecule
 *           &OUT_TABLES/glp1_validation.csv
 *           &OUT_TABLES/glp1_validation_by_drug.csv
 *           &OUT_TABLES/glp1_validation_detail.csv
 *
 * Gate 3:   >= 6 of the 8 Category A groups REPLICATED on at least one
 *           molecule. Logged as *** GATE 3 PASSED *** or *** GATE 3 FAILED ***.
 *
 * -----------------------------------------------------------------------
 * WHY THE REFERENCE SET IS TIME-INDEXED
 * -----------------------------------------------------------------------
 * A validation set built only from "what is on the label today" can only
 * ever prove the method agrees with the present. It cannot distinguish a
 * method that detects real risk from one that has memorised the label.
 *
 * Each reference item here therefore carries the date and the body that
 * acted on it, and the twelve groups fall into four categories that ask
 * four different questions:
 *
 *   A  Label Warnings & Precautions, in force throughout 2025Q3-2026Q2.
 *      Question: does the method recover a known risk? Expect REPLICATED.
 *      These eight groups are the gate.
 *
 *   B  Not separate rows. The thyroid C-cell boxed warning (group A1) rests
 *      on rodent carcinogenicity, not on human spontaneous reports, and
 *      medullary thyroid cancer runs at roughly 0.2 per 100,000 per year in
 *      the population. Low FAERS counts there are the expected result, not a
 *      failure, so A1 carries a CATEGORY_NOTE saying so rather than being
 *      scored twice under two names.
 *
 *   C  Investigated and closed. Regulators looked at GLP-1 suicidality and
 *      concluded no causal link (EMA PRAC Apr 2024; FDA Jan 2026, which
 *      asked for the warning to come off). Question: does the method stay
 *      quiet? A REPLICATED here is a false positive worth reporting.
 *
 *   D  Recognised during or just before the data window - NAION (EMA Jun
 *      2025), pulmonary aspiration (FDA Nov 2024), tirzepatide hair loss
 *      (by the Sep 2025 label). Question: would this method have been early?
 *
 * -----------------------------------------------------------------------
 * PER-MOLECULE APPLICABILITY, AND WHY IT IS NOT A CARTESIAN PRODUCT
 * -----------------------------------------------------------------------
 * APPLICABLE_DRUGS restricts each reference PT to the molecules whose label
 * actually carries it. Testing all four molecules against all 42 PTs would
 * manufacture failures: 'Blood calcitonin increased' would be scored MISSED
 * on semaglutide, which has no such reports and no such label text, and the
 * group would look weaker than the evidence says it is.
 *
 * The rule is: a pair is evaluated only if the PT is in the reference set
 * for that molecule AND that molecule has a >= MIN_N for the PT. Everything
 * else lands in NOT_IN_DATA or BELOW_MIN_N and is excluded from the group
 * verdict rather than counted against it.
 *
 * Several NOT_IN_DATA results are expected and legitimate - 'Medullary
 * thyroid cancer' x DULAGLUTIDE, 'Thyroid C-cell hyperplasia' on three of
 * four molecules, 'Renal impairment' x LIRAGLUTIDE. Rare events with a
 * boxed warning still standing.
 *
 * -----------------------------------------------------------------------
 * DISPROPORTIONALITY IS NOT CAUSATION, AND THIS SET SHOWS IT BOTH WAYS
 * -----------------------------------------------------------------------
 * Two results in this reference set are the interesting ones precisely
 * because they disagree with the label, and the program is built to report
 * them rather than smooth them over.
 *
 * Acute kidney injury (A4) is a labelled W&P on all four molecules and
 * comes back PRR_BELOW_1 on all four. The mechanism is real -
 * volume depletion from vomiting and diarrhoea - but this class attracts an
 * enormous volume of non-serious consumer reports, and that denominator
 * dilutes serious renal events below the class background. A disproportion-
 * ality method cannot see a risk that is common in the comparator too. The
 * INTERPRETATION column says this in words, and the gate is set at 6 of 8
 * so an honest negative does not have to be argued away.
 *
 * Reaching that verdict took one change after the first run. Eleven of A4's
 * twelve pairs report below background, several emphatically - tirzepatide
 * x 'Acute kidney injury' sits at PRR 0.24 on chi2 351. The twelfth,
 * dulaglutide on the same PT, is PRR 1.16 on chi2 0.87. Under the original
 * rule that pair counted as SUB_THRESHOLD, and because any single PT can
 * set a molecule's verdict, it alone lifted the whole group to WEAK and had
 * the table reporting 'labelled risk detected below the Evans threshold'.
 *
 * A PRR of 1.16 that cannot clear a chi-square of 4 is not weak evidence of
 * a risk. It is no evidence in either direction, and letting it outrank
 * eleven measured negatives inverted what the group actually shows.
 * SUB_THRESHOLD therefore now requires PRR >= 1 AND chi2 >= &CHI2_THRESHOLD,
 * and a pair that leans up on noise alone is NOT_SIGNIFICANT.
 *
 * The threshold is not invented for this purpose: chi2 >= 4 is the second
 * of the three Evans criteria and is already &CHI2_THRESHOLD in
 * 00_config.sas. The split moves exactly one group verdict - A4, from WEAK
 * back to the PRR_BELOW_1 this section always argued it was. Of the ten
 * sub-threshold pairs in the first run, five clear the chi-square
 * comfortably (chi2 5.2 to 86.2) and stay WEAK; five do not (chi2 0.21 to
 * 3.51) and reclassify. Gate 3 is untouched at 7 of 8, because none of the
 * five sits on a molecule that was carrying its group.
 *
 * Suicidality (C1) runs the other way. The primary PT 'Suicidal ideation'
 * does NOT signal, which agrees with the regulators. But 'Depression
 * suicidal' and 'Self-injurious ideation' sit at a = 11 to 33 with modest
 * PRR and do clear Evans, because a >= 3 with PRR >= 2 is a low bar for a
 * rare term. That is what Evans criteria do on thin counts, and reporting
 * it is more useful than hiding it.
 *
 * -----------------------------------------------------------------------
 * WHAT THIS PROGRAM DELIBERATELY DOES NOT PRODUCE
 * -----------------------------------------------------------------------
 * No "novel signals" table. The obvious definition - an Evans signal that
 * is not on this reference list - would label nausea, vomiting, constipation
 * and injection-site reactions as novel findings, which is false and would
 * be embarrassing in front of anyone who knows the class. Calling something
 * unlabelled requires an exhaustive labelled-PT mapping, which needs a
 * MedDRA licence or the full openFDA label text; neither is in scope. The
 * absence of a claim is better than a claim that cannot be defended.
 *
 * EBGM, EB05 and EB95 travel in VALIDATION_DETAIL as reference columns and
 * appear in NO decision anywhere in this program. The delivered EBGM was
 * fitted with an untruncated likelihood, giving a prior mean of 17.3 against
 * DuMouchel's ~1.04, so it is demoted to ranking and context only - the same
 * decision 03_glp1_signal_profile.sas took on 2026-09-09. Detection here is
 * Evans criteria, via SIGNAL_FLAG.
 *
 * Author:   Hingling Yu (design, specification, execution, review)
 *           Code drafted with AI coding assistant (Claude)
 * Created:  2026-09-10
 *****************************************************************************/

/*==========================================================================
  1. SETUP
  ==========================================================================*/

/* Both includes use literal paths. &BASE is defined BY 00_config.sas so it
   cannot be used to find it, and 00_ref_pt_filter.sas is pinned the same way
   here on purpose: this program is uploaded to SAS ODA on its own, and a
   path that resolves through a macro variable fails with a confusing error
   if the config upload is stale. Two literals, one failure mode. */
%include "/home/u64291357/mydata/sas/00_config.sas";
%include "/home/u64291357/mydata/sas/00_ref_pt_filter.sas";

/* 00_config.sas turns MPRINT and SYMBOLGEN on. %pt_category expands to a
   fifty-line CASE and appears twice below; the trace would bury the tables
   this program exists to print. */
options nosymbolgen nomprint;

%let _T0 = %sysfunc(datetime());

%macro _stamp(label);
    %local e;
    %let e = %sysevalf(%sysfunc(datetime()) - &_T0);
    %put NOTE: [%sysfunc(putn(&e, time12.2))] &label;
%mend _stamp;

/* &OUT_TABLES must exist before PROC EXPORT writes into it. XCMD is disabled
   on SAS ODA, so DCREATE is the only way to create a directory from code; it
   is a no-op when the directory is already there. */
%macro _ensure_dir(subdir);
    %local rc;
    %if %sysfunc(fileexist(&BASE./output/&subdir)) = 0 %then %do;
        %let rc = %sysfunc(dcreate(&subdir, &BASE./output));
        %if %length(&rc) = 0 %then
            %put WARNING: Could not create &BASE./output/&subdir - the CSV export will fail.;
    %end;
%mend _ensure_dir;

%_ensure_dir(tables)

title "Phase 3 Step 6 - GLP-1 Signal Validation (Time-Indexed Reference)";

/* Prerequisite checked before the join rather than discovered inside it. A
   missing table makes PROC SQL blame its own FROM clause and the real cause
   ends up buried under every step that follows. */
%macro require_inputs;
    %if %sysfunc(exist(signal.glp1_signals)) = 0 %then %do;
        %put ERROR: SIGNAL.GLP1_SIGNALS does not exist.;
        %put ERROR- Run 03_glp1_signal_profile.sas before this program.;
        %abort cancel;
    %end;
%mend require_inputs;

%require_inputs

%_stamp(03_glp1_validation.sas started.)


/*==========================================================================
  2. THE REFERENCE SET
  --------------------------------------------------------------------------
  One row per signal group x PT. Twelve groups, 41 rows.

  DELIMITERS - the one thing to get right in this DATA step.

  The datalines delimiter is '|', matching WORK.REF_GLP1_DRUG in
  00_config.sas and WORK.REF_NOISE_PTS in 00_ref_pt_filter.sas, so all three
  reference tables in this project read the same way. APPLICABLE_DRUGS
  therefore separates its molecules with ',' - it has to be something other
  than '|', or the list would be shredded into separate fields by INFILE
  before SCAN ever sees it. Section 3 splits on the same ','.

  SEMICOLONS ARE FORBIDDEN in every field. A ';' inside a DATALINES line
  ends the data block, and SAS then parses the rest of the line as
  statements (ERROR 180-322). 02_positive_controls.sas learned this the hard
  way; the C1 source below says 'Apr 2024 / Jan 2026' for that reason.

  SOURCE IS CONSTANT WITHIN A SIGNAL GROUP, and section 6 asserts it. It is
  carried through GROUP BY in both rollups, so a source that varied by PT -
  'Boxed warning (all GLP-1 RAs)' on five rows and 'Boxed warning (related
  neoplasm)' on the sixth - would split signal_id 1 into two groups, turn
  Category A into thirteen groups instead of eight, and change what the gate
  is counting without any error being raised. Per-PT nuance lives in PT_ROLE
  instead, which no GROUP BY touches.

  PT_ROLE marks whether a term is the group's core concept (CORE) or an
  adjacent term included to widen recall (RELATED). It is descriptive only -
  a RELATED PT counts toward detection exactly like a CORE one, because a
  method that finds 'Cholecystitis acute' but not 'Cholecystitis' has still
  found gallbladder disease.

  MIN_N is a column rather than a constant so a group covering an especially
  rare event could raise its own floor later. Every row is 3 today, matching
  &MIN_CASES and the Evans a >= 3 criterion.

  Every PT below was verified present in glp1_signals.csv for at least one
  applicable molecule on 2026-09-09. Two candidates were dropped in that
  check: 'Renal failure acute', which is not a PT in this extract for any
  molecule, and 'Haemorrhagic necrotic pancreatitis', which exists only for
  tirzepatide at a = 2 and added nothing to a group that already has five
  strong terms.
  ==========================================================================*/
data work.ref_validation;
    length category $1 signal_id 8 signal_group $40 pt $100
           applicable_drugs $30 min_n 8 pt_role $8 source $80
           category_note $120;
    infile datalines dlm='|' truncover;
    input category $ signal_id signal_group $ pt $
          applicable_drugs $ min_n pt_role $ source $;

    /* Category B is a reading of group A1, not a group of its own. */
    if signal_id = 1 then
        category_note = 'Category B - boxed warning rests on rodent carcinogenicity, '
                     || 'not human reports. Low counts expected.';
    else category_note = '';

    label category         = 'Reference category (A/C/D)'
          signal_id        = 'Signal group id'
          signal_group     = 'Signal group'
          pt               = 'MedDRA Preferred Term'
          applicable_drugs = 'Molecules whose label carries this PT'
          min_n            = 'Minimum cases required to evaluate the pair'
          pt_role          = 'CORE concept or RELATED term'
          source           = 'Regulatory basis, constant within the group'
          category_note    = 'Extra reading of this group, where one applies';
    datalines;
A|1|Thyroid C-cell tumors|Medullary thyroid cancer|SEMA,TIRZ,DULA,LIRA|3|CORE|Boxed warning (all GLP-1 RAs) - rodent C-cell carcinogenicity
A|1|Thyroid C-cell tumors|Thyroid cancer|SEMA,TIRZ,DULA,LIRA|3|CORE|Boxed warning (all GLP-1 RAs) - rodent C-cell carcinogenicity
A|1|Thyroid C-cell tumors|Thyroid neoplasm|SEMA,TIRZ,DULA,LIRA|3|CORE|Boxed warning (all GLP-1 RAs) - rodent C-cell carcinogenicity
A|1|Thyroid C-cell tumors|Thyroid C-cell hyperplasia|SEMA,TIRZ,DULA,LIRA|3|CORE|Boxed warning (all GLP-1 RAs) - rodent C-cell carcinogenicity
A|1|Thyroid C-cell tumors|Blood calcitonin increased|TIRZ|3|RELATED|Boxed warning (all GLP-1 RAs) - rodent C-cell carcinogenicity
A|1|Thyroid C-cell tumors|Papillary thyroid cancer|SEMA,TIRZ|3|RELATED|Boxed warning (all GLP-1 RAs) - rodent C-cell carcinogenicity
A|2|Pancreatitis|Pancreatitis|SEMA,TIRZ,DULA,LIRA|3|CORE|W&P (all GLP-1 RAs) - trials and post-marketing
A|2|Pancreatitis|Pancreatitis acute|SEMA,TIRZ,DULA,LIRA|3|CORE|W&P (all GLP-1 RAs) - trials and post-marketing
A|2|Pancreatitis|Pancreatitis chronic|SEMA,DULA|3|RELATED|W&P (all GLP-1 RAs) - trials and post-marketing
A|2|Pancreatitis|Pancreatitis necrotising|SEMA,DULA|3|RELATED|W&P (all GLP-1 RAs) - trials and post-marketing
A|2|Pancreatitis|Obstructive pancreatitis|SEMA|3|RELATED|W&P (all GLP-1 RAs) - trials and post-marketing
A|3|Gallbladder disease|Cholelithiasis|SEMA,TIRZ,DULA,LIRA|3|CORE|W&P (all GLP-1 RAs) - cholelithiasis and cholecystitis in trials
A|3|Gallbladder disease|Cholecystitis|SEMA,TIRZ,DULA,LIRA|3|CORE|W&P (all GLP-1 RAs) - cholelithiasis and cholecystitis in trials
A|3|Gallbladder disease|Cholecystitis acute|SEMA,TIRZ,DULA|3|CORE|W&P (all GLP-1 RAs) - cholelithiasis and cholecystitis in trials
A|3|Gallbladder disease|Biliary colic|SEMA,TIRZ,DULA,LIRA|3|RELATED|W&P (all GLP-1 RAs) - cholelithiasis and cholecystitis in trials
A|3|Gallbladder disease|Gallbladder disorder|SEMA,TIRZ,DULA|3|RELATED|W&P (all GLP-1 RAs) - cholelithiasis and cholecystitis in trials
A|3|Gallbladder disease|Gallbladder injury|SEMA,TIRZ,DULA,LIRA|3|RELATED|W&P (all GLP-1 RAs) - cholelithiasis and cholecystitis in trials
A|4|Acute kidney injury|Acute kidney injury|SEMA,TIRZ,DULA,LIRA|3|CORE|W&P (all GLP-1 RAs) - volume depletion mechanism
A|4|Acute kidney injury|Renal impairment|SEMA,TIRZ,DULA,LIRA|3|CORE|W&P (all GLP-1 RAs) - volume depletion mechanism
A|4|Acute kidney injury|Renal failure|SEMA,TIRZ,DULA,LIRA|3|CORE|W&P (all GLP-1 RAs) - volume depletion mechanism
A|5|Hypoglycaemia|Hypoglycaemia|SEMA,TIRZ,DULA,LIRA|3|CORE|W&P (all GLP-1 RAs) - with insulin secretagogues
A|6|Diabetic retinopathy|Diabetic retinopathy|SEMA,TIRZ,DULA,LIRA|3|CORE|W&P (SEMA / TIRZ / DULA) - SUSTAIN-6 rapid improvement
A|7|Ileus / GI obstruction|Ileus|SEMA,TIRZ,DULA,LIRA|3|CORE|Post-marketing - FDA SEMA label update Sep 2023
A|7|Ileus / GI obstruction|Ileus paralytic|SEMA,TIRZ,DULA|3|CORE|Post-marketing - FDA SEMA label update Sep 2023
A|7|Ileus / GI obstruction|Intestinal obstruction|SEMA,TIRZ,DULA,LIRA|3|CORE|Post-marketing - FDA SEMA label update Sep 2023
A|7|Ileus / GI obstruction|Small intestinal obstruction|SEMA,DULA|3|RELATED|Post-marketing - FDA SEMA label update Sep 2023
A|8|Gastroparesis / delayed emptying|Impaired gastric emptying|SEMA,TIRZ,DULA,LIRA|3|CORE|W&P severe gastroparesis (SEMA / TIRZ) - delayed emptying
A|8|Gastroparesis / delayed emptying|Diabetic gastroparesis|SEMA,TIRZ,DULA|3|CORE|W&P severe gastroparesis (SEMA / TIRZ) - delayed emptying
A|8|Gastroparesis / delayed emptying|Gastric hypomotility|DULA|3|RELATED|W&P severe gastroparesis (SEMA / TIRZ) - delayed emptying
A|8|Gastroparesis / delayed emptying|Gastrointestinal hypomotility|SEMA,TIRZ,DULA|3|RELATED|W&P severe gastroparesis (SEMA / TIRZ) - delayed emptying
C|9|Suicidal ideation / behaviour|Suicidal ideation|SEMA,TIRZ,LIRA|3|CORE|Investigated and closed - EMA PRAC Apr 2024 / FDA Jan 2026 no link
C|9|Suicidal ideation / behaviour|Suicide attempt|SEMA,TIRZ,LIRA|3|CORE|Investigated and closed - EMA PRAC Apr 2024 / FDA Jan 2026 no link
C|9|Suicidal ideation / behaviour|Completed suicide|SEMA,TIRZ,LIRA|3|CORE|Investigated and closed - EMA PRAC Apr 2024 / FDA Jan 2026 no link
C|9|Suicidal ideation / behaviour|Depression suicidal|SEMA,TIRZ,LIRA|3|RELATED|Investigated and closed - EMA PRAC Apr 2024 / FDA Jan 2026 no link
C|9|Suicidal ideation / behaviour|Self-injurious ideation|SEMA,TIRZ|3|RELATED|Investigated and closed - EMA PRAC Apr 2024 / FDA Jan 2026 no link
C|9|Suicidal ideation / behaviour|Suicidal behaviour|SEMA,TIRZ|3|RELATED|Investigated and closed - EMA PRAC Apr 2024 / FDA Jan 2026 no link
D|10|NAION|Optic ischaemic neuropathy|SEMA,TIRZ,DULA|3|CORE|EMA PRAC Jun 2025 - NAION a very rare side effect of semaglutide
D|11|Pulmonary aspiration|Aspiration|SEMA,TIRZ,DULA|3|CORE|FDA Nov 2024 - added to W&P for all GLP-1 RAs
D|11|Pulmonary aspiration|Pneumonia aspiration|SEMA,TIRZ|3|RELATED|FDA Nov 2024 - added to W&P for all GLP-1 RAs
D|12|Alopecia|Alopecia|TIRZ,SEMA|3|CORE|TIRZ post-marketing hair loss - present by the Sep 2025 label
;
run;

/* What the reference set contains, before anything is matched against it. */
title2 'Reference set - one row per group';
proc sql;
    select   category           label='Cat',
             signal_id          label='ID',
             signal_group       label='Signal group',
             count(*)           label='PTs'      format=comma6.,
             sum(pt_role = 'CORE')    label='Core'    format=comma6.,
             sum(pt_role = 'RELATED') label='Related' format=comma6.,
             max(source)        label='Regulatory basis'
    from     work.ref_validation
    group by category, signal_id, signal_group
    order by category, signal_id;
quit;
title2;

%_stamp(Section 2 - reference set built.)


/*==========================================================================
  3. EXPAND BY MOLECULE, THEN MATCH AGAINST THE SIGNAL TABLE
  --------------------------------------------------------------------------
  3a expands 'SEMA,TIRZ,DULA,LIRA' into four rows and maps each abbreviation
  to the DRUG_LABEL spelling SIGNAL.GLP1_SIGNALS uses. Doing it in a DATA
  step rather than a join keeps the reference table readable: forty lines of
  data instead of the 160-row cross product it expands to.

  The abbreviations are checked, not trusted. A typo would otherwise become
  a DRUG_LABEL that matches nothing, and the whole group would report
  NOT_IN_DATA - a failure that looks like a finding.
  ==========================================================================*/
data work.ref_expanded;
    set work.ref_validation;
    length drug_abbrev $4 drug_label $20;

    do i = 1 to countw(applicable_drugs, ',');
        drug_abbrev = strip(scan(applicable_drugs, i, ','));

        select (drug_abbrev);
            when ('SEMA') drug_label = "&DRUG_SEMA";
            when ('TIRZ') drug_label = "&DRUG_TIRZ";
            when ('DULA') drug_label = "&DRUG_DULA";
            when ('LIRA') drug_label = "&DRUG_LIRA";
            otherwise do;
                put 'WARNING: Unknown drug abbreviation ' drug_abbrev
                    'in reference row ' signal_id= pt=;
                drug_label = drug_abbrev;
            end;
        end;

        output;
    end;

    drop i drug_abbrev;
run;


/*--------------------------------------------------------------------------
  3b. LEFT JOIN to the signal table.

  LEFT, not inner: a reference PT with no matching row is a result - the
  molecule has no reports of that event - and an inner join would delete it
  silently, leaving a group looking smaller and cleaner than it is.

  SINGLE_INGREDIENT = 1 in the ON clause, not in a WHERE. SIGNAL.GLP1_SIGNALS
  is keyed on prod_ai, so 'SEMAGLUTIDE' and 'CYANOCOBALAMIN\SEMAGLUTIDE' are
  two rows that both carry drug_label SEMAGLUTIDE; without the restriction
  one reference PT could match several and the group counts would double.
  Putting it in the ON clause keeps unmatched reference rows in the output,
  which is the whole point of the LEFT join - a WHERE on a right-table column
  would turn it back into an inner join. Same rule as
  03_glp1_signal_profile.sas uses for its top table.

  UPCASE(STRIP()) on both sides. 01_import_clean.sas upcases prod_ai and
  00_config.sas upcases drug_label, so this should be redundant, but the PT
  strings here were typed by hand from label text and the comparison is
  written to survive that.

  PT_CATEGORY is computed from r.pt, the reference term, not from s.pt. The
  classification is a property of the term itself and has to be available on
  rows that matched nothing - s.pt is missing there, and %pt_category() of a
  missing value falls through to CLINICAL_AE, which would be a classification
  by accident. On matched rows the two are identical by construction, since
  the join equates them.

  For the same reason NON_CLINICAL is tested FIRST in DETECT_STATUS. Whether
  a reference PT is a genuine adverse event does not depend on how many
  reports it has, so it should not be decided after the count tests. In
  practice no reference PT here should ever be non-clinical - this is a
  safety net against a future edit adding, say, a procedure term.

  SUB_THRESHOLD requires PRR >= 1 AND chi2 >= &CHI2_THRESHOLD. A pair that
  leans up but cannot clear the chi-square is NOT_SIGNIFICANT, a separate
  status, because PRR 1.16 on chi2 0.87 is not weak evidence of a risk - it
  is no evidence either way, and the rollup in section 4 treats the two very
  differently. See the header for what this cost before it was split out.
  A missing chi2 lands in NOT_SIGNIFICANT, which is the conservative side.

  EBGM and EB05 are selected for context and are used in no decision here.
  See the header.
  --------------------------------------------------------------------------*/
proc sql;
    create table work.validation_detail as
        select  r.category,
                r.signal_id,
                r.signal_group,
                r.pt              as expected_pt length=100
                    label='Reference PT',
                r.pt_role,
                r.drug_label,
                r.min_n,
                r.source,
                r.category_note,
                %pt_category(r.pt) as pt_category length=25
                    label='CLINICAL_AE or the non-clinical category it fell in',
                s.prod_ai,
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
                s.signal_flag,
                s.signal_ror,

                /* First match wins. Order is deliberate - see above. */
                case
                    when calculated pt_category ne 'CLINICAL_AE'
                                                    then 'NON_CLINICAL'
                    when missing(s.a) or s.a = 0    then 'NOT_IN_DATA'
                    when s.a < r.min_n              then 'BELOW_MIN_N'
                    when s.signal_flag = 1          then 'DETECTED'
                    when s.PRR >= 1
                     and s.PRR_CHI2 >= &CHI2_THRESHOLD
                                                    then 'SUB_THRESHOLD'
                    when s.PRR >= 1                 then 'NOT_SIGNIFICANT'
                    else                                 'PRR_BELOW_1'
                end as detect_status length=15
                    label='Outcome for this reference PT on this molecule'

        from    work.ref_expanded  as r
        left join signal.glp1_signals as s
            on  upcase(strip(r.drug_label)) = upcase(strip(s.drug_label))
            and upcase(strip(r.pt))         = upcase(strip(s.pt))
            and s.single_ingredient = 1

        order by r.signal_id, r.drug_label, r.pt;
quit;

%_stamp(Section 3 - reference set matched against SIGNAL.GLP1_SIGNALS.)


/*==========================================================================
  4. ROLL UP - BY MOLECULE, THEN BY GROUP
  --------------------------------------------------------------------------
  4a. One row per group x molecule.

  NON_CLINICAL rows are dropped here rather than in section 3, so
  VALIDATION_DETAIL keeps every reference PT and a reviewer can see what was
  held out and why. Only the verdict excludes them.

  DRUG_STATUS is first-match-wins down a severity ladder: any detected PT
  makes the group REPLICATED on that molecule, because a class effect found
  under 'Cholecystitis acute' has still been found. Below that, WEAK means
  the direction is right and statistically distinguishable from background
  but the PRR threshold was not cleared; PRR_BELOW_1 means the method
  actively points the other way - the honest negative; and NOT_SIGNIFICANT
  sits between them for a pair that leans up on noise alone.

  NOT_SIGNIFICANT ranks BELOW PRR_BELOW_1 on purpose. A molecule with one PT
  reporting well under background and another wobbling just over 1 is better
  described by the first: PRR 0.24 on chi2 351 is a measurement, PRR 1.16 on
  chi2 0.87 is an absence of one, and the stronger statement should win.

  Any rung of this ladder can be reached by a SINGLE PT, which is what makes
  the chi-square split in section 3b matter rather than being a refinement.
  See the header.

  BEST_A is the largest case count among detected PTs and BEST_PRR the
  largest PRR among them. They are independent maxima and need not describe
  the same PT - the labels say so, and the per-PT detail is one file away
  for anyone who needs the pairing.
  ==========================================================================*/
proc sql;
    create table work.validation_by_drug as
        select  category,
                signal_id,
                signal_group,
                drug_label,
                source,
                category_note,

                count(*) as n_pts_tested
                    label='Reference PTs for this molecule',
                sum(detect_status = 'DETECTED')      as n_detected
                    label='Cleared Evans criteria',
                sum(detect_status = 'SUB_THRESHOLD') as n_sub_threshold
                    label='PRR >= 1 but below Evans',
                sum(detect_status = 'PRR_BELOW_1')   as n_prr_below_1
                    label='PRR below 1 - reported less than background',
                sum(detect_status = 'NOT_SIGNIFICANT') as n_not_significant
                    label='PRR >= 1 but chi-square below threshold',
                sum(detect_status = 'NOT_IN_DATA')   as n_not_in_data
                    label='No reports of this PT for this molecule',
                sum(detect_status = 'BELOW_MIN_N')   as n_below_min_n
                    label='Reports present but below the min_n floor',

                max(case when detect_status = 'DETECTED' then PRR else . end)
                    as best_PRR format=8.2
                    label='Highest PRR among detected PTs',
                max(case when detect_status = 'DETECTED' then a else . end)
                    as best_a format=comma8.
                    label='Largest case count among detected PTs',

                case
                    when calculated n_detected      > 0 then 'REPLICATED'
                    when calculated n_sub_threshold > 0 then 'WEAK'
                    when calculated n_prr_below_1   > 0 then 'PRR_BELOW_1'
                    when calculated n_not_significant > 0 then 'NOT_SIGNIFICANT'
                    when calculated n_not_in_data = calculated n_pts_tested
                                                        then 'NOT_IN_DATA'
                    else                                     'BELOW_MIN_N'
                end as drug_status length=15
                    label='Verdict for this group on this molecule'

        from    work.validation_detail
        where   detect_status ne 'NON_CLINICAL'
        group by category, signal_id, signal_group, drug_label, source,
                 category_note
        order by signal_id, drug_label;
quit;


/*--------------------------------------------------------------------------
  4b. One row per group, across molecules.

  The same ladder one level up: a group is REPLICATED if the method found it
  on any molecule the label covers. That is the right bar for a class effect
  and the wrong one for a per-molecule comparison, which is what
  03_glp1_drug_compare.sas is for.

  INTERPRETATION is where the category earns its keep. The same
  GROUP_STATUS means opposite things in A and C: REPLICATED in Category A is
  the method working, REPLICATED in Category C is a false positive against a
  closed investigation. Writing that judgement into the table rather than
  leaving it to whoever reads the CSV is the difference between a result and
  a deliverable.
  --------------------------------------------------------------------------*/
proc sql;
    create table work.glp1_validation as
        select  category,
                signal_id,
                signal_group,
                source,
                category_note,

                count(*) as n_drugs_tested
                    label='Molecules this group was evaluated on',
                sum(drug_status = 'REPLICATED')  as n_drugs_replicated
                    label='Molecules where the method replicated it',
                sum(drug_status = 'WEAK')        as n_drugs_weak
                    label='Molecules detected below the Evans threshold',
                sum(drug_status = 'PRR_BELOW_1') as n_drugs_prr_below_1
                    label='Molecules reporting below background',
                sum(drug_status = 'NOT_SIGNIFICANT') as n_drugs_not_significant
                    label='Molecules where nothing reached significance',

                max(best_PRR) as best_PRR format=8.2
                    label='Highest PRR among detected PTs, any molecule',
                max(best_a)   as best_a   format=comma8.
                    label='Largest case count among detected PTs, any molecule',

                case
                    when sum(drug_status = 'REPLICATED')  > 0 then 'REPLICATED'
                    when sum(drug_status = 'WEAK')        > 0 then 'WEAK'
                    when sum(drug_status = 'PRR_BELOW_1') > 0 then 'PRR_BELOW_1'
                    when sum(drug_status = 'NOT_SIGNIFICANT') > 0
                                                              then 'NOT_SIGNIFICANT'
                    else                                          'NOT_FOUND'
                end as group_status length=15
                    label='Verdict for this group',

                case
                    when category = 'A' then
                        case
                            when calculated group_status = 'REPLICATED'
                                then 'Method confirmed a labelled risk'
                            when calculated group_status = 'WEAK'
                                then 'Labelled risk detected below the Evans threshold'
                            when calculated group_status = 'PRR_BELOW_1'
                                then 'Labelled risk not detected by disproportionality - see discussion'
                            when calculated group_status = 'NOT_SIGNIFICANT'
                                then 'Labelled risk not distinguishable from the reporting background'
                            else 'Not enough data to test'
                        end
                    when category = 'C' then
                        case
                            when calculated group_status = 'REPLICATED'
                                then 'CAUTION - method flags a closed investigation, review as a false positive'
                            else 'Consistent with the regulatory conclusion of no causal link'
                        end
                    when category = 'D' then
                        case
                            when calculated group_status = 'REPLICATED'
                                then 'Method detected a newly recognised safety signal'
                            when calculated group_status = 'WEAK'
                                then 'Newly recognised signal detected below the Evans threshold'
                            else 'Method did not detect this signal - see discussion'
                        end
                    else ''
                end as interpretation length=100
                    label='What this verdict means in this category'

        from    work.validation_by_drug
        group by category, signal_id, signal_group, source, category_note
        order by category, signal_id;
quit;

%_stamp(Section 4 - group and molecule rollups built.)


/*==========================================================================
  5. THE REPORT TABLES
  ==========================================================================*/
title2 'Validation summary by signal group';
proc sql;
    select   category           label='Cat',
             signal_id          label='ID',
             signal_group       label='Signal group',
             group_status       label='Verdict',
             n_drugs_replicated label='Repl'    format=comma5.,
             n_drugs_tested     label='Tested'  format=comma6.,
             best_PRR           label='Best PRR',
             best_a             label='Best a',
             interpretation     label='Interpretation'
    from     work.glp1_validation
    order by category, signal_id;
quit;
title2;

title2 'Validation detail by signal group and molecule';
proc sql;
    select   category        label='Cat',
             signal_id       label='ID',
             signal_group    label='Signal group',
             drug_label      label='Molecule',
             drug_status     label='Verdict',
             n_detected      label='Det'   format=comma4.,
             n_sub_threshold label='Sub'   format=comma4.,
             n_not_significant label='NotSig' format=comma6.,
             n_prr_below_1   label='PRR<1' format=comma5.,
             n_not_in_data   label='NoData' format=comma6.,
             best_PRR        label='Best PRR',
             best_a          label='Best a'
    from     work.validation_by_drug
    order by signal_id, drug_label;
quit;
title2;

/* Where the method disagrees with the label, PT by PT. This is the table the
   discussion section is written from, so it prints rather than only exporting. */
title2 'Reference PTs the method did not detect';
proc sql;
    select   category      label='Cat',
             signal_group  label='Signal group',
             expected_pt   label='Reference PT',
             drug_label    label='Molecule',
             detect_status label='Outcome',
             a             label='Cases' format=comma8.,
             PRR           label='PRR'   format=8.2
    from     work.validation_detail
    where    detect_status in ('SUB_THRESHOLD', 'NOT_SIGNIFICANT', 'PRR_BELOW_1')
    order by category, signal_id, drug_label, PRR desc;
quit;
title2;


/*==========================================================================
  6. ASSERTIONS AND GATE 3
  --------------------------------------------------------------------------
  Four checks before the gate is read, each one guarding an assumption the
  numbers above rest on. All are cheap; the alternative is a gate result
  that is arithmetically correct and semantically meaningless.
  ==========================================================================*/

/* 6a. SOURCE and CATEGORY_NOTE constant within a group. Both are carried
   through GROUP BY, so a per-PT variant would split one group into several
   and quietly change what the gate counts. See the section 2 header. */
proc sql noprint;
    select count(*) into :N_SPLIT trimmed
    from (select signal_id
          from   work.ref_validation
          group by signal_id
          having count(distinct source) > 1
              or count(distinct category_note) > 1);
quit;

%macro assert_no_split;
    %if &N_SPLIT > 0 %then %do;
        %put ERROR: &N_SPLIT signal group(s) carry more than one SOURCE or CATEGORY_NOTE.;
        %put ERROR- The GROUP BY in section 4 will split them and Gate 3 will count the wrong number of groups.;
        %put ERROR- Make SOURCE constant within each signal_id - put per-PT nuance in PT_ROLE.;
        %abort cancel;
    %end;
    %else %put NOTE: Assertion passed - SOURCE and CATEGORY_NOTE are constant within every group.;
%mend assert_no_split;

%assert_no_split

/* 6b. The join stayed 1:1. SINGLE_INGREDIENT = 1 should make at most one
   signal row match each reference PT x molecule; if SIGNAL.GLP1_SIGNALS ever
   holds a duplicate pair, every count above is inflated. */
proc sql noprint;
    select count(*) into :N_EXPANDED trimmed from work.ref_expanded;
    select count(*) into :N_DETAIL   trimmed from work.validation_detail;
quit;

%macro assert_join;
    %if &N_DETAIL ne &N_EXPANDED %then %do;
        %put ERROR: &N_DETAIL detail rows for &N_EXPANDED reference pairs - the join is not 1:1.;
        %put ERROR- SIGNAL.GLP1_SIGNALS holds a duplicate drug_label x pt pair at single_ingredient = 1.;
        %abort cancel;
    %end;
    %else %put NOTE: Assertion passed - &N_DETAIL detail rows for &N_EXPANDED reference pairs.;
%mend assert_join;

%assert_join

/* 6c. Every evaluated pair has a computable PRR. DETECT_STATUS sends a
   missing PRR to PRR_BELOW_1, which would be a wrong label rather than a
   wrong number, so the case is counted rather than assumed away. The engine
   makes it impossible - a >= 3 with positive marginals always gives a PRR -
   but that is a property of the upstream program, not of this one. */
proc sql noprint;
    select count(*) into :N_NO_PRR trimmed
    from   work.validation_detail
    where  detect_status not in ('NOT_IN_DATA', 'BELOW_MIN_N', 'NON_CLINICAL')
      and  missing(PRR);
quit;

%macro assert_prr;
    %if &N_NO_PRR > 0 %then
        %put WARNING: &N_NO_PRR evaluated pair(s) have a missing PRR and were labelled PRR_BELOW_1.;
    %else %put NOTE: Assertion passed - every evaluated pair has a computable PRR.;
%mend assert_prr;

%assert_prr

/* 6d. Category A still has the eight groups the gate is calibrated against.
   A ninth group would make 6 of 9 an easier bar than intended, a seventh a
   harder one, and neither would announce itself. */
proc sql noprint;
    select coalesce(sum(group_status = 'REPLICATED'), 0),
           count(*)
    into   :N_A_REPLICATED trimmed,
           :N_A_TOTAL      trimmed
    from   work.glp1_validation
    where  category = 'A';
quit;

%macro assert_cat_a;
    %if &N_A_TOTAL ne 8 %then
        %put WARNING: Category A holds &N_A_TOTAL groups, not the 8 Gate 3 was calibrated against.;
%mend assert_cat_a;

%assert_cat_a

/*--------------------------------------------------------------------------
  GATE 3 - at least 6 of the 8 Category A groups replicated.

  Six of eight, not eight of eight, and the two the bar makes room for are
  known before the run: A4 (acute kidney injury) is expected PRR_BELOW_1 on
  every molecule, and A5 (hypoglycaemia) does not clear Evans on
  semaglutide. Both are argued in the header. A gate that demanded 8 of 8
  would have to be argued down after the fact, which is how a validation
  becomes a formality.

  Categories C and D are reported, not gated. C is a specificity check with
  one group - too thin to hang a pass/fail on - and D is the "was the method
  early" question, where a miss is a finding rather than a defect.
  --------------------------------------------------------------------------*/
%macro gate3;
    %if &N_A_REPLICATED >= 6 %then %do;
        %put NOTE: *** GATE 3 PASSED *** - &N_A_REPLICATED of &N_A_TOTAL Category A groups replicated (need >= 6).;
    %end;
    %else %do;
        %put WARNING: *** GATE 3 FAILED *** - only &N_A_REPLICATED of &N_A_TOTAL Category A groups replicated (need >= 6).;
        %put WARNING- Do not publish the validation table until this is explained.;
    %end;
%mend gate3;

%gate3

/* Per-group results, one log line each.

   A DATA _NULL_ rather than the SELECT INTO :x1-:x99 plus %do loop that does
   the same job in macro. Group names here contain '/' and '-', the count is
   read from the data rather than fixed, and none of that has to be quoted or
   bounded when the text is built in a DATA step. PUTLOG writes the same
   NOTE:/WARNING: prefixes a log scan looks for. */
data _null_;
    set work.glp1_validation end=last;
    length prefix $8 msg $300;

    /* WARNING for anything a reader needs to look at: a Category A or D
       group the method did not replicate, or a Category C group it did. */
    if category in ('A', 'D') then
        prefix = ifc(group_status in ('REPLICATED', 'WEAK'), 'NOTE:', 'WARNING:');
    else if category = 'C' then
        prefix = ifc(group_status = 'REPLICATED', 'WARNING:', 'NOTE:');
    else prefix = 'NOTE:';

    msg = catx(' ', prefix,
               cats('[', category, signal_id, ']'),
               strip(signal_group), '-', strip(group_status));

    /* CAT, not CATS. CATS strips every argument, including the spaces in
       the literals below, and the line comes out as '(best PRR478.04on
       a=2,081)'. The PUT results are stripped individually instead. */
    if not missing(best_PRR) then
        msg = catx(' ', msg, cat('(best PRR ', strip(put(best_PRR, 8.2)),
                                 ' on a=', strip(put(best_a, comma8.)), ')'));

    msg = catx(' ', msg, cats('[', strip(interpretation), ']'));
    putlog msg;

    if last then putlog 'NOTE: --------------------------------------------';
run;

%_stamp(Section 6 - assertions and Gate 3 evaluated.)


/*==========================================================================
  7. SAVE AND WRAP UP
  --------------------------------------------------------------------------
  compress=yes on all three. SOURCE is $80 and CATEGORY_NOTE $120, both
  repeated on every row of a group, so the saving is most of the file.

  The LENGTH statement before each SET pins the widths and fixes column
  order, so a downstream PROC PRINT reads the same way every run rather than
  inheriting whatever order the last join happened to emit.
  ==========================================================================*/
data signal.glp1_validation (compress=yes
        label='GLP-1 validation verdict, one row per reference signal group');
    length category $1 signal_id 8 signal_group $40 group_status $15
           interpretation $100 source $80 category_note $120;
    set work.glp1_validation;
run;

data signal.glp1_validation_by_drug (compress=yes
        label='GLP-1 validation, one row per reference group x molecule');
    length category $1 signal_id 8 signal_group $40 drug_label $20
           drug_status $15 source $80 category_note $120;
    set work.validation_by_drug;
run;

data signal.glp1_validation_detail (compress=yes
        label='GLP-1 validation, one row per reference PT x molecule');
    length category $1 signal_id 8 signal_group $40 expected_pt $100
           pt_role $8 drug_label $20 detect_status $15 pt_category $25;
    set work.validation_detail;
run;

proc export data=work.glp1_validation
            outfile="&OUT_TABLES./glp1_validation.csv" dbms=csv replace;
run;

proc export data=work.validation_by_drug
            outfile="&OUT_TABLES./glp1_validation_by_drug.csv" dbms=csv replace;
run;

proc export data=work.validation_detail
            outfile="&OUT_TABLES./glp1_validation_detail.csv" dbms=csv replace;
run;

/* Headline counts for the log summary. Category C is reported as "stayed
   quiet", which is the pass condition there, not the failure it would be
   in Category A. */
proc sql noprint;
    select count(*) into :N_GROUPS trimmed from work.glp1_validation;

    select coalesce(sum((category = 'C') and (group_status ne 'REPLICATED')), 0),
           coalesce(sum(category = 'C'), 0),
           coalesce(sum((category = 'D') and (group_status = 'REPLICATED')), 0),
           coalesce(sum(category = 'D'), 0)
    into   :N_C_QUIET trimmed, :N_C_TOTAL trimmed,
           :N_D_CAUGHT trimmed, :N_D_TOTAL trimmed
    from   work.glp1_validation;

    select count(*) into :N_REF_PAIRS trimmed from work.validation_detail;
    select coalesce(sum(detect_status = 'DETECTED'), 0)
        into :N_PAIRS_DETECTED trimmed from work.validation_detail;
quit;

%macro finish;
    %local e;
    %let e = %sysevalf(%sysfunc(datetime()) - &_T0);

    %put NOTE: ============================================;
    %put NOTE: 03_glp1_validation.sas complete.;
    %put NOTE: Reference groups     = &N_GROUPS (&N_A_TOTAL Category A, &N_C_TOTAL Category C, &N_D_TOTAL Category D);
    %put NOTE: Reference PT x drug  = &N_REF_PAIRS pairs, &N_PAIRS_DETECTED detected;
    %put NOTE: Category A replicated = &N_A_REPLICATED of &N_A_TOTAL (Gate 3 needs >= 6);
    %put NOTE: Category C quiet      = &N_C_QUIET of &N_C_TOTAL (quiet is the pass condition);
    %put NOTE: Category D caught     = &N_D_CAUGHT of &N_D_TOTAL;
    %put NOTE: Datasets             = SIGNAL.GLP1_VALIDATION;
    %put NOTE:                        SIGNAL.GLP1_VALIDATION_BY_DRUG;
    %put NOTE:                        SIGNAL.GLP1_VALIDATION_DETAIL;
    %put NOTE: Tables               = &OUT_TABLES./glp1_validation.csv;
    %put NOTE:                        &OUT_TABLES./glp1_validation_by_drug.csv;
    %put NOTE:                        &OUT_TABLES./glp1_validation_detail.csv;
    %put NOTE: Elapsed              = %sysfunc(putn(&e, time12.2));
    %put NOTE: ============================================;

    %if &N_A_REPLICATED >= 6 %then
        %put NOTE: GATE 3 PASSED - the method recovers the labelled GLP-1 risk profile.;
    %else
        %put WARNING: GATE 3 FAILED - see the per-group warnings above.;
%mend finish;

%finish

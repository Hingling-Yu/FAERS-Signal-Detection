/*****************************************************************************
 * 03_glp1_signal_profile.sas - GLP-1 signal profile
 *
 * Purpose:  Phase 3 Step 2. Cut the full-database signal table down to the
 *           GLP-1 class and rank what it contains. Every PRR, ROR and EBGM
 *           in the output was computed by 02_signal_engine.sas against the
 *           full 1,529,453-case universe; this program computes no 2x2
 *           table of its own.
 *
 * Inputs:   SIGNAL.ALL_SIGNALS    every evaluated prod_ai x PT pair, flagged
 *           CLEAN.GLP1_CASES      the Step 1 cohort, for reconciliation only
 *           WORK.REF_GLP1_DRUG    class definition, from 00_config.sas
 *
 * Outputs:  SIGNAL.GLP1_SIGNALS                     GLP-1 pairs, all measures
 *           &OUT_TABLES/glp1_signals.csv            the same, for Tableau
 *           &OUT_TABLES/glp1_top_signals.csv        top 20 per molecule
 *           &OUT_QC/qc_glp1_signal_profile.csv      QC metrics
 *
 * -----------------------------------------------------------------------
 * METHOD - filter, do not recompute
 * -----------------------------------------------------------------------
 * The engine already evaluated every GLP-1 pair against the full database.
 * Recomputing here would mean rebuilding the 2x2 tables with N = the full
 * FAERS universe, which risks a subtly different case-matching rule and a
 * GLP-1 PRR that no longer equals the one in ALL_SIGNALS. Filtering is
 * faster and identical by construction.
 *
 * The filter is the same cross join used in 00_config.sas and
 * 03_glp1_extract.sas section 2: four reference rows, FIND doing the real
 * work, and drug_label and generation carried back out. %glp1_match() would
 * answer "is it in the class" but cannot say which member, which is exactly
 * what the ranking needs.
 *
 * -----------------------------------------------------------------------
 * GRAIN - prod_ai x PT, not drug_label x PT
 * -----------------------------------------------------------------------
 * This is the one place the filter approach departs from what the spec
 * describes, and it is worth reading before the top-20 table is trusted.
 *
 * SIGNAL.ALL_SIGNALS is keyed on prod_ai, the raw FAERS ingredient string.
 * 'SEMAGLUTIDE' and 'CYANOCOBALAMIN\SEMAGLUTIDE' are therefore two separate
 * rows with two separate 2x2 tables, and both land under drug_label
 * SEMAGLUTIDE after the join. The MySQL warehouse counts 27 distinct
 * prod_ai strings across the four molecules; 23 of them are compounded or
 * combination products, and together they cover 276 cases out of 111,674.
 * Counting these per drug_label instead gives 28 and 24, because
 * 'CYANOCOBALAMIN\SEMAGLUTIDE\TIRZEPATIDE' is one string under two labels.
 * The run confirms the 27: N_PRODAI in the QC table.
 *
 * The consequence is a ranking hazard, not a counting error. A compounded
 * prod_ai reported by 28 cases needs only 3 of them to share one rare PT to
 * clear Evans (a >= 3, PRR >= 2, chi2 >= 4) at a PRR in the hundreds - and
 * a PRR-descending top 20 would put that above the real class effects.
 *
 * SINGLE_INGREDIENT flags whether prod_ai is the molecule alone.
 * SIGNAL.GLP1_SIGNALS keeps every row so nothing is lost, and the top-20
 * table filters on the flag. The first run measured the cost of not
 * filtering: 13 of 80 top-20 rows rested on a compounded prod_ai, so the
 * decision was made against a number rather than a guess - the same
 * treatment 03_glp1_extract.sas gave its indication dedup.
 *
 * -----------------------------------------------------------------------
 * RANKING - PRR, descending
 * -----------------------------------------------------------------------
 * This table was ranked by EBGM until 2026-09-09. The reasoning then was
 * sound in principle: EBGM is the shrunk estimate, so a pair resting on few
 * cases is pulled toward the fitted background and evidence is weighed with
 * effect size. Ranking by raw PRR put SEMAGLUTIDE x Pancreatitis - the
 * FDA-labelled class effect and this project's Gate 2 positive control, at
 * PRR 6.18 on 456 cases - 129th over the unfiltered set.
 *
 * The principle held; the fit did not. Independent review found the
 * delivered EBGM was fitted with an untruncated likelihood, giving a prior
 * mean of 17.3 against DuMouchel's ~1.04. A prior that far off does not
 * shrink thin evidence in the way the argument above assumes, so ordering
 * by EBGM is not the defensible choice it was taken to be. Ranking is now
 * by PRR, which is at least a stated and reproducible quantity.
 *
 * The cost is real and is measured, not hidden: the QC table reports the
 * positive control's rank under both orderings, and the log warns when it
 * falls outside the top 20. The floor that protects against single-case
 * pairs is the Evans criterion itself - every row here has a >= 3.
 *
 * EBGM, EB05 and EB95 all stay in the table as reference columns. The
 * change is to the ORDER, not to what is reported.
 *
 * Descending order puts missing PRR last, since SAS sorts missing below
 * every number. In practice no row here has one: a >= 3 with positive
 * marginals makes PRR computable for every Evans signal.
 *
 * A prod_ai naming two class members ('CYANOCOBALAMIN\SEMAGLUTIDE\
 * TIRZEPATIDE') appears once under each drug_label. That is intended and
 * is the same behaviour as the Step 1 cohort.
 *
 * -----------------------------------------------------------------------
 * WHY n_drug HERE IS SMALLER THAN THE STEP 1 CASE COUNT
 * -----------------------------------------------------------------------
 * Two reasons, both expected, both quantified in section 4. The engine's
 * universe is PS cases carrying at least one coded PT, so a GLP-1 case with
 * no reaction row is in CLEAN.GLP1_CASES and in no 2x2 table. And n_drug is
 * per prod_ai, so the main-molecule row excludes the compounded variants
 * counted above. For SEMAGLUTIDE the arithmetic is 35,705 cohort cases
 * minus 54 compounded-variant cases; the QC table shows the residual.
 *
 * Author:   Hingling Yu
 * Created:  2026-09-05
 *****************************************************************************/

/*==========================================================================
  1. SETUP
  ==========================================================================*/

/* Literal path, for the same reason as every other program in this phase:
   &BASE is defined BY this file, so it cannot be used to find it. Every
   path after this line derives from &BASE. */
%include "/home/u64291357/mydata/sas/00_config.sas";
%include "&SAS_PATH./00_ref_pt_filter.sas";

/* 00_config.sas turns MPRINT and SYMBOLGEN on. This program is a report;
   the macro trace would bury the tables it exists to print. */
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

title "Phase 3 Step 2 - GLP-1 Signal Profile";

/* Prerequisites, checked before the first join rather than discovered
   inside it. A missing table makes PROC SQL blame its own FROM clause and
   the real cause ends up buried under every step that follows. */
%macro require_inputs;
    %local missing;
    %let missing = 0;

    %if %sysfunc(exist(signal.all_signals)) = 0 %then %do;
        %put ERROR: SIGNAL.ALL_SIGNALS does not exist.;
        %put ERROR- Run 02_signal_engine.sas before this program.;
        %let missing = %eval(&missing + 1);
    %end;

    %if %sysfunc(exist(clean.glp1_cases)) = 0 %then %do;
        %put ERROR: CLEAN.GLP1_CASES does not exist.;
        %put ERROR- Run 03_glp1_extract.sas before this program.;
        %let missing = %eval(&missing + 1);
    %end;

    /* WORK.REF_GLP1_DRUG is created by 00_config.sas. Its absence does not
       mean the include failed - it means the copy of 00_config.sas on SAS
       ODA predates the class-definition rewrite, back when no reference
       table existed. The fix is to re-upload sas/00_config.sas. */
    %if %sysfunc(exist(work.ref_glp1_drug)) = 0 %then %do;
        %put ERROR: WORK.REF_GLP1_DRUG does not exist after including 00_config.sas.;
        %put ERROR- The copy of 00_config.sas on SAS ODA is out of date.;
        %put ERROR- Re-upload sas/00_config.sas from the repo to &SAS_PATH, then re-run.;
        %let missing = %eval(&missing + 1);
    %end;

    %if &missing > 0 %then %abort cancel;
%mend require_inputs;

%require_inputs

%_stamp(03_glp1_signal_profile.sas started.)


/*==========================================================================
  2. FILTER THE FULL SIGNAL TABLE TO THE GLP-1 CLASS
  --------------------------------------------------------------------------
  Cross join filtered by FIND. WORK.REF_GLP1_DRUG holds four rows, so the
  expansion is trivial and FIND does the filtering. s.* carries every
  measure the engine computed, untouched.

  SINGLE_INGREDIENT is derived here rather than downstream so the flag
  travels with the permanent dataset and the CSVs. prod_ai is upcased by
  01_import_clean.sas and drug_label is upcased in 00_config.sas, but the
  comparison is written defensively in case either convention changes.
  ==========================================================================*/
proc sql;
    create table work.glp1_signals as
        select  g.drug_label,
                g.generation,
                (upcase(strip(s.prod_ai)) = upcase(strip(g.drug_label)))
                    as single_ingredient length=8
                    label='prod_ai is the molecule alone (1) or a combination (0)',
                %pt_category(s.pt) as pt_category length=25
                    label='CLINICAL_AE or the non-clinical category it fell in',
                s.*
        from    signal.all_signals  as s,
                work.ref_glp1_drug  as g
        where   not missing(s.prod_ai)
          and   find(s.prod_ai, strip(g.match_string), 'i') > 0
        order by g.drug_label, s.PRR desc;
quit;

%_stamp(Section 2 - signal table filtered to the GLP-1 class.)


/*==========================================================================
  3. TOP SIGNALS PER MOLECULE
  --------------------------------------------------------------------------
  A DATA step with a BY-group counter, not the monotonic() + GROUP BY the
  spec sketched. monotonic() is undocumented, its value depends on how the
  optimiser chose to feed the subquery, and putting a non-summarised column
  in a HAVING clause makes PROC SQL remerge - so the sketch can silently
  return the wrong 20 rows. A sorted BY group cannot.

  Three filters, all departures from the spec and all argued in the header:

    signal_flag = 1       Evans is the project's primary criterion and the
                          only one of the three carrying the a >= 3 floor.

    single_ingredient = 1 the molecule alone. See GRAIN - the alternative
                          gave 13 of 80 slots to compounded products.

    pt_category =         a genuine adverse event. Medication errors, device
      'CLINICAL_AE'       complaints, product quality reports, dosing
                          mistakes, surgical history and litigation-intake
                          artefacts are classified by keyword rules in
                          00_ref_pt_filter.sas and held out of this table.
                          Without it the top 20 opened on 'Intercepted
                          product selection error' at PRR 606 and
                          'Corrective lens user' at PRR 105. Every row stays
                          in GLP1_SIGNALS and in glp1_signals.csv, carrying
                          pt_category, so the errors remain one WHERE clause
                          away for anyone who wants them.

  Ordered by PRR rather than EBGM. See RANKING for why, and note that
  SIGNAL.GLP1_SIGNALS keeps every row and every measure regardless: this
  section decides what the deliverable leads with, not what exists.

  The sort keys after PRR are tie-breakers only. Two pairs with the same
  PRR rank by case count and then alphabetically, which makes the output
  reproducible instead of dependent on the order the join happened to emit.
  ==========================================================================*/
proc sort data=work.glp1_signals out=work.glp1_ranked_in;
    by drug_label descending PRR descending a pt;
    where signal_flag = 1 and single_ingredient = 1
      and pt_category = 'CLINICAL_AE';
run;

data work.glp1_ranked;
    set work.glp1_ranked_in;
    by drug_label;

    length signal_rank 8;
    if first.drug_label then signal_rank = 0;
    signal_rank + 1;

    label signal_rank = 'Rank within molecule by PRR (descending)';
run;

/* Column order is fixed here rather than left to the join: the top-signals
   CSV is a deliverable and should read the same way every run. */
data work.glp1_top_signals;
    /* RETAIN before SET, which is what actually fixes the column order:
       variable position is set at compile time by first appearance, so the
       same list written after the SET would be a no-op. */
    retain drug_label generation prod_ai pt single_ingredient pt_category
           signal_rank
           a n_drug n_reac
           EBGM EB05 EB95
           PRR PRR_LCL PRR_UCL PRR_CHI2
           ROR ROR_LCL ROR_UCL
           signal_flag signal_ror signal_ebgm;

    set work.glp1_ranked;
    where signal_rank <= 20;

    keep drug_label generation prod_ai pt single_ingredient pt_category
         signal_rank
         a n_drug n_reac
         EBGM EB05 EB95
         PRR PRR_LCL PRR_UCL PRR_CHI2
         ROR ROR_LCL ROR_UCL
         signal_flag signal_ror signal_ebgm;
run;

proc datasets library=work nolist;
    delete glp1_ranked_in;
quit;

%_stamp(Section 3 - top signals ranked.)


/*==========================================================================
  4. QC REPORT
  --------------------------------------------------------------------------
  Four questions this section has to answer:
    1. Did the filter select the class the Step 1 cohort selected?
    2. How much of the signal set rests on compounded prod_ai variants?
    3. How much of it is not a clinical adverse event at all?
    4. Does the engine still recover SEMAGLUTIDE x Pancreatitis?

  Question 3 is the gate. It is the GLP-1 positive control from Gate 2
  (PRR 6.18, a = 456) and the only pair in this program whose answer is
  known in advance, so a filter that loses it is broken regardless of what
  the row counts say.
  ==========================================================================*/

/* Per-molecule signal counts, built from the reference table rather than a
   typed drug list so a fifth molecule needs no edit here. LEFT JOIN so a
   molecule with no signals at all appears as a zero rather than vanishing. */
proc sql;
    create table work.sig_by_drug as
        select      r.drug_label,
                    r.generation,
                    coalesce(s.n_pairs,      0) as n_pairs,
                    coalesce(s.n_prod_ai,    0) as n_prod_ai,
                    coalesce(s.n_evans,      0) as n_evans,
                    coalesce(s.n_evans_single, 0) as n_evans_single,
                    coalesce(s.n_evans_clinical, 0) as n_evans_clinical,
                    coalesce(s.n_ror,        0) as n_ror,
                    coalesce(s.n_ebgm,       0) as n_ebgm,
                    coalesce(s.n_all3,       0) as n_all3
        from        work.ref_glp1_drug as r
        left join   (select drug_label,
                            count(*)                as n_pairs,
                            count(distinct prod_ai) as n_prod_ai,
                            sum(signal_flag)        as n_evans,
                            sum(case when signal_flag = 1
                                          and single_ingredient = 1
                                     then 1 else 0 end) as n_evans_single,
                            sum(case when signal_flag = 1
                                          and single_ingredient = 1
                                          and pt_category = 'CLINICAL_AE'
                                     then 1 else 0 end) as n_evans_clinical,
                            sum(signal_ror)         as n_ror,
                            sum(signal_ebgm)        as n_ebgm,
                            sum(case when signal_flag = 1 and signal_ror = 1
                                          and signal_ebgm = 1
                                     then 1 else 0 end) as n_all3
                     from   work.glp1_signals
                     group by drug_label) as s
               on   r.drug_label = s.drug_label
        order by    r.drug_label;

    /* Reconciliation against Step 1. The signal side is summed over
       DISTINCT prod_ai because n_drug repeats down every PT row of the same
       ingredient string. See the header for why the two sides differ. */
    create table work.case_check as
        select      c.drug_label,
                    c.cohort_cases,
                    coalesce(v.signal_cases, 0)               as signal_cases,
                    calculated signal_cases - c.cohort_cases  as diff,
                    100 * (calculated signal_cases - c.cohort_cases)
                        / c.cohort_cases as pct_diff format=8.2
        from        (select drug_label, count(distinct primaryid) as cohort_cases
                     from   clean.glp1_cases
                     group by drug_label) as c
        left join   (select drug_label, sum(n_drug) as signal_cases
                     from   (select distinct drug_label, prod_ai, n_drug
                             from work.glp1_signals)
                     group by drug_label) as v
               on   c.drug_label = v.drug_label
        order by    c.drug_label;
quit;

/* Scalars for the QC table. */
proc sql noprint;
    select count(*)                  into :N_PAIRS    trimmed from work.glp1_signals;
    select count(distinct prod_ai)   into :N_PRODAI   trimmed from work.glp1_signals;
    select count(distinct pt)        into :N_PT       trimmed from work.glp1_signals;

    select count(*) into :N_EVALUABLE trimmed
        from work.glp1_signals where PRR is not missing;

    select sum(signal_flag) into :N_EVANS trimmed from work.glp1_signals;
    select sum(signal_ror)  into :N_ROR   trimmed from work.glp1_signals;
    select sum(signal_ebgm) into :N_EBGM  trimmed from work.glp1_signals;

    select count(*) into :N_ALL3 trimmed
        from work.glp1_signals
        where signal_flag = 1 and signal_ror = 1 and signal_ebgm = 1;

    /* The ranking hazard from the header, measured. */
    select count(*) into :N_COMBO_PAIRS trimmed
        from work.glp1_signals where single_ingredient = 0;
    select count(*) into :N_COMBO_EVANS trimmed
        from work.glp1_signals where single_ingredient = 0 and signal_flag = 1;
    select count(*) into :N_COMBO_TOP trimmed
        from work.glp1_top_signals where single_ingredient = 0;

    select count(*) into :N_TOP trimmed from work.glp1_top_signals;

    /* Molecules with fewer than 20 single-ingredient Evans signals - their
       block is short, which is a property of the data and not a bug. Counted
       on the same set the top-20 is drawn from, not on all Evans signals. */
    select count(*) into :N_SHORT trimmed
        from work.sig_by_drug where n_evans_clinical < 20;

    /* Non-clinical PT filter (2026-09-09). Both counts are taken on the
       Evans + single-ingredient set, which is the population the top table
       is drawn from - counting over all pairs would answer a question
       nobody asked. */
    select count(*) into :N_NOISE_EVANS trimmed
        from work.glp1_signals
        where signal_flag = 1 and single_ingredient = 1
          and pt_category ne 'CLINICAL_AE';
    select count(*) into :N_CLINICAL_EVANS trimmed
        from work.glp1_signals
        where signal_flag = 1 and single_ingredient = 1
          and pt_category = 'CLINICAL_AE';
    select count(*) into :N_NOISE_TOP trimmed
        from work.glp1_top_signals where pt_category ne 'CLINICAL_AE';

    /* Cohort reconciliation. The signal side is a subset by construction,
       so only a POSITIVE difference is impossible. */
    select count(*) into :N_OOT trimmed
        from work.case_check where pct_diff > 0 or pct_diff < -10;
quit;

/* The positive control. Matched on the molecule alone, not on any
   compounded variant, because that is the row Gate 2 validated. */
%let PC_FOUND = 0;
%let PC_PRR   = .;
%let PC_A     = .;
%let PC_RANK  = .;
%let PC_RANK_EBGM = .;

proc sql noprint;
    select count(*) into :PC_FOUND trimmed
        from work.glp1_signals
        where drug_label = "&DRUG_SEMA"
          and upcase(strip(prod_ai)) = "&DRUG_SEMA"
          and upcase(strip(pt))      = 'PANCREATITIS'
          and signal_flag = 1;
quit;

%macro pc_detail;
    %if &PC_FOUND > 0 %then %do;
        proc sql noprint;
            select PRR, a into :PC_PRR trimmed, :PC_A trimmed
                from work.glp1_signals
                where drug_label = "&DRUG_SEMA"
                  and upcase(strip(prod_ai)) = "&DRUG_SEMA"
                  and upcase(strip(pt))      = 'PANCREATITIS';
            select signal_rank into :PC_RANK trimmed
                from work.glp1_ranked
                where drug_label = "&DRUG_SEMA"
                  and upcase(strip(prod_ai)) = "&DRUG_SEMA"
                  and upcase(strip(pt))      = 'PANCREATITIS';

            /* The same row's rank under the retired EBGM ordering, over
               the SAME set - single-ingredient Evans signals. Kept as the
               like-for-like contrast: it shows what the ranking change cost
               or bought on the one pair whose answer is known independently.

               A subquery rather than a comparison against a macro variable,
               so the count cannot be off by one on a floating-point
               round-trip through a macro variable. */
            select count(*) + 1 into :PC_RANK_EBGM trimmed
                from work.glp1_ranked
                where drug_label = "&DRUG_SEMA"
                  and EBGM > (select EBGM from work.glp1_ranked
                              where drug_label = "&DRUG_SEMA"
                                and upcase(strip(prod_ai)) = "&DRUG_SEMA"
                                and upcase(strip(pt))      = 'PANCREATITIS');
        quit;
    %end;
%mend pc_detail;

%pc_detail

data work.qc_signal_profile;
    length metric $60 value 8 note $90;

    metric = 'GLP-1 prod_ai x PT pairs';
    value  = &N_PAIRS;
    note   = 'Rows in SIGNAL.GLP1_SIGNALS';                              output;

    metric = 'Distinct prod_ai strings matched';
    value  = &N_PRODAI;
    note   = 'Molecules alone plus compounded variants';                 output;

    metric = 'Distinct PTs';
    value  = &N_PT;
    note   = 'MedDRA Preferred Terms across the class';                  output;

    metric = 'Pairs with computable PRR';
    value  = &N_EVALUABLE;
    note   = 'Remainder had a zero 2x2 cell - not evaluable';            output;

    metric = 'Evans signals (signal_flag=1)';
    value  = &N_EVANS;
    note   = "a>=&MIN_CASES, PRR>=&PRR_THRESHOLD, chi2>=&CHI2_THRESHOLD"; output;

    /* Per molecule, from the reference table. */
    do until (_eof1);
        set work.sig_by_drug end=_eof1;
        metric = '  ' || strip(drug_label) || ' Evans signals';
        value  = n_evans;
        note   = catx(' ', strip(put(n_evans_single, comma12.)),
                           'single-ingredient, from',
                           strip(put(n_pairs, comma12.)), 'pairs /',
                           strip(put(n_prod_ai, comma12.)), 'prod_ai');
        output;
    end;

    metric = 'ROR signals (signal_ror=1)';
    value  = &N_ROR;
    note   = 'ROR 95% CI lower bound > 1, no case-count floor';          output;

    metric = 'EBGM signals (signal_ebgm=1)';
    value  = &N_EBGM;
    note   = 'EB05 >= 2, untruncated fit - ranking reference only';       output;

    metric = 'All three criteria';
    value  = &N_ALL3;
    note   = 'Intersection - EBGM uses a mis-fit prior; Evans + ROR is the count';  output;

    /* Cohort reconciliation, per molecule. */
    do until (_eof2);
        set work.case_check end=_eof2;
        metric = '  ' || strip(drug_label) || ' cases in 2x2';
        value  = signal_cases;
        note   = catx(' ', 'Step 1 cohort', strip(put(cohort_cases, comma12.)),
                           '- difference', strip(put(pct_diff, 8.2)), '%');
        output;
    end;

    metric = 'Pairs on a combination prod_ai';
    value  = &N_COMBO_PAIRS;
    note   = 'single_ingredient=0 - compounded or combination products';  output;

    metric = 'Evans signals excluded as a combination';
    value  = &N_COMBO_EVANS;
    note   = 'Kept in GLP1_SIGNALS, held out of the top table';           output;

    metric = 'Top-20 slots held by a combination';
    value  = &N_COMBO_TOP;
    note   = 'Must be 0 - the single_ingredient filter guarantees it';    output;

    metric = 'Evans signals filtered as non-clinical';
    value  = &N_NOISE_EVANS;
    note   = 'MED_ERROR DEVICE PRODUCT_QUALITY DOSING_ERROR PROCEDURE LITIGATION LOE'; output;

    metric = 'Clinical Evans signals (top-table population)';
    value  = &N_CLINICAL_EVANS;
    note   = 'pt_category=CLINICAL_AE, single ingredient, Evans';         output;

    metric = 'Top-20 slots held by a non-clinical PT';
    value  = &N_NOISE_TOP;
    note   = 'Must be 0 - the pt_category filter guarantees it';          output;

    metric = 'Rows in the top-signals table';
    value  = &N_TOP;
    note   = 'Up to 20 per molecule, fewer where signals are scarce';     output;

    metric = 'SEMAGLUTIDE x Pancreatitis PRR';
    value  = &PC_PRR;
    note   = 'Gate 2 positive control - expected 6.18 on 456 cases';      output;

    metric = 'SEMAGLUTIDE x Pancreatitis rank (PRR)';
    value  = &PC_RANK;
    note   = 'Delivered ordering - <=20 means it makes the table';         output;

    metric = 'SEMAGLUTIDE x Pancreatitis rank (EBGM)';
    value  = &PC_RANK_EBGM;
    note   = 'Retired ordering, same set - contrast only, EBGM is mis-fit'; output;

    stop;
    label metric = 'Metric' value = 'Value' note = 'Note';
    keep  metric value note;
run;

/* Assertions in the log. The log is the artefact reviewed after a SAS ODA
   run, so every verdict has to be visible there and not only in the CSV. */
%macro profile_verdict;

    /* The gate. */
    %if &PC_FOUND > 0 %then %do;
        %put NOTE: Validation check - SEMAGLUTIDE x Pancreatitis confirmed in GLP-1 signal profile.;
        %put NOTE-       PRR = &PC_PRR on a = &PC_A cases.;
        %put NOTE-       Rank within SEMAGLUTIDE, single-ingredient Evans signals:;
        %put NOTE-       &PC_RANK by PRR (delivered), &PC_RANK_EBGM by EBGM (retired) - same set, ordering alone.;
        %if %sysevalf(&PC_RANK > 20) %then %do;
            %put WARNING: The GLP-1 positive control is outside the top 20 under PRR ordering.;
            %put WARNING- glp1_top_signals.csv will not contain the class effect the report is about.;
        %end;
        %else
            %put NOTE-       Inside the top 20 - it appears in glp1_top_signals.csv.;
    %end;
    %else %do;
        %put WARNING: SEMAGLUTIDE x Pancreatitis NOT found - check signal filtering logic.;
        %put WARNING- Gate 2 recorded this pair at PRR 6.18 on 456 cases with signal_flag=1.;
        %put WARNING- Either the FIND filter is not matching prod_ai or ALL_SIGNALS was rebuilt.;
    %end;

    /* Cohort reconciliation. */
    %if &N_OOT = 0 %then
        %put NOTE: Cohort reconciliation passed - every molecule within tolerance of Step 1.;
    %else %do;
        %put WARNING: &N_OOT molecule(s) outside the reconciliation tolerance.;
        %put WARNING- The 2x2 case count must be a subset of the Step 1 cohort and within 10%% of it.;

        proc print data=work.case_check noobs label;
            where pct_diff > 0 or pct_diff < -10;
            var drug_label cohort_cases signal_cases diff pct_diff;
            format cohort_cases signal_cases diff comma12.;
            title2 'Molecules outside the reconciliation tolerance';
        run;
        title2;
    %end;

    /* Assertion, not a warning: section 3 filters on single_ingredient = 1,
       so a non-zero count here means that filter did not do what it says. */
    %if &N_COMBO_TOP > 0 %then %do;
        %put ERROR: &N_COMBO_TOP of &N_TOP top-20 rows rest on a combination prod_ai.;
        %put ERROR- Section 3 filters on single_ingredient = 1, so this must be 0.;

        proc print data=work.glp1_top_signals noobs label;
            where single_ingredient = 0;
            var drug_label prod_ai pt signal_rank a n_drug PRR EBGM;
            format a n_drug comma12. PRR EBGM 10.2;
            title2 'ERROR - top-20 rows resting on a combination product';
        run;
        title2;
    %end;
    %else %put NOTE: Combination assertion passed - &N_COMBO_EVANS Evans signal(s) held out of the top table.;

    %if &N_SHORT > 0 %then
        %put NOTE: &N_SHORT molecule(s) have fewer than 20 clinical Evans signals - their block is short by design.;

    /* Assertion, not a note: section 3 filters on pt_category, so a
       non-clinical PT in the top table means the filter did not apply. */
    %if &N_NOISE_TOP > 0 %then %do;
        %put ERROR: &N_NOISE_TOP of &N_TOP top-20 rows hold a non-clinical PT.;
        %put ERROR- Section 3 filters on pt_category = CLINICAL_AE, so this must be 0.;
    %end;
    %else %do;
        %put NOTE: Non-clinical PT filter: &N_NOISE_EVANS Evans signal(s) held out of the top table.;
        %put NOTE-       &N_CLINICAL_EVANS clinical Evans signal(s) remain as the top-table population.;
    %end;

%mend profile_verdict;

%profile_verdict

title2 'Table 1: Signals by Molecule';
proc print data=work.sig_by_drug noobs label;
    var drug_label generation n_prod_ai n_pairs n_evans n_evans_single
        n_evans_clinical n_ror n_ebgm n_all3;
    format n_pairs n_evans n_evans_single n_evans_clinical n_ror n_ebgm n_all3 comma12.;
    label drug_label     = 'Molecule'   generation = 'Generation'
          n_prod_ai      = 'prod_ai'    n_pairs    = 'Pairs'
          n_evans        = 'Evans'      n_evans_single = 'Evans (single ai)'
          n_evans_clinical = 'Evans (single ai, clinical)'
          n_ror          = 'ROR'        n_ebgm     = 'EBGM'
          n_all3         = 'All three';
run;

title2 'Table 2: Step 1 Cohort Reconciliation';
proc print data=work.case_check noobs label;
    var drug_label cohort_cases signal_cases diff pct_diff;
    format cohort_cases signal_cases diff comma12.;
    label drug_label   = 'Molecule'        cohort_cases = 'Step 1 Cohort'
          signal_cases = 'Cases in 2x2'    diff         = 'Difference'
          pct_diff     = 'Difference (%)';
run;

title2 'Table 3: Signal Profile QC';
proc print data=work.qc_signal_profile noobs label;
    format value comma12.2;
run;

title2 'Table 4: Top 10 Evans Signals per Molecule (ranked by PRR)';
proc print data=work.glp1_top_signals noobs label;
    where signal_rank <= 10;
    var drug_label pt signal_rank a n_drug PRR PRR_LCL EBGM EB05;
    format a n_drug comma12. PRR PRR_LCL EBGM EB05 10.2;
    label drug_label  = 'Molecule'  pt     = 'Reaction (PT)'
          signal_rank = 'Rank'      a      = 'Cases'
          n_drug      = 'Drug N';
run;
title2;

%_stamp(Section 4 - QC complete.)


/*==========================================================================
  5. SAVE AND WRAP UP
  --------------------------------------------------------------------------
  compress=yes: prod_ai is $500 and most of the class shares one short
  ingredient string, so the saving is large and Steps 3-7 read this dataset
  repeatedly.

  The LENGTH statement before the SET pins the widths the spec requires -
  prod_ai $500, pt $100, drug_label $20, generation $12 - rather than
  trusting them to survive the join, and fixes column order at the same time
  so a downstream PROC PRINT reads the same way every run.
  ==========================================================================*/
data signal.glp1_signals (compress=yes
        label='GLP-1 disproportionality signals, one row per prod_ai x PT');
    length drug_label $20 generation $12 prod_ai $500 pt $100
           single_ingredient 8 pt_category $25;
    set work.glp1_signals;
run;

proc export data=work.glp1_signals
            outfile="&OUT_TABLES./glp1_signals.csv" dbms=csv replace;
run;

proc export data=work.glp1_top_signals
            outfile="&OUT_TABLES./glp1_top_signals.csv" dbms=csv replace;
run;

proc export data=work.qc_signal_profile
            outfile="&OUT_QC./qc_glp1_signal_profile.csv" dbms=csv replace;
run;

%macro finish;
    %local e;
    %let e = %sysevalf(%sysfunc(datetime()) - &_T0);

    %put NOTE: ============================================;
    %put NOTE: 03_glp1_signal_profile.sas complete.;
    %put NOTE: prod_ai x PT pairs   = &N_PAIRS (&N_PRODAI prod_ai, &N_PT PTs);
    %put NOTE: Evaluable PRR        = &N_EVALUABLE;
    %put NOTE: Evans / ROR / EBGM   = &N_EVANS / &N_ROR / &N_EBGM;
    %put NOTE: All three criteria   = &N_ALL3;
    %put NOTE: Combination pairs    = &N_COMBO_PAIRS (Evans: &N_COMBO_EVANS, all held out of the top table);
    %put NOTE: Top-signals rows     = &N_TOP (single-ingredient Evans, ranked by PRR);
    %put NOTE: Positive control     = rank &PC_RANK by PRR, &PC_RANK_EBGM by EBGM (single-ingredient set);
    %put NOTE: Dataset              = SIGNAL.GLP1_SIGNALS;
    %put NOTE: Tables               = &OUT_TABLES./glp1_signals.csv;
    %put NOTE:                        &OUT_TABLES./glp1_top_signals.csv;
    %put NOTE: QC                   = &OUT_QC./qc_glp1_signal_profile.csv;
    %put NOTE: Elapsed              = %sysfunc(putn(&e, time12.2));
    %put NOTE: ============================================;

    %if &PC_FOUND > 0 and &N_OOT = 0 %then
        %put NOTE: GLP-1 SIGNAL PROFILE PASSED - ready for Phase 3 Step 3.;
    %else
        %put WARNING: GLP-1 SIGNAL PROFILE needs review - see the warnings above.;
%mend finish;

%finish

/*****************************************************************************
 * 03_glp1_report.sas - GLP-1 deliverables assembly
 *
 * Purpose:  Phase 3 Step 7. Turn the outputs of Steps 1-6 into the tables
 *           that go in front of a reader: an ODS HTML report with formatted,
 *           footnoted PROC REPORT output, and one CSV per table for the
 *           Phase 4 Tableau dashboard.
 *
 *           This program computes NO new statistic. Every PRR, ROR, EBGM,
 *           trend label and validation verdict shown here was produced
 *           upstream. What happens here is selection, formatting and
 *           ordering - and the counts in Section 9 are looked up rather than
 *           typed, so a rerun on refreshed data cannot leave the narrative
 *           contradicting the tables above it.
 *
 * Inputs:   CLEAN.GLP1_CASES  GLP1_REAC  GLP1_INDI  GLP1_OUTC   Step 1
 *           SIGNAL.GLP1_SIGNALS  GLP1_TOP_SIGNALS               Step 2
 *           SIGNAL.GLP1_COMPARE_SEMA_TIRZ                       Step 3
 *           SIGNAL.GLP1_COMPARE_GENERATION
 *           SIGNAL.GLP1_COMPARE_OVERVIEW
 *           SIGNAL.GLP1_AGE_DEPENDENT  GLP1_SUBGROUP_AGE        Step 4
 *           SIGNAL.GLP1_TREND_SUMMARY  GLP1_TIME_TREND          Step 5
 *           SIGNAL.GLP1_EMERGING
 *           SIGNAL.GLP1_VALIDATION  _BY_DRUG  _DETAIL           Step 6
 *
 * Outputs:  &OUT_TABLES/glp1_report.html            the formatted report
 *           &OUT_TABLES/report_cohort_summary.csv   Table 1
 *           &OUT_TABLES/report_top_signals.csv      Table 2
 *           &OUT_TABLES/report_drug_compare.csv     Table 3a
 *           &OUT_TABLES/report_gen_compare.csv      Table 3b
 *           &OUT_TABLES/report_four_drug.csv        Table 3c
 *           &OUT_TABLES/report_subgroup_highlights.csv  Table 4
 *           &OUT_TABLES/report_time_trends.csv      Table 5
 *           &OUT_TABLES/report_validation.csv       Table 6
 *           &OUT_TABLES/report_executive_summary.csv
 *           &OUT_TABLES/report_crown_jewels.csv
 *           &OUT_QC/qc_glp1_report.csv              row count per table
 *
 * -----------------------------------------------------------------------
 * WHY EVERY PT TABLE IS FILTERED TO CLINICAL_AE
 * -----------------------------------------------------------------------
 * 00_ref_pt_filter.sas classifies each PT into CLINICAL_AE, MED_ERROR,
 * DOSING_ERROR, DEVICE, PRODUCT_QUALITY, PROCEDURE_NOISE, LACK_OF_EFFICACY
 * or LITIGATION_FINGERPRINT, and stores the answer as PT_CATEGORY on the
 * signal datasets. It never deletes a row, because the non-clinical
 * categories are evidence about how this class is reported and belong in
 * the underlying data.
 *
 * They do not belong in a safety table. Left in, 'Incorrect dose
 * administered' and 'Device difficult to use' outrank pancreatitis on PRR
 * and the reader's first impression of the top-signals table is a list of
 * things that are not adverse drug reactions. Every table here that names a
 * PT is therefore filtered to PT_CATEGORY = 'CLINICAL_AE'; the CSV exports
 * from Steps 2-6 keep the full picture, and qc_glp1_report.csv records how
 * many rows each filter removed.
 *
 * -----------------------------------------------------------------------
 * WHY THE KEY-FINDINGS TABLE LOOKS ITS NUMBERS UP
 * -----------------------------------------------------------------------
 * Section 9 is a short, curated list of the findings worth talking about.
 * The narrative around each one is a judgement call and is written out in
 * full. The numbers inside it are not: each PRR, case count and share is
 * read back out of the dataset that produced it, at run time.
 *
 * The reason is specific rather than stylistic. The draft of this table
 * carried a hand-copied claim that tirzepatide's injection-site PRR moved
 * from 2.8 to 13.8 once semaglutide was removed from the comparator.
 * Neither number is in any dataset this pipeline produces, and no
 * comparator-exclusion analysis exists to produce them - semaglutide is
 * 35,705 cases against a FAERS background of roughly 1.5 million, so
 * dropping it cannot move a PRR by a factor of five. A number that cannot
 * be traced to a row is worse than no number, and worst of all in the one
 * table written to be quoted out loud. The finding was rewritten around
 * what the data does show, and the rest are now derived so the same thing
 * cannot happen on the next refresh.
 *
 * -----------------------------------------------------------------------
 * WHAT THE FORMATTING MEANS
 * -----------------------------------------------------------------------
 * One palette across every table, so a colour means the same thing twice:
 *
 *   #FFCCCC  red     read this row harder - an Emerging trend, an
 *                    Elderly-concentrated pattern, a failed validation
 *                    verdict, or in Table 2 a signal resting on under five
 *                    reports. Red is 'slow down', not 'higher risk': in
 *                    Table 2 it marks the WEAKEST rows, not the strongest,
 *                    and that table's footnote says so plainly
 *   #FFFFCC  yellow  borderline - WEAK or SUB_THRESHOLD, or five to nine
 *                    reports behind a Table 2 signal
 *   #CCFFCC  green   reassuring or confirmatory - REPLICATED, Declining,
 *                    a PT signalling on all four molecules
 *   #FFE0CC  orange  Accelerating trend, tirzepatide side of a comparison
 *   #CCCCFF  blue    Youth-concentrated, semaglutide side of a comparison
 *
 * Signal strength notation in Table 2: * clears Evans; ** Evans and ROR;
 * *** Evans, ROR and EBGM. EBGM is labelled an EB shrinkage estimate and
 * used for ranking only - the delivered fit is untruncated, with a prior
 * mean of 17.3 against DuMouchel's ~1.04, so it gates nothing here or
 * anywhere else in this pipeline. Detection is Evans criteria throughout.
 *
 * -----------------------------------------------------------------------
 * NOTES ON THE INPUTS THAT AFFECT HOW THE TABLES READ
 * -----------------------------------------------------------------------
 * CLEAN.GLP1_CASES is one row per primaryid x drug_label, so a combination
 * product is counted under every molecule it contains. Per-drug case counts
 * therefore sum to more than the cohort total and the per-drug shares of
 * the cohort sum to more than 100%. Cohort totals use COUNT(DISTINCT
 * primaryid); Table 1 footnotes the rest.
 *
 * Steps 3 to 5 name their subject column EVENT and carry EVENT_TYPE to say
 * whether it holds a PT or a grouped signal. Step 2 names it PT. Both are
 * kept as they are and labelled 'Reaction (PT)' or 'Event' accordingly;
 * nothing upstream is renamed to make this program tidier.
 *
 * Author:   Hingling Yu (design, specification, execution, review)
 *           Code drafted with AI coding assistant (Claude)
 * Created:  2026-09-10
 *****************************************************************************/

/*==========================================================================
  1. SETUP
  ==========================================================================*/

/* Literal path, not &BASE./sas/... - &BASE is defined BY the file being
   included, so it cannot be used to find it. Same convention as every other
   program in this pipeline.

   00_ref_pt_filter.sas and 00_ref_pt_group.sas are deliberately NOT
   included. This program calls neither %pt_category() nor the group
   reference: PT_CATEGORY and the grouped EVENT rows are stored columns on
   the datasets it reads, written when those datasets were built. Including
   two reference programs whose macros nobody calls would add two upload
   dependencies that can fail the run, and ~40KB of QC output to a log whose
   job today is to show which tables were written. */
%include "/home/u64291357/mydata/sas/00_config.sas";

/* 00_config.sas turns MPRINT and SYMBOLGEN on. The guard macros below run
   once per table and the trace would bury the row counts. */
options nosymbolgen nomprint;

options nodate nonumber;

/* ESCAPECHAR is what lets %_skipped push an inline style directive into the
   HTML; without it the directive prints as literal text. NOPROCTITLE
   suppresses the procedure title PROC REPORT writes above every table -
   eleven repetitions of 'The REPORT Procedure' in a document meant to read
   as a report. Both are restored in Section 10. */
ods escapechar = "^";
ods noproctitle;

%let _T0 = %sysfunc(datetime());

%macro _stamp(label);
    %local e;
    %let e = %sysevalf(%sysfunc(datetime()) - &_T0);
    %put NOTE: [%sysfunc(putn(&e, time12.2))] &label;
%mend _stamp;

/* &OUT_TABLES and &OUT_QC must exist before ODS and PROC EXPORT write into
   them. XCMD is disabled on SAS ODA, so DCREATE is the only way to create a
   directory from code; it is a no-op when the directory is already there. */
%macro _ensure_dir(subdir);
    %local rc;
    %if %sysfunc(fileexist(&BASE./output/&subdir)) = 0 %then %do;
        %let rc = %sysfunc(dcreate(&subdir, &BASE./output));
        %if %length(&rc) = 0 %then
            %put WARNING: Could not create &BASE./output/&subdir - writes there will fail.;
    %end;
%mend _ensure_dir;

%_ensure_dir(tables)
%_ensure_dir(qc)

/*--------------------------------------------------------------------------
  %_nobs(ds) - observation count, 0 when the dataset does not exist

  Used to guard every PROC REPORT. PROC REPORT and PROC PRINT both abort on
  a zero-observation input, and several tables here can legitimately come
  back empty - Table 3a keeps only divergent signalling pairs, Table 4 only
  age strata with adequate coverage. An empty table is a finding, not an
  error, and should print a note rather than stop the report.

  Built from OPEN/ATTRN rather than PROC SQL on purpose: it has to be usable
  inside %IF, which means it must resolve to a number without generating any
  SAS code. NLOBS is unavailable on some engines and returns a negative
  value there, so NOBS is the fallback.
  --------------------------------------------------------------------------*/
%macro _nobs(ds);
%local dsid n;
%let n = 0;
%if %sysfunc(exist(&ds)) %then %do;
    %let dsid = %sysfunc(open(&ds));
    %if &dsid > 0 %then %do;
        %let n = %sysfunc(attrn(&dsid, nlobs));
        %if &n < 0 %then %let n = %sysfunc(attrn(&dsid, nobs));
        %let dsid = %sysfunc(close(&dsid));
    %end;
%end;
%if &n < 0 %then %let n = 0;
&n
%mend _nobs;

/*--------------------------------------------------------------------------
  Input inventory

  Checked up front rather than discovered inside a join. A missing table
  makes PROC SQL blame its own FROM clause, and by the time the real cause
  surfaces it is buried under every step that followed. Missing inputs are
  counted, not fatal: a partial report is more useful than none, and the
  count is repeated in the wrap-up so it cannot be missed.
  --------------------------------------------------------------------------*/
%global _MISSING_INPUTS;
%let _MISSING_INPUTS = 0;

%macro check_input(ds);
    %if %sysfunc(exist(&ds)) %then
        %put NOTE: Input OK - &ds (%_nobs(&ds) rows).;
    %else %do;
        %put WARNING: Input MISSING - &ds - the tables that read it will be empty.;
        %let _MISSING_INPUTS = %eval(&_MISSING_INPUTS + 1);
    %end;
%mend check_input;

%check_input(clean.glp1_cases)
%check_input(clean.glp1_reac)
%check_input(clean.glp1_indi)
%check_input(clean.glp1_outc)
%check_input(signal.glp1_signals)
%check_input(signal.glp1_top_signals)
%check_input(signal.glp1_compare_sema_tirz)
%check_input(signal.glp1_compare_generation)
%check_input(signal.glp1_compare_overview)
%check_input(signal.glp1_subgroup_age)
%check_input(signal.glp1_age_dependent)
%check_input(signal.glp1_time_trend)
%check_input(signal.glp1_trend_summary)
%check_input(signal.glp1_emerging)
%check_input(signal.glp1_validation)
%check_input(signal.glp1_validation_by_drug)
%check_input(signal.glp1_validation_detail)

/*--------------------------------------------------------------------------
  %_shell(out, lengths) - empty typed placeholder

  When an input is missing, its report table is created empty with the right
  columns instead of not created at all. Everything downstream - the CSV
  export, the QC count, the completeness check - then behaves normally and
  reports zero rows, rather than failing on a dataset that is not there and
  taking the rest of the report with it.
  --------------------------------------------------------------------------*/
%macro _shell(out, lengths);
    data &out;
        length &lengths;
        stop;
    run;
    %put WARNING: &out is empty - its input dataset is missing.;
%mend _shell;

/*--------------------------------------------------------------------------
  %_skipped(what) - say so in the report, not only in the log

  A reader looking at the HTML needs to know the difference between a table
  that found nothing and a table that was never run.
  --------------------------------------------------------------------------*/
%macro _skipped(what);
    ods text="^{style [color=#888888 font_style=italic] &what}";
    %put NOTE: &what;
%mend _skipped;

ods html file="&OUT_TABLES./glp1_report.html"
         style=HTMLBlue
         gtitle gfootnote;
ods listing close;

title  "FAERS GLP-1 Receptor Agonist Signal Detection";
title2 "Disproportionality analysis, FAERS 2025Q3 - 2026Q2";

%_stamp(03_glp1_report.sas started.)


/*==========================================================================
  2. TABLE 1 - COHORT CHARACTERISTICS

  The Table 1 every clinical and PV study opens with: who is in the cohort,
  before any statement about what happened to them.

  Delivered in two shapes. WORK.COHORT_OVERALL is one row per molecule and
  is what the reader sees first. WORK.REPORT_COHORT_SUMMARY stacks overall
  counts, age, sex, indication and outcome into one long table - the shape
  Tableau wants, where a single sheet pivots across all five breakdowns
  instead of needing five extracts.

  The stacked table carries three columns beyond the four the reader sees:

    DENOM           the denominator each PCT was computed against. Overall
                    rows use the cohort; every other row uses that drug's
                    own case count. Without it a reader of the CSV alone
                    cannot tell which of the two a percentage refers to.
    CATEGORY_ORDER  presentation order of the five blocks. CATEGORY sorts
                    alphabetically otherwise and the overall counts land
                    fourth, between indications and sex.
    LABEL_ORDER     order within a block. Age groups sort '46-64' before
                    '<=45' on character collation, which is wrong and looks
                    like a bug in the numbers.
  ==========================================================================*/

%macro build_table1;

%if %sysfunc(exist(clean.glp1_cases)) = 0 %then %do;
    %_shell(work.cohort_overall,
            %str(drug_label $20 generation $12 n_cases 8 pct_of_cohort 8))
    %_shell(work.report_cohort_summary,
            %str(drug_label $20 category $30 label $100 n_cases 8 denom 8 pct 8
                 category_order 8 label_order 8))
    %return;
%end;

/* Cohort denominator. COUNT(DISTINCT primaryid) rather than COUNT(*): a
   combination product such as SEMAGLUTIDE\CYANOCOBALAMIN has a row under
   every class member it names, and counting rows would inflate the cohort
   by the number of those products. */
%local n_cohort;
proc sql noprint;
    select count(distinct primaryid) into :n_cohort trimmed
        from clean.glp1_cases;
quit;

/* 2a. One row per molecule. */
proc sql;
    create table work.cohort_overall as
        select      drug_label,
                    generation,
                    count(distinct primaryid) as n_cases,
                    100 * count(distinct primaryid) / &n_cohort
                        as pct_of_cohort
        from        clean.glp1_cases
        group by    drug_label, generation
        order by    n_cases desc;
quit;

/* Per-drug denominators for every within-drug percentage below. */
proc sql;
    create table work._t1_denom as
        select drug_label, n_cases as denom
            from work.cohort_overall;
quit;

/* 2a as a stacked block. */
data work._t1_overall;
    length drug_label $20 category $30 label $100;
    set work.cohort_overall;
    category       = 'Overall';
    label          = strip(generation) || ' generation';
    denom          = &n_cohort;
    category_order = 1;
    label_order    = 1;
    keep drug_label category label n_cases denom category_order label_order;
run;

/* 2b. Age group.

   AGE_GRP is the project's own three-band grouping from 03_glp1_extract.sas
   and holds 'Unknown' wherever age was absent or reported in a unit other
   than years. That share is large and differs by molecule, so it is shown
   rather than dropped: a reader who cannot see it would read the three real
   bands as if they covered the whole cohort. */
proc sql;
    create table work._t1_age as
        select      c.drug_label,
                    'Age group'  as category  length=30,
                    c.age_grp    as label     length=100,
                    count(distinct c.primaryid) as n_cases,
                    d.denom,
                    2 as category_order,
                    case strip(c.age_grp)
                        when '<=45'  then 1
                        when '46-64' then 2
                        when '>=65'  then 3
                        else 4
                    end as label_order
        from        clean.glp1_cases as c
        left join   work._t1_denom   as d on c.drug_label = d.drug_label
        group by    c.drug_label, c.age_grp, d.denom, calculated label_order;
quit;

/* 2c. Sex. FAERS codes M, F and UNK, and leaves the field blank on some
   cases; blank and UNK are not the same thing upstream but mean the same
   thing here. */
proc sql;
    create table work._t1_sex as
        select      c.drug_label,
                    'Sex' as category length=30,
                    case when strip(c.sex) = 'M'   then 'Male'
                         when strip(c.sex) = 'F'   then 'Female'
                         when missing(c.sex)
                           or strip(c.sex) = 'UNK' then 'Not reported'
                         else strip(c.sex)
                    end as label length=100,
                    count(distinct c.primaryid) as n_cases,
                    d.denom,
                    3 as category_order,
                    1 as label_order
        from        clean.glp1_cases as c
        left join   work._t1_denom   as d on c.drug_label = d.drug_label
        group by    c.drug_label, calculated label, d.denom;
quit;

/* 2d. Top 5 indications.

   What the drug was being taken for, which for this class separates the
   diabetes population from the weight-management one - two cohorts with
   different ages, different comorbidity and different reporting behaviour.
   The percentage is of that molecule's cases, and a case can report more
   than one indication, so the five do not sum to the drug's total. */
proc sql;
    create table work._t1_indi as
        select      i.drug_label,
                    'Indication (top 5)' as category length=30,
                    i.indi_pt as label length=100,
                    count(distinct i.primaryid) as n_cases,
                    d.denom,
                    4 as category_order,
                    1 as label_order
        from        clean.glp1_indi as i
        left join   work._t1_denom  as d on i.drug_label = d.drug_label
        where       not missing(i.indi_pt)
        group by    i.drug_label, i.indi_pt, d.denom
        order by    i.drug_label, n_cases desc;
quit;

data work._t1_indi;
    set work._t1_indi;
    by drug_label;
    if first.drug_label then _rank = 0;
    _rank + 1;
    if _rank <= 5;
    drop _rank;
run;

/* 2e. Outcomes.

   GLP1_OUTC carries primaryid and outc_cod only, so the molecule has to
   come from GLP1_CASES. The join is on primaryid alone - which is correct
   here, unlike the reaction joins in Steps 3 to 5: an outcome belongs to
   the case, not to one drug on it, so a combination-product case genuinely
   contributes its outcome to both molecules.

   A case can carry several outcome codes, so these do not sum to 100%
   either. Read them as 'x% of this molecule's cases reported death', not
   as a partition. */
proc sql;
    create table work._t1_outc as
        select      c.drug_label,
                    'Outcome' as category length=30,
                    put(o.outc_cod, $outcf.) as label length=100,
                    count(distinct o.primaryid) as n_cases,
                    d.denom,
                    5 as category_order,
                    1 as label_order
        from        clean.glp1_outc  as o
        inner join  clean.glp1_cases as c on o.primaryid = c.primaryid
        left join   work._t1_denom   as d on c.drug_label = d.drug_label
        where       not missing(o.outc_cod)
        group by    c.drug_label, calculated label, d.denom;
quit;

data work.report_cohort_summary;
    length drug_label $20 category $30 label $100
           n_cases 8 denom 8 pct 8 category_order 8 label_order 8;
    set work._t1_overall work._t1_age work._t1_sex
        work._t1_indi    work._t1_outc;
    if denom > 0 then pct = 100 * n_cases / denom;

    label drug_label     = 'Drug'
          category       = 'Breakdown'
          label          = 'Level'
          n_cases        = 'Cases'
          denom          = 'Denominator'
          pct            = 'Percent'
          category_order = 'Breakdown sort key'
          label_order    = 'Level sort key';
run;

proc sort data=work.report_cohort_summary;
    by category_order drug_label label_order descending n_cases;
run;

proc datasets library=work nolist;
    delete _t1_overall _t1_age _t1_sex _t1_indi _t1_outc _t1_denom;
quit;

%mend build_table1;

%build_table1

title3 "Table 1. GLP-1 Cohort Characteristics";
footnote2 "Source: FDA FAERS quarterly extracts 2025Q3-2026Q2. Cases with a GLP-1 receptor agonist in the Primary Suspect role.";
footnote3 "A combination product is counted under every class member it names, so per-drug counts sum to more than the cohort and the shares to more than 100%.";

%macro t1_report;
%if %_nobs(work.cohort_overall) = 0 %then %do;
    %_skipped(Table 1 skipped - CLEAN.GLP1_CASES was not available.)
    %return;
%end;

proc report data=work.cohort_overall nowd;
    columns drug_label generation n_cases pct_of_cohort;
    define drug_label    / display 'Drug'
                           style(column)={font_weight=bold};
    define generation    / display 'Generation';
    define n_cases       / display 'Cases' format=comma10.
                           style(column)={just=right};
    define pct_of_cohort / display '% of cohort' format=5.1
                           style(column)={just=right};
run;
%mend t1_report;

%t1_report

title3 "Table 1b. Cohort Breakdown by Age, Sex, Indication and Outcome";
footnote4 "Percentages within Overall are of the full GLP-1 cohort; every other row is of that molecule's own case count (DENOM). Indications and outcomes are not mutually exclusive.";

%macro t1b_report;
%if %_nobs(work.report_cohort_summary) = 0 %then %do;
    %_skipped(Table 1b skipped - CLEAN.GLP1_CASES was not available.)
    %return;
%end;

proc report data=work.report_cohort_summary nowd;
    columns category_order category drug_label label n_cases pct;
    define category_order / order noprint;
    define category   / order 'Breakdown'
                        style(column)={font_weight=bold};
    define drug_label / order 'Drug';
    define label      / display 'Level';
    define n_cases    / display 'Cases' format=comma10.
                        style(column)={just=right};
    define pct        / display 'Percent' format=5.1
                        style(column)={just=right};
run;
%mend t1b_report;

%t1b_report

title3;
footnote2;

%_stamp(Section 2 - Table 1 built.)


/*==========================================================================
  3. TABLE 2 - TOP SIGNALS PER MOLECULE

  SIGNAL.GLP1_TOP_SIGNALS already holds the top slice per molecule by
  SIGNAL_RANK. All that happens here is the CLINICAL_AE filter, the three
  confidence-interval strings, and the strength mark.

  The strength mark is the point of the table. Evans criteria alone is a low
  bar on a rare term: a >= 3 with PRR >= 2 will flag a PT reported five
  times. Showing whether ROR and the EB shrinkage estimate agree, in one
  glanceable column, is what separates a signal worth a case review from an
  artefact of a thin count - without promoting EBGM into a gate, which this
  pipeline does not do.

  ---------------------------------------------------------------------
  WHY THE SHADING IS ON CASE COUNT AND NOT ON PRR
  ---------------------------------------------------------------------
  It was on PRR first - red above 5, yellow from 2 to 5, the obvious choice
  and the one every other table here uses. On this data it shaded all eighty
  rows red, because the lowest PRR in the table is 7.6. The yellow band
  never fired, and a footnote described a colour no reader would ever see.

  That is not bad luck, it is the construction of the table. These rows are
  the top twenty per molecule out of a set already filtered to SIGNAL_FLAG=1,
  so every one of them cleared PRR >= &PRR_THRESHOLD before it got here and
  most cleared it by an order of magnitude. A PRR band cannot discriminate
  inside a slice selected on PRR. The strength column has the same problem
  for the same reason - 77 of 80 rows read '***'.

  What does vary, and varies enormously, is how many reports each ratio
  rests on: 31 of the 80 have fewer than ten cases, and semaglutide's third
  ranked PT sits at PRR 62.9 on three reports with a confidence interval
  from 10.5 to 376. That is the number a reviewer needs flagged, and it is
  the question anyone reading this table will ask first. So red now means
  thin, not high.

  The bands below are report-level presentation choices and are deliberately
  NOT the Evans MIN_CASES threshold from 00_config.sas. That threshold
  decides what counts as a signal at all and was applied upstream; these
  decide when to warn the reader that a signal is resting on very little.
  ==========================================================================*/

%let T2_RED_N    = 5;    /* fewer than this many cases  -> red    */
%let T2_YELLOW_N = 10;   /* fewer than this many cases  -> yellow */

%macro build_table2;

%if %sysfunc(exist(signal.glp1_top_signals)) = 0 %then %do;
    %_shell(work.report_top_signals,
            %str(drug_label $20 pt $100 n_cases 8 PRR 8 PRR_CI $30
                 ROR 8 ROR_CI $30 EBGM 8 EBGM_CI $30
                 signal_flag 8 signal_ror 8 signal_ebgm 8 strength $3))
    %return;
%end;

/* The CASE around each interval string is not decoration. PUT() of a
   missing numeric returns '.', so an unevaluable EBGM would otherwise print
   as '. (. - .)' - which reads like a computed value rather than an absent
   one. CAT with STRIP on each component rather than CATS: CATS would strip
   the separators too and run the bounds together. */
proc sql;
    create table work.report_top_signals as
        select  drug_label,
                pt,
                a as n_cases,
                PRR,
                case when PRR is not missing
                     then cat(strip(put(PRR, 8.1)), ' (',
                              strip(put(PRR_LCL, 8.1)), ' - ',
                              strip(put(PRR_UCL, 8.1)), ')')
                     else '' end as PRR_CI length=30,
                ROR,
                case when ROR is not missing
                     then cat(strip(put(ROR, 8.1)), ' (',
                              strip(put(ROR_LCL, 8.1)), ' - ',
                              strip(put(ROR_UCL, 8.1)), ')')
                     else '' end as ROR_CI length=30,
                EBGM,
                case when EBGM is not missing
                     then cat(strip(put(EBGM, 8.1)), ' (',
                              strip(put(EB05, 8.1)), ' - ',
                              strip(put(EB95, 8.1)), ')')
                     else '' end as EBGM_CI length=30,
                signal_flag,
                signal_ror,
                signal_ebgm,
                case when signal_flag = 1 and signal_ror = 1
                      and signal_ebgm = 1                     then '***'
                     when signal_flag = 1 and signal_ror = 1  then '**'
                     when signal_flag = 1                     then '*'
                     else '' end as strength length=3
        from    signal.glp1_top_signals
        where   pt_category = 'CLINICAL_AE'
        order by drug_label, PRR desc;
quit;

%mend build_table2;

%build_table2

title3 "Table 2. Top Safety Signals per GLP-1 Molecule";
title4 "Clinical adverse events only, ranked by PRR within molecule";
footnote2 "Evans criteria: PRR >= &PRR_THRESHOLD, chi-square >= &CHI2_THRESHOLD, N >= &MIN_CASES cases. Strength: * Evans; ** Evans and ROR; *** Evans, ROR and EBGM.";
footnote3 "EBGM is an empirical-Bayes shrinkage estimate fitted on an untruncated likelihood; it is shown as a ranking aid and gates nothing. Detection is Evans criteria via SIGNAL_FLAG.";
footnote4 "Shading marks thin evidence, not high ratios: red under &T2_RED_N cases, yellow &T2_RED_N to %eval(&T2_YELLOW_N - 1). Every row here already clears Evans criteria, so a PRR band would shade the whole table; what separates these rows is how many reports each ratio rests on. Read a shaded row together with its confidence interval.";
footnote5 "Medication-error, dosing, device and product-quality PTs are excluded from this table and retained in full in glp1_signals.csv.";

%macro t2_report;
%if %_nobs(work.report_top_signals) = 0 %then %do;
    %_skipped(Table 2 skipped - no clinical AE rows in SIGNAL.GLP1_TOP_SIGNALS.)
    %return;
%end;

proc report data=work.report_top_signals nowd;
    columns drug_label pt n_cases PRR_CI ROR_CI EBGM_CI strength;
    define drug_label / order 'Drug'
                        style(column)={font_weight=bold};
    define pt         / display 'Reaction (PT)';
    define n_cases    / display 'Cases' format=comma8.
                        style(column)={just=right};
    define PRR_CI     / display 'PRR (95% CI)'
                        style(column)={just=right};
    define ROR_CI     / display 'ROR (95% CI)'
                        style(column)={just=right};
    define EBGM_CI    / display 'EBGM (EB05 - EB95)'
                        style(column)={just=right};
    define strength   / display 'Strength'
                        style(column)={just=center font_weight=bold};

    /* N_CASES shades itself, so no hidden companion column is needed - the
       numeric PRR that used to be carried NOPRINT for that job is gone from
       the report, though it stays in the dataset and in the CSV.

       N_CASES is a DISPLAY item, which is what makes this fire once per row.
       See Table 3c for what happens when a compute block is attached to an
       ORDER item instead. */
    compute n_cases;
        if n_cases < &T2_RED_N then
            call define(_col_, 'style', 'style={background=#FFCCCC}');
        else if n_cases < &T2_YELLOW_N then
            call define(_col_, 'style', 'style={background=#FFFFCC}');
    endcomp;
run;
%mend t2_report;

%t2_report

title3;
title4;
footnote2;

%_stamp(Section 3 - Table 2 built.)


/*==========================================================================
  4. TABLE 3 - DRUG COMPARISON, THREE LAYERS

  Three questions that need three different comparators:

    3a  Semaglutide against tirzepatide. The two newer molecules head to
        head, which is the comparison a prescriber actually faces.
    3b  Newer generation against older. Whether the difference is molecular
        or generational.
    3c  All four at once. Whether a signal is a class effect or belongs to
        one molecule.

  All three read EVENT and EVENT_TYPE - Step 3's names for a subject that
  can be either a single PT or a grouped signal. 3a and 3b are capped at 20
  rows because they are ordered by divergence and the tail is not divergent;
  3c is not capped, because a class-effect list is only useful complete.
  ==========================================================================*/

/*--- 4a. Layer 1: semaglutide vs tirzepatide ---------------------------*/

%macro build_table3a;

%if %sysfunc(exist(signal.glp1_compare_sema_tirz)) = 0 %then %do;
    %_shell(work.report_drug_compare,
            %str(event_type $8 event $100 sema_a 8 sema_PRR 8 tirz_a 8
                 tirz_PRR 8 prr_diff 8 direction $20 ci_overlap 8))
    %return;
%end;

/* Requiring at least one side to signal is what keeps this a safety table.
   Without it the largest PRR differences are pairs where neither molecule
   clears Evans and the gap is noise on two thin counts. */
proc sql;
    create table work._t3a_all as
        select  event_type,
                event,
                sema_a,
                sema_PRR,
                tirz_a,
                tirz_PRR,
                prr_diff,
                direction,
                ci_overlap
        from    signal.glp1_compare_sema_tirz
        where   pt_category = 'CLINICAL_AE'
            and direction in ('SEMA higher', 'TIRZ higher')
            and (sema_signal = 1 or tirz_signal = 1)
        order by abs(prr_diff) desc;
quit;

data work.report_drug_compare;
    set work._t3a_all;
    if _n_ <= 20;
    label event_type = 'Type'      event    = 'Event'
          sema_a     = 'SEMA cases' sema_PRR = 'SEMA PRR'
          tirz_a     = 'TIRZ cases' tirz_PRR = 'TIRZ PRR'
          prr_diff   = 'PRR difference'
          direction  = 'Direction'
          ci_overlap = 'CI overlap';
run;

%mend build_table3a;

%build_table3a

title3 "Table 3a. Semaglutide vs Tirzepatide - Most Divergent Clinical Signals";
title4 "Top 20 by absolute PRR difference, where at least one molecule clears Evans criteria";
footnote2 "PRR difference = TIRZ PRR - SEMA PRR. CI overlap = 0 means the two 95% confidence intervals do not overlap, which is the stronger evidence of a real difference.";
footnote3 "Shading: blue where semaglutide is higher, orange where tirzepatide is higher. Both molecules are measured against the same full-FAERS comparator.";

%macro t3a_report;
%if %_nobs(work.report_drug_compare) = 0 %then %do;
    %_skipped(Table 3a skipped - no divergent clinical AE pair where either molecule signals.)
    %return;
%end;

proc report data=work.report_drug_compare nowd;
    columns event_type event sema_a sema_PRR tirz_a tirz_PRR
            prr_diff ci_overlap direction;
    define event_type / display 'Type';
    define event      / display 'Event';
    define sema_a     / display 'SEMA cases' format=comma8.;
    define sema_PRR   / display 'SEMA PRR'   format=8.1;
    define tirz_a     / display 'TIRZ cases' format=comma8.;
    define tirz_PRR   / display 'TIRZ PRR'   format=8.1;
    define prr_diff   / display 'PRR diff'   format=8.2;
    define ci_overlap / display 'CI overlap' format=8.;
    define direction  / display 'Direction';

    compute direction;
        if direction = 'SEMA higher' then
            call define(_col_, 'style',
                        'style={background=#CCCCFF font_weight=bold}');
        else if direction = 'TIRZ higher' then
            call define(_col_, 'style',
                        'style={background=#FFE0CC font_weight=bold}');
    endcomp;
run;
%mend t3a_report;

%t3a_report

title3;
title4;
footnote2;

/*--- 4b. Layer 2: newer vs older generation ----------------------------*/

%macro build_table3b;

%if %sysfunc(exist(signal.glp1_compare_generation)) = 0 %then %do;
    %_shell(work.report_gen_compare,
            %str(event_type $8 event $100 newer_a 8 newer_PRR 8 older_a 8
                 older_PRR 8 prr_ratio 8 flag $20 ci_overlap 8))
    %return;
%end;

/* Ordered on abs(prr_ratio - 1) rather than on the ratio: a ratio of 0.4
   and a ratio of 2.5 are the same size of difference in opposite
   directions, and sorting on the raw ratio would bury every case where the
   older generation is higher at the bottom of the table. */
proc sql;
    create table work._t3b_all as
        select  event_type,
                event,
                newer_a,
                newer_PRR,
                older_a,
                older_PRR,
                prr_ratio,
                flag,
                ci_overlap
        from    signal.glp1_compare_generation
        where   pt_category = 'CLINICAL_AE'
            and flag in ('NEWER HIGHER', 'OLDER HIGHER')
            and (newer_signal = 1 or older_signal = 1)
        order by abs(prr_ratio - 1) desc;
quit;

data work.report_gen_compare;
    set work._t3b_all;
    if _n_ <= 20;
    label event_type = 'Type'        event     = 'Event'
          newer_a    = 'Newer cases' newer_PRR = 'Newer PRR'
          older_a    = 'Older cases' older_PRR = 'Older PRR'
          prr_ratio  = 'PRR ratio'
          flag       = 'Direction'
          ci_overlap = 'CI overlap';
run;

%mend build_table3b;

%build_table3b

title3 "Table 3b. Newer Generation (SEMA + TIRZ) vs Older (DULA + LIRA)";
title4 "Top 20 by absolute distance from parity, where at least one generation clears Evans criteria";
footnote2 "PRR ratio = newer PRR / older PRR. Above 1.5 or below 0.67 is a meaningful difference; 1.0 is parity.";
footnote3 "Generation cohorts pool two molecules each, so a ratio can be driven by one of the pair. Table 3c separates them.";

%macro t3b_report;
%if %_nobs(work.report_gen_compare) = 0 %then %do;
    %_skipped(Table 3b skipped - no divergent clinical AE pair where either generation signals.)
    %return;
%end;

proc report data=work.report_gen_compare nowd;
    columns event_type event newer_a newer_PRR older_a older_PRR
            prr_ratio ci_overlap flag;
    define event_type / display 'Type';
    define event      / display 'Event';
    define newer_a    / display 'Newer cases' format=comma8.;
    define newer_PRR  / display 'Newer PRR'   format=8.1;
    define older_a    / display 'Older cases' format=comma8.;
    define older_PRR  / display 'Older PRR'   format=8.1;
    define prr_ratio  / display 'PRR ratio'   format=8.2;
    define ci_overlap / display 'CI overlap'  format=8.;
    define flag       / display 'Direction';

    compute flag;
        if flag = 'NEWER HIGHER' then
            call define(_col_, 'style',
                        'style={background=#FFCCCC font_weight=bold}');
        else if flag = 'OLDER HIGHER' then
            call define(_col_, 'style',
                        'style={background=#CCFFCC font_weight=bold}');
    endcomp;
run;
%mend t3b_report;

%t3b_report

title3;
title4;
footnote2;

/*--- 4c. Layer 3: four-molecule overview -------------------------------*/

%macro build_table3c;

%if %sysfunc(exist(signal.glp1_compare_overview)) = 0 %then %do;
    %_shell(work.report_four_drug,
            %str(event_type $8 event $100 sema_a 8 sema_PRR 8 tirz_a 8
                 tirz_PRR 8 dula_a 8 dula_PRR 8 lira_a 8 lira_PRR 8
                 n_drugs_signal 8))
    %return;
%end;

proc sql;
    create table work.report_four_drug as
        select  event_type,
                event,
                sema_a  label='SEMA cases',
                sema_PRR label='SEMA PRR',
                tirz_a  label='TIRZ cases',
                tirz_PRR label='TIRZ PRR',
                dula_a  label='DULA cases',
                dula_PRR label='DULA PRR',
                lira_a  label='LIRA cases',
                lira_PRR label='LIRA PRR',
                n_drugs_signal label='Molecules signalling'
        from    signal.glp1_compare_overview
        where   pt_category = 'CLINICAL_AE'
            and n_drugs_signal >= 2
        order by n_drugs_signal desc, event_type, event;
quit;

%mend build_table3c;

%build_table3c

title3 "Table 3c. Class Effect Overview - Events Signalling on Two or More Molecules";
title4 "All four GLP-1 receptor agonists, each against the same full-FAERS comparator";
footnote2 "Molecules signalling = number of the four where the event clears Evans criteria. Four of four is the strongest available evidence of a class effect rather than a molecule-specific risk.";
footnote3 "A blank cell means the molecule had no case reporting that event. Rows where all four signal are shaded green.";

%macro t3c_report;
%if %_nobs(work.report_four_drug) = 0 %then %do;
    %_skipped(Table 3c skipped - no clinical AE signalled on two or more molecules.)
    %return;
%end;

proc report data=work.report_four_drug nowd;
    columns n_drugs_signal event_type event
            sema_a sema_PRR tirz_a tirz_PRR
            dula_a dula_PRR lira_a lira_PRR;
    /* All three are DISPLAY, not ORDER, and the reason is the COMPUTE block
       at the foot of this step rather than presentation.

       PROC REPORT runs an ORDER item's compute block once per GROUP - when
       the value changes - not once per row. With N_DRUGS_SIGNAL defined as
       ORDER, CALL DEFINE(_ROW_) fired a single time for the whole
       four-of-four block and shaded its first row only: 1 row green where 27
       should have been, with no warning in the log because nothing was
       wrong, only misunderstood. A DISPLAY item's compute block runs for
       every detail row, which is what row-level shading needs.

       EVENT_TYPE and EVENT have to change with it. PROC REPORT sorts on its
       ORDER items, so leaving those two as ORDER would re-sort the report
       ascending by event and destroy the n_drugs_signal-descending order
       this table is built around. With no ORDER item at all it keeps the
       input order, and WORK.REPORT_FOUR_DRUG already arrives sorted
       n_drugs_signal desc, event_type, event.

       The cost is that the count now repeats down the column instead of
       printing once per block. In a 155-row table that is a gain: a reader
       scrolled to the middle can still see which block they are in. */
    define n_drugs_signal / display 'Molecules signalling'
                            format=8.
                            style(column)={font_weight=bold just=center};
    define event_type / display 'Type';
    define event      / display 'Event';
    define sema_a     / display 'SEMA cases' format=comma8.;
    define sema_PRR   / display 'SEMA PRR'   format=8.1;
    define tirz_a     / display 'TIRZ cases' format=comma8.;
    define tirz_PRR   / display 'TIRZ PRR'   format=8.1;
    define dula_a     / display 'DULA cases' format=comma8.;
    define dula_PRR   / display 'DULA PRR'   format=8.1;
    define lira_a     / display 'LIRA cases' format=comma8.;
    define lira_PRR   / display 'LIRA PRR'   format=8.1;

    compute n_drugs_signal;
        if n_drugs_signal = 4 then
            call define(_row_, 'style', 'style={background=#CCFFCC}');
    endcomp;
run;
%mend t3c_report;

%t3c_report

title3;
title4;
footnote2;

proc datasets library=work nolist;
    delete _t3a_all _t3b_all;
quit;

%_stamp(Section 4 - Table 3a 3b 3c built.)


/*==========================================================================
  5. TABLE 4 - AGE-DEPENDENT SIGNALS

  Restricted to COVERAGE_FLAG = 'OK'. Step 4 attaches that flag because age
  missingness in this cohort is not random and not equal across molecules -
  roughly half of semaglutide cases carry a usable age against a third of
  tirzepatide's. A stratified PRR computed on the reporting third is a
  statement about who filed a report, not about who is at risk, and Step 4
  labels those rows SELECTION BIAS rather than deleting them.

  Publishing only the OK rows is the point of having the flag. The rest stay
  in glp1_age_dependent.csv for anyone who wants to see what was held back.
  ==========================================================================*/

%macro build_table4;

%if %sysfunc(exist(signal.glp1_age_dependent)) = 0 %then %do;
    %_shell(work.report_subgroup_age,
            %str(drug_label $20 event_type $8 event $100 age_pattern $30
                 a_young 8 prr_young 8 a_middle 8 prr_middle 8
                 a_elderly 8 prr_elderly 8 prr_ratio_ey 8 coverage_pct 8))
    %return;
%end;

proc sql;
    create table work._t4_all as
        select  drug_label,
                event_type,
                event,
                age_pattern,
                a_young,
                prr_young,
                a_middle,
                prr_middle,
                a_elderly,
                prr_elderly,
                prr_ratio_ey,
                coverage_pct
        from    signal.glp1_age_dependent
        where   pt_category = 'CLINICAL_AE'
            and coverage_flag = 'OK'
        order by drug_label, abs(prr_ratio_ey - 1) desc;
quit;

/* Ten per molecule, not ten overall: the whole question here is whether a
   molecule behaves differently by age, and a global top ten would fill with
   whichever molecule has the most cases. */
data work.report_subgroup_age;
    set work._t4_all;
    by drug_label;
    if first.drug_label then _rank = 0;
    _rank + 1;
    if _rank <= 10;
    drop _rank;

    label drug_label   = 'Drug'          event_type   = 'Type'
          event        = 'Event'         age_pattern  = 'Pattern'
          a_young      = 'Cases <=45'    prr_young    = 'PRR <=45'
          a_middle     = 'Cases 46-64'   prr_middle   = 'PRR 46-64'
          a_elderly    = 'Cases >=65'    prr_elderly  = 'PRR >=65'
          prr_ratio_ey = 'PRR >=65 / <=45'
          coverage_pct = 'Age coverage';
run;

proc datasets library=work nolist;
    delete _t4_all;
quit;

%mend build_table4;

%build_table4

title3 "Table 4. Age-Dependent Safety Signals";
title4 "Clinical adverse events, top 10 per molecule, adequate age coverage only";
footnote2 "Age bands are the project's own: <=&AGE_CUT1, %eval(&AGE_CUT1+1)-&AGE_CUT2, >=%eval(&AGE_CUT2+1) years, from reported age in years only. PRR >=65 / <=45 above 1.5 reads as elderly-elevated, below 0.67 as youth-elevated.";
footnote3 "Rows Step 4 flagged SELECTION BIAS are excluded: age missingness in this cohort runs from roughly a third to two thirds of cases and differs by molecule, so a stratified PRR on the reporting subset would describe the reporters, not the risk.";
footnote4 "Shading: red where the elderly band is concentrated or elevated, blue where the young band is.";

%macro t4_report;
%if %_nobs(work.report_subgroup_age) = 0 %then %do;
    %_skipped(Table 4 skipped - no clinical AE age pattern passed the coverage check.)
    %return;
%end;

proc report data=work.report_subgroup_age nowd;
    columns drug_label event_type event
            a_young prr_young a_middle prr_middle a_elderly prr_elderly
            prr_ratio_ey coverage_pct age_pattern;
    define drug_label   / order 'Drug' style(column)={font_weight=bold};
    define event_type   / display 'Type';
    define event        / display 'Event';
    define a_young      / display 'Cases <=45'  format=comma8.;
    define prr_young    / display 'PRR <=45'    format=8.1;
    define a_middle     / display 'Cases 46-64' format=comma8.;
    define prr_middle   / display 'PRR 46-64'   format=8.1;
    define a_elderly    / display 'Cases >=65'  format=comma8.;
    define prr_elderly  / display 'PRR >=65'    format=8.1;
    define prr_ratio_ey / display 'PRR >=65 / <=45' format=8.2;
    define coverage_pct / display 'Age coverage';
    define age_pattern  / display 'Pattern';

    compute age_pattern;
        if substr(age_pattern, 1, 7) = 'Elderly' then
            call define(_col_, 'style',
                        'style={background=#FFCCCC font_weight=bold}');
        else if substr(age_pattern, 1, 5) = 'Youth' then
            call define(_col_, 'style',
                        'style={background=#CCCCFF font_weight=bold}');
    endcomp;
run;
%mend t4_report;

%t4_report

title3;
title4;
footnote2;

%_stamp(Section 5 - Table 4 built.)


/*==========================================================================
  6. TABLE 5 - TIME TRENDS

  Four quarters of PRR per molecule x PT, with Step 5's trend label.

  'Inconsistent' is excluded. It is by far the largest class and it means
  the quarterly PRRs move without direction - which on four points and thin
  counts is what noise looks like. Reporting it would put two thousand rows
  of nothing in front of the reader; the count of what was held back is in
  the executive summary and the full series is in glp1_trend_summary.csv.

  TREND_ORD exists because PROC REPORT re-sorts on its own ORDER variables
  and would put these four labels in alphabetical order - Accelerating,
  Declining, Emerging, Stable - which reverses the intended reading. The
  numeric key is carried NOPRINT so the order survives.
  ==========================================================================*/

%macro build_table5;

%if %sysfunc(exist(signal.glp1_trend_summary)) = 0 %then %do;
    %_shell(work.report_time_trends,
            %str(trend_ord 8 drug_label $20 pt $100 trend $20
                 trend_confidence $10 signal_velocity 8 n_quarters_data 8
                 n_quarters_signal 8 first_prr 8 last_prr 8
                 prr_q1 8 prr_q2 8 prr_q3 8 prr_q4 8 monotonic 8 a_total 8))
    %return;
%end;

proc sql;
    create table work.report_time_trends as
        select  case trend
                    when 'Emerging'     then 1
                    when 'Accelerating' then 2
                    when 'Stable'       then 3
                    when 'Declining'    then 4
                    else 5
                end as trend_ord label='Trend sort key',
                drug_label        label='Drug',
                pt                label='Reaction (PT)',
                trend             label='Trend',
                trend_confidence  label='Confidence',
                signal_velocity   label='Velocity',
                n_quarters_data   label='Quarters with data',
                n_quarters_signal label='Quarters signalling',
                first_prr         label='First PRR',
                last_prr          label='Last PRR',
                prr_q1            label='PRR 2025Q3',
                prr_q2            label='PRR 2025Q4',
                prr_q3            label='PRR 2026Q1',
                prr_q4            label='PRR 2026Q2',
                monotonic         label='Monotonic',
                a_total           label='Total cases'
        from    signal.glp1_trend_summary
        where   pt_category = 'CLINICAL_AE'
            and trend in ('Emerging', 'Accelerating', 'Stable', 'Declining')
        order by calculated trend_ord, signal_velocity desc;
quit;

%mend build_table5;

%build_table5

title3 "Table 5. GLP-1 Signal Time Trends, Quarter by Quarter";
title4 "Clinical adverse events with a directional trend, ordered Emerging, Accelerating, Stable, Declining";
footnote2 "Emerging: sub-threshold in the early quarters, crossing Evans criteria later. Accelerating: signalling throughout with PRR rising. Declining: signalling early, falling after.";
footnote3 "Signal velocity = (last PRR - first PRR) / quarters spanned. Monotonic = 1 where PRR moves in one direction across every signalling quarter.";
footnote4 "Trends labelled Inconsistent are excluded: on four quarters they mean the series has no direction. They remain in glp1_trend_summary.csv. A quarter reflects the FDA initial receive date, so a rising PRR can also reflect rising attention to the class.";

%macro t5_report;
%if %_nobs(work.report_time_trends) = 0 %then %do;
    %_skipped(Table 5 skipped - no clinical AE carried a directional trend.)
    %return;
%end;

proc report data=work.report_time_trends nowd;
    columns trend_ord trend drug_label pt trend_confidence
            prr_q1 prr_q2 prr_q3 prr_q4
            signal_velocity monotonic n_quarters_signal a_total;
    define trend_ord         / order noprint;
    define trend             / display 'Trend'
                               style(column)={font_weight=bold};
    define drug_label        / display 'Drug';
    define pt                / display 'Reaction (PT)';
    define trend_confidence  / display 'Confidence';
    define prr_q1            / display 'PRR 25Q3' format=8.1;
    define prr_q2            / display 'PRR 25Q4' format=8.1;
    define prr_q3            / display 'PRR 26Q1' format=8.1;
    define prr_q4            / display 'PRR 26Q2' format=8.1;
    define signal_velocity   / display 'Velocity' format=8.2;
    define monotonic         / display 'Mono'     format=8.;
    define n_quarters_signal / display 'Qtrs sig' format=8.;
    define a_total           / display 'Cases'    format=comma8.;

    compute trend;
        if trend = 'Emerging' then
            call define(_col_, 'style',
                        'style={background=#FFCCCC font_weight=bold}');
        else if trend = 'Accelerating' then
            call define(_col_, 'style', 'style={background=#FFE0CC}');
        else if trend = 'Declining' then
            call define(_col_, 'style', 'style={background=#CCFFCC}');
    endcomp;
run;
%mend t5_report;

%t5_report

title3;
title4;
footnote2;

%_stamp(Section 6 - Table 5 built.)


/*==========================================================================
  7. TABLE 6 - VALIDATION SCORECARD

  Step 6's twelve reference groups, in one table. This is the table that
  answers 'does the method work', and it is the one an interviewer will read
  first, so it carries the full INTERPRETATION text rather than a code.

  Category A asks whether the method recovers a risk regulators already
  established. Category C asks whether it stays quiet on one they
  investigated and dismissed. Category D asks whether it would have been
  early on a risk recognised inside the data window. A REPLICATED means
  something different in each, which is why the category column stays.
  ==========================================================================*/

%macro build_table6;

%if %sysfunc(exist(signal.glp1_validation)) = 0 %then %do;
    %_shell(work.report_validation,
            %str(category $1 signal_id 8 signal_group $40 source $80
                 group_status $15 n_drugs_tested 8 n_drugs_replicated 8
                 replicated_of $16 best_PRR 8 best_a 8 interpretation $100))
    %return;
%end;

proc sql;
    create table work.report_validation as
        select  category            label='Cat',
                signal_id           label='#',
                signal_group        label='Reference signal group',
                source              label='Regulatory source',
                group_status        label='Verdict',
                n_drugs_tested      label='Molecules tested',
                n_drugs_replicated  label='Molecules replicated',
                cat(strip(put(n_drugs_replicated, 8.)), ' of ',
                    strip(put(n_drugs_tested, 8.)))
                    as replicated_of length=16 label='Replicated',
                best_PRR            label='Best PRR',
                best_a              label='Cases at best PRR',
                interpretation      label='Interpretation'
        from    signal.glp1_validation
        order by signal_id;
quit;

%mend build_table6;

%build_table6

title3 "Table 6. Signal Validation Scorecard - Time-Indexed Reference Set";
title4 "Twelve reference groups across three questions, tested only on the molecules whose label carries them";
footnote2 "Category A: Warnings and Precautions in force throughout 2025Q3-2026Q2 - expect REPLICATED. Category C: investigated and closed by regulators - a REPLICATED here is a false positive worth reporting. Category D: recognised during or just before the window - expect the method to be early.";
footnote3 "Gate 3 requires at least 6 of the 8 Category A groups replicated on at least one molecule. Best PRR is blank where no molecule reached the minimum case count.";
footnote4 "Shading: green REPLICATED, yellow WEAK or SUB_THRESHOLD, red PRR_BELOW_1, NOT_SIGNIFICANT, NOT_IN_DATA or MISSED.";

%macro t6_report;
%if %_nobs(work.report_validation) = 0 %then %do;
    %_skipped(Table 6 skipped - SIGNAL.GLP1_VALIDATION was not available.)
    %return;
%end;

proc report data=work.report_validation nowd;
    columns signal_id category signal_group source group_status
            replicated_of best_PRR best_a interpretation;
    define signal_id      / order '#' format=8.;
    define category       / display 'Cat'
                            style(column)={just=center font_weight=bold};
    define signal_group   / display 'Reference signal group'
                            style(column)={font_weight=bold};
    define source         / display 'Regulatory source';
    define group_status   / display 'Verdict';
    define replicated_of  / display 'Replicated'
                            style(column)={just=center};
    define best_PRR       / display 'Best PRR' format=8.1;
    define best_a         / display 'Cases'    format=comma8.;
    define interpretation / display 'Interpretation';

    compute group_status;
        if group_status = 'REPLICATED' then
            call define(_col_, 'style',
                        'style={background=#CCFFCC font_weight=bold}');
        else if group_status in ('WEAK', 'SUB_THRESHOLD') then
            call define(_col_, 'style', 'style={background=#FFFFCC}');
        else if group_status in ('PRR_BELOW_1', 'NOT_SIGNIFICANT',
                                 'NOT_IN_DATA', 'MISSED') then
            call define(_col_, 'style',
                        'style={background=#FFCCCC font_weight=bold}');
    endcomp;
run;
%mend t6_report;

%t6_report

title3;
title4;
footnote2;

%_stamp(Section 7 - Table 6 built.)


/*==========================================================================
  8. EXECUTIVE SUMMARY

  One row per metric, three columns: SECTION, METRIC, VALUE. Long rather
  than wide so Tableau can put the whole thing on one sheet and so a metric
  can be added later without changing the shape of the file.

  Every SELECT names all three columns. OUTER UNION CORR matches on column
  name, and an unnamed literal in a UNION gets a generated name - two
  branches would then stack into separate columns instead of aligning, and
  the failure is silent: the table comes out with the right number of rows
  and most cells blank. LENGTH is declared on the first branch only, which
  is where OUTER UNION CORR takes it from.

  Counts of Evans-flagged signals use the thresholds from 00_config.sas
  rather than repeating them, so the label cannot drift from the criterion
  actually applied upstream.
  ==========================================================================*/

%macro build_exec_summary;

%local have_cases have_reac have_signals have_valid have_trend have_over;
%let have_cases   = %sysfunc(exist(clean.glp1_cases));
%let have_reac    = %sysfunc(exist(clean.glp1_reac));
%let have_signals = %sysfunc(exist(signal.glp1_signals));
%let have_valid   = %sysfunc(exist(signal.glp1_validation));
%let have_trend   = %sysfunc(exist(signal.glp1_trend_summary));
%let have_over    = %sysfunc(exist(signal.glp1_compare_overview));

data work.report_executive_summary;
    length section $30 metric $80 value 8;
    stop;
run;

%if &have_cases %then %do;
proc sql;
    create table work._es_cohort as
        select 'Cohort'            as section length=30,
               'Total GLP-1 cases (distinct primaryid)' as metric length=80,
               count(distinct primaryid) as value
        from   clean.glp1_cases
    outer union corr
        select 'Cohort' as section,
               'Molecules monitored' as metric,
               count(distinct drug_label) as value
        from   clean.glp1_cases
    outer union corr
        select 'Cohort' as section,
               'Cases with a usable reported age' as metric,
               count(distinct primaryid) as value
        from   clean.glp1_cases
        where  age_grp ne 'Unknown';
quit;
data work.report_executive_summary;
    set work.report_executive_summary work._es_cohort;
run;
%end;

%if &have_reac %then %do;
proc sql;
    create table work._es_reac as
        select 'Cohort' as section length=30,
               'Reaction terms reported (case x molecule x PT)' as metric length=80,
               count(*) as value
        from   clean.glp1_reac;
quit;
data work.report_executive_summary;
    set work.report_executive_summary work._es_reac;
run;
%end;

%if &have_signals %then %do;
proc sql;
    create table work._es_signals as
        select 'Signals' as section length=30,
               'Molecule x event pairs evaluated' as metric length=80,
               count(*) as value
        from   signal.glp1_signals
    outer union corr
        select 'Signals' as section,
               "Evans-flagged signals (N>=&MIN_CASES, PRR>=&PRR_THRESHOLD, chi2>=&CHI2_THRESHOLD)" as metric,
               sum(case when signal_flag = 1 then 1 else 0 end) as value
        from   signal.glp1_signals
    outer union corr
        select 'Signals' as section,
               'Evans-flagged, clinical AE only' as metric,
               sum(case when signal_flag = 1 and pt_category = 'CLINICAL_AE'
                        then 1 else 0 end) as value
        from   signal.glp1_signals
    outer union corr
        select 'Signals' as section,
               'Evans-flagged and ROR-confirmed' as metric,
               sum(case when signal_flag = 1 and signal_ror = 1
                        then 1 else 0 end) as value
        from   signal.glp1_signals
    outer union corr
        select 'Signals' as section,
               'Evans-flagged, held back as non-clinical PT' as metric,
               sum(case when signal_flag = 1 and pt_category ne 'CLINICAL_AE'
                        then 1 else 0 end) as value
        from   signal.glp1_signals;
quit;
data work.report_executive_summary;
    set work.report_executive_summary work._es_signals;
run;
%end;

%if &have_valid %then %do;
proc sql;
    create table work._es_valid as
        select 'Validation' as section length=30,
               'Category A groups (labelled risks) total' as metric length=80,
               sum(case when category = 'A' then 1 else 0 end) as value
        from   signal.glp1_validation
    outer union corr
        select 'Validation' as section,
               'Category A groups replicated' as metric,
               sum(case when category = 'A' and group_status = 'REPLICATED'
                        then 1 else 0 end) as value
        from   signal.glp1_validation
    outer union corr
        select 'Validation' as section,
               'Gate 3 status (1 = PASS, needs 6 of 8)' as metric,
               case when sum(case when category = 'A'
                                   and group_status = 'REPLICATED'
                                  then 1 else 0 end) >= 6
                    then 1 else 0 end as value
        from   signal.glp1_validation
    outer union corr
        select 'Validation' as section,
               'Category C groups (closed by regulators) total' as metric,
               sum(case when category = 'C' then 1 else 0 end) as value
        from   signal.glp1_validation
    outer union corr
        select 'Validation' as section,
               'Category C groups the method stayed quiet on' as metric,
               sum(case when category = 'C' and group_status ne 'REPLICATED'
                        then 1 else 0 end) as value
        from   signal.glp1_validation
    outer union corr
        select 'Validation' as section,
               'Category D groups (newly recognised) total' as metric,
               sum(case when category = 'D' then 1 else 0 end) as value
        from   signal.glp1_validation
    outer union corr
        select 'Validation' as section,
               'Category D groups detected' as metric,
               sum(case when category = 'D' and group_status = 'REPLICATED'
                        then 1 else 0 end) as value
        from   signal.glp1_validation;
quit;
data work.report_executive_summary;
    set work.report_executive_summary work._es_valid;
run;
%end;

%if &have_trend %then %do;
proc sql;
    create table work._es_trend as
        select 'Trends' as section length=30,
               'Emerging signals (clinical AE)' as metric length=80,
               sum(case when trend = 'Emerging'
                         and pt_category = 'CLINICAL_AE' then 1 else 0 end) as value
        from   signal.glp1_trend_summary
    outer union corr
        select 'Trends' as section,
               'Accelerating signals (clinical AE)' as metric,
               sum(case when trend = 'Accelerating'
                         and pt_category = 'CLINICAL_AE' then 1 else 0 end) as value
        from   signal.glp1_trend_summary
    outer union corr
        select 'Trends' as section,
               'Declining signals (clinical AE)' as metric,
               sum(case when trend = 'Declining'
                         and pt_category = 'CLINICAL_AE' then 1 else 0 end) as value
        from   signal.glp1_trend_summary
    outer union corr
        select 'Trends' as section,
               'Inconsistent, excluded from Table 5 (clinical AE)' as metric,
               sum(case when trend = 'Inconsistent'
                         and pt_category = 'CLINICAL_AE' then 1 else 0 end) as value
        from   signal.glp1_trend_summary;
quit;
data work.report_executive_summary;
    set work.report_executive_summary work._es_trend;
run;
%end;

%if &have_over %then %do;
proc sql;
    create table work._es_over as
        select 'Comparison' as section length=30,
               'Events signalling on all 4 molecules (class effects)' as metric length=80,
               sum(case when n_drugs_signal = 4 then 1 else 0 end) as value
        from   signal.glp1_compare_overview
        where  pt_category = 'CLINICAL_AE'
    outer union corr
        select 'Comparison' as section,
               'Events signalling on exactly 1 molecule' as metric,
               sum(case when n_drugs_signal = 1 then 1 else 0 end) as value
        from   signal.glp1_compare_overview
        where  pt_category = 'CLINICAL_AE';
quit;
data work.report_executive_summary;
    set work.report_executive_summary work._es_over;
run;
%end;

data work.report_executive_summary;
    set work.report_executive_summary;
    label section = 'Section' metric = 'Metric' value = 'Value';
run;

proc datasets library=work nolist;
    delete _es_cohort _es_reac _es_signals _es_valid _es_trend _es_over;
quit;

%mend build_exec_summary;

%build_exec_summary

title3 "Executive Summary";
footnote2 "Every figure here is read from the datasets the tables above are built on. Gate 3 is the acceptance criterion set before Step 6 was run.";

%macro es_report;
%if %_nobs(work.report_executive_summary) = 0 %then %do;
    %_skipped(Executive summary skipped - no input dataset was available.)
    %return;
%end;

proc report data=work.report_executive_summary nowd;
    columns section metric value;
    define section / order 'Section' style(column)={font_weight=bold};
    define metric  / display 'Metric';
    define value   / display 'Value' format=comma12.
                     style(column)={just=right font_weight=bold};
run;
%mend es_report;

%es_report

title3;
footnote2;

%_stamp(Section 8 - executive summary built.)


/*==========================================================================
  9. KEY FINDINGS

  Six findings worth talking about, with the narrative written out and every
  number looked up. See the header for why the numbers are derived rather
  than typed.

  Each macro variable is initialised to 'n/a' first. SELECT INTO leaves a
  macro variable at its previous value when no row matches, so without the
  initialisation a reference set that changed shape would silently carry a
  number forward from wherever it was last set. 'n/a' in the table is a
  visible failure; a stale number is not.
  ==========================================================================*/

%let J_NAION_PRR  = n/a;   %let J_NAION_A    = n/a;
%let J_SUI_PRR    = n/a;   %let J_SUI_A      = n/a;
%let J_SUI_DEP    = n/a;   %let J_SUI_SII    = n/a;
%let J_AKI_PRR    = n/a;   %let J_AKI_A      = n/a;
%let J_AKI_NBELOW = n/a;   %let J_AKI_NTEST  = n/a;
%let J_GAST_PRR   = n/a;   %let J_GAST_A     = n/a;   %let J_GAST_PCT = n/a;
%let J_GAST_SPCT  = n/a;
%let J_INJ_TPRR   = n/a;   %let J_INJ_TA     = n/a;   %let J_INJ_TPCT = n/a;
%let J_INJ_SPRR   = n/a;   %let J_INJ_SA     = n/a;   %let J_INJ_SPCT = n/a;
%let J_CLASS_N    = n/a;   %let J_CLASS_PT   = n/a;   %let J_CLASS_GRP = n/a;
%let J_A_REPL     = n/a;   %let J_A_TOTAL    = n/a;

/* Denominators for the two share statements. COUNT with no GROUP BY always
   returns exactly one row, so these are set even when a molecule has no
   cases - which is what makes them safe to divide by after a guard. */
%let N_DULA = 0;
%let N_TIRZ = 0;
%let N_SEMA = 0;

%macro jewel_numbers;

%if %sysfunc(exist(clean.glp1_cases)) %then %do;
proc sql noprint;
    select count(distinct primaryid) into :N_DULA trimmed
        from clean.glp1_cases where drug_label = 'DULAGLUTIDE';
    select count(distinct primaryid) into :N_TIRZ trimmed
        from clean.glp1_cases where drug_label = 'TIRZEPATIDE';
    select count(distinct primaryid) into :N_SEMA trimmed
        from clean.glp1_cases where drug_label = 'SEMAGLUTIDE';
quit;
%end;

%if %sysfunc(exist(signal.glp1_validation_detail)) %then %do;
proc sql noprint;
    select strip(put(PRR, 8.1)), strip(put(a, comma12.))
      into :J_NAION_PRR trimmed, :J_NAION_A trimmed
      from signal.glp1_validation_detail
     where expected_pt = 'Optic ischaemic neuropathy'
       and drug_label  = 'SEMAGLUTIDE';

    select strip(put(PRR, 8.2)), strip(put(a, comma12.))
      into :J_SUI_PRR trimmed, :J_SUI_A trimmed
      from signal.glp1_validation_detail
     where expected_pt = 'Suicidal ideation'
       and drug_label  = 'SEMAGLUTIDE';

    select strip(put(PRR, 8.2)) into :J_SUI_DEP trimmed
      from signal.glp1_validation_detail
     where expected_pt = 'Depression suicidal'
       and drug_label  = 'SEMAGLUTIDE';

    select strip(put(PRR, 8.2)) into :J_SUI_SII trimmed
      from signal.glp1_validation_detail
     where expected_pt = 'Self-injurious ideation'
       and drug_label  = 'SEMAGLUTIDE';

    select strip(put(PRR, 8.2)), strip(put(a, comma12.))
      into :J_AKI_PRR trimmed, :J_AKI_A trimmed
      from signal.glp1_validation_detail
     where expected_pt = 'Acute kidney injury'
       and drug_label  = 'SEMAGLUTIDE';

    select strip(put(sum(detect_status = 'PRR_BELOW_1'), 8.)),
           strip(put(count(*), 8.))
      into :J_AKI_NBELOW trimmed, :J_AKI_NTEST trimmed
      from signal.glp1_validation_detail
     where signal_id = 4;
quit;
%end;

%if %sysfunc(exist(signal.glp1_validation)) %then %do;
proc sql noprint;
    select strip(put(sum((category = 'A') and (group_status = 'REPLICATED')), 8.)),
           strip(put(sum(category = 'A'), 8.))
      into :J_A_REPL trimmed, :J_A_TOTAL trimmed
      from signal.glp1_validation;
quit;
%end;

%if %sysfunc(exist(signal.glp1_compare_overview)) %then %do;
proc sql noprint;
    select strip(put(count(*), comma12.)),
           strip(put(sum(event_type = 'PT'), comma12.)),
           strip(put(sum(event_type = 'GROUP'), comma12.))
      into :J_CLASS_N trimmed, :J_CLASS_PT trimmed, :J_CLASS_GRP trimmed
      from signal.glp1_compare_overview
     where pt_category = 'CLINICAL_AE' and n_drugs_signal = 4;

    %if &N_DULA > 0 and &N_SEMA > 0 %then %do;
    select strip(put(dula_PRR, 8.0)), strip(put(dula_a, comma12.)),
           strip(put(100 * dula_a / &N_DULA, 5.1)),
           strip(put(100 * sema_a / &N_SEMA, 5.1))
      into :J_GAST_PRR trimmed, :J_GAST_A trimmed, :J_GAST_PCT trimmed,
           :J_GAST_SPCT trimmed
      from signal.glp1_compare_overview
     where event_type = 'GROUP' and event = 'GASTROPARESIS';
    %end;

    %if &N_TIRZ > 0 and &N_SEMA > 0 %then %do;
    select strip(put(tirz_PRR, 8.1)), strip(put(tirz_a, comma12.)),
           strip(put(100 * tirz_a / &N_TIRZ, 5.1)),
           strip(put(sema_PRR, 8.2)), strip(put(sema_a, comma12.)),
           strip(put(100 * sema_a / &N_SEMA, 5.1))
      into :J_INJ_TPRR trimmed, :J_INJ_TA trimmed, :J_INJ_TPCT trimmed,
           :J_INJ_SPRR trimmed, :J_INJ_SA trimmed, :J_INJ_SPCT trimmed
      from signal.glp1_compare_overview
     where event_type = 'GROUP' and event = 'INJECTION_SITE';
    %end;
quit;
%end;

%mend jewel_numbers;

%jewel_numbers

data work.report_crown_jewels;
    length rank 8 finding $120 detail $800 evidence $90;
    label rank     = '#'
          finding  = 'Finding'
          detail   = 'What the data shows'
          evidence = 'Where to check it';

    rank = 1;
    finding  = 'NAION found without being told to look for it';
    detail   = "Optic ischaemic neuropathy on semaglutide: PRR &J_NAION_PRR "
            || "on &J_NAION_A cases, and it signals on dulaglutide and "
            || "tirzepatide too. The EMA PRAC concluded NAION was a very rare "
            || "side effect of semaglutide in June 2025 - inside this data "
            || "window. The reference set is time-indexed for exactly this: "
            || "the method is not being scored against a label it could have "
            || "memorised.";
    evidence = 'Table 6 group 10 (category D); glp1_validation_detail.csv';
    output;

    rank = 2;
    finding  = 'Suicidality: the primary term stays quiet, two rarer terms do not';
    detail   = "Suicidal ideation on semaglutide sits at PRR &J_SUI_PRR on "
            || "&J_SUI_A cases - below the Evans threshold, agreeing with EMA "
            || "PRAC (Apr 2024) and FDA (Jan 2026), both of which found no "
            || "causal link. But Depression suicidal (PRR &J_SUI_DEP) and "
            || "Self-injurious ideation (PRR &J_SUI_SII) do clear Evans on "
            || "counts in the teens, so the group verdict reads REPLICATED. "
            || "That is what Evans criteria do on rare terms, and the "
            || "scorecard reports it as a false positive rather than hiding it.";
    evidence = 'Table 6 group 9 (category C); glp1_validation_detail.csv';
    output;

    rank = 3;
    finding  = 'A labelled risk that reports below background on every molecule';
    detail   = "Acute kidney injury is a Warning and Precaution on all four "
            || "molecules and comes back under PRR 1 on all four - semaglutide "
            || "at PRR &J_AKI_PRR on &J_AKI_A cases, &J_AKI_NBELOW of "
            || "&J_AKI_NTEST reference pairs below background. The mechanism is "
            || "real; what fails is the comparator. This class draws an enormous "
            || "volume of non-serious consumer reports, and disproportionality "
            || "cannot see a risk that is common in the denominator too. Gate 3 "
            || "was set at 6 of 8 so an honest negative need not be argued away.";
    evidence = 'Table 6 group 4 (category A); glp1_validation_detail.csv';
    output;

    rank = 4;
    finding  = 'Dulaglutide and gastroparesis: a reporting artefact, not a risk ranking';
    detail   = "The gastroparesis group on dulaglutide runs at PRR &J_GAST_PRR "
            || "on &J_GAST_A cases - &J_GAST_PCT% of every dulaglutide case in "
            || "the cohort, against &J_GAST_SPCT% of semaglutide's. A share that "
            || "size on one molecule for one syndrome is not how spontaneous "
            || "reporting distributes, and dulaglutide is the molecule named in "
            || "US gastroparesis litigation running across this window. The PRR "
            || "is correct and reading it as a risk ranking against the other "
            || "three would be wrong. Confirming the mechanism needs reporter "
            || "occupation, which this pipeline does not carry through to the "
            || "GLP-1 cohort - it is a stated limitation, not a finding.";
    evidence = 'Table 3c GASTROPARESIS row; glp1_compare_overview.csv';
    output;

    rank = 5;
    finding  = 'Injection-site burden separates the two newer molecules';
    detail   = "Tirzepatide: PRR &J_INJ_TPRR on &J_INJ_TA cases, "
            || "&J_INJ_TPCT% of its cohort. Semaglutide: PRR &J_INJ_SPRR on "
            || "&J_INJ_SA cases, &J_INJ_SPCT% - sitting exactly on the FAERS "
            || "background, so injection-site reactions are no more likely to be "
            || "reported for semaglutide than for an average drug. Same class, "
            || "same route, one measured difference. Device, formulation and "
            || "injection-frequency differences are all candidates, and this "
            || "data cannot separate them.";
    evidence = 'Table 3c INJECTION_SITE row; glp1_compare_sema_tirz.csv';
    output;

    rank = 6;
    finding  = 'Class effects are separable from molecule-specific ones';
    detail   = "&J_CLASS_N clinical events signal on all four molecules "
            || "(&J_CLASS_PT individual PTs and &J_CLASS_GRP grouped signals), "
            || "which is the strongest evidence available here for a class "
            || "effect rather than a property of one product. Running four "
            || "molecules against a common comparator instead of one is what "
            || "makes that distinction possible at all, and it is also what "
            || "isolates findings 4 and 5.";
    evidence = 'Table 3c; glp1_compare_overview.csv, n_drugs_signal = 4';
    output;
run;

title3 "Key Findings";
title4 "Every figure below is read from the datasets at run time, not transcribed";
footnote2 "Disproportionality measures reporting, not incidence. A high PRR says an event is reported more often for this drug than for the FAERS background; it is a prompt for review, not a causal claim.";
footnote3 "Gate 3: &J_A_REPL of &J_A_TOTAL Category A reference groups replicated.";

%macro cj_report;
%if %_nobs(work.report_crown_jewels) = 0 %then %do;
    %_skipped(Key findings table skipped.)
    %return;
%end;

proc report data=work.report_crown_jewels nowd;
    columns rank finding detail evidence;
    define rank     / display '#' format=8.
                      style(column)={just=center font_weight=bold};
    define finding  / display 'Finding'
                      style(column)={font_weight=bold};
    define detail   / display 'What the data shows';
    define evidence / display 'Where to check it'
                      style(column)={font_style=italic};
run;
%mend cj_report;

%cj_report

title3;
title4;
footnote2;

%_stamp(Section 9 - key findings built.)


/*==========================================================================
  10. CLOSE ODS, EXPORT, QC, WRAP UP
  ==========================================================================*/

ods html close;
ods listing;
ods proctitle;

/* One PROC EXPORT per table. Every one of these datasets exists by now,
   empty or not: each build macro answers a missing input with a %_shell()
   placeholder that has the right columns and no rows, rather than with no
   dataset at all. A partial run therefore still writes a complete set of
   files, and the QC table below can say which of them are empty and whether
   that was allowed. */
proc export data=work.report_cohort_summary
            outfile="&OUT_TABLES./report_cohort_summary.csv"
            dbms=csv replace;
run;

proc export data=work.report_top_signals
            outfile="&OUT_TABLES./report_top_signals.csv"
            dbms=csv replace;
run;

proc export data=work.report_drug_compare
            outfile="&OUT_TABLES./report_drug_compare.csv"
            dbms=csv replace;
run;

proc export data=work.report_gen_compare
            outfile="&OUT_TABLES./report_gen_compare.csv"
            dbms=csv replace;
run;

proc export data=work.report_four_drug
            outfile="&OUT_TABLES./report_four_drug.csv"
            dbms=csv replace;
run;

proc export data=work.report_subgroup_age
            outfile="&OUT_TABLES./report_subgroup_highlights.csv"
            dbms=csv replace;
run;

proc export data=work.report_time_trends
            outfile="&OUT_TABLES./report_time_trends.csv"
            dbms=csv replace;
run;

proc export data=work.report_validation
            outfile="&OUT_TABLES./report_validation.csv"
            dbms=csv replace;
run;

proc export data=work.report_executive_summary
            outfile="&OUT_TABLES./report_executive_summary.csv"
            dbms=csv replace;
run;

proc export data=work.report_crown_jewels
            outfile="&OUT_TABLES./report_crown_jewels.csv"
            dbms=csv replace;
run;

/* Completeness check.

   EXPECT_ROWS is the point of this table. A row count on its own cannot
   distinguish 'the filter removed everything' from 'the input was missing',
   and both are legitimate outcomes for some of these tables - Table 3a can
   genuinely find no divergent signalling pair. Recording what each table
   was expected to be non-empty for turns the check into something a reader
   can act on. */
data work.qc_report;
    length table_name $40 csv_file $40 n_rows 8 expect_rows $3 note $80;

    table_name='report_cohort_summary';    csv_file='report_cohort_summary.csv';
        n_rows=%_nobs(work.report_cohort_summary);   expect_rows='Yes';
        note='Empty only if CLEAN.GLP1_CASES is missing.'; output;
    table_name='report_top_signals';       csv_file='report_top_signals.csv';
        n_rows=%_nobs(work.report_top_signals);      expect_rows='Yes';
        note='Empty only if no top signal is a clinical AE.'; output;
    table_name='report_drug_compare';      csv_file='report_drug_compare.csv';
        n_rows=%_nobs(work.report_drug_compare);     expect_rows='No';
        note='May be empty - no divergent pair where either molecule signals.'; output;
    table_name='report_gen_compare';       csv_file='report_gen_compare.csv';
        n_rows=%_nobs(work.report_gen_compare);      expect_rows='No';
        note='May be empty - no divergent pair where either generation signals.'; output;
    table_name='report_four_drug';         csv_file='report_four_drug.csv';
        n_rows=%_nobs(work.report_four_drug);        expect_rows='Yes';
        note='Empty only if nothing signals on 2 or more molecules.'; output;
    table_name='report_subgroup_age';      csv_file='report_subgroup_highlights.csv';
        n_rows=%_nobs(work.report_subgroup_age);     expect_rows='No';
        note='May be empty - all age patterns flagged SELECTION BIAS.'; output;
    table_name='report_time_trends';       csv_file='report_time_trends.csv';
        n_rows=%_nobs(work.report_time_trends);      expect_rows='No';
        note='May be empty - every trend Inconsistent.'; output;
    table_name='report_validation';        csv_file='report_validation.csv';
        n_rows=%_nobs(work.report_validation);       expect_rows='Yes';
        note='Expect 12 rows - the reference set is fixed.'; output;
    table_name='report_executive_summary'; csv_file='report_executive_summary.csv';
        n_rows=%_nobs(work.report_executive_summary); expect_rows='Yes';
        note='One row per metric.'; output;
    table_name='report_crown_jewels';      csv_file='report_crown_jewels.csv';
        n_rows=%_nobs(work.report_crown_jewels);     expect_rows='Yes';
        note='Six curated findings, numbers derived at run time.'; output;

    label table_name  = 'Report table'
          csv_file    = 'Exported file'
          n_rows      = 'Rows'
          expect_rows = 'Must be non-empty'
          note        = 'Interpretation';
run;

proc export data=work.qc_report
            outfile="&OUT_QC./qc_glp1_report.csv"
            dbms=csv replace;
run;

/* A table that is empty when it was allowed to be gets a NOTE; one that is
   empty when it was not gets a WARNING. Grading the two the same would mean
   either crying wolf on every run or missing the run that matters. */
data _null_;
    set work.qc_report end=eof;
    retain n_bad 0 n_soft 0;

    if n_rows = 0 and expect_rows = 'Yes' then do;
        n_bad + 1;
        put "WARNING: " table_name "is EMPTY and should not be - " note;
    end;
    else if n_rows = 0 then do;
        n_soft + 1;
        put "NOTE: " table_name "is empty - " note;
    end;
    else put "NOTE: " table_name "- " n_rows "rows.";

    if eof then do;
        call symputx('N_QC_BAD',  n_bad,  'G');
        call symputx('N_QC_SOFT', n_soft, 'G');
    end;
run;

%macro finish;
    %local e;
    %let e = %sysevalf(%sysfunc(datetime()) - &_T0);

    %put NOTE: ============================================;
    %put NOTE: 03_glp1_report.sas complete.;
    %put NOTE: Report      = &OUT_TABLES./glp1_report.html;
    %put NOTE: CSV exports = 10 report tables in &OUT_TABLES;
    %put NOTE: QC          = &OUT_QC./qc_glp1_report.csv;
    %put NOTE: Gate 3      = &J_A_REPL of &J_A_TOTAL Category A groups replicated;

    %if &_MISSING_INPUTS > 0 %then
        %put WARNING: &_MISSING_INPUTS input dataset(s) were missing - see the input inventory above.;

    %if &N_QC_BAD > 0 %then %do;
        %put WARNING: ============================================;
        %put WARNING: &N_QC_BAD report table(s) are empty that should not be.;
        %put WARNING: Do not download this report - fix the upstream step first.;
        %put WARNING: ============================================;
    %end;
    %else %do;
        %put NOTE: ============================================;
        %put NOTE: *** All required report tables populated. ***;
        %if &N_QC_SOFT > 0 %then
            %put NOTE: &N_QC_SOFT optional table(s) empty - legitimate, see qc_glp1_report.csv.;
        %put NOTE: ============================================;
    %end;

    %put NOTE: Elapsed: %sysfunc(putn(&e, time12.2));
%mend finish;

%finish

title;
title2;
footnote;

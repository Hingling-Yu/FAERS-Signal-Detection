/*****************************************************************************
 * 00_config.sas — Master Configuration for FAERS Signal Detection Project
 *
 * Purpose:  Central config file included by all downstream programs.
 *           Sets libnames, file paths, macro variables, and formats
 *           for SAS OnDemand for Academics (SAS ODA) environment.
 *
 * Environment: SAS ODA (SAS Studio browser-based)
 * Base path:   /home/u64291357/mydata/
 *
 * Usage:     %include "/home/u64291357/mydata/sas/00_config.sas";
 *            at the top of every .sas program.
 *
 * Author:    Hingling Yu
 * Created:   2026-09-02
 *****************************************************************************/

/*==========================================================================
  1. BASE PATH
  ==========================================================================*/
%let BASE = /home/u64291357/mydata;

/*==========================================================================
  2. LIBRARY ASSIGNMENTS
  ==========================================================================*/

/* Raw data — read-only reference to original FAERS ASCII folders */
/* libname raw - not used, import macro uses &RAW_PATH directly */

/* Clean analytical datasets after import + dedup */
options dlcreatedir;
libname clean "&BASE./output/clean";

/* Signal detection results */
libname signal "&BASE./output/signal";
options nodlcreatedir;

/*==========================================================================
  3. QUARTER MACRO VARIABLES
  ==========================================================================
  Naming: Qyyyy_q  (e.g. Q2025_3 = 2025 Q3)
  File pattern: DEMO25Q3.txt → prefix = table name, suffix = YYQn
  Folder pattern: faers_ascii_2025q3/ASCII/
  ==========================================================================*/

/* --- Quarter list --- */
%let QUARTERS = 2025q3 2025q4 2026q1 2026q2;
%let N_QUARTERS = 4;

/* --- Individual quarter variables --- */
%let Q1_FOLDER = faers_ascii_2025q3;
%let Q1_SUFFIX = 25Q3;
%let Q1_LABEL  = 2025 Q3;

%let Q2_FOLDER = faers_ascii_2025q4;
%let Q2_SUFFIX = 25Q4;
%let Q2_LABEL  = 2025 Q4;

%let Q3_FOLDER = faers_ascii_2026q1;
%let Q3_SUFFIX = 26Q1;
%let Q3_LABEL  = 2026 Q1;

%let Q4_FOLDER = faers_ascii_2026q2;
%let Q4_SUFFIX = 26Q2;
%let Q4_LABEL  = 2026 Q2;

/*==========================================================================
  4. FILE PATHS
  ==========================================================================*/

/* Raw data root (FAERS ASCII folders sit here) */
%let RAW_PATH = &BASE;

/* SAS programs */
%let SAS_PATH = &BASE./sas;

/* Output subdirectories */
%let OUT_TABLES  = &BASE./output/tables;
%let OUT_FIGURES = &BASE./output/figures;
%let OUT_LOGS    = &BASE./output/logs;
%let OUT_QC      = &BASE./output/qc;

/*==========================================================================
  5. FAERS TABLE DEFINITIONS
  ==========================================================================
  Each table: name, file prefix (in FAERS files), column count
  Used by the import macro to know what to expect.
  ==========================================================================*/

%let FAERS_TABLES = DEMO DRUG REAC INDI OUTC THER RPSR;

/* Column counts per table (from FAERS documentation + verified) */
%let DEMO_NCOLS = 25;
%let DRUG_NCOLS = 20;
%let REAC_NCOLS = 4;
%let INDI_NCOLS = 4;
%let OUTC_NCOLS = 3;
%let THER_NCOLS = 7;
%let RPSR_NCOLS = 3;

/*==========================================================================
  6. GLP-1 RECEPTOR AGONIST CLASS DEFINITION
  ==========================================================================
  MATCHING RULE: SUBSTRING, NOT EQUALITY.

  This file originally matched prod_ai with an exact IN list. That was wrong.
  FAERS stores multi-ingredient products as a single backslash-separated
  prod_ai string - 'SEMAGLUTIDE\CYANOCOBALAMIN' for compounded formulations,
  for example - and an equality test drops every one of them without warning.

  The MySQL warehouse surfaced the gap: sql/03_queries.sql Q3.2 lists every
  prod_ai value a wildcard match catches beyond an exact match. Reviewed
  2026-09-03 - all genuine GLP-1 combination and compounded products, no
  false positives. Both layers now select the same cohort, so a SAS case
  count and a MySQL case count of the same drug reconcile.

  Substring matching is safe for this particular class because no member's
  name is a substring of another's, and none appears inside an unrelated
  ingredient name. That is a property of these four molecules, not a general
  rule - re-run Q3.2 before adding a fifth.

  GRAIN: a prod_ai naming two class members matches both, so one drug record
  can yield one row per molecule. Count cases with COUNT(DISTINCT primaryid)
  or NODUPKEY, never by row. Same rule as glp1_ps_case on the MySQL side.
  ==========================================================================*/

/* Class definition. The SAS counterpart of the ref_glp1_drug table in
   sql/01_ddl.sql - keep the two in step when the class changes.

   match_string exists separately from drug_label so a molecule whose FAERS
   spelling differs from its reporting label can be handled without renaming
   it everywhere downstream. It must be a single token with no spaces: the
   macro variables below are built from it as a space-separated list. */
data work.ref_glp1_drug;
    length drug_label $20 match_string $30 generation $12 brand_names $60;
    infile datalines dlm='|' truncover;
    input drug_label $ match_string $ generation $ brand_names $;
    datalines;
SEMAGLUTIDE|SEMAGLUTIDE|newer|Ozempic / Wegovy / Rybelsus
TIRZEPATIDE|TIRZEPATIDE|newer|Mounjaro / Zepbound
LIRAGLUTIDE|LIRAGLUTIDE|comparator|Victoza / Saxenda
DULAGLUTIDE|DULAGLUTIDE|comparator|Trulicity
;
run;

/* Macro variables are DERIVED from the dataset, not typed twice, so the
   dataset stays the single source of truth for the class definition. */
proc sql noprint;
    select drug_label   into :GLP1_DRUGS      separated by ' ' from work.ref_glp1_drug;
    select match_string into :GLP1_MATCH_LIST separated by ' ' from work.ref_glp1_drug;
    select count(*)     into :N_GLP1_DRUGS trimmed             from work.ref_glp1_drug;
quit;

/* NOTE: &GLP1_DRUGS is now a SPACE-separated list of bare words, not the
   quoted comma list it used to be. `where prod_ai in (&GLP1_DRUGS)` is
   therefore a syntax error rather than a silently narrow filter - which is
   the point. Use %glp1_match() below instead. */

/* Individual drug macro vars for program flexibility */
%let DRUG_SEMA = SEMAGLUTIDE;
%let DRUG_TIRZ = TIRZEPATIDE;
%let DRUG_LIRA = LIRAGLUTIDE;
%let DRUG_DULA = DULAGLUTIDE;


/*--------------------------------------------------------------------------
  %glp1_match(var) - boolean expression, true when VAR names any class member

  Generates, for the current class definition:

      (find(prod_ai, "SEMAGLUTIDE", 'i') > 0
       or find(prod_ai, "TIRZEPATIDE", 'i') > 0
       or find(prod_ai, "LIRAGLUTIDE", 'i') > 0
       or find(prod_ai, "DULAGLUTIDE", 'i') > 0)

  Usage - DATA step or PROC SQL, both work:

      data glp1_ps;
          set clean.drug;
          where role_cod = 'PS' and %glp1_match(prod_ai);
      run;

  FIND with the 'i' modifier rather than INDEX: prod_ai is upcased by
  01_import_clean.sas so case should never matter, but a case-insensitive
  test costs nothing and keeps the macro correct if it is later pointed at
  drugname, or at a dataset built outside this pipeline.

  This answers "is it in the class". It cannot answer "which member is it",
  because a record can match more than one. For that, join to
  WORK.REF_GLP1_DRUG - the SAS equivalent of the LIKE join in
  sql/03_queries.sql section 3:

      proc sql;
          create table glp1_ps_case as
              select  d.primaryid, d.caseid, g.drug_label, g.generation,
                      count(*) as n_drug_records
              from    clean.drug as d, work.ref_glp1_drug as g
              where   d.role_cod = 'PS'
                and   find(d.prod_ai, strip(g.match_string), 'i') > 0
              group by d.primaryid, d.caseid, g.drug_label, g.generation;
      quit;

  That is a deliberate cross join filtered by FIND: with only four reference
  rows the expansion is trivial, and it is the one formulation that keeps a
  combination product attributed to every molecule it actually contains.
  --------------------------------------------------------------------------*/
%macro glp1_match(var);
%local i;
(
%do i = 1 %to &N_GLP1_DRUGS;
    %if &i > 1 %then %do; or %end;
    find(&var, "%scan(&GLP1_MATCH_LIST, &i)", 'i') > 0
%end;
)
%mend glp1_match;

/*==========================================================================
  7. ANALYSIS PARAMETERS
  ==========================================================================*/

/* Signal detection thresholds — Evans criteria */
%let PRR_THRESHOLD = 2;        /* PRR >= 2                */
%let CHI2_THRESHOLD = 4;       /* Chi-square >= 4         */
%let MIN_CASES = 3;            /* N >= 3 cases            */

/* Age group cutoffs for subgroup analysis */
%let AGE_CUT1 = 45;            /* <=45 = young            */
%let AGE_CUT2 = 64;            /* 46-64 = middle          */
                                /* >=65 = elderly           */

/*==========================================================================
  8. FORMATS
  ==========================================================================*/
proc format;
    /* Age group */
    value agegrpf
        low -  &AGE_CUT1  = '<=45'
        %eval(&AGE_CUT1+1) - &AGE_CUT2 = '46-64'
        %eval(&AGE_CUT2+1) - high = '>=65'
    ;

    /* Drug role code */
    value $rolef
        'PS' = 'Primary Suspect'
        'SS' = 'Secondary Suspect'
        'C'  = 'Concomitant'
        'I'  = 'Interacting'
    ;

    /* Outcome code */
    value $outcf
        'DE' = 'Death'
        'LT' = 'Life-Threatening'
        'HO' = 'Hospitalization'
        'DS' = 'Disability'
        'CA' = 'Congenital Anomaly'
        'RI' = 'Required Intervention'
        'OT' = 'Other Serious'
    ;

    /* Report source */
    value $rpsrf
        'FGN' = 'Foreign'
        'SDY' = 'Study'
        'LIT' = 'Literature'
        'CSM' = 'Consumer'
        'HP'  = 'Health Professional'
        'UF'  = 'User Facility'
        'DT'  = 'Distributor'
        'OTH' = 'Other'
    ;

    /* Signal flag based on Evans criteria */
    value sigf
        1 = 'Signal'
        0 = 'No Signal'
    ;
run;

/*==========================================================================
  9. GLOBAL OPTIONS
  ==========================================================================*/
options
    nocenter
    nodate
    ls=200
    ps=60
    mprint           /* show macro-generated code in log */
    symbolgen        /* show macro variable resolution   */
    fmtsearch=(work) /* search work library for formats  */
;

title "FAERS Signal Detection - GLP-1 Receptor Agonists";
footnote "Data: FDA FAERS 2025Q3-2026Q2 | Analysis by Hingling Yu";

/*==========================================================================
  10. CONFIRMATION
  ==========================================================================*/
%put NOTE: ============================================;
%put NOTE: 00_config.sas loaded successfully.;
%put NOTE: BASE path  = &BASE;
%put NOTE: Quarters   = &QUARTERS;
%put NOTE: GLP-1 class  = &GLP1_DRUGS (&N_GLP1_DRUGS molecules, substring match);
%put NOTE: PRR threshold = &PRR_THRESHOLD  Chi2 = &CHI2_THRESHOLD  MinN = &MIN_CASES;
%put NOTE: ============================================;

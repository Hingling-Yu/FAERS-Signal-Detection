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
  6. GLP-1 RECEPTOR AGONIST DRUG LIST
  ==========================================================================
  Values match prod_ai field in DRUG table (will be UPCASE TRIMMED at import).
  Used by 03_glp1_*.sas programs for subsetting.
  ==========================================================================*/

%let GLP1_DRUGS = 'SEMAGLUTIDE', 'TIRZEPATIDE', 'LIRAGLUTIDE', 'DULAGLUTIDE';

/* Individual drug macro vars for program flexibility */
%let DRUG_SEMA = SEMAGLUTIDE;
%let DRUG_TIRZ = TIRZEPATIDE;
%let DRUG_LIRA = LIRAGLUTIDE;
%let DRUG_DULA = DULAGLUTIDE;

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
%put NOTE: GLP-1 drugs = &GLP1_DRUGS;
%put NOTE: PRR threshold = &PRR_THRESHOLD  Chi2 = &CHI2_THRESHOLD  MinN = &MIN_CASES;
%put NOTE: ============================================;

/*****************************************************************************
 * 02_signal_engine.sas - Full-database disproportionality signal detection
 *
 * Purpose:  Phase 2 core engine. Builds the case-level drug x reaction
 *           contingency table for every Primary Suspect drug in the cleaned
 *           FAERS database, computes PRR and ROR with 95% CIs, and applies
 *           the Evans signal criteria.
 *
 * Inputs:   CLEAN.DRUG   role_cod, prod_ai   (produced by 01_import_clean.sas)
 *           CLEAN.REAC   pt
 *
 * Outputs:  SIGNAL.ALL_SIGNALS                    every evaluated pair, flagged
 *           &OUT_TABLES/all_signals_flagged.csv   Evans-flagged subset
 *           &OUT_QC/qc_signal_engine.csv          run audit
 *
 * Scope:    FULL database. No drug-class filter is applied here - the GLP-1
 *           cohort is carved out of SIGNAL.ALL_SIGNALS downstream, so the
 *           class comparison is made against the whole reporting background
 *           rather than against a background that was pre-filtered to the
 *           class itself.
 *
 * -----------------------------------------------------------------------
 * METHOD - the 2x2 table
 * -----------------------------------------------------------------------
 *                       | Reaction of interest | All other reactions
 *   --------------------+----------------------+---------------------
 *   Drug of interest    |          a           |          b
 *   All other drugs     |          c           |          d
 *
 *   a = cases reporting drug X with reaction Y
 *   b = cases reporting drug X with any other reaction   = n_drug - a
 *   c = cases reporting reaction Y with any other drug   = n_reac - a
 *   d = cases reporting neither                          = N - n_drug - n_reac + a
 *
 *   The unit of analysis is the CASE (primaryid), not the drug record. A
 *   case listing the same ingredient on three drug lines is one case, so
 *   every cell is counted on de-duplicated primaryid values.
 *
 * -----------------------------------------------------------------------
 * METHOD - why every cell comes from the same universe
 * -----------------------------------------------------------------------
 *   N, n_drug and n_reac are all counted from WORK.DRUG_REAC_PAIRS, i.e.
 *   from cases that have at least one PS drug AND at least one coded
 *   reaction. Mixing sources here is the classic way to get a negative d:
 *   count n_reac from all of CLEAN.REAC and it includes cases with no PS
 *   drug, which are not in N, and d = N - n_drug - n_reac + a can go below
 *   zero. Held to one universe, inclusion-exclusion guarantees
 *   n_drug + n_reac - a <= N, so d >= 0 by construction. Section 4 asserts
 *   this rather than trusting it.
 *
 * -----------------------------------------------------------------------
 * STORAGE - read before the first run
 * -----------------------------------------------------------------------
 *   SAS ODA allows 5 GB. The pairs table is roughly 7M rows carrying
 *   prod_ai ($500) and pt ($100), which is over 4 GB unless compressed -
 *   hence COMPRESS=YES below, which is not optional on this platform. Most
 *   of those 500 bytes are trailing blanks and RLE removes them almost
 *   entirely. Intermediates are deleted as soon as the next stage has read
 *   them, so peak usage stays near two copies of the largest table.
 *
 *   If space still runs short: replace prod_ai and pt with numeric surrogate
 *   keys in sections 2-4 and join the text back on only at section 6. That
 *   cuts the pairs table to ~24 bytes per row at the cost of two extra
 *   lookup tables, and is the first thing to try before trimming scope.
 *
 * Runtime:  roughly 20-40 minutes on SAS ODA. The GROUP BY that produces a
 *           is the dominant step.
 *
 * Author:   Hingling Yu
 * Created:  2026-09-03
 *****************************************************************************/

/*==========================================================================
  1. SETUP
  ==========================================================================*/

/* Literal path, for the same reason as 01_import_clean.sas: &BASE is defined
   BY this file, so it cannot be used to find it. Every path after this line
   derives from &BASE. */
%include "/home/u64291357/mydata/sas/00_config.sas";

%include "&SAS_PATH./macros/calc_prr.sas";
%include "&SAS_PATH./macros/calc_ror.sas";

/* 00_config.sas turns MPRINT and SYMBOLGEN on. Useful when debugging a
   single macro call, unreadable across a run that generates several million
   rows - the row counts get buried. */
options nosymbolgen nomprint;

/* Not optional here - see the STORAGE note in the header. */
options compress=yes;

/* Run timer. */
%let _T0 = %sysfunc(datetime());

/*--------------------------------------------------------------------------
  Two small helpers used for the progress log only.

  %_stamp  prints a message prefixed with elapsed time since &_T0.
  %_count  does the same and appends a row count read from the dataset
           header (NLOBS), so logging the size of a 7M-row table costs
           nothing - no COUNT(*) pass over the data.

  Both format the number INSIDE the macro rather than at the call site. A
  comma-formatted count passed in as an argument would resolve to
  "7,123,456" during argument scanning, and the macro processor would read
  those commas as parameter delimiters.
  --------------------------------------------------------------------------*/
%macro _stamp(label);
    %local e;
    %let e = %sysevalf(%sysfunc(datetime()) - &_T0);
    %put NOTE: [%sysfunc(putn(&e, time12.2))] &label;
%mend _stamp;

%macro _count(label, ds);
    %local dsid n rc e;
    %let dsid = %sysfunc(open(&ds));
    %if &dsid = 0 %then %let n = .;
    %else %do;
        %let n  = %sysfunc(attrn(&dsid, nlobs));
        %let rc = %sysfunc(close(&dsid));
    %end;
    %let e = %sysevalf(%sysfunc(datetime()) - &_T0);
    %put NOTE: [%sysfunc(putn(&e, time12.2))] &label = %sysfunc(putn(&n, comma16.)) rows;
%mend _count;

/* &OUT_TABLES must exist before PROC EXPORT writes into it. XCMD is disabled
   on SAS ODA, so DCREATE is the only way to create a directory from code;
   it is a no-op when the directory is already there. */
%macro _ensure_tables_dir;
    %local rc;
    %if %sysfunc(fileexist(&OUT_TABLES)) = 0 %then %do;
        %let rc = %sysfunc(dcreate(tables, &BASE./output));
        %if %length(&rc) = 0 %then
            %put WARNING: Could not create &OUT_TABLES - the CSV export will fail.;
    %end;
%mend _ensure_tables_dir;

%_ensure_tables_dir

%_stamp(02_signal_engine.sas started.)


/*==========================================================================
  2. CASE-LEVEL DRUG x REACTION PAIRS
  --------------------------------------------------------------------------
  PS only. Concomitant ('C') and interacting ('I') drugs are excluded because
  disproportionality asks whether a drug SUSPECTED of causing the event is
  reported with it more often than expected; counting every concomitant
  medication would attribute the event to whatever the patient happened to
  also be taking. Secondary suspect ('SS') is excluded for the same reason
  the FDA's own screening does - PS is the reporter's primary attribution.

  SELECT DISTINCT is what makes section 4 correct: FAERS lists one row per
  drug line, so a case naming the same ingredient on three lines produces
  three rows here. Collapsed to one row per primaryid x prod_ai x pt, a
  plain COUNT(*) downstream is already a case count.
  ==========================================================================*/
proc sql;
    create table work.drug_reac_pairs as
        select distinct
               d.primaryid,
               d.prod_ai,
               r.pt
        from   clean.drug as d
               inner join clean.reac as r
                    on d.primaryid = r.primaryid
        where  d.role_cod = 'PS'
          and  not missing(d.prod_ai)      /* a blank ingredient is not a drug */
          and  not missing(r.pt);          /* an uncoded reaction is not a PT  */
quit;

%_count(drug_reac_pairs, work.drug_reac_pairs)


/*==========================================================================
  3. DENOMINATORS
  --------------------------------------------------------------------------
  COUNT(DISTINCT primaryid) is required in both totals: a case appears once
  per reaction in the pairs table, so a drug reported with four PTs would be
  counted four times by COUNT(*). It is NOT required in section 4, where the
  DISTINCT of section 2 has already made one row equal one case.
  ==========================================================================*/
proc sql;
    create table work.drug_totals as
        select   prod_ai,
                 count(distinct primaryid) as n_drug label='Cases reporting this drug'
        from     work.drug_reac_pairs
        group by prod_ai;

    create table work.reac_totals as
        select   pt,
                 count(distinct primaryid) as n_reac label='Cases reporting this reaction'
        from     work.drug_reac_pairs
        group by pt;

    /* N - the analysis universe. See the header note on why this is counted
       from the pairs table and not from CLEAN.DRUG. */
    select count(distinct primaryid) into :TOTAL_N trimmed
        from work.drug_reac_pairs;

    /* Reconciliation only: PS cases that carry no coded reaction contribute
       to no cell and are correctly outside N. Logged so the gap is visible
       rather than silent. */
    select count(distinct primaryid) into :PS_CASES trimmed
        from clean.drug
        where role_cod = 'PS' and not missing(prod_ai);
quit;

%_count(distinct prod_ai, work.drug_totals)
%_count(distinct PT, work.reac_totals)
%put NOTE: Analysis universe N (PS case with >=1 coded PT) = %sysfunc(putn(&TOTAL_N, comma16.));
%put NOTE: PS cases in CLEAN.DRUG                          = %sysfunc(putn(&PS_CASES, comma16.));


/*==========================================================================
  4. THE 2x2 TABLE
  ==========================================================================*/

/* --- 4a. Cell a: cases with this drug AND this reaction ------------------ */
proc sql;
    create table work.pair_counts as
        select   prod_ai,
                 pt,
                 count(*) as a label='Cases with this drug and this reaction'
        from     work.drug_reac_pairs
        group by prod_ai, pt;
quit;

%_count(drug x reaction combinations, work.pair_counts)

/* The pairs table is ~7M rows and nothing downstream reads it again. */
proc datasets library=work nolist;
    delete drug_reac_pairs;
quit;

/* --- 4b. Cells b, c, d --------------------------------------------------
   LEFT JOIN rather than INNER is defensive only: every prod_ai and pt here
   came from the same table the totals were built from, so a miss is
   impossible. If one ever happened it would produce a missing n_drug, hence
   a missing b, and section 4c would catch it. */
proc sql;
    create table work.counts_2x2 as
        select p.prod_ai,
               p.pt,
               p.a,
               dt.n_drug - p.a                            as b
                   label='Cases with this drug, other reactions',
               rt.n_reac - p.a                            as c
                   label='Cases with this reaction, other drugs',
               &TOTAL_N - dt.n_drug - rt.n_reac + p.a     as d
                   label='Cases with neither',
               dt.n_drug,
               rt.n_reac
        from   work.pair_counts as p
               left join work.drug_totals as dt on p.prod_ai = dt.prod_ai
               left join work.reac_totals as rt on p.pt      = rt.pt;
quit;

proc datasets library=work nolist;
    delete pair_counts;
quit;

/* --- 4c. Assertion: the table must be internally consistent -------------
   A negative or missing cell means the universes drifted apart - the one
   failure mode of this design, and one that would otherwise surface as
   quietly wrong PRRs rather than as an error. */
%macro assert_2x2;
    %local nbad;
    proc sql noprint;
        select count(*) into :nbad trimmed
            from work.counts_2x2
            where nmiss(a, b, c, d) > 0 or min(a, b, c, d) < 0;
    quit;

    %if &nbad > 0 %then %do;
        %put ERROR: %sysfunc(putn(&nbad, comma16.)) rows have a missing or negative 2x2 cell.;
        %put ERROR- The drug, reaction and N counts are not on the same universe.;

        proc print data=work.counts_2x2(obs=20) noobs;
            where nmiss(a, b, c, d) > 0 or min(a, b, c, d) < 0;
            var prod_ai pt a b c d n_drug n_reac;
            title2 'ERROR - inconsistent 2x2 cells (first 20)';
        run;
        title2;
    %end;
    %else %put NOTE: 2x2 assertion passed - no missing or negative cells.;

    %global N_BADCELL;
    %let N_BADCELL = &nbad;
%mend assert_2x2;

%assert_2x2

%_count(counts_2x2, work.counts_2x2)


/*==========================================================================
  5. DISPROPORTIONALITY MEASURES
  --------------------------------------------------------------------------
  Both macros are pure row-wise DATA steps and accept ds_out = ds_in. The
  intermediates are named out here for a readable log and deleted straight
  after, which keeps at most two copies of a multi-million-row table on disk
  at once. On a tighter quota, write both in place instead.

  Zero cells come back as missing PRR / ROR, not as zero - see the macro
  headers. Section 6 relies on SAS treating missing as smaller than any
  number, so a non-evaluable pair can never satisfy a >= threshold test.
  ==========================================================================*/
%calc_prr(ds_in=work.counts_2x2, ds_out=work.with_prr);

proc datasets library=work nolist;
    delete counts_2x2;
quit;

%_stamp(PRR computed.)

%calc_ror(ds_in=work.with_prr, ds_out=work.with_prr_ror);

proc datasets library=work nolist;
    delete with_prr;
quit;

%_stamp(ROR computed.)


/*==========================================================================
  6. EVANS CRITERIA AND SIGNAL FLAGS
  --------------------------------------------------------------------------
  signal_flag - Evans (2001), the project's primary criterion:
      a >= &MIN_CASES  and  PRR >= &PRR_THRESHOLD  and  PRR_CHI2 >= &CHI2_THRESHOLD
    All three thresholds come from 00_config.sas. Changing a threshold is a
    config edit, never an edit here.

  signal_ror - the EMA-style criterion: the lower bound of the ROR 95% CI
    lies above 1, i.e. the association is statistically significant.

    Note what signal_ror deliberately does NOT include: a minimum case count.
    That makes it sensitive to sparse cells by design - a drug reported twice,
    once with a common PT, can produce a huge ROR with a lower bound above 1
    on a single case. Section 7 quantifies how many ROR flags sit below
    &MIN_CASES so the difference between the two criteria is measured rather
    than assumed, and the CSV export is restricted to the Evans set, which
    carries the case-count floor.
  ==========================================================================*/
data work.flagged;
    set work.with_prr_ror;

    length signal_flag signal_ror 8;

    signal_flag = (a >= &MIN_CASES
                   and PRR      >= &PRR_THRESHOLD
                   and PRR_CHI2 >= &CHI2_THRESHOLD);

    signal_ror  = (ROR_LCL > 1);

    /* Not evaluable is not the same as no signal: a zero cell means the
       measure is undefined, which both flags above score as 0. Carrying the
       distinction explicitly stops a downstream reader counting them as
       screened-and-cleared. */
    length evaluable 8;
    evaluable = (nmiss(PRR, ROR) = 0);

    /* The SIGF format from 00_config.sas is applied at display time in
       section 7, never stored on the dataset. PROC EXPORT writes FORMATTED
       values, so attaching it here would send the text 'Signal' / 'No Signal'
       to the CSV instead of 1 / 0 - awkward to load into MySQL or Tableau,
       and it would also break in any session that reads SIGNAL.ALL_SIGNALS
       without first running 00_config.sas, since SIGF lives in WORK. */

    label signal_flag = 'Evans signal (PRR)'
          signal_ror  = 'ROR signal (LCL > 1)'
          evaluable   = 'PRR and ROR both computable';
run;

proc datasets library=work nolist;
    delete with_prr_ror;
quit;

/* Full table - signals and non-signals both. The flag columns separate them;
   dropping the non-signals here would make it impossible to show what was
   screened, which is the part a reviewer asks about first.

   Descending PRR puts missing values last, because SAS sorts missing below
   every number - non-evaluable pairs therefore land at the bottom of their
   flag group rather than the top.

   This is the widest step in the program: several million rows carrying
   prod_ai $500. If it fails on utility-file space, add TAGSORT - it sorts
   the two BY keys alone and gathers the rows afterwards, trading a much
   smaller temporary footprint for a slower final pass. */
proc sort data=work.flagged out=signal.all_signals;
    by descending signal_flag descending PRR;
run;

proc datasets library=work nolist;
    delete flagged;
quit;

%_count(SIGNAL.ALL_SIGNALS, signal.all_signals)


/*==========================================================================
  7. QC SUMMARY
  ==========================================================================*/
proc sql noprint;
    select count(*)                                    into :QC_PAIRS    trimmed
        from signal.all_signals;
    select sum(evaluable)                              into :QC_EVAL     trimmed
        from signal.all_signals;
    select sum(signal_flag)                            into :QC_EVANS    trimmed
        from signal.all_signals;
    select sum(signal_ror)                             into :QC_ROR      trimmed
        from signal.all_signals;
    /* COUNT(*) with a WHERE rather than SUM(<boolean>): SAS SQL does
       evaluate a comparison to 1/0, but spelling the condition as a filter
       is unambiguous to anyone reading this against the ANSI SQL in sql/. */
    select count(*)                                    into :QC_BOTH     trimmed
        from signal.all_signals
        where signal_flag = 1 and signal_ror = 1;
    select count(*)                                    into :QC_ROR_THIN trimmed
        from signal.all_signals
        where signal_ror = 1 and a < &MIN_CASES;
quit;

data work.qc_signal;
    length metric $60 value 8 note $90;

    metric = 'Drug x reaction pairs evaluated';
    value  = &QC_PAIRS;
    note   = 'One row per prod_ai x PT, PS drugs only';   output;

    metric = 'Pairs with computable PRR and ROR';
    value  = &QC_EVAL;
    note   = 'Remainder had a zero cell - not evaluable, not cleared';  output;

    metric = 'Signals - Evans criteria';
    value  = &QC_EVANS;
    note   = "a>=&MIN_CASES, PRR>=&PRR_THRESHOLD, chi2>=&CHI2_THRESHOLD";  output;

    metric = 'Signals - ROR lower CI bound > 1';
    value  = &QC_ROR;
    note   = 'No minimum case count applied';             output;

    metric = 'Signals - both criteria';
    value  = &QC_BOTH;
    note   = 'Intersection, the most defensible subset';  output;

    metric = "ROR signals with a < &MIN_CASES";
    value  = &QC_ROR_THIN;
    note   = 'Sparse-cell ROR flags, excluded by Evans';  output;

    metric = 'Analysis universe N (cases)';
    value  = &TOTAL_N;
    note   = 'PS case with at least one coded PT';        output;

    metric = 'PS cases in CLEAN.DRUG';
    value  = &PS_CASES;
    note   = 'Difference from N = PS cases with no coded PT'; output;

    metric = 'Inconsistent 2x2 rows';
    value  = &N_BADCELL;
    note   = 'Must be 0 - see section 4c assertion';      output;

    label metric = 'Metric' value = 'Value' note = 'Note';
run;

proc export data=work.qc_signal
            outfile="&OUT_QC./qc_signal_engine.csv" dbms=csv replace;
run;

title2 "Phase 2 - signal engine QC summary";
proc print data=work.qc_signal noobs label;
    format value comma16.;
run;

/* Agreement between the two criteria, and the one place the SIGF format
   earns its keep - applied to the display, not stored on the data. */
title2 "Evans vs ROR criteria - agreement";
proc freq data=signal.all_signals;
    tables signal_flag * signal_ror / norow nocol nopercent;
    format signal_flag signal_ror sigf.;
run;

/* Sanity check. The sort in section 6 already put the strongest Evans
   signals first, so the first 20 rows ARE the top 20 by PRR. Expect the
   familiar shape of a full-database run: very rare drugs paired with very
   specific PTs, high PRR on small a. That is not a bug - it is why the
   case-count floor and the CI bounds are reported next to the point
   estimate. */
title2 "Top 20 Evans signals by PRR - sanity check";
proc print data=signal.all_signals(obs=20) noobs label;
    var prod_ai pt a b c d PRR PRR_LCL PRR_UCL PRR_CHI2 ROR ROR_LCL ROR_UCL;
    format a b c d comma12. PRR PRR_LCL PRR_UCL ROR ROR_LCL ROR_UCL 10.4
           PRR_CHI2 12.2;
run;
title2;

/* Evans subset only. The ROR criterion carries no case-count floor (see
   section 6), so exporting the union would push a large volume of
   single-case sparse-cell rows into a file meant for eyeball review. The
   ROR columns and signal_ror travel with every exported row, so both
   criteria stay visible for the rows that are exported. */
proc export data=signal.all_signals(where=(signal_flag = 1))
            outfile="&OUT_TABLES./all_signals_flagged.csv" dbms=csv replace;
run;


/*==========================================================================
  8. WRAP-UP
  ==========================================================================*/
%macro finish;
    %local e;
    %let e = %sysevalf(%sysfunc(datetime()) - &_T0);

    %put NOTE: ============================================;
    %put NOTE: 02_signal_engine.sas complete.;
    %put NOTE: Pairs evaluated  = %sysfunc(putn(&QC_PAIRS, comma16.));
    %put NOTE: Evans signals    = %sysfunc(putn(&QC_EVANS, comma16.));
    %put NOTE: ROR signals      = %sysfunc(putn(&QC_ROR, comma16.));
    %put NOTE: Both criteria    = %sysfunc(putn(&QC_BOTH, comma16.));
    %put NOTE: Output           = SIGNAL.ALL_SIGNALS;
    %put NOTE: CSV              = &OUT_TABLES./all_signals_flagged.csv;
    %put NOTE: QC               = &OUT_QC./qc_signal_engine.csv;
    %put NOTE: Elapsed          = %sysfunc(putn(&e, time12.2));
    %put NOTE: ============================================;

    %if &N_BADCELL > 0 %then %do;
        %put ERROR: Gate 2 FAILED - the 2x2 assertion in section 4c did not pass.;
        %put ERROR- Do not use SIGNAL.ALL_SIGNALS until this is resolved.;
    %end;
%mend finish;

%finish

/* Restore the trace settings 00_config.sas set, so a program %included after
   this one behaves as its author expects. */
options symbolgen mprint;

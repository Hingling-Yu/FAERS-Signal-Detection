/*****************************************************************************
 * 02_signal_engine.sas - Full-database disproportionality signal detection
 *
 * Purpose:  Phase 2 core engine. Builds the case-level drug x reaction
 *           contingency table for every Primary Suspect drug in the cleaned
 *           FAERS database, computes PRR and ROR with 95% CIs and the
 *           empirical Bayes EBGM with its 90% credible interval, and applies
 *           the Evans, ROR and MGPS signal criteria.
 *
 * Inputs:   CLEAN.DRUG   role_cod, prod_ai   (produced by 01_import_clean.sas)
 *           CLEAN.REAC   pt
 *
 * Outputs:  SIGNAL.ALL_SIGNALS                    every evaluated pair, flagged
 *           &OUT_TABLES/all_signals_flagged.csv   Evans-flagged subset
 *           &OUT_TABLES/signals_ebgm.csv          EBGM-flagged subset
 *           &OUT_QC/qc_signal_engine.csv          run audit
 *           &OUT_QC/qc_ebgm_model.csv             fitted MGPS prior
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
 * METHOD - three criteria, not one
 * -----------------------------------------------------------------------
 *   PRR (Evans) and ROR are frequentist ratios computed one pair at a time.
 *   Both are at their least trustworthy exactly where a full-database screen
 *   produces the most rows: rare drugs with one or two reports, where a
 *   single case can drive the ratio into double digits.
 *
 *   EBGM answers the same question with the whole database as a prior. The
 *   MGPS mixture is fitted once across every pair, then each pair is shrunk
 *   toward that background by an amount set by its own evidence, so a
 *   500-case association barely moves and a 1-case association collapses
 *   toward 1. Reporting all three side by side is what lets section 7
 *   measure how much of the Evans and ROR signal list is sparse-cell noise
 *   rather than asserting it. See macros/calc_ebgm.sas for the method.
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
 * Runtime:  roughly 30-55 minutes on SAS ODA. The GROUP BY that produces a
 *           is the dominant step; the EBGM fit adds roughly 5-15 minutes,
 *           most of it in the EB05 / EB95 bisection.
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
%include "&SAS_PATH./macros/calc_ebgm.sas";

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
  The two ratio macros are pure row-wise DATA steps and accept ds_out =
  ds_in. The intermediates are named out here for a readable log and deleted
  straight after, which keeps at most two copies of a multi-million-row
  table on disk at once. On a tighter quota, write them in place instead.

  Zero cells come back as missing PRR / ROR, not as zero - see the macro
  headers. Section 6 relies on SAS treating missing as smaller than any
  number, so a non-evaluable pair can never satisfy a >= threshold test.

  %calc_ebgm is the odd one out: it is a PROC IML step, not a DATA step,
  because the MGPS prior is fitted across every pair at once rather than row
  by row. It reads n_drug and n_reac - carried through untouched from
  section 4b by both ratio macros - and takes N as a macro variable NAME, so
  the engine's own &TOTAL_N is the single source of the analysis universe.
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

%calc_ebgm(ds_in=work.with_prr_ror, ds_out=work.with_all_measures,
           total_n=TOTAL_N);

proc datasets library=work nolist;
    delete with_prr_ror;
quit;

%_stamp(EBGM computed.)


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

  signal_ebgm - the FDA / MGPS criterion: EB05 >= 2, i.e. the 5th percentile
    of the posterior still sits at twice the expected count. It carries no
    minimum case count either, and unlike signal_ror it does not need one:
    the Bayesian shrinkage already pulls a one-case pair back toward 1, so a
    sparse pair cannot reach EB05 >= 2 on its own. That is the whole point of
    the method, and section 7 checks it holds on this database rather than
    taking it on faith.

    The threshold is written literally rather than pulled from 00_config.sas
    because 2 is not a tuning knob here - it is the published FDA screening
    cutoff, and the same number as &PRR_THRESHOLD only by coincidence of
    scale.
  ==========================================================================*/
data work.flagged;
    set work.with_all_measures;

    length signal_flag signal_ror signal_ebgm 8;

    signal_flag = (a >= &MIN_CASES
                   and PRR      >= &PRR_THRESHOLD
                   and PRR_CHI2 >= &CHI2_THRESHOLD);

    signal_ror  = (ROR_LCL > 1);

    signal_ebgm = (EB05 >= 2);

    /* Not evaluable is not the same as no signal: a zero cell means the
       measure is undefined, which all three flags above score as 0. Carrying
       the distinction explicitly stops a downstream reader counting them as
       screened-and-cleared. */
    length evaluable ebgm_evaluable 8;
    evaluable      = (nmiss(PRR, ROR) = 0);

    /* Kept separate from EVALUABLE on purpose. PRR and ROR need all four
       2x2 cells non-zero; EBGM needs only a > 0 and positive marginals, so
       it is computable on strictly more pairs. Without both counts the QC
       table cannot say whether an EBGM-only signal is a real difference in
       method or just a difference in denominator. */
    ebgm_evaluable = (not missing(EBGM));

    /* The SIGF format from 00_config.sas is applied at display time in
       section 7, never stored on the dataset. PROC EXPORT writes FORMATTED
       values, so attaching it here would send the text 'Signal' / 'No Signal'
       to the CSV instead of 1 / 0 - awkward to load into MySQL or Tableau,
       and it would also break in any session that reads SIGNAL.ALL_SIGNALS
       without first running 00_config.sas, since SIGF lives in WORK. */

    label signal_flag    = 'Evans signal (PRR)'
          signal_ror     = 'ROR signal (LCL > 1)'
          signal_ebgm    = 'MGPS signal (EB05 >= 2)'
          evaluable      = 'PRR and ROR both computable'
          ebgm_evaluable = 'EBGM computable';
run;

proc datasets library=work nolist;
    delete with_all_measures;
quit;

/* Full table - signals and non-signals both. The flag columns separate them;
   dropping the non-signals here would make it impossible to show what was
   screened, which is the part a reviewer asks about first.

   Sorted by the two flags first and EBGM last: the head of the table is the
   set of pairs both the frequentist and the Bayesian screen agree on,
   ordered by the shrunk estimate rather than the raw ratio. Ordering by PRR
   instead would put single-case pairs with astronomical ratios on top, which
   is the opposite of what a reviewer wants to read first.

   Descending EBGM puts missing values last, because SAS sorts missing below
   every number - non-evaluable pairs therefore land at the bottom of their
   flag group rather than the top.

   This is the widest step in the program: several million rows carrying
   prod_ai $500. If it fails on utility-file space, add TAGSORT - it sorts
   the BY keys alone and gathers the rows afterwards, trading a much
   smaller temporary footprint for a slower final pass. */
proc sort data=work.flagged out=signal.all_signals;
    by descending signal_flag descending signal_ebgm descending EBGM;
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

    /* EBGM block. QC_EBGM_THIN is the claim in section 6 put to the test:
       if shrinkage really does protect against sparse cells, almost none of
       the EBGM signals should sit below the case-count floor that Evans has
       to impose by hand. */
    select sum(ebgm_evaluable)                         into :QC_EBEVAL   trimmed
        from signal.all_signals;
    select sum(signal_ebgm)                            into :QC_EBGM     trimmed
        from signal.all_signals;
    select count(*)                                    into :QC_ALL3     trimmed
        from signal.all_signals
        where signal_flag = 1 and signal_ror = 1 and signal_ebgm = 1;
    select count(*)                                    into :QC_EBGM_THIN trimmed
        from signal.all_signals
        where signal_ebgm = 1 and a < &MIN_CASES;

    /* Mean shrinkage. EBGM/RR is 1 when the data overwhelm the prior and
       approaches 0 as the evidence thins, so the average over the database
       is a single number for how hard the prior is pulling. */
    select avg(EBGM / RR)                              into :QC_SHRINK   trimmed
        from signal.all_signals
        where ebgm_evaluable = 1 and RR > 0;
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

    metric = 'Signals - both PRR and ROR criteria';
    value  = &QC_BOTH;
    note   = 'Intersection of the two frequentist criteria'; output;

    metric = "ROR signals with a < &MIN_CASES";
    value  = &QC_ROR_THIN;
    note   = 'Sparse-cell ROR flags, excluded by Evans';  output;

    metric = 'Pairs with computable EBGM';
    value  = &QC_EBEVAL;
    note   = 'Needs a>0 only - more pairs than PRR/ROR can evaluate'; output;

    metric = 'Signals - EBGM (EB05 >= 2)';
    value  = &QC_EBGM;
    note   = 'FDA MGPS criterion, no case-count floor applied'; output;

    metric = "EBGM signals with a < &MIN_CASES";
    value  = &QC_EBGM_THIN;
    note   = 'Should be near 0 - shrinkage replaces the floor'; output;

    metric = 'Signals - all three criteria';
    value  = &QC_ALL3;
    note   = 'Evans AND ROR AND EBGM, the most defensible subset'; output;

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

/* The fitted MGPS prior gets its own table rather than extra rows in
   WORK.QC_SIGNAL. That table's VALUE column is printed with COMMA16., which
   is right for counts in the millions and would round a mixing weight of
   0.63 to 1. Mixing magnitudes in one column costs either the commas or the
   decimals; two tables cost neither.

   These parameters are the audit trail for the EBGM column: two runs on the
   same data must produce the same five numbers, and a reviewer who wants to
   reproduce an EBGM by hand needs them. All come from macros/calc_ebgm.sas
   via the global macro variables it sets. */
data work.qc_ebgm_model;
    length parameter $44 value 8 note $90;

    parameter = 'Mixing weight P';
    value     = &_EBGM_P;
    note      = 'Prior probability a pair is background (component 1)'; output;

    parameter = 'alpha1 (background shape)';
    value     = &_EBGM_A1;
    note      = 'Component 1 prior mean = alpha1 / beta1';    output;

    parameter = 'beta1 (background rate)';
    value     = &_EBGM_B1;
    note      = 'Larger beta1 = tighter background around its mean'; output;

    parameter = 'alpha2 (signal shape)';
    value     = &_EBGM_A2;
    note      = 'Component 2 prior mean = alpha2 / beta2';    output;

    parameter = 'beta2 (signal rate)';
    value     = &_EBGM_B2;
    note      = 'Larger beta2 = tighter signal component';    output;

    parameter = 'EM iterations run';
    value     = &_EBGM_ITER;
    note      = "Cap = 200; see calc_ebgm.sas MAX_ITER=";     output;

    parameter = 'EM converged (1 = yes)';
    value     = &_EBGM_CONV;
    note      = 'Must be 1 - otherwise the prior is not a fit'; output;

    parameter = 'Final log-likelihood';
    value     = &_EBGM_LL;
    note      = 'Marginal NB mixture log-likelihood at the optimum'; output;

    parameter = 'Pairs used in the fit';
    value     = &_EBGM_NFIT;
    note      = 'Rows with a>0 and positive marginals';       output;

    parameter = 'Mean shrinkage EBGM / RR';
    value     = &QC_SHRINK;
    note      = '1 = no shrinkage; lower = prior pulling harder'; output;

    label parameter = 'MGPS model parameter' value = 'Value' note = 'Note';
run;

proc export data=work.qc_ebgm_model
            outfile="&OUT_QC./qc_ebgm_model.csv" dbms=csv replace;
run;

title2 "Phase 2 - fitted MGPS prior (two-component Gamma mixture)";
proc print data=work.qc_ebgm_model noobs label;
    format value best12.;
run;

/* Agreement between the criteria, and the one place the SIGF format earns
   its keep - applied to the display, not stored on the data. The Evans x
   EBGM cell counts are the headline: the off-diagonal is the disagreement
   between a frequentist ratio and a shrunk Bayesian one, which is the whole
   reason for computing both. */
title2 "Criteria agreement - Evans vs ROR vs EBGM";
proc freq data=signal.all_signals;
    tables signal_flag * signal_ror
           signal_flag * signal_ebgm
           signal_ror  * signal_ebgm / norow nocol nopercent;
    format signal_flag signal_ror signal_ebgm sigf.;
run;

/* Sanity check. The sort in section 6 already put the pairs that satisfy
   both Evans and EBGM first, ordered by EBGM, so the first 20 rows ARE the
   top 20 by the shrunk estimate. Expect well-populated pairs here - high a,
   RR and EBGM close together. If instead the head of the table is full of
   a=1 rows with EBGM far below RR, the shrinkage is not doing its job and
   the fitted prior in the model card above is the first thing to check. */
title2 "Top 20 signals by EBGM - sanity check";
proc print data=signal.all_signals(obs=20) noobs label;
    var prod_ai pt a E RR EBGM EB05 EB95 PRR PRR_CHI2 ROR ROR_LCL;
    format a comma12. E RR EBGM EB05 EB95 PRR ROR ROR_LCL 10.4
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

/* The EBGM set exported separately rather than merged into the file above.
   Keeping them apart is what makes the two files comparable: Phase 2 Step 3
   validates the engine against known positive controls, and "which criterion
   found it" is the question that validation has to answer. Every exported
   row still carries all three flags, so either file can be re-filtered. */
proc export data=signal.all_signals(where=(signal_ebgm = 1))
            outfile="&OUT_TABLES./signals_ebgm.csv" dbms=csv replace;
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
    %put NOTE: EBGM signals     = %sysfunc(putn(&QC_EBGM, comma16.));
    %put NOTE: PRR + ROR        = %sysfunc(putn(&QC_BOTH, comma16.));
    %put NOTE: All 3 criteria   = %sysfunc(putn(&QC_ALL3, comma16.));
    %put NOTE: MGPS prior       = P=&_EBGM_P a1=&_EBGM_A1 b1=&_EBGM_B1 a2=&_EBGM_A2 b2=&_EBGM_B2;
    %put NOTE: EM               = &_EBGM_ITER iterations, converged=&_EBGM_CONV;
    %put NOTE: Mean EBGM/RR     = &QC_SHRINK;
    %put NOTE: Output           = SIGNAL.ALL_SIGNALS;
    %put NOTE: CSV              = &OUT_TABLES./all_signals_flagged.csv;
    %put NOTE: CSV              = &OUT_TABLES./signals_ebgm.csv;
    %put NOTE: QC               = &OUT_QC./qc_signal_engine.csv;
    %put NOTE: QC               = &OUT_QC./qc_ebgm_model.csv;
    %put NOTE: Elapsed          = %sysfunc(putn(&e, time12.2));
    %put NOTE: ============================================;

    %if &N_BADCELL > 0 %then %do;
        %put ERROR: Gate 2 FAILED - the 2x2 assertion in section 4c did not pass.;
        %put ERROR- Do not use SIGNAL.ALL_SIGNALS until this is resolved.;
    %end;

    /* A non-converged EM is not a hard failure - the last-iteration
       parameters still produce usable estimates - but the EBGM column is no
       longer reproducible from a stated fit, so it must not pass Gate 2b
       unreviewed. */
    %if &_EBGM_CONV ne 1 %then %do;
        %put WARNING: The MGPS EM did not converge in &_EBGM_ITER iterations.;
        %put WARNING- EBGM, EB05 and EB95 use last-iteration parameters. Review before use.;
    %end;
%mend finish;

%finish

/* Restore the trace settings 00_config.sas set, so a program %included after
   this one behaves as its author expects. */
options symbolgen mprint;

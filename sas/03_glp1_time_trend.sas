/*****************************************************************************
 * 03_glp1_time_trend.sas - GLP-1 quarter-by-quarter PRR trend analysis
 *
 * Purpose:  Phase 3 Step 5. Recompute disproportionality inside each of the
 *           four reporting quarters, classify how every drug x reaction pair
 *           moves across them, and separate signals that genuinely emerge
 *           from signals that only appear to emerge because the quarter they
 *           were absent from was too thin to measure.
 *
 * Inputs:   CLEAN.GLP1_CASES   Step 1 cohort, one row per case x molecule
 *           CLEAN.GLP1_REAC    Step 1 reactions, primaryid x drug x pt
 *           CLEAN.DRUG         full FAERS, for the analysis universe
 *           CLEAN.REAC         full FAERS, for quarter-level c and n_reac
 *           CLEAN.DEMO         full FAERS, for the quarter each case sits in
 *
 * Outputs:  SIGNAL.GLP1_TIME_TREND     PRR per drug x pt x quarter (long)
 *           SIGNAL.GLP1_TREND_SUMMARY  one row per drug x pt, classified
 *           SIGNAL.GLP1_EMERGING       emerging + accelerating only
 *           &OUT_TABLES/glp1_time_trend.csv
 *           &OUT_TABLES/glp1_trend_summary.csv
 *           &OUT_TABLES/glp1_emerging_signals.csv
 *           &OUT_QC/qc_glp1_time_trend.csv
 *
 * -----------------------------------------------------------------------
 * THREE DEPARTURES FROM THE SPEC
 * -----------------------------------------------------------------------
 * 1. QUARTER DERIVATION. The spec derives year_qtr with
 *    SUBSTR(strip(init_fda_dt),1,4). init_fda_dt in CLEAN.DEMO is a numeric
 *    SAS date formatted yymmdd10., not the 8-character string the spec
 *    assumed, so SUBSTR would read the first four digits of a five-digit
 *    date serial and file every case under a year in the 2000s that does not
 *    exist. YEAR() and QTR() are used instead, matching what
 *    03_glp1_extract.sas already does for the cohort. Same correction, same
 *    reason, second occurrence.
 *
 * 2. DENOMINATORS COME FROM THE STEP 2-4 UNIVERSE, NOT FROM CLEAN.DEMO.
 *    The spec counts N per quarter straight off CLEAN.DEMO (1,529,536
 *    cases). Steps 2, 3 and 4 all computed their PRRs on the 1,529,453 cases
 *    that carry both a PS drug and a coded PT, and Step 4 aborts if that
 *    number moves. Eighty-three cases is a rounding error in the arithmetic
 *    and it is not why this matters: a quarterly PRR that cannot be laid
 *    beside the pooled PRR from Step 2 has no baseline to be a trend
 *    against. The universe is rebuilt here by the same two-DISTINCT
 *    construction and asserted before anything is estimated.
 *
 * 3. SIGNAL VELOCITY IS DIVIDED BY THE ELAPSED SPAN, NOT THE QUARTER COUNT.
 *    The spec divides by n_quarters_data. For a pair measurable in 2025Q3
 *    and 2026Q2 but not in between, that divides a three-quarter change by
 *    two and reports it as a per-quarter rate. VELOCITY_SPAN_QTRS holds the
 *    actual distance between the first and last evaluable quarter and is
 *    carried into the output so the division can be checked by hand. The
 *    1.3x / 0.7x classification thresholds are left exactly as specified.
 *
 * -----------------------------------------------------------------------
 * WHY A MISSING QUARTER IS NOT A SUB-THRESHOLD QUARTER
 * -----------------------------------------------------------------------
 * This is the failure mode the whole program is shaped around, and it is
 * specific to this dataset. Quarterly GLP-1 case volume is not flat:
 *
 *     SEMAGLUTIDE   13,519 / 2,726 / 2,895 / 15,137
 *     TIRZEPATIDE   16,594 / 16,281 / 18,226 / 18,312
 *
 * TIRZEPATIDE barely moves. SEMAGLUTIDE's two middle quarters run about a
 * fifth of its outer two. A reaction reported at a steady rate across all
 * four quarters therefore falls under the a >= 3 floor in 2025Q4 and 2026Q1
 * for SEMAGLUTIDE and at no point for TIRZEPATIDE - purely because of how
 * many SEMAGLUTIDE cases arrived, not because the reaction stopped.
 *
 * Applied naively, the spec's Emerging rule reads that hole as evidence:
 * sub-threshold early, signal late, therefore emerging. It would fill the
 * headline table with SEMAGLUTIDE reactions that never went anywhere. So:
 *
 *   FULL GRID       Section 4 keeps a pair once it clears a >= 3 in ANY
 *                   quarter, then writes all four quarters for it. A quarter
 *                   with no cases is a row with a = 0, not an absent row.
 *
 *   EVAL_STATUS     EVALUABLE (a >= 3, PRR computed), THIN (1 <= a < 3,
 *                   reported, no PRR) or ABSENT (a = 0). Only EVALUABLE
 *                   quarters contribute a PRR to the trend arithmetic.
 *
 *   EMERGING_BASIS  'Measured' when both early quarters were evaluable and
 *                   genuinely sub-threshold. 'Inferred' when at least one of
 *                   them could not be measured. Same classification, stated
 *                   confidence. Read Measured first.
 *
 *   COVERAGE_NOTE   names every non-evaluable quarter with its own a and the
 *                   molecule's case count for that quarter, so the reader
 *                   sees the 2,726 next to the gap it caused.
 *
 * Nothing above filters anything out, in keeping with Step 4: the low-
 * confidence rows are reported and labelled, not dropped.
 *
 * -----------------------------------------------------------------------
 * THE CLOCK, AND THE 13% IT EXCLUDES
 * -----------------------------------------------------------------------
 * Cases are assigned to a quarter by init_fda_dt, the FDA initial receive
 * date, falling back to fda_dt. That is the standard FAERS choice and the
 * right one for an emerging-signal question: it does not move when a case is
 * revised, so a 2025Q3 report stays in 2025Q3 no matter how many follow-ups
 * it later attracts.
 *
 * The cost is that the four quarterly files are not four quarterly cohorts.
 * Each file also carries follow-up versions of older cases, whose initial
 * date is outside the window. About 200,000 of the 1.53M cases - 13% - fall
 * outside 2025Q3-2026Q2 and are excluded here. They are counted in the QC
 * table rather than left implicit, because that share is the reason a
 * quarterly N here is smaller than the same quarter's file.
 *
 * The other date hazard is empty: a date reported as a bare year is imputed
 * to January 1 by the import macro and would land in Q1 without having been
 * a Q1 report. 03_glp1_extract.sas measured this for the cohort and found 0.
 * Section 2 measures it again for the full denominator population, which
 * this program is the first to depend on.
 *
 * -----------------------------------------------------------------------
 * ONE GRAIN ONLY
 * -----------------------------------------------------------------------
 * Steps 3 and 4 carry a PT grain and a class-effect GROUP grain. This
 * program runs at PT grain alone. A trend is read as a shape across four
 * points, and the group grain would put a second, non-additive set of shapes
 * beside the first for the same underlying cases - the fastest way to double
 * count an emerging signal in a headline table. Group-level trends belong in
 * Step 7, computed from SIGNAL.GLP1_TIME_TREND, once the PT-level shapes are
 * settled.
 *
 * Author:   Hingling Yu
 * Created:  2026-09-08
 *****************************************************************************/

/*==========================================================================
  1. SETUP
  ==========================================================================*/

/* Literal path: &BASE is defined BY this file, so it cannot be used to find
   it. Every path after this line derives from &BASE or &SAS_PATH. */
%include "/home/u64291357/mydata/sas/00_config.sas";
%include "&SAS_PATH./macros/calc_prr.sas";

/* 00_config.sas turns MPRINT and SYMBOLGEN on. The joins below are plain
   SQL and the macro trace would bury the tables this program exists to
   print. */
options nosymbolgen nomprint;

%let _T0 = %sysfunc(datetime());

/* Chronological. Q1..Q4 throughout this program mean positions in this list,
   never calendar quarters - 2026Q1 is position 3. */
%let QTR_LIST  = 2025Q3 2025Q4 2026Q1 2026Q2;
%let N_QTRS    = 4;
%let QTR_WHERE = '2025Q3','2025Q4','2026Q1','2026Q2';

/* The universe Steps 2, 3 and 4 computed their PRRs on. */
%let N_UNIVERSE_EXPECTED = 1529453;

/* An argument containing an unquoted comma is read as a second positional
   parameter and the call fails with "more positional parameters found than
   defined". Either avoid the comma or wrap the argument in %str(). */
%macro _stamp(label);
    %local e;
    %let e = %sysevalf(%sysfunc(datetime()) - &_T0);
    %put NOTE: [%sysfunc(putn(&e, time12.2))] &label;
%mend _stamp;

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

title  "FAERS Signal Detection - GLP-1 Receptor Agonists";
title2 "Phase 3 Step 5 - Quarter-by-Quarter PRR Trend Analysis";

%_stamp(Section 1 - setup complete.)


/*==========================================================================
  2. ANALYSIS UNIVERSE AND QUARTER ASSIGNMENT

  Departure 1 (quarter derivation) and departure 2 (universe) both land
  here. See the header.
  ==========================================================================*/

/* Universe - identical construction to Steps 2, 3 and 4. Two DISTINCT sets
   joined, rather than one DISTINCT over the 7M-row DRUG x REAC join. */
proc sql;
    create table work._ps_cases as
        select distinct primaryid from clean.drug
        where role_cod = 'PS' and not missing(prod_ai);

    create table work._reac_cases as
        select distinct primaryid from clean.reac
        where not missing(pt);

    create table work.universe as
        select      p.primaryid
        from        work._ps_cases   as p
        inner join  work._reac_cases as r on p.primaryid = r.primaryid;
quit;

proc datasets library=work nolist;
    delete _ps_cases _reac_cases;
quit;

proc sql noprint;
    select count(*) into :N_UNIVERSE trimmed from work.universe;
quit;

%macro assert_universe;
    %if &N_UNIVERSE ne &N_UNIVERSE_EXPECTED %then %do;
        %put ERROR: Analysis universe is &N_UNIVERSE, expected &N_UNIVERSE_EXPECTED..;
        %put ERROR- Steps 2, 3 and 4 computed their PRRs on &N_UNIVERSE_EXPECTED cases.;
        %put ERROR- A quarterly PRR on a different universe is not a trend against them.;
        %abort cancel;
    %end;
    %put NOTE: Analysis universe N = %sysfunc(putn(&N_UNIVERSE, comma16.)) - matches Steps 2-4.;
%mend assert_universe;

%assert_universe

/* Quarter for every universe case.

   init_fda_dt is the FDA initial receive date. It is a NUMERIC SAS date,
   which is why YEAR()/QTR() are used and SUBSTR is not - see header note 1.
   fda_dt is the fallback for the handful whose initial date failed to parse.

   The result sorts correctly as a string: '2025Q3' < '2025Q4' < '2026Q1'. */
proc sql;
    create table work.demo_qtr as
        select      u.primaryid,
                    case when dm.init_fda_dt is not missing
                             then cats(put(year(dm.init_fda_dt), 4.), 'Q',
                                       put(qtr(dm.init_fda_dt), 1.))
                         when dm.fda_dt is not missing
                             then cats(put(year(dm.fda_dt), 4.), 'Q',
                                       put(qtr(dm.fda_dt), 1.))
                         else ''
                    end as year_qtr length=6
                        label='Report year-quarter',
                    dm.init_fda_dt_prec
        from        work.universe as u
        inner join  clean.demo    as dm on u.primaryid = dm.primaryid;
quit;

/* Measured before the window filter, so the QC table can state what the
   filter cost rather than leave it implicit. */
proc sql noprint;
    select count(*) into :N_QTR_MISSING trimmed
        from work.demo_qtr where year_qtr = '';

    select count(*) into :N_OUT_WINDOW trimmed
        from work.demo_qtr where year_qtr ne '' and year_qtr not in (&QTR_WHERE);

    /* 'Y' = year only, 'M' = year and month only. Both are imputed to the
       first of the period by the import macro, so a 'Y' date lands on
       January 1 and is filed under Q1 without ever having been a Q1 report.
       03_glp1_extract.sas found 0 of these in the GLP-1 cohort; the
       denominators used here are the first thing to depend on the full
       population, so it is re-measured. */
    select count(*) into :N_DATE_IMPUTED trimmed
        from work.demo_qtr where init_fda_dt_prec in ('Y', 'M');
quit;

proc sql;
    create table work.demo_win as
        select primaryid, year_qtr
        from   work.demo_qtr
        where  year_qtr in (&QTR_WHERE);
quit;

proc sql noprint;
    select count(*) into :N_IN_WINDOW trimmed from work.demo_win;
quit;

%put NOTE: In-window universe = %sysfunc(putn(&N_IN_WINDOW, comma16.)) of &N_UNIVERSE cases.;
%put NOTE- &N_OUT_WINDOW case(s) have an initial receive date outside 2025Q3-2026Q2.;
%put NOTE- &N_QTR_MISSING case(s) have no parseable date at all.;

%macro assert_dates;
    %if &N_DATE_IMPUTED > 0 %then %do;
        %put WARNING: &N_DATE_IMPUTED universe case(s) carry a year- or month-only initial date.;
        %put WARNING- These are imputed to the first of the period and bias the Q1 of their year.;
    %end;
    %else %put NOTE: Date precision assertion passed - no year- or month-only initial dates.;
%mend assert_dates;

%assert_dates

%_stamp(Section 2 - universe asserted and quarters assigned.)


/*==========================================================================
  3. QUARTER-LEVEL DENOMINATORS

  Each quarter is its own universe. A quarterly PRR built on the pooled N
  would dilute every quarterly contrast it exists to measure.
  ==========================================================================*/

/* n_drug - cases of this molecule in this quarter.

   Joined through DEMO_WIN rather than reading CLEAN.GLP1_CASES.YEAR_QTR, so
   numerator and denominator cannot disagree about which quarter a case is
   in. Section 8 checks the two agree on every case; they are derived from
   the same date by the same rule, and the check is there to keep that true
   if either side is ever edited. */
proc sql;
    create table work.tt_ndrug as
        select      g.drug_label,
                    g.generation,
                    dw.year_qtr,
                    count(distinct g.primaryid) as n_drug
        from        clean.glp1_cases as g
        inner join  work.demo_win    as dw on g.primaryid = dw.primaryid
        group by    g.drug_label, g.generation, dw.year_qtr;
quit;

/* n_reac - all cases in this quarter reporting this PT, GLP-1 or not. */
proc sql;
    create table work.tt_nreac as
        select      dw.year_qtr,
                    r.pt,
                    count(distinct r.primaryid) as n_reac
        from        clean.reac    as r
        inner join  work.demo_win as dw on r.primaryid = dw.primaryid
        where       not missing(r.pt)
        group by    dw.year_qtr, r.pt;
quit;

/* N - all cases in this quarter. */
proc sql;
    create table work.tt_ntotal as
        select      year_qtr,
                    count(distinct primaryid) as N_qtr
        from        work.demo_win
        group by    year_qtr;
quit;

title3 "Quarterly case volume - the denominator every trend below is read against";
proc report data=work.tt_ndrug nowd;
    columns drug_label year_qtr, n_drug;
    define drug_label / group 'Drug';
    define year_qtr   / across ' ';
    define n_drug     / analysis sum ' ' format=comma8.;
run;
title3;

%_stamp(Section 3 - quarterly denominators built.)


/*==========================================================================
  4. THE 2x2 TABLES - ON A FULL FOUR-QUARTER GRID

  The grid is the guardrail described in the header. A pair qualifies once
  it clears a >= &MIN_CASES in any single quarter; it then gets a row in all
  four, with a = 0 where it was never reported. A quarter is then something
  the trend logic can see and label, rather than a row that is simply not
  there and gets read as a zero.
  ==========================================================================*/

/* a - cases on this molecule, in this quarter, reporting this PT.

   The GLP1_CASES join is on primaryid AND drug_label. GLP1_REAC carries one
   row per case x molecule x PT, and a combination product puts the same
   case under two molecules; joining on primaryid alone would pair each
   molecule's reactions with the other's cases. */
proc sql;
    create table work.tt_a_raw as
        select      r.drug_label,
                    r.generation,
                    dw.year_qtr,
                    r.pt,
                    count(distinct r.primaryid) as a
        from        clean.glp1_reac  as r
        inner join  clean.glp1_cases as c
               on   r.primaryid  = c.primaryid
              and   r.drug_label = c.drug_label
        inner join  work.demo_win    as dw on c.primaryid = dw.primaryid
        group by    r.drug_label, r.generation, dw.year_qtr, r.pt;
quit;

/* Pairs worth tracking at all. MIN_CASES is applied to the pair's best
   quarter, not to each quarter independently - that is the whole point. */
proc sql;
    create table work.tt_pairs as
        select      drug_label, generation, pt,
                    max(a) as a_max,
                    sum(a) as a_total
        from        work.tt_a_raw
        group by    drug_label, generation, pt
        having      max(a) >= &MIN_CASES;
quit;

data work.tt_qtrs;
    length year_qtr $6;
    do qtr_order = 1 to &N_QTRS;
        year_qtr = scan("&QTR_LIST", qtr_order, ' ');
        output;
    end;
run;

proc sql;
    /* Cross join first, fill second. Written as two steps rather than one
       chained CROSS JOIN ... LEFT JOIN because the join order of the mixed
       form is worth nobody's time to reason about. */
    create table work._grid as
        select      p.drug_label, p.generation, p.pt, p.a_total as a_total_pair,
                    q.year_qtr, q.qtr_order
        from        work.tt_pairs as p,
                    work.tt_qtrs  as q;

    create table work.tt_grid as
        select      g.*,
                    coalesce(ar.a, 0) as a
        from        work._grid    as g
        left join   work.tt_a_raw as ar
               on   g.drug_label = ar.drug_label
              and   g.pt         = ar.pt
              and   g.year_qtr   = ar.year_qtr;
quit;

/* b = drug cases without the reaction, c = the reaction on other drugs,
   d = the remainder. LEFT JOIN on n_reac only because a PT can be absent
   from a quarter entirely, which is exactly the a = 0 case the grid exists
   to represent; COALESCE turns that into a zero count rather than a missing
   cell that would silently null out d. */
proc sql;
    create table work.tt_2x2 as
        select      g.drug_label,
                    g.generation,
                    g.pt,
                    g.year_qtr,
                    g.qtr_order,
                    g.a,
                    nd.n_drug,
                    coalesce(nr.n_reac, 0) as n_reac,
                    nt.N_qtr as N,
                    (nd.n_drug - g.a)                        as b,
                    (coalesce(nr.n_reac, 0) - g.a)           as c,
                    (nt.N_qtr - nd.n_drug
                     - coalesce(nr.n_reac, 0) + g.a)         as d
        from        work.tt_grid   as g
        inner join  work.tt_ndrug  as nd
               on   g.drug_label = nd.drug_label and g.year_qtr = nd.year_qtr
        left  join  work.tt_nreac  as nr
               on   g.pt         = nr.pt         and g.year_qtr = nr.year_qtr
        inner join  work.tt_ntotal as nt
               on   g.year_qtr   = nt.year_qtr;
quit;

proc datasets library=work nolist;
    delete _grid;
quit;

%_stamp(Section 4 - quarterly 2x2 tables assembled on the full grid.)


/*==========================================================================
  5. QUARTERLY PRR AND EVALUABILITY

  %calc_prr is the same macro Steps 2, 3 and 4 used, so a quarterly PRR and
  a pooled PRR are the same statistic computed on different rows. It returns
  a missing PRR for any zero cell rather than a continuity-corrected one,
  which is what puts every a = 0 quarter into EVAL_STATUS = 'ABSENT'.
  ==========================================================================*/
%calc_prr(ds_in=work.tt_2x2, ds_out=work.tt_prr);

data work.time_trend;
    set work.tt_prr;
    length eval_status $9;

    /* EVALUABLE  a >= MIN_CASES and all four cells positive - has a PRR
       THIN       reported, but under the floor - counted, never estimated
       ABSENT     not reported in this quarter at all */
    if a >= &MIN_CASES and not missing(PRR) then do;
        evaluable   = 1;
        eval_status = 'EVALUABLE';
    end;
    else do;
        evaluable   = 0;
        if a = 0 then eval_status = 'ABSENT';
        else          eval_status = 'THIN';
    end;

    /* Evans criteria, applied inside the quarter. A THIN or ABSENT quarter
       is not a signal, but it is not evidence of no signal either - which
       is what EVAL_STATUS carries forward for section 6. */
    if evaluable = 1
       and PRR      >= &PRR_THRESHOLD
       and PRR_CHI2 >= &CHI2_THRESHOLD
        then signal_flag = 1;
        else signal_flag = 0;

    label
        a           = 'Cases on drug with reaction'
        b           = 'Cases on drug without reaction'
        c           = 'Cases on other drugs with reaction'
        d           = 'Cases on other drugs without reaction'
        N           = 'Total cases in quarter'
        n_drug      = 'Total cases on drug in quarter'
        n_reac      = 'Total cases with reaction in quarter'
        evaluable   = 'PRR computable this quarter (a >= 3)'
        eval_status = 'EVALUABLE / THIN / ABSENT'
        signal_flag = 'Evans signal this quarter'
        qtr_order   = 'Quarter position 1-4';
run;

proc sort data=work.time_trend;
    by drug_label pt qtr_order;
run;

%_stamp(Section 5 - quarterly PRR computed.)


/*==========================================================================
  6. TREND CLASSIFICATION

  Q1..Q4 below are positions in &QTR_LIST: Q1 = 2025Q3, Q4 = 2026Q2.

  The 1.3x and 0.7x cut-points are judgment calls, not published standards.
  They are the spec's values and are left alone so this program's output can
  be compared against the spec's expectations; if they are revisited, this
  is the only place they appear.
  ==========================================================================*/
proc sql;
    create table work.trend_wide as
        select      drug_label, generation, pt,

                    /* Case counts - raw, including the quarters no PRR was
                       computed for. */
                    sum(case when qtr_order=1 then a else 0 end) as a_q1,
                    sum(case when qtr_order=2 then a else 0 end) as a_q2,
                    sum(case when qtr_order=3 then a else 0 end) as a_q3,
                    sum(case when qtr_order=4 then a else 0 end) as a_q4,

                    /* PRR - evaluable quarters only. A THIN quarter has no
                       PRR here even where the 2x2 arithmetic would produce
                       one, so nothing downstream can read an estimate built
                       on one or two cases as a point on the trend. */
                    max(case when qtr_order=1 and evaluable=1 then PRR else . end) as prr_q1,
                    max(case when qtr_order=2 and evaluable=1 then PRR else . end) as prr_q2,
                    max(case when qtr_order=3 and evaluable=1 then PRR else . end) as prr_q3,
                    max(case when qtr_order=4 and evaluable=1 then PRR else . end) as prr_q4,

                    max(case when qtr_order=1 then signal_flag else 0 end) as sig_q1,
                    max(case when qtr_order=2 then signal_flag else 0 end) as sig_q2,
                    max(case when qtr_order=3 then signal_flag else 0 end) as sig_q3,
                    max(case when qtr_order=4 then signal_flag else 0 end) as sig_q4,

                    max(case when qtr_order=1 then evaluable else 0 end) as ev_q1,
                    max(case when qtr_order=2 then evaluable else 0 end) as ev_q2,
                    max(case when qtr_order=3 then evaluable else 0 end) as ev_q3,
                    max(case when qtr_order=4 then evaluable else 0 end) as ev_q4,

                    /* The molecule's quarterly volume, carried alongside so
                       a gap can be read against the denominator that caused
                       it without opening a second table. */
                    max(case when qtr_order=1 then n_drug else . end) as n_drug_q1,
                    max(case when qtr_order=2 then n_drug else . end) as n_drug_q2,
                    max(case when qtr_order=3 then n_drug else . end) as n_drug_q3,
                    max(case when qtr_order=4 then n_drug else . end) as n_drug_q4,

                    sum(a)                as a_total,
                    sum(case when a > 0 then 1 else 0 end) as n_quarters_data,
                    sum(evaluable)        as n_quarters_eval,
                    sum(signal_flag)      as n_quarters_signal

        from        work.time_trend
        group by    drug_label, generation, pt;
quit;

data work.trend_summary;
    set work.trend_wide;

    length trend $15 trend_confidence $6 emerging_basis $8
           weber_note $110 coverage_note $200;

    array _prr[4] prr_q1 prr_q2 prr_q3 prr_q4;
    array _ev [4] ev_q1  ev_q2  ev_q3  ev_q4;
    array _a  [4] a_q1   a_q2   a_q3   a_q4;
    array _nd [4] n_drug_q1 n_drug_q2 n_drug_q3 n_drug_q4;

    /*----------------------------------------------------------------------
      Signal velocity. First and last EVALUABLE quarter - a THIN quarter has
      no PRR to be an endpoint. Divided by the elapsed span, not by the
      number of quarters with data: see header note 3.
      ----------------------------------------------------------------------*/
    _first_i = .;
    _last_i  = .;
    do _i = 1 to 4;
        if _ev[_i] = 1 then do;
            if missing(_first_i) then _first_i = _i;
            _last_i = _i;
        end;
    end;

    if not missing(_first_i) then first_prr = _prr[_first_i];
    if not missing(_last_i)  then last_prr  = _prr[_last_i];

    if n_quarters_eval >= 2 then do;
        velocity_span_qtrs = _last_i - _first_i;
        signal_velocity    = (last_prr - first_prr) / velocity_span_qtrs;
    end;
    else do;
        velocity_span_qtrs = .;
        signal_velocity    = .;
    end;

    /* Explicit argument list rather than mean(of prr_q1-prr_q4). The numeric
       suffix range resolves off PDV order, which is correct here and would
       stop being correct the day a prr_q5 or a reordered SELECT arrives. */
    mean_prr = mean(prr_q1, prr_q2, prr_q3, prr_q4);

    /*----------------------------------------------------------------------
      Classification. First match wins, so the order of these branches is
      the definition.

      sig_qN is already 0 whenever quarter N was THIN or ABSENT, so the
      spec's paired "(sig_qN = 0 or a_qN = 0)" tests reduce to sig_qN = 0.
      What that reduction hides is the reason EMERGING_BASIS exists below:
      the test cannot tell a measured sub-threshold quarter from one that
      was never measurable.
      ----------------------------------------------------------------------*/

    /* EMERGING - quiet through the first half, crosses Evans in the second */
    if sig_q1 = 0 and sig_q2 = 0 and (sig_q3 = 1 or sig_q4 = 1) then
        trend = 'Emerging';

    /* EMERGING - the narrower case: sub-threshold in Q1 only, signal in the
       three quarters after it. Requires Q1 to have actually been measured
       and to have come in under threshold, so this branch never fires on a
       missing first quarter. */
    else if sig_q1 = 0 and sig_q2 = 1 and sig_q3 = 1 and sig_q4 = 1
            and ev_q1 = 1 and prr_q1 < &PRR_THRESHOLD then
        trend = 'Emerging';

    /* ACCELERATING - signal throughout and strengthening */
    else if n_quarters_signal >= 3
            and not missing(first_prr) and not missing(last_prr)
            and last_prr > first_prr * 1.3
            and signal_velocity > 0 then
        trend = 'Accelerating';

    /* DECLINING - signal early, weakening after */
    else if (sig_q1 = 1 or sig_q2 = 1)
            and not missing(first_prr) and not missing(last_prr)
            and last_prr < first_prr * 0.7
            and signal_velocity < 0 then
        trend = 'Declining';

    /* STABLE - signal in at least three quarters and every evaluable PRR
       within 30% of the mean. Anything else with three signals is moving in
       no describable direction. */
    else if n_quarters_signal >= 3 then do;
        if mean_prr > 0 then
            _max_dev = max(abs(prr_q1 - mean_prr) / mean_prr,
                           abs(prr_q2 - mean_prr) / mean_prr,
                           abs(prr_q3 - mean_prr) / mean_prr,
                           abs(prr_q4 - mean_prr) / mean_prr);
        else _max_dev = .;

        if not missing(_max_dev) and _max_dev <= 0.30 then trend = 'Stable';
        else trend = 'Inconsistent';
    end;

    else trend = 'Inconsistent';

    /*----------------------------------------------------------------------
      Confidence and basis - the guardrails, not the verdict.
      ----------------------------------------------------------------------*/
    if      n_quarters_eval = 4 then trend_confidence = 'High';
    else if n_quarters_eval = 3 then trend_confidence = 'Medium';
    else                             trend_confidence = 'Low';

    /* 'Measured' means both early quarters cleared the floor and came in
       under threshold on their own numbers. 'Inferred' means at least one of
       them was too thin to measure and the emergence rests on its absence.
       Same trend, different weight of evidence. */
    if trend = 'Emerging' then do;
        if ev_q1 = 1 and ev_q2 = 1 then emerging_basis = 'Measured';
        else                            emerging_basis = 'Inferred';
    end;
    else emerging_basis = '';

    /* Name every quarter that could not be estimated, with its own case
       count and the molecule's volume for that quarter beside it. */
    coverage_note = '';
    if n_quarters_eval < 4 then do;
        do _i = 1 to 4;
            if _ev[_i] ne 1 then
                coverage_note = catx('; ', coverage_note,
                    catx(' ', scan("&QTR_LIST", _i, ' '),
                              cats('a=',      put(_a[_i],  4.)),
                              cats('n_drug=', put(_nd[_i], comma7.))));
        end;
        coverage_note = catx(' ', 'Not evaluable -', coverage_note);
    end;

    /* Weber effect: a new drug is over-reported in its first years on
       market, so an early-high, later-lower PRR can be a reporting artifact
       rather than a falling risk. Annotated, not adjusted for. */
    if trend = 'Declining' and drug_label = 'TIRZEPATIDE' then
        weber_note = 'Possible Weber effect - TIRZ approved May 2022 (T2D) and Nov 2023 (obesity)';
    else if trend = 'Declining' and drug_label = 'SEMAGLUTIDE' then
        weber_note = 'Possible Weber effect - SEMA approved Dec 2017 (T2D) and Jun 2021 (obesity)';
    else
        weber_note = '';

    drop _i _first_i _last_i _max_dev;

    label
        trend              = 'Trend classification'
        trend_confidence   = 'Evaluable quarters: High=4 Medium=3 Low<=2'
        emerging_basis     = 'Emerging on measured or inferred early quarters'
        signal_velocity    = 'PRR change per quarter'
        velocity_span_qtrs = 'Quarters between first and last evaluable'
        first_prr          = 'PRR in first evaluable quarter'
        last_prr           = 'PRR in last evaluable quarter'
        mean_prr           = 'Mean PRR across evaluable quarters'
        n_quarters_data    = 'Quarters with at least one case'
        n_quarters_eval    = 'Quarters with a computable PRR'
        n_quarters_signal  = 'Quarters meeting Evans criteria'
        coverage_note      = 'Quarters that could not be estimated'
        weber_note         = 'Weber effect caveat';

    format prr_q1 prr_q2 prr_q3 prr_q4
           signal_velocity first_prr last_prr mean_prr 10.4;
run;

proc sort data=work.trend_summary;
    by drug_label descending n_quarters_eval descending signal_velocity;
run;

%_stamp(Section 6 - trends classified.)


/*==========================================================================
  7. EMERGING AND ACCELERATING SIGNALS - THE HEADLINE TABLE
  ==========================================================================*/
data work.emerging;
    set work.trend_summary;
    where trend in ('Emerging', 'Accelerating');
run;

/* Sorted by evidence, not by drug: the rows resting on four measured
   quarters come first, and the fastest movers within each tier lead. */
proc sort data=work.emerging;
    by descending n_quarters_eval descending signal_velocity;
run;

proc sql noprint;
    select count(*) into :N_EMERGING trimmed
        from work.emerging where trend = 'Emerging';
    select count(*) into :N_EMERG_MEAS trimmed
        from work.emerging where trend = 'Emerging' and emerging_basis = 'Measured';
    select count(*) into :N_ACCEL trimmed
        from work.emerging where trend = 'Accelerating';
    select count(*) into :N_EM_HIGHMED trimmed
        from work.emerging where trend_confidence in ('High', 'Medium');
    select count(*) into :N_EM_LOW trimmed
        from work.emerging where trend_confidence = 'Low';
quit;

/* PROC REPORT and PROC PRINT both abort on a zero-observation input, and a
   quarter with no emerging signal at all is a legitimate outcome here - see
   the spec's note on what zero emerging signals means. Each table is
   therefore guarded by its own count rather than by an assumption. */
%macro headline_tables;

%if &N_EM_HIGHMED = 0 %then %do;
    %put NOTE: No emerging or accelerating signal has 3 or more evaluable quarters - Table 1 skipped.;
%end;
%else %do;

title3 "Table 1: Emerging and accelerating GLP-1 signals, 2025Q3 - 2026Q2";
title4 "Sorted by evaluable quarters then velocity - the fully measured rows lead";
proc report data=work.emerging(where=(trend_confidence in ('High', 'Medium'))) nowd;
    columns drug_label pt trend emerging_basis signal_velocity
            a_q1 prr_q1 a_q2 prr_q2 a_q3 prr_q3 a_q4 prr_q4;
    define drug_label      / display 'Drug';
    define pt              / display 'Reaction (PT)' width=40;
    define trend           / display 'Trend';
    define emerging_basis  / display 'Basis';
    define signal_velocity / display 'Velocity' format=8.2;
    define a_q1  / display 'N 25Q3'   format=comma7.;
    define prr_q1/ display 'PRR 25Q3' format=8.2;
    define a_q2  / display 'N 25Q4'   format=comma7.;
    define prr_q2/ display 'PRR 25Q4' format=8.2;
    define a_q3  / display 'N 26Q1'   format=comma7.;
    define prr_q3/ display 'PRR 26Q1' format=8.2;
    define a_q4  / display 'N 26Q2'   format=comma7.;
    define prr_q4/ display 'PRR 26Q2' format=8.2;
run;

%end;

%if &N_EM_LOW = 0 %then %do;
    %put NOTE: Every emerging and accelerating signal has 3 or more evaluable quarters - Table 2 skipped.;
%end;
%else %do;

title3 "Table 2: Low-confidence emerging and accelerating rows - reported, not filtered";
title4 "Two or fewer evaluable quarters; COVERAGE_NOTE names the gaps and the volume behind them";
proc print data=work.emerging(where=(trend_confidence = 'Low')) noobs label;
    var drug_label pt trend emerging_basis signal_velocity coverage_note;
    format signal_velocity 8.2;
run;

%end;
%mend headline_tables;

%headline_tables

title3 "Table 3: Trend classification by molecule";
proc freq data=work.trend_summary;
    tables drug_label * trend / nocol nopercent norow;
run;
title3;
title4;

%_stamp(Section 7 - headline tables printed.)


/*==========================================================================
  8. QC REPORT
  ==========================================================================*/

%let V_EMERG = 0;
%let V_DECL  = 0;

/* The one thing sections 3 and 4 assume and never proved: the quarter
   DEMO_WIN assigns a case and the quarter Step 1 wrote into GLP1_CASES are
   the same quarter. Both derive from init_fda_dt by the same rule, so this
   should be 0; it is checked because if it ever is not, every b in this
   program is computed against a denominator from a different quarter. */
proc sql noprint;
    select count(*) into :N_QTR_MISMATCH trimmed
        from        clean.glp1_cases as g
        inner join  work.demo_win    as dw on g.primaryid = dw.primaryid
        where       g.year_qtr ne dw.year_qtr;

    select count(*) into :N_TT_ROWS  trimmed from work.time_trend;
    select count(*) into :N_TT_PAIRS trimmed from work.trend_summary;

    select count(*) into :N_BADCELL trimmed
        from work.time_trend where nmiss(a, b, c, d) > 0 or min(a, b, c, d) < 0;

    select count(*) into :N_EVAL   trimmed from work.time_trend where eval_status = 'EVALUABLE';
    select count(*) into :N_THIN   trimmed from work.time_trend where eval_status = 'THIN';
    select count(*) into :N_ABSENT trimmed from work.time_trend where eval_status = 'ABSENT';

    select count(*) into :N_STABLE trimmed from work.trend_summary where trend = 'Stable';
    select count(*) into :N_DECL   trimmed from work.trend_summary where trend = 'Declining';
    select count(*) into :N_INCONS trimmed from work.trend_summary where trend = 'Inconsistent';
    select count(*) into :N_WEBER  trimmed from work.trend_summary where weber_note ne '';

    select count(*) into :N_LOWCONF trimmed
        from work.trend_summary where trend_confidence = 'Low';

    /* Directional sanity: these two means must have opposite signs, or the
       classifier and the velocity are not describing the same thing.
       COALESCE and the %LET defaults above cover the no-rows case, where a
       bare SELECT INTO would leave the macro variable unresolved and the
       %SYSEVALF in the verdict would fail on an empty string. */
    select coalesce(mean(signal_velocity), 0) into :V_EMERG trimmed
        from work.trend_summary where trend = 'Emerging' and not missing(signal_velocity);
    select coalesce(mean(signal_velocity), 0) into :V_DECL trimmed
        from work.trend_summary where trend = 'Declining' and not missing(signal_velocity);

    /* Volume swing per molecule - the reason coverage is reported at all. */
    create table work.vol_swing as
        select      drug_label,
                    min(n_drug) as n_min,
                    max(n_drug) as n_max,
                    max(n_drug) / min(n_drug) as swing_ratio
        from        work.tt_ndrug
        group by    drug_label;
quit;

proc sql;
    create table work.trend_by_drug as
        select      drug_label, trend, count(*) as n_pairs
        from        work.trend_summary
        group by    drug_label, trend
        order by    drug_label, trend;
quit;

data work.qc_time_trend;
    length metric $62 value 8 note $95;

    metric = 'Analysis universe N';
    value  = &N_UNIVERSE;
    note   = "Must equal &N_UNIVERSE_EXPECTED - the Steps 2-4 universe";           output;

    metric = 'Universe cases inside 2025Q3-2026Q2';
    value  = &N_IN_WINDOW;
    note   = 'The denominator population for every quarterly PRR below';           output;

    metric = '  excluded - initial receive date outside window';
    value  = &N_OUT_WINDOW;
    note   = 'Follow-up versions of cases first received before 2025Q3';           output;

    metric = '  excluded - no parseable receive date';
    value  = &N_QTR_MISSING;
    note   = 'Neither init_fda_dt nor fda_dt parsed';                              output;

    metric = 'Universe cases with a year- or month-only initial date';
    value  = &N_DATE_IMPUTED;
    note   = 'Imputed to the first of the period - biases Q1 if non-zero';         output;

    metric = 'GLP1_CASES quarter disagreeing with DEMO quarter';
    value  = &N_QTR_MISMATCH;
    note   = 'Must be 0 - numerator and denominator share one clock';              output;

    /* Volume swing, before any result is read. */
    do until (_eof1);
        set work.vol_swing end=_eof1;
        metric = '  ' || strip(drug_label) || ' quarterly volume swing (max/min)';
        value  = swing_ratio;
        note   = catx(' ', 'from', strip(put(n_min, comma8.)),
                            'to',   strip(put(n_max, comma8.)), 'cases per quarter');
        output;
    end;

    metric = 'Drug x PT pairs tracked';
    value  = &N_TT_PAIRS;
    note   = 'Cleared a >= 3 in at least one quarter';                             output;

    metric = 'Drug x PT x quarter rows';
    value  = &N_TT_ROWS;
    note   = "Must equal pairs x &N_QTRS - the grid has no holes";                 output;

    metric = 'Rows with a missing or negative 2x2 cell';
    value  = &N_BADCELL;
    note   = 'Must be 0';                                                          output;

    metric = '  EVALUABLE quarters (a >= 3, PRR computed)';
    value  = &N_EVAL;
    note   = 'The only rows contributing a PRR to a trend';                        output;

    metric = '  THIN quarters (1-2 cases, no PRR)';
    value  = &N_THIN;
    note   = 'Reported, never estimated - not evidence of no signal';              output;

    metric = '  ABSENT quarters (0 cases)';
    value  = &N_ABSENT;
    note   = 'Grid rows the raw counts would not have produced';                   output;

    metric = 'Trend classification - Emerging';
    value  = &N_EMERGING;
    note   = 'The star metric - crosses Evans in the second half';                 output;

    metric = '  of which Measured (both early quarters evaluable)';
    value  = &N_EMERG_MEAS;
    note   = 'The defensible subset - read these first';                           output;

    metric = 'Trend classification - Accelerating';
    value  = &N_ACCEL;
    note   = 'Signal in >= 3 quarters and last PRR > 1.3x first';                  output;

    metric = 'Trend classification - Stable';
    value  = &N_STABLE;
    note   = 'Signal in >= 3 quarters, all PRR within 30% of mean';                output;

    metric = 'Trend classification - Declining';
    value  = &N_DECL;
    note   = 'Last PRR < 0.7x first - check the Weber annotation';                 output;

    metric = 'Trend classification - Inconsistent';
    value  = &N_INCONS;
    note   = 'Signal present in some quarters with no clear direction';            output;

    metric = 'Weber-annotated declining signals';
    value  = &N_WEBER;
    note   = 'Early-high PRR on a recently approved drug';                         output;

    metric = 'Pairs with <= 2 evaluable quarters';
    value  = &N_LOWCONF;
    note   = 'trend_confidence = Low - labelled, not filtered';                    output;

    metric = 'Mean velocity - Emerging signals';
    value  = &V_EMERG;
    note   = 'Must be positive';                                                   output;

    metric = 'Mean velocity - Declining signals';
    value  = &V_DECL;
    note   = 'Must be negative';                                                   output;

    /* Per molecule x trend, built from the data so a fifth molecule needs no
       edit here. */
    do until (_eof2);
        set work.trend_by_drug end=_eof2;
        metric = '  ' || strip(drug_label) || ' / ' || strip(trend);
        value  = n_pairs;
        note   = 'Classified pairs';
        output;
    end;

    stop;
    label metric = 'Metric' value = 'Value' note = 'Note';
    keep  metric value note;
run;

title3 'Table 4: Time trend QC';
proc print data=work.qc_time_trend noobs label;
    format value comma12.2;
run;
title3;

%macro trend_verdict;
    %if &N_BADCELL = 0 %then
        %put NOTE: 2x2 assertion passed - no missing or negative cells in any quarter.;
    %else
        %put ERROR: &N_BADCELL quarterly row(s) have an inconsistent 2x2 cell.;

    %if &N_TT_ROWS = %eval(&N_TT_PAIRS * &N_QTRS) %then
        %put NOTE: Grid assertion passed - &N_TT_PAIRS pairs x &N_QTRS quarters = &N_TT_ROWS rows.;
    %else
        %put ERROR: Grid is incomplete - &N_TT_ROWS rows for &N_TT_PAIRS pairs.;

    %if &N_QTR_MISMATCH ne 0 %then
        %put ERROR: &N_QTR_MISMATCH case(s) sit in a different quarter in GLP1_CASES than in DEMO.;

    %if %sysevalf(&N_EMERGING + &N_ACCEL > 0) %then %do;
        %put NOTE: TIME TREND ANALYSIS COMPLETE - &N_EMERGING emerging + &N_ACCEL accelerating signal(s) identified.;
        %put NOTE- &N_EMERG_MEAS of the emerging signals rest on two measured early quarters.;
        %if &N_LOWCONF > 0 %then
            %put NOTE- &N_LOWCONF pair(s) carry trend_confidence = Low and are reported with their coverage gaps.;
    %end;
    %else
        %put NOTE: No emerging or accelerating signals detected. Every GLP-1 signal was present throughout the window - itself a finding about a well-characterised safety profile.;

    %if %sysevalf(&V_EMERG <= 0) and &N_EMERGING > 0 %then
        %put WARNING: Mean emerging velocity is &V_EMERG - expected positive. Check the classifier.;
    %if %sysevalf(&V_DECL >= 0) and &N_DECL > 0 %then
        %put WARNING: Mean declining velocity is &V_DECL - expected negative. Check the classifier.;
%mend trend_verdict;

%trend_verdict

%_stamp(Section 8 - QC complete.)


/*==========================================================================
  9. SAVE, EXPORT AND WRAP UP
  ==========================================================================*/
data signal.glp1_time_trend (compress=yes
        label='GLP-1 PRR by drug x PT x quarter, 2025Q3-2026Q2');
    set work.time_trend;
run;

data signal.glp1_trend_summary (compress=yes
        label='GLP-1 trend classification and signal velocity by drug x PT');
    set work.trend_summary;
run;

data signal.glp1_emerging (compress=yes
        label='GLP-1 emerging and accelerating signals, 2025Q3-2026Q2');
    set work.emerging;
run;

proc export data=signal.glp1_time_trend
            outfile="&OUT_TABLES./glp1_time_trend.csv" dbms=csv replace;
run;
proc export data=signal.glp1_trend_summary
            outfile="&OUT_TABLES./glp1_trend_summary.csv" dbms=csv replace;
run;
proc export data=signal.glp1_emerging
            outfile="&OUT_TABLES./glp1_emerging_signals.csv" dbms=csv replace;
run;
proc export data=work.qc_time_trend
            outfile="&OUT_QC./qc_glp1_time_trend.csv" dbms=csv replace;
run;

proc datasets library=work nolist;
    delete universe demo_qtr demo_win tt_a_raw tt_pairs tt_qtrs tt_grid
           tt_2x2 tt_prr trend_wide vol_swing trend_by_drug;
quit;

title2;

%macro finish;
    %local e;
    %let e = %sysevalf(%sysfunc(datetime()) - &_T0);

    %put NOTE: ============================================;
    %put NOTE: 03_glp1_time_trend.sas complete.;
    %put NOTE: Universe N          = &N_UNIVERSE (in window &N_IN_WINDOW);
    %put NOTE: Pairs x quarters    = &N_TT_PAIRS x &N_QTRS = &N_TT_ROWS rows;
    %put NOTE: Quarter status      = &N_EVAL evaluable / &N_THIN thin / &N_ABSENT absent;
    %put NOTE: Emerging            = &N_EMERGING (&N_EMERG_MEAS measured);
    %put NOTE: Accelerating        = &N_ACCEL;
    %put NOTE: Stable / Declining  = &N_STABLE / &N_DECL (&N_WEBER Weber-annotated);
    %put NOTE: Inconsistent        = &N_INCONS;
    %put NOTE: Low confidence      = &N_LOWCONF pair(s) with <= 2 evaluable quarters;
    %put NOTE: Datasets            = SIGNAL.GLP1_TIME_TREND / _TREND_SUMMARY / _EMERGING;
    %put NOTE: Headline CSV        = &OUT_TABLES./glp1_emerging_signals.csv;
    %put NOTE: QC                  = &OUT_QC./qc_glp1_time_trend.csv;
    %put NOTE: Elapsed             = %sysfunc(putn(&e, time12.2));
    %put NOTE: ============================================;

    %if &N_BADCELL = 0 and &N_QTR_MISMATCH = 0
        and &N_TT_ROWS = %eval(&N_TT_PAIRS * &N_QTRS) %then
        %put NOTE: GLP-1 TIME TREND ANALYSIS PASSED - ready for Phase 3 Step 6.;
    %else
        %put WARNING: GLP-1 TIME TREND ANALYSIS needs review - see the errors above.;
%mend finish;

%finish

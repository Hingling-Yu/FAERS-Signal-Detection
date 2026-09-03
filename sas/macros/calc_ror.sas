/*****************************************************************************
 * macros/calc_ror.sas - Reporting Odds Ratio (ROR) calculator
 *
 * Purpose:  Given a dataset of 2x2 disproportionality counts, append the ROR
 *           and its 95% confidence interval to every row.
 *
 * Contingency table convention (one row = one drug x reaction pair):
 *
 *                       | Reaction of interest | All other reactions
 *   --------------------+----------------------+---------------------
 *   Drug of interest    |          a           |          b
 *   All other drugs     |          c           |          d
 *
 * Requires: Nothing. This macro is deliberately free of libname / path
 *           dependencies so it can be unit-tested without 00_config.sas.
 *
 * Why both ROR and PRR:  the two measures answer the same question with
 *           different denominators. ROR uses odds and is the measure that
 *           can be adjusted by logistic regression, which is why EMA and
 *           most published RWE work report it; PRR uses proportions and is
 *           the historical MHRA / Evans measure. They diverge when the
 *           reaction is common within the drug's own reports, so reporting
 *           both is the standard robustness check.
 *
 * Author:   Hingling Yu
 * Created:  2026-09-03
 *****************************************************************************/


/*==========================================================================
  MACRO: %calc_ror
  --------------------------------------------------------------------------
  Parameters
    ds_in    Required. Input dataset containing numeric a, b, c, d.
             All other input columns are carried through unchanged.
    ds_out   Required. Output dataset. May be the same as ds_in.

  Columns added
    ROR        Reporting Odds Ratio = (a*d) / (b*c)
    ROR_LCL    Lower bound of the 95% CI
    ROR_UCL    Upper bound of the 95% CI

  Method
    As for PRR, the interval is built on the log scale and back-transformed,
    so it is asymmetric around the point estimate and cannot go below zero.
    The standard error is the classic Woolf estimator:

        SE(ln ROR) = sqrt( 1/a + 1/b + 1/c + 1/d )
        ROR_LCL    = exp( ln(ROR) - 1.96 * SE )
        ROR_UCL    = exp( ln(ROR) + 1.96 * SE )

    The conventional signal rule for ROR is ROR_LCL > 1 together with a
    minimum case count; that flag is applied in 02_signal_engine.sas rather
    than here, so this macro stays a pure calculation.

  Zero cells
    If any of a, b, c, d is zero or missing, ROR and both bounds are set to
    missing. A zero in b or c would divide by zero, a zero in a or d makes
    the Woolf SE infinite, and adding a 0.5 continuity correction would
    invent reports that do not exist. Treat a missing ROR as "not
    evaluable", never as "no signal".

  Performance
    Single DATA step, no PROC SQL: the calculation is row-wise, so one
    sequential pass with no join or sort is the cheapest way to process the
    several hundred thousand drug x reaction pairs in this project.

  Example
    %calc_ror(ds_in=work.counts_2x2, ds_out=signal.ror_results);
  ==========================================================================*/
%macro calc_ror(ds_in=, ds_out=);

    %local i dsid rc var vnum vtype bad;

    /*----------------------------------------------------------------------
      1. Validate parameters - fail loudly and early rather than writing an
         output dataset full of missing values that looks like a real result.
      ----------------------------------------------------------------------*/
    %if %length(&ds_in) = 0 or %length(&ds_out) = 0 %then %do;
        %put ERROR: [calc_ror] DS_IN= and DS_OUT= are both required.;
        %return;
    %end;

    %if %sysfunc(exist(&ds_in)) = 0 %then %do;
        %put ERROR: [calc_ror] Input dataset &ds_in does not exist.;
        %return;
    %end;

    /* The 2x2 cells must all be present and numeric. A character "a" would
       otherwise abort the DATA step with an obscure type-mismatch error. */
    %let dsid = %sysfunc(open(&ds_in));
    %let bad  = 0;
    %do i = 1 %to 4;
        %let var  = %scan(a b c d, &i);
        %let vnum = %sysfunc(varnum(&dsid, &var));
        %if &vnum = 0 %then %do;
            %put ERROR: [calc_ror] &ds_in is missing required column "&var".;
            %let bad = 1;
        %end;
        %else %do;
            %let vtype = %sysfunc(vartype(&dsid, &vnum));
            %if &vtype ne N %then %do;
                %put ERROR: [calc_ror] Column "&var" in &ds_in must be numeric.;
                %let bad = 1;
            %end;
        %end;
    %end;
    %let rc = %sysfunc(close(&dsid));

    %if &bad %then %do;
        %put ERROR- [calc_ror] Expected 2x2 cell counts named a, b, c, d.;
        %return;
    %end;

    %put NOTE: [calc_ror] &ds_in -> &ds_out;

    /*----------------------------------------------------------------------
      2. Row-wise calculation.
      ----------------------------------------------------------------------*/
    data &ds_out;
        set &ds_in;

        length ROR ROR_LCL ROR_UCL 8;

        /* min() over the four cells catches zeros and negatives in one test;
           nmiss() catches empty cells. Both mean "not evaluable". */
        if nmiss(a, b, c, d) = 0 and min(a, b, c, d) > 0 then do;

            ROR = (a * d) / (b * c);

            _ror_se = sqrt(1/a + 1/b + 1/c + 1/d);
            ROR_LCL = exp(log(ROR) - 1.96 * _ror_se);
            ROR_UCL = exp(log(ROR) + 1.96 * _ror_se);
        end;
        else do;
            ROR     = .;
            ROR_LCL = .;
            ROR_UCL = .;
        end;

        drop _ror_se;

        format ROR ROR_LCL ROR_UCL 10.4;

        label
            ROR     = 'Reporting Odds Ratio'
            ROR_LCL = 'ROR 95% CI lower limit'
            ROR_UCL = 'ROR 95% CI upper limit';
    run;

%mend calc_ror;

%put NOTE: [calc_ror] macro compiled.;


/*==========================================================================
  VERIFICATION TEST - uncomment the block below and run in SAS Studio.
  --------------------------------------------------------------------------
  Hand-calculated expected values for a=20, b=80, c=100, d=800:

    ROR     = (20*800) / (80*100) = 16000 / 8000 = 2.0000
    SE      = sqrt(1/20 + 1/80 + 1/100 + 1/800) = sqrt(0.073750) = 0.271570
    ROR_LCL = exp(ln(2) - 1.96*0.271570) = 1.1745
    ROR_UCL = exp(ln(2) + 1.96*0.271570) = 3.4056

  The second and third rows check the zero-cell guard: every ROR column must
  come back missing (.) and the log must contain no division-by-zero note.
  ==========================================================================*/
/*
data work._test_ror;
    length scenario $15;
    input scenario $ a b c d;
    datalines;
Evans_example  20  80 100 800
Zero_cell_a     0  80 100 800
Zero_cell_d    20  80 100   0
;
run;

%calc_ror(ds_in=work._test_ror, ds_out=work._test_ror_out);

proc print data=work._test_ror_out noobs;
    title 'calc_ror verification - row 1 expects ROR=2.0000, CI 1.1745-3.4056';
run;
title;
*/

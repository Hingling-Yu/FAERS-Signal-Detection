/*****************************************************************************
 * macros/calc_prr.sas - Proportional Reporting Ratio (PRR) calculator
 *
 * Purpose:  Given a dataset of 2x2 disproportionality counts, append the PRR,
 *           its 95% confidence interval, and the Yates-free chi-square test
 *           statistic to every row.
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
 * Author:   Hingling Yu
 * Created:  2026-09-03
 *****************************************************************************/


/*==========================================================================
  MACRO: %calc_prr
  --------------------------------------------------------------------------
  Parameters
    ds_in    Required. Input dataset containing numeric a, b, c, d.
             All other input columns are carried through unchanged.
    ds_out   Required. Output dataset. May be the same as ds_in.

  Columns added
    PRR        Proportional Reporting Ratio = (a/(a+b)) / (c/(c+d))
    PRR_LCL    Lower bound of the 95% CI
    PRR_UCL    Upper bound of the 95% CI
    PRR_CHI2   Pearson chi-square (1 df), uncorrected

  Method
    The CI is built on the log scale, which is the standard PV convention
    (Evans 2001; EMA EudraVigilance guidance) because ln(PRR) is far closer
    to normally distributed than PRR itself, and back-transforming keeps the
    interval strictly positive.

        SE(ln PRR) = sqrt( 1/a - 1/(a+b) + 1/c - 1/(c+d) )
        PRR_LCL    = exp( ln(PRR) - 1.96 * SE )
        PRR_UCL    = exp( ln(PRR) + 1.96 * SE )

        N          = a + b + c + d
        PRR_CHI2   = N * (a*d - b*c)**2 / ((a+b) * (c+d) * (a+c) * (b+d))

    Chi-square is reported uncorrected on purpose: Evans' signal criteria
    (PRR >= 2, chi2 >= 4, n >= 3) were defined against the uncorrected
    statistic, so applying a Yates correction here would silently shift the
    signal threshold.

  Zero cells
    If any of a, b, c, d is zero or missing, PRR, both bounds and PRR_CHI2
    are set to missing rather than to 0 or infinity. A zero cell makes the
    ratio (or its SE) undefined, and a continuity correction such as +0.5
    would fabricate cases that were never reported - unacceptable in a
    regulatory-facing signal table. Downstream code should treat a missing
    PRR as "not evaluable", not as "no signal". The MIN_CASES=3 filter in
    02_signal_engine.sas already removes the a<3 rows this affects most.

  Performance
    Implemented as a single DATA step rather than PROC SQL: the calculation
    is purely row-wise, so a sequential pass with no join or sort is the
    cheapest way to process the several hundred thousand drug x reaction
    pairs produced from 1.6M FAERS cases.

  Example
    %calc_prr(ds_in=work.counts_2x2, ds_out=signal.prr_results);
  ==========================================================================*/
%macro calc_prr(ds_in=, ds_out=);

    %local i dsid rc var vnum vtype bad;

    /*----------------------------------------------------------------------
      1. Validate parameters - fail loudly and early rather than writing an
         output dataset full of missing values that looks like a real result.
      ----------------------------------------------------------------------*/
    %if %length(&ds_in) = 0 or %length(&ds_out) = 0 %then %do;
        %put ERROR: [calc_prr] DS_IN= and DS_OUT= are both required.;
        %return;
    %end;

    %if %sysfunc(exist(&ds_in)) = 0 %then %do;
        %put ERROR: [calc_prr] Input dataset &ds_in does not exist.;
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
            %put ERROR: [calc_prr] &ds_in is missing required column "&var".;
            %let bad = 1;
        %end;
        %else %do;
            %let vtype = %sysfunc(vartype(&dsid, &vnum));
            %if &vtype ne N %then %do;
                %put ERROR: [calc_prr] Column "&var" in &ds_in must be numeric.;
                %let bad = 1;
            %end;
        %end;
    %end;
    %let rc = %sysfunc(close(&dsid));

    %if &bad %then %do;
        %put ERROR- [calc_prr] Expected 2x2 cell counts named a, b, c, d.;
        %return;
    %end;

    %put NOTE: [calc_prr] &ds_in -> &ds_out;

    /*----------------------------------------------------------------------
      2. Row-wise calculation.
      ----------------------------------------------------------------------*/
    data &ds_out;
        set &ds_in;

        length PRR PRR_LCL PRR_UCL PRR_CHI2 8;

        /* min() over the four cells catches zeros and negatives in one test;
           nmiss() catches empty cells. Both mean "not evaluable". */
        if nmiss(a, b, c, d) = 0 and min(a, b, c, d) > 0 then do;

            PRR = (a / (a + b)) / (c / (c + d));

            _prr_se = sqrt(1/a - 1/(a + b) + 1/c - 1/(c + d));
            PRR_LCL = exp(log(PRR) - 1.96 * _prr_se);
            PRR_UCL = exp(log(PRR) + 1.96 * _prr_se);

            _n       = a + b + c + d;
            PRR_CHI2 = (_n * (a*d - b*c)**2) /
                       ((a + b) * (c + d) * (a + c) * (b + d));
        end;
        else do;
            PRR      = .;
            PRR_LCL  = .;
            PRR_UCL  = .;
            PRR_CHI2 = .;
        end;

        drop _prr_se _n;

        format PRR PRR_LCL PRR_UCL PRR_CHI2 10.4;

        label
            PRR      = 'Proportional Reporting Ratio'
            PRR_LCL  = 'PRR 95% CI lower limit'
            PRR_UCL  = 'PRR 95% CI upper limit'
            PRR_CHI2 = 'Chi-square (1 df, uncorrected)';
    run;

%mend calc_prr;

%put NOTE: [calc_prr] macro compiled.;


/*==========================================================================
  VERIFICATION TEST - uncomment the block below and run in SAS Studio.
  --------------------------------------------------------------------------
  Hand-calculated expected values for a=20, b=80, c=100, d=800:

    PRR      = (20/100) / (100/900) = 0.2000 / 0.1111 = 1.8000
    SE       = sqrt(1/20 - 1/100 + 1/100 - 1/900) = sqrt(0.048889) = 0.221108
    PRR_LCL  = exp(ln(1.8) - 1.96*0.221108) = 1.1670
    PRR_UCL  = exp(ln(1.8) + 1.96*0.221108) = 2.7764
    PRR_CHI2 = 1000 * (20*800 - 80*100)**2 / (100*900*120*880)
             = 1000 * 64,000,000 / 9,504,000,000 = 6.7340

  The second and third rows check the zero-cell guard: every PRR column must
  come back missing (.) and the log must contain no division-by-zero note.
  ==========================================================================*/
/*
data work._test_prr;
    length scenario $15;
    input scenario $ a b c d;
    datalines;
Evans_example  20  80 100 800
Zero_cell_a     0  80 100 800
Zero_cell_d    20  80 100   0
;
run;

%calc_prr(ds_in=work._test_prr, ds_out=work._test_prr_out);

proc print data=work._test_prr_out noobs;
    title 'calc_prr verification - row 1 expects PRR=1.8000, CHI2=6.7340';
run;
title;
*/

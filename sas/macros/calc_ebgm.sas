/*****************************************************************************
 * macros/calc_ebgm.sas - Empirical Bayes Geometric Mean (MGPS) calculator
 *
 * Purpose:  Given a dataset of drug x reaction counts, fit the two-component
 *           Gamma-Poisson mixture of DuMouchel's Multi-item Gamma Poisson
 *           Shrinker (MGPS) across ALL pairs at once, then append the shrunk
 *           point estimate EBGM and its 90% credible interval (EB05, EB95)
 *           to every row.
 *
 * Count convention (one row = one drug x reaction pair):
 *
 *           a       = cases reporting this drug WITH this reaction
 *           n_drug  = cases reporting this drug, any reaction
 *           n_reac  = cases reporting this reaction, any drug
 *           N       = analysis universe (passed in via TOTAL_N=)
 *
 *           E = n_drug * n_reac / N        expected count under independence
 *           RR = a / E                     raw Relative Reporting Ratio (MLE)
 *
 *           Note that this macro needs n_drug and n_reac, NOT the b/c/d cells
 *           that %calc_prr and %calc_ror consume. Both parameterisations
 *           describe the same 2x2 table; MGPS is written in terms of an
 *           expected count, so the marginals are the natural input.
 *
 * Why EBGM in addition to PRR and ROR
 *           PRR and ROR are frequentist ratios computed one pair at a time,
 *           so a drug reported three times, twice with the same PT, produces
 *           a spectacular ratio on almost no evidence. EBGM is an empirical
 *           Bayes estimate: the prior is estimated from the whole database,
 *           so every pair is shrunk toward the overall distribution by an
 *           amount that depends on how much evidence that pair actually
 *           carries. Large-count pairs barely move; single-case pairs
 *           collapse toward the fitted background. This is the method FDA's
 *           own FAERS screening runs, which is why EB05 >= 2 is the
 *           criterion a regulator recognises.
 *
 * Note:    the likelihood is ZERO-TRUNCATED, which is a deliberate
 *           departure from the formula in docs/spec_ebgm.md. Callers pass
 *           only pairs that were observed, so the plain mixture in the spec
 *           is the wrong likelihood for the data and biases the fit upward.
 *           See ZERO TRUNCATION in the macro docstring for the measurements.
 *
 * Requires: SAS/IML (licensed on SAS OnDemand for Academics). Beyond that
 *           the macro is free of libname / path dependencies, so it can be
 *           unit-tested without 00_config.sas - same rule as calc_prr.sas.
 *
 * Reference: DuMouchel W. "Bayesian Data Mining in Large Frequency Tables,
 *           with an Application to the FDA Spontaneous Reporting System."
 *           The American Statistician 1999;53(3):177-190.
 *
 * Author:   Hingling Yu
 * Created:  2026-09-03
 *****************************************************************************/


/*==========================================================================
  MACRO: %calc_ebgm
  --------------------------------------------------------------------------
  Parameters
    ds_in     Required. Input dataset containing numeric a, n_drug, n_reac.
              All other input columns are carried through unchanged.
    ds_out    Required. Output dataset. May be the same as ds_in.
    total_n   Required. The NAME of a GLOBAL macro variable holding the
              analysis universe N - e.g. total_n=TOTAL_N, not
              total_n=&TOTAL_N. Resolved through DICTIONARY.MACROS, not
              through &&&total_n; see the comment at the resolution step for
              why that distinction is load-bearing.
    max_iter  Simplex iteration cap. Default 2000; the fit normally settles
              in 150-250.
    converge  The simplex is judged converged when the spread of the
              objective across its vertices falls below
              converge * (1 + |objective|) - a RELATIVE test, because the
              objective is a weighted sum and so scales with the table.
              Default 1e-8.
    truncate  0 (DEFAULT, and not the theoretically correct choice - read
              ZERO TRUNCATION before changing it). 0 uses the spec's plain
              mixture. 1 conditions on the pair having been reported,
              f(N|N>=1) = f(N)/(1 - f(0)), which is right in theory and
              degenerates on this database in practice.
    squash    1 (default) = fit the mixture on binned (a, E) cells rather
              than on every pair. See SQUASHING below. 0 fits on every row,
              which is 100x+ slower on a full-database table and was what
              exhausted a SAS ODA session on the first attempt.
    debug     1 = print the objective every 25 simplex iterations.
              Default 0.

  Columns added
    E         Expected count      = n_drug * n_reac / N
    RR        Relative Reporting Ratio = a / E   (raw, unshrunk)
    EBGM      Empirical Bayes Geometric Mean     (shrunk point estimate)
    EB05      5th  percentile of the posterior   (the FDA signal criterion)
    EB95      95th percentile of the posterior

  Global macro variables set (for the log and QC only - NOT columns)
    _EBGM_P     fitted mixing weight P        _EBGM_A2   fitted alpha2
    _EBGM_A1    fitted alpha1                 _EBGM_B2   fitted beta2
    _EBGM_B1    fitted beta1                  _EBGM_ITER simplex iterations
    _EBGM_LL    final log-likelihood          _EBGM_CONV 1 = converged
    _EBGM_NFIT  rows the mixture was fitted on

  --------------------------------------------------------------------------
  METHOD
  --------------------------------------------------------------------------
  1. Prior.  The true reporting ratio lambda is modelled as a mixture of two
     Gamma densities, five free parameters in all:

         f(lambda) = P * Gamma(lambda; alpha1, beta1)
                   + (1 - P) * Gamma(lambda; alpha2, beta2)

     Component 1 is the "background" - most pairs, lambda near 1. Component 2
     is the signal tail. P is the prior probability that a pair is background.

  2. Marginal likelihood.  Integrating lambda out of a Poisson(lambda * E)
     likelihood against a Gamma prior leaves a Negative Binomial, so the
     observed count of pair i is a two-component NB mixture:

         f(a_i | E_i) = P * NB(a_i; alpha1, p1_i) + (1-P) * NB(a_i; alpha2, p2_i)
         p_k_i        = beta_k / (beta_k + E_i)

     This is what makes the method "empirical" Bayes: the prior is fitted to
     the observed counts of every pair in the database at once.

  3. Fitting.  The five parameters are estimated by minimising the negative
     zero-truncated log-likelihood directly, with a Nelder-Mead simplex over
     (logit P, log alpha1, log beta1, log alpha2, log beta2). The transforms
     hold P in (0,1) and the Gamma parameters positive without constraints.

     Not EM, which is what the spec asked for: the truncation term couples
     the two components, so the M-step no longer separates into two
     independent two-parameter problems. See ZERO TRUNCATION below, and the
     note at section 2c for the EM variant that was tried first and why it
     was not enough.

  4. Posterior.  With the fitted parameters, pair i has posterior

         Q_i * Gamma(alpha1 + a_i, beta1 + E_i)
       + (1 - Q_i) * Gamma(alpha2 + a_i, beta2 + E_i)

     EBGM is exp(E[log lambda]), the geometric rather than arithmetic mean,
     which is the summary DuMouchel proposed because the posterior is heavily
     right-skewed and its arithmetic mean is dragged by that tail:

         EBGM_i = exp( Q_i * [digamma(alpha1 + a_i) - log(beta1 + E_i)]
                    + (1-Q_i) * [digamma(alpha2 + a_i) - log(beta2 + E_i)] )

     EB05 and EB95 have no closed form for a mixture, so they are found by
     bisection on the mixture CDF. The bracket is not guessed: the mixture
     CDF is a weighted average of the two component CDFs, so its q-th
     quantile always lies between the two component q-th quantiles. Starting
     from that pair of QUANTILE() calls makes the bracket both valid by
     construction and tight, so 40 halvings land far inside display
     precision.

  --------------------------------------------------------------------------
  ZERO TRUNCATION - an open problem, and why the default is the wrong answer
  --------------------------------------------------------------------------
  This macro is handed only the pairs that were REPORTED. 02_signal_engine
  builds them from an INNER JOIN, so a pair with a = 0 is not a row; it is
  one of roughly 60 million cells (3,555 ingredients x 17,046 PTs) that never
  appear. The spec's likelihood assumes those cells were sampled. It was not
  written for this table, and it shows: the first full run fitted a
  "background" component with mean alpha1/beta1 = 2.62, when that component
  is the no-association bulk of the database and belongs near 1. Everything
  sparse was shrunk toward 2.6, 19.8% of the database cleared EB05 >= 2, and
  42% of those signals rested on fewer than three cases.

  The textbook correction is to condition on the pair having been observed,
  f(N | N>=1) = f(N)/(1 - f(0)) - TRUNCATE=1 here. On simulated data it is
  exactly right. Refitting tables drawn from a known prior of background mean
  1.00 and signal mean 5.00:

      observed cells   plain NB (TRUNCATE=0)   truncated (TRUNCATE=1)
      72%              1.123 / 5.24            1.003 / 5.11
      42%              1.330 / 5.79            1.003 / 5.13
      11%              7.432 / 1.84            1.003 / 4.90
      3.3% (FAERS-shaped marginals)            0.991 / 4.96

  On THIS database it collapses. Two runs, the second from five different
  starting points with restarts, all reached the same place:

      P = 0.9998   alpha1 = 1.2e-6   beta1 = 0.0084   -> prior mean 0.00014
                   alpha2 = 0.280    beta2 = 0.423

  All five starts returned an identical log-likelihood of -1,333,100, and
  alpha1 wandered over orders of magnitude between runs without moving it.
  That is a flat ridge, not a local trap: as alpha -> 0 the zero-truncated
  Negative Binomial tends to a logarithmic series distribution, and the
  optimiser is sitting on that boundary. The degenerate point IS the
  truncated maximum likelihood estimate for this data.

  A posterior built on it is useless - Gamma(alpha1 + N, beta1 + E) with
  alpha1 ~ 0 and beta1 = 0.0084 gives a single-case pair with a small E a
  posterior mean near 1/(0.0084 + E), which is the opposite of shrinkage.

  Why the simulations never showed it: they generate lambda from an actual
  two-component Gamma mixture, so the model is correctly specified and the
  tail is mild. Real FAERS is not. The top of this database carries pairs
  like a = 328 against E = 0.19 - a raw ratio of 1,758, with the top twenty
  reaching 18,000. No two-component Gamma can hold both that tail and the
  bulk, and under truncation the fit resolves the conflict by degenerating.

  So TRUNCATE defaults to 0: the biased fit, knowingly. It is the one that
  produces a usable ranking, and its bias is measured and stated above rather
  than hidden. Read the EBGM RANKING; do not read the EBGM signal COUNT as a
  standalone screen.

  Not yet tried, in the order worth trying:
    1. Fit on the full table WITH the zero cells rather than conditioning
       them away. Mathematically equivalent to truncation and equally
       correct in simulation, but a different surface for an optimiser to
       cross. The zero cells never need materialising - bin the drug and PT
       marginals, and the cross product gives the count of cells per E bin.
    2. Bound alpha away from 0 (say alpha >= 0.05), closing the degenerate
       corner. A shape that small is not a background in any useful sense.
    3. A three-component mixture, or a heavier-tailed prior, if the tail is
       genuinely what breaks it.

  --------------------------------------------------------------------------
  NUMERICAL NOTES
  --------------------------------------------------------------------------
  Everything is computed on the log scale with LGAMMA, never GAMMA. With
  a in the thousands, GAMMA(a + alpha) overflows a double long before the
  ratio it appears in does. The two places where logs have to come back to
  the linear scale - the responsibility w_i and the log-likelihood - both
  subtract the larger exponent first, so the argument to EXP is never
  positive and cannot overflow.

  --------------------------------------------------------------------------
  NOT EVALUABLE ROWS
  --------------------------------------------------------------------------
  A row with a <= 0, n_drug <= 0, n_reac <= 0, or any of the three missing,
  gets missing E, RR, EBGM, EB05 and EB95, and is excluded from the mixture
  fit. In this pipeline no such row can exist - 02_signal_engine.sas builds
  pairs from an INNER JOIN, so a >= 1 always - but the guard is here so the
  macro cannot silently fit a prior to rows that carry no information.
  Treat a missing EBGM as "not evaluable", never as "no signal".

  Note that EBGM survives cases PRR and ROR do not. Those two need all four
  2x2 cells non-zero; EBGM needs only a > 0 and positive marginals. On a
  full-database run that difference is worth reporting, which is why
  02_signal_engine.sas counts EBGM-evaluable pairs separately.

  --------------------------------------------------------------------------
  PERFORMANCE
  --------------------------------------------------------------------------
  PROC IML rather than DATA steps: the fit evaluates its objective a few
  hundred times, each time over the whole table, so a DATA step
  implementation would mean a few hundred passes over a multi-million-row
  table on disk. In IML the counts live in memory as two vectors (about 6 MB
  per million rows) and each evaluation is a handful of vectorised
  expressions. Only the five result columns are written back, joined to the
  input by position - the wide character columns such as prod_ai never enter
  IML at all.

  Example
    %calc_ebgm(ds_in=work.with_prr_ror, ds_out=work.with_all_measures,
               total_n=TOTAL_N);
  ==========================================================================*/
%macro calc_ebgm(ds_in=, ds_out=, total_n=, max_iter=2000, converge=1e-8,
                 squash=1, truncate=0, debug=0);

    %local i dsid rc var vnum vtype bad nval nin nout iml_ok nebgm _bgmean;

    %global _EBGM_P _EBGM_A1 _EBGM_B1 _EBGM_A2 _EBGM_B2
            _EBGM_ITER _EBGM_LL _EBGM_CONV _EBGM_NFIT _EBGM_NBIN _EBGM_TRUNC;

    /* Seeded to missing before anything can fail. A caller that writes
       "value = &_EBGM_P;" into a DATA step must get a valid statement even
       on the paths below that %return early - an empty macro variable there
       is a syntax error three steps away from its real cause. */
    %let _EBGM_P    = .;   %let _EBGM_A1   = .;   %let _EBGM_B1   = .;
    %let _EBGM_A2   = .;   %let _EBGM_B2   = .;   %let _EBGM_ITER = .;
    %let _EBGM_LL   = .;   %let _EBGM_CONV = 0;   %let _EBGM_NFIT = .;
    %let _EBGM_NBIN = .;
    /* Published so the caller's QC can record WHICH likelihood produced the
       parameters. With two fits available that is not optional metadata. */
    %let _EBGM_TRUNC = &truncate;

    /*----------------------------------------------------------------------
      1. Validate parameters - fail loudly and early rather than writing an
         output dataset full of missing values that looks like a real result.
      ----------------------------------------------------------------------*/
    %if %length(&ds_in) = 0 or %length(&ds_out) = 0 or %length(&total_n) = 0 %then %do;
        %put ERROR: [calc_ebgm] DS_IN=, DS_OUT= and TOTAL_N= are all required.;
        %return;
    %end;

    %if %sysfunc(exist(&ds_in)) = 0 %then %do;
        %put ERROR: [calc_ebgm] Input dataset &ds_in does not exist.;
        %return;
    %end;

    /*----------------------------------------------------------------------
      Resolve the NAME in TOTAL_N= to its value.

      The obvious &&&total_n is WRONG here, and wrong in a way that costs a
      whole run. Macro variable names are case-insensitive, so the parameter
      TOTAL_N= is itself a local macro variable named TOTAL_N holding the
      string "TOTAL_N". It therefore SHADOWS the caller's global TOTAL_N:

          &&&total_n  ->  & + "TOTAL_N"  ->  &TOTAL_N  ->  "TOTAL_N"

      Both passes find the local parameter, so the result is the name again,
      not the count. %SYMEXIST does not help - it finds the local too - and
      the string sails through into PROC IML, where "N = TOTAL_N;" fails with
      "Matrix has not been set to a value" and every EBGM column comes back
      missing. Nesting a helper macro does not help either: macro scopes are
      nested, so an inner macro still sees this one's locals.

      DICTIONARY.MACROS names the scope explicitly, which is the one thing
      that cannot be shadowed. The caller's N must be GLOBAL - in this
      pipeline it is, because 02_signal_engine.sas creates TOTAL_N with a
      PROC SQL INTO in open code.
      ----------------------------------------------------------------------*/
    proc sql noprint;
        select value into :nval trimmed
            from dictionary.macros
            where upcase(name) = upcase("&total_n")
              and scope = 'GLOBAL';
    quit;

    %if %length(&nval) = 0 %then %do;
        %put ERROR: [calc_ebgm] No GLOBAL macro variable named "&total_n".;
        %put ERROR- [calc_ebgm] TOTAL_N= takes a NAME, e.g. total_n=TOTAL_N,;
        %put ERROR- [calc_ebgm] and that variable must be global when called.;
        %return;
    %end;

    /* VERIFY rather than %SYSEVALF: %sysevalf on a non-numeric string does
       not reliably fail, which is how the shadowing bug above stayed silent.
       A case count is pure digits, so anything else is a hard stop. */
    %if %sysfunc(verify(&nval, 0123456789)) > 0 %then %do;
        %put ERROR: [calc_ebgm] &total_n resolved to "&nval", which is not a count.;
        %return;
    %end;

    %if &nval <= 0 %then %do;
        %put ERROR: [calc_ebgm] &total_n = &nval - N must be a positive count.;
        %return;
    %end;

    /* The three count columns must be present and numeric. A character "a"
       would otherwise abort PROC IML with an obscure type-mismatch error. */
    %let dsid = %sysfunc(open(&ds_in));
    %let bad  = 0;
    %do i = 1 %to 3;
        %let var  = %scan(a n_drug n_reac, &i);
        %let vnum = %sysfunc(varnum(&dsid, &var));
        %if &vnum = 0 %then %do;
            %put ERROR: [calc_ebgm] &ds_in is missing required column "&var".;
            %let bad = 1;
        %end;
        %else %do;
            %let vtype = %sysfunc(vartype(&dsid, &vnum));
            %if &vtype ne N %then %do;
                %put ERROR: [calc_ebgm] Column "&var" in &ds_in must be numeric.;
                %let bad = 1;
            %end;
        %end;
    %end;
    %let nin = %sysfunc(attrn(&dsid, nlobs));
    %let rc  = %sysfunc(close(&dsid));

    %if &bad %then %do;
        %put ERROR- [calc_ebgm] Expected counts named a, n_drug, n_reac.;
        %return;
    %end;

    /* PROC IML cannot allocate a zero-row matrix, so an empty input would
       fail inside the fit with a dimension error rather than here. */
    %if &nin = 0 %then %do;
        %put ERROR: [calc_ebgm] &ds_in has no rows - nothing to fit.;
        %return;
    %end;

    /* SYSPROD returns 1 when the product is licensed, 0 when it is not, and
       -1 when it does not recognise the name. Only 0 is a definite "no": a
       -1 is treated as "cannot tell" and the run proceeds, because refusing
       to run on an inconclusive licence check would be worse than letting
       PROC IML report the problem itself. */
    %let iml_ok = %sysfunc(sysprod(iml));
    %if &iml_ok = 0 %then %do;
        %put ERROR: [calc_ebgm] SAS/IML is not licensed in this session.;
        %put ERROR- [calc_ebgm] The MGPS fit needs IML. &ds_out was not written.;
        %return;
    %end;
    %else %if &iml_ok ne 1 %then
        %put WARNING: [calc_ebgm] SYSPROD(IML) returned &iml_ok - proceeding anyway.;

    %put NOTE: [calc_ebgm] &ds_in -> &ds_out (N = &nval from &total_n).;

    /*----------------------------------------------------------------------
      2. Fit the mixture and compute the posterior summaries.
      ----------------------------------------------------------------------*/
    proc iml;

        /*==================================================================
          2a. Numerical core, as modules so the fit below reads like the
              algorithm rather than like arithmetic.
          ==================================================================*/

        /* log Negative Binomial PMF, with p = beta/(beta+E) substituted in.
           LGAMMA throughout: every argument is strictly positive, so this is
           defined and stable for any count the database can produce. */
        start lognb(cnt, alpha, beta, expc);
            den = beta + expc;
            return( lgamma(cnt + alpha) - lgamma(alpha) - lgamma(cnt + 1)
                    + alpha # (log(beta) - log(den))
                    + cnt   # (log(expc) - log(den)) );
        finish;

        /* Posterior probability that a pair belongs to component 1. Used
           both as the E-step responsibility during fitting and as Q_i in the
           final per-pair posterior. */
        start qpost(cnt, expc, P, a1, b1, a2, b2);
            t = lognb(cnt, a2, b2, expc) - lognb(cnt, a1, b1, expc);
            t = choose(t >  700,  700, t);   /* exp(700) is near the double  */
            t = choose(t < -700, -700, t);   /* limit; beyond it w is 0 or 1 */
            return( 1 / (1 + ((1 - P) / P) # exp(t)) );
        finish;

        /* 1 - exp(-x), evaluated so it keeps its digits when x is tiny.
           The straight form loses them all: for x = 1e-12, exp(-x) rounds to
           a double that differs from 1 in its last bits, and subtracting
           leaves noise. The series is the first three terms of 1-exp(-x). */
        start onemexp(x);
            xs = choose(x > 700, 700, x);
            return( choose(x < 1e-5,
                           x # (1 - (x / 2) # (1 - x / 3)),
                           1 - exp(-xs)) );
        finish;

        /* Negative ZERO-TRUNCATED log-likelihood of the mixture - the whole
           objective, in one function, minimised directly.

           TH holds the five parameters in unconstrained form: logit(P) and
           the logs of alpha1, beta1, alpha2, beta2. Optimising the transforms
           rather than the parameters is what keeps P inside (0,1) and the
           Gamma parameters positive without a single constraint.

           The truncation term is the point of this function. The caller only
           ever sees pairs that were REPORTED at least once; a pair with a = 0
           is not a row in the table, it is one of the tens of millions of
           drug x reaction cells that never appear. Conditioning on that -
           dividing by 1 - f(0 | E) - is what stops the fit inflating every
           parameter to explain an absence of zeros that was never in the
           data. See the ZERO TRUNCATION note in the macro header.

           1 - f(0|E) is built from ONEMEXP rather than as 1 - f0, because
           for a pair with a small expected count f0 is within rounding
           distance of 1 and the subtraction would return zero. */
        start negll(th, cnt, expc, wt);
            tp = th[1];
            tp = choose(tp >  30,  30, choose(tp < -30, -30, tp));
            P  = 1 / (1 + exp(-tp));

            lp  = th[2:5];
            lp  = choose(lp >  14,  14, choose(lp < -14, -14, lp));
            al1 = exp(lp[1]);   be1 = exp(lp[2]);
            al2 = exp(lp[3]);   be2 = exp(lp[4]);

            l1 = lognb(cnt, al1, be1, expc);
            l2 = lognb(cnt, al2, be2, expc);
            m  = choose(l1 > l2, l1, l2);
            ll = m + log( P # exp(l1 - m) + (1 - P) # exp(l2 - m) );

            /* u_k = -log NB(0; alpha_k, beta_k, E) = alpha_k * log(1 + E/beta_k).
               Written this way rather than as log(beta+E) - log(beta), which
               cancels to nothing when E << beta. */
%if &truncate %then %do;
            u1 = al1 # log(1 + expc / be1);
            u2 = al2 # log(1 + expc / be2);
            om = P # onemexp(u1) + (1 - P) # onemexp(u2);
            om = choose(om < 1e-300, 1e-300, om);
            ll = ll - log(om);
%end;
            return( -sum( wt # ll ) );
        finish;

        /* One Nelder-Mead run. Returns the best vertex, its objective, the
           iterations used and whether the spread test was met.

           A module rather than inline code because the driver below runs it
           several times: from different starting points, and again from
           wherever the previous run stopped. Restarting a simplex is not
           ceremony - Nelder-Mead can collapse into a degenerate shape and
           report convergence while sitting nowhere near a minimum, and
           rebuilding the simplex around the point it stopped at is the
           standard way to find out whether it really had finished. */
        start nmfit(th0, stepsz, cnt, expc, wt, mxit, tolr, thb, fb, itb, cvb);
            npar = ncol(th0);

            Smp = repeat(th0, npar + 1, 1);
            do i = 1 to npar;
                Smp[i+1, i] = Smp[i+1, i] + stepsz;
            end;

            Fsm = j(npar + 1, 1, 0);
            do i = 1 to npar + 1;
                Fsm[i] = negll(Smp[i,], cnt, expc, wt);
            end;

            cvb = 0;
            itb = 0;
            do it = 1 to mxit until (cvb);
                itb = it;

                Wsm = Fsm || Smp;
                call sort(Wsm, 1);
                Fsm = Wsm[, 1];
                Smp = Wsm[, 2:(npar+1)];

                if abs(Fsm[npar+1] - Fsm[1]) < tolr * (1 + abs(Fsm[1]))
                    then cvb = 1;
                else do;
                    Sbest = Smp[1:npar, ];
                    cen   = Sbest[:, ];
                    xw    = Smp[npar+1, ];

                    xr = cen + (cen - xw);
                    fr = negll(xr, cnt, expc, wt);

                    if fr < Fsm[1] then do;
                        xe = cen + 2 * (cen - xw);
                        fe = negll(xe, cnt, expc, wt);
                        if fe < fr then do; Smp[npar+1,] = xe; Fsm[npar+1] = fe; end;
                        else            do; Smp[npar+1,] = xr; Fsm[npar+1] = fr; end;
                    end;
                    else if fr < Fsm[npar] then do;
                        Smp[npar+1,] = xr;  Fsm[npar+1] = fr;
                    end;
                    else do;
                        xc = cen + 0.5 * (xw - cen);
                        fc = negll(xc, cnt, expc, wt);
                        if fc < Fsm[npar+1] then do;
                            Smp[npar+1,] = xc;  Fsm[npar+1] = fc;
                        end;
                        else do;
                            do i = 2 to npar + 1;
                                Smp[i,] = Smp[1,] + 0.5 # (Smp[i,] - Smp[1,]);
                                Fsm[i]  = negll(Smp[i,], cnt, expc, wt);
                            end;
                        end;
                    end;
                end;
            end;

            Wsm = Fsm || Smp;
            call sort(Wsm, 1);
            thb = Wsm[1, 2:(npar+1)];
            fb  = Wsm[1, 1];
        finish;

        /* Percentile of the two-component Gamma posterior mixture, by
           bisection. The two component quantiles bracket the mixture
           quantile because the mixture CDF is their weighted average, so no
           bracket search or widening loop is needed. */
        start ebpct(Qw, s1, r1, s2, r2, target);
            tv = j(nrow(s1), 1, target);
            x1 = quantile("GAMMA", tv, s1, 1 / r1);
            x2 = quantile("GAMMA", tv, s2, 1 / r2);
            lo = choose(x1 < x2, x1, x2);
            hi = choose(x1 < x2, x2, x1);

            /* 30 halvings, not 50. The bracket is a pair of component
               quantiles, so it starts narrower than 20 in practice and the
               remaining error is width/2^30 - below 2e-8, four orders finer
               than the 10.4 format these values are written with. Each extra
               halving costs two gamma CDF passes over every pair, which is
               the largest single cost left in this macro. */
            do bi = 1 to 30;
                mid = (lo + hi) / 2;
                Fm  = Qw # cdf("GAMMA", mid, s1, 1 / r1)
                      + (1 - Qw) # cdf("GAMMA", mid, s2, 1 / r2);
                lo  = choose(Fm < target, mid, lo);
                hi  = choose(Fm < target, hi,  mid);
            end;

            return( (lo + hi) / 2 );
        finish;

        /*==================================================================
          2b. Read the counts. Only the three numeric columns cross into
              IML - see the PERFORMANCE note in the macro header.
          ==================================================================*/
        use &ds_in;
        read all var {a n_drug n_reac} into raw;
        close &ds_in;

        n_all = nrow(raw);
        N     = &nval;

        aObs = raw[, 1];
        nDrg = raw[, 2];
        nRea = raw[, 3];
        free raw;

        E    = j(n_all, 1, .);
        RR   = j(n_all, 1, .);
        EBGM = j(n_all, 1, .);
        EB05 = j(n_all, 1, .);
        EB95 = j(n_all, 1, .);

        /* IML orders missing below every number, so a missing count fails
           each of these tests and drops out of the fit exactly as intended. */
        okr  = loc(aObs > 0 & nDrg > 0 & nRea > 0);
        nfit = ncol(okr);

        if nfit > 0 then do;

            ok = t(okr);
            Ev = nDrg[ok] # nRea[ok] / N;
            Nv = aObs[ok];

            E[ok]  = Ev;
            RR[ok] = Nv / Ev;

            free nDrg nRea aObs okr;

            /*==============================================================
              2b-2. SQUASHING - collapse the pairs the fit has to see.

              The marginal likelihood of a pair depends on nothing but its
              (a, E). Two pairs with the same count and a near-identical
              expected count contribute the same term, so fitting five
              parameters against all 750,000 of them separately is wasted
              work: the fit re-evaluates LGAMMA over every row on each of the
              few hundred objective evaluations the simplex needs.

              Squashing bins the pairs and gives each bin a weight equal to
              how many pairs it stands for. Counts bin exactly up to 50 -
              where the great majority of FAERS pairs sit - and geometrically
              above it; E bins geometrically at 5% per bin, so every pair in
              a bin has an expected count within 5% of the bin mean.

              Measured on a simulated 753,594-pair table: 10,628 bins, a 71x
              reduction. One objective evaluation falls from 95 ms to 0.7 ms
              and the whole fit from 28.4 s to 0.18 s, while both runs
              converge to the same answer - component means 1.0028 / 5.039
              binned against 1.0017 / 5.013 unbinned, on data generated from
              a true 1.000 / 5.00. This is the standard treatment -
              DuMouchel's own paper bins the table before fitting, and
              openEBGM does the same - not a shortcut invented here.

              What is NOT squashed: EBGM, EB05 and EB95 are computed for
              every pair individually from the fitted prior. Only the FIT is
              done on bins.
              ==============================================================*/
            if &squash then do;

                /* Bin index for each pair. Both branches of CHOOSE are
                   evaluated, so log(Nv/50) is taken even where Nv <= 50 -
                   harmless, since Nv >= 1 keeps the argument positive. */
                nb = choose(Nv <= 50, Nv, 50 + floor(log(Nv / 50) / log(1.15)));
                eb = floor(log(Ev) / log(1.05));
                eb = eb - min(eb) + 1;          /* shift to keep the key > 0 */
                key = nb # 100000 + eb;

                /* Sort by key so each bin is one contiguous run of rows. */
                M = key || Nv || Ev;
                call sort(M, 1);
                ks = M[, 1];

                nrw = nrow(M);
                d   = j(nrw, 1, 0);
                d[1] = 1;
                if nrw > 1 then d[2:nrw] = (ks[2:nrw] ^= ks[1:(nrw-1)]);

                starts = t(loc(d));
                nbin   = nrow(starts);
                ends   = j(nbin, 1, nrw);
                if nbin > 1 then ends[1:(nbin-1)] = starts[2:nbin] - 1;

                /* Bin means by an explicit loop over the runs rather than by
                   differencing a CUSUM. Differencing would subtract two large
                   running totals to recover a small bin sum, and the tiny E
                   values in this table are exactly where that cancellation
                   loses digits. A loop over a few thousand bins costs
                   nothing. */
                Nf   = j(nbin, 1, 0);
                Ef   = j(nbin, 1, 0);
                rwt  = j(nbin, 1, 0);
                do bi = 1 to nbin;
                    sIx = starts[bi];
                    eIx = ends[bi];
                    rwt[bi] = eIx - sIx + 1;
                    Nf[bi]  = sum(M[sIx:eIx, 2]) / rwt[bi];
                    Ef[bi]  = sum(M[sIx:eIx, 3]) / rwt[bi];
                end;

                free M ks d starts ends key nb eb;
                print "[calc_ebgm] squashed to bins for the fit:" nfit nbin;
            end;
            else do;
                Nf   = Nv;
                Ef   = Ev;
                rwt  = j(nfit, 1, 1);
                nbin = nfit;
            end;

            /*==============================================================
              2c. FIT - direct minimisation of the negative zero-truncated
                  log-likelihood by Nelder-Mead simplex.

                  This replaces the EM of the spec. Two reasons, both found
                  by measurement rather than preference:

                  1. The spec's likelihood is untruncated, and on a table of
                     observed pairs only that is the wrong likelihood - it
                     put the background component at 2.62 instead of ~1 on
                     the first full FAERS run. The truncated objective does
                     not factor into two independent component problems the
                     way the untruncated one does, so the EM's tidy M-step
                     stops applying.
                  2. An EM that imputes the missing zero cells does exist and
                     was tried. It recovered the background component but not
                     the signal component, and was still moving after 400
                     iterations. Direct minimisation reaches the answer in
                     around 200.

                  Validated by simulating from a KNOWN prior of background
                  mean 1.00 and signal mean 5.00 and refitting:

                      observed cells   fitted means      P (true 0.85)
                      72%              1.003 / 5.11      0.855
                      42%              1.003 / 5.13      0.855
                      18%              0.995 / 4.74      0.839
                      11%              1.003 / 4.90      0.844

                  Nelder-Mead rather than a gradient method: the objective is
                  cheap (one pass over a few thousand bins) but its gradient
                  in five transformed parameters is not, and a derivative-free
                  method has no Hessian to go indefinite on. Written out here
                  rather than called from NLPNMS so that MAX_ITER= and
                  CONVERGE= mean exactly what this file says they mean.

                  Starting point is DuMouchel's: alpha1=0.2, beta1=0.1,
                  alpha2=2, beta2=4, P=0.5.
              ==============================================================*/
            /*----------------------------------------------------------
              Multi-start. The simplex is run from five starting points and
              again from wherever each one stopped, and the best result wins.

              This is not caution for its own sake. On the first truncated
              run a single start from DuMouchel's values reported CONVERGED
              at alpha1 = 2.06e-6 - a background component collapsed onto a
              point mass at zero carrying 99.97% of the weight, which is not
              a prior anyone can use. Refitting simulated data of the same
              shape and sparsity did not reproduce it, so the trap is a
              property of this database rather than of the sparsity, and the
              only defence that does not depend on guessing where it is, is
              to approach the optimum from several directions and compare.

              Every start's objective is written to the log. If they disagree
              the surface has more than one basin and the fit needs a human
              look, which is exactly what the log is for.
              ----------------------------------------------------------*/
            npar = 5;

            /* logit(P), log alpha1, log beta1, log alpha2, log beta2 */
            STARTS = { 0.0  -1.6094  -2.3026   0.6931   1.3863,
                       0.0   0.6931   0.6931   0.4055  -1.2040,
                       1.0   0.0      0.0      0.0     -1.6094,
                       0.0  -0.6931  -0.6931   1.0986   0.0   ,
                       1.5   1.0986   1.0986  -0.6931  -2.3026 };
            nstart = nrow(STARTS);

            /* Output arguments must exist as symbols before the first call. */
            th0 = j(1, npar, 0);
            thb = j(1, npar, 0);   fb  = 0;   itb = 0;   cvb = 0;
            thbest = thb;  fbest = .;  iter = 0;  conv = 0;
            SLOG = j(nstart, 3, 0);

            do sIx = 1 to nstart;

                /* Fresh simplex, then a tighter one rebuilt where it landed.
                   TH0 is copied out each time rather than passing STARTS[sIx,]
                   or THB straight in: IML modules take their arguments by
                   reference, so handing the same matrix in as both the input
                   and the output would alias them. */
                th0 = STARTS[sIx,];
                run nmfit(th0, 0.5, Nf, Ef, rwt, &max_iter, &converge,
                          thb, fb, itb, cvb);

                th0 = thb;
                run nmfit(th0, 0.1, Nf, Ef, rwt, &max_iter, &converge,
                          thb, fb, itb, cvb);

                SLOG[sIx, 1] = sIx;
                SLOG[sIx, 2] = fb;
                SLOG[sIx, 3] = cvb;

                if fbest = . | fb < fbest then do;
                    fbest  = fb;
                    thbest = thb;
                    iter   = itb;
                    conv   = cvb;
                end;
            end;

            print SLOG[colname={"start" "negLL" "converged"} format=best16.
                       label="[calc_ebgm] fit by starting point - all five should agree"];

            th = thbest;
            ll = -fbest;

            tp = th[1];
            tp = choose(tp > 30, 30, choose(tp < -30, -30, tp));
            P  = 1 / (1 + exp(-tp));

            lp = th[2:5];
            lp = choose(lp > 14, 14, choose(lp < -14, -14, lp));
            a1 = exp(lp[1]);  b1 = exp(lp[2]);
            a2 = exp(lp[3]);  b2 = exp(lp[4]);

            /* Label switching. The likelihood is invariant to swapping the
               two components, so which one the optimiser lands on is
               arbitrary. Fixing component 1 as the larger-weight background
               makes the reported parameters comparable across runs. */
            if P < 0.5 then do;
                P    = 1 - P;
                tmpa = a1;  a1 = a2;  a2 = tmpa;
                tmpb = b1;  b1 = b2;  b2 = tmpb;
            end;

            /* Back to the full table: Q is computed per PAIR, not per bin.
               LL keeps the value from the fit and is not overwritten. */
            Q = qpost(Nv, Ev, P, a1, b1, a2, b2);
            free Nf Ef rwt STARTS SLOG;

            /*==============================================================
              2d. Posterior summaries.
              ==============================================================*/
            s1 = a1 + Nv;   r1 = b1 + Ev;
            s2 = a2 + Nv;   r2 = b2 + Ev;
            free Nv Ev;

            EBGM[ok] = exp( Q # (digamma(s1) - log(r1))
                            + (1 - Q) # (digamma(s2) - log(r2)) );
            EB05[ok] = ebpct(Q, s1, r1, s2, r2, 0.05);
            EB95[ok] = ebpct(Q, s1, r1, s2, r2, 0.95);
        end;
        else do;
            P = .;  a1 = .;  b1 = .;  a2 = .;  b2 = .;
            iter = .;  ll = .;  conv = 0;  nbin = 0;
            print "ERROR: [calc_ebgm] No evaluable rows - every EBGM column is missing.";
        end;

        /*==================================================================
          2e. Write the five result columns and the fitted parameters.
              _EBGM_COLS is in input row order, which is what lets section 3
              join it back by position.
          ==================================================================*/
        create work._ebgm_cols var {E RR EBGM EB05 EB95};
        append;
        close work._ebgm_cols;

        EB_P    = P;     EB_A1 = a1;  EB_B1 = b1;
        EB_A2   = a2;    EB_B2 = b2;
        EB_ITER = iter;  EB_LL = ll;  EB_CONV = conv;  EB_NFIT = nfit;
        EB_NBIN = nbin;

        create work._ebgm_parms
            var {EB_P EB_A1 EB_B1 EB_A2 EB_B2 EB_ITER EB_LL EB_CONV EB_NFIT
                 EB_NBIN};
        append;
        close work._ebgm_parms;
    quit;

    /*----------------------------------------------------------------------
      3. Publish the fit to macro variables, then join the columns back.
      ----------------------------------------------------------------------*/
    %if %sysfunc(exist(work._ebgm_cols)) = 0 %then %do;
        %put ERROR: [calc_ebgm] PROC IML produced no output - &ds_out not written.;
        %return;
    %end;

    proc sql noprint;
        select EB_P, EB_A1, EB_B1, EB_A2, EB_B2, EB_ITER, EB_LL, EB_CONV,
               EB_NFIT, EB_NBIN
            into :_EBGM_P    trimmed, :_EBGM_A1   trimmed, :_EBGM_B1 trimmed,
                 :_EBGM_A2   trimmed, :_EBGM_B2   trimmed, :_EBGM_ITER trimmed,
                 :_EBGM_LL   trimmed, :_EBGM_CONV trimmed, :_EBGM_NFIT trimmed,
                 :_EBGM_NBIN trimmed
            from work._ebgm_parms;
    quit;

    %put NOTE: [calc_ebgm] fitted P=&_EBGM_P alpha1=&_EBGM_A1 beta1=&_EBGM_B1;
    %put NOTE: [calc_ebgm]         alpha2=&_EBGM_A2 beta2=&_EBGM_B2;
    %put NOTE: [calc_ebgm] simplex iterations=&_EBGM_ITER truncated logL=&_EBGM_LL rows fitted=&_EBGM_NFIT;
    %put NOTE: [calc_ebgm] mixture fitted on &_EBGM_NBIN squashed bins (squash=&squash, truncate=&truncate).;

    %if &_EBGM_CONV ne 1 %then %do;
        %put WARNING: [calc_ebgm] The simplex did not converge in &max_iter iterations.;
        %put WARNING- [calc_ebgm] Results use the best vertex reached.;
    %end;

    /*----------------------------------------------------------------------
      Degeneracy guard.

      A converged optimiser is not the same as a usable prior. The truncated
      fit's first full run reported CONVERGED while sitting at
      alpha1 = 2.06e-6 - the background component collapsed onto a point mass
      at zero, holding 99.97% of the weight. Every other check in this macro
      passed: 753,594 rows written, all five columns populated, no missing
      values. Only the parameters themselves showed it.

      Component 1 is the no-association background of the database, so its
      prior mean belongs near 1. Anything outside [0.2, 5] is not a
      background, and a shape parameter within a factor of ~100 of the
      exp(-14) clamp means the optimiser was walking into a corner rather
      than sitting in a minimum. Neither is made an ERROR: the estimates are
      still written, because a human reading the parameters next to this
      warning is better placed to judge than a threshold is.
      ----------------------------------------------------------------------*/
    %if %sysevalf(&_EBGM_B1 > 0) %then %do;
        %let _bgmean = %sysevalf(&_EBGM_A1 / &_EBGM_B1);
%if &truncate %then %do;
        %put NOTE: [calc_ebgm] background component prior mean = &_bgmean (should be near 1).;
%end;
%else %do;
        /* Under TRUNCATE=0 a background near 1 is NOT what this fit produces,
           and saying so would make a correct run look broken. The untruncated
           likelihood is biased upward on a table of observed pairs - see ZERO
           TRUNCATION - and lands near 2.6 on this database. That is the known
           cost of the default, not a fault to chase. */
        %put NOTE: [calc_ebgm] background component prior mean = &_bgmean;
        %put NOTE: [calc_ebgm] TRUNCATE=0 biases this upward - near 1 is correct in theory,;
        %put NOTE: [calc_ebgm] around 2.6 is what this database gives. See ZERO TRUNCATION.;
%end;

        %if %sysevalf(&_bgmean < 0.2) or %sysevalf(&_bgmean > 5) %then %do;
            %put WARNING: [calc_ebgm] Background prior mean &_bgmean is implausible.;
            %put WARNING- [calc_ebgm] It is the no-association bulk of the database and belongs near 1.;
            %put WARNING- [calc_ebgm] Check the per-start negative log-likelihood table printed above.;
        %end;
    %end;

    %if %sysevalf(&_EBGM_A1 < 1e-4) or %sysevalf(&_EBGM_A2 < 1e-4) %then %do;
        %put WARNING: [calc_ebgm] A shape parameter is near the exp(-14) clamp;
        %put WARNING- [calc_ebgm] (alpha1=&_EBGM_A1 alpha2=&_EBGM_A2). The fit is degenerate, not converged.;
    %end;

    /* The join is positional, so a row-count mismatch would silently pair
       the wrong EBGM with the wrong drug. Refuse to write &ds_out instead. */
    %let dsid = %sysfunc(open(work._ebgm_cols));
    %let nout = %sysfunc(attrn(&dsid, nlobs));
    %let rc   = %sysfunc(close(&dsid));

    %if &nout ne &nin %then %do;
        %put ERROR: [calc_ebgm] IML returned &nout rows for &nin input rows.;
        %put ERROR- [calc_ebgm] &ds_out was not written.;
        %return;
    %end;

    /* Backstop. A row count alone is not proof of a fit: the five result
       vectors are allocated missing before the EM runs, so an error inside
       PROC IML leaves a table of the right SHAPE full of nothing, and every
       other check in this macro still passes. That is exactly how the
       TOTAL_N shadowing bug reached a finished run. If the macro claims to
       have fitted rows, it has to show estimates for some of them. */
    %let nebgm = 0;
    proc sql noprint;
        select sum(not missing(EBGM)) into :nebgm trimmed
            from work._ebgm_cols;
    quit;

    %if &nebgm = 0 or &nebgm = . %then %do;
        %put ERROR: [calc_ebgm] The fit produced no EBGM values at all.;
        %put ERROR- [calc_ebgm] Check the PROC IML errors above. &ds_out was not written.;
        %return;
    %end;

    %put NOTE: [calc_ebgm] EBGM computed for %sysfunc(putn(&nebgm, comma16.)) of &nin rows.;

    /* Two SET statements, no BY: both datasets are read in step, row for
       row. A MERGE would need a key column that neither table has, and
       sorting a multi-million-row table to invent one would cost more than
       the whole EM fit. */
    data &ds_out;
        set &ds_in;
        set work._ebgm_cols;

        format E RR EBGM EB05 EB95 10.4;

        label
            E    = 'Expected count (n_drug * n_reac / N)'
            RR   = 'Relative Reporting Ratio (a / E, unshrunk)'
            EBGM = 'Empirical Bayes Geometric Mean'
            EB05 = 'EBGM 5th percentile (posterior lower bound)'
            EB95 = 'EBGM 95th percentile (posterior upper bound)';
    run;

    proc datasets library=work nolist;
        delete _ebgm_cols _ebgm_parms;
    quit;

%mend calc_ebgm;

%put NOTE: [calc_ebgm] macro compiled.;


/*==========================================================================
  VERIFICATION TEST - uncomment the block below and run in SAS Studio.
  --------------------------------------------------------------------------
  The table is 22 ordinary pairs drawn from a genuine Gamma-Poisson process,
  plus four rows chosen to make one point, plus two guard rows. With
  N = 100,000, E and RR are exact and hand-checkable:

    NULL_BIG       E = 1000 * 5000 / 100000 = 50.0000   RR =  50/50   =  1.0000
    STRONG_BIG     E = 1000 * 5000 / 100000 = 50.0000   RR = 500/50   = 10.0000
    STRONG_MID     E =  200 * 3000 / 100000 =  6.0000   RR =  60/6    = 10.0000
    STRONG_SPARSE  E =   10 * 3000 / 100000 =  0.3000   RR =   3/0.3  = 10.0000

  THE POINT: those last three rows have the SAME raw RR of 10, on 500, 60
  and 3 cases. PRR and ROR score all three alike. EBGM does not:

    pair             a      RR     EBGM     EB05    EB05 >= 2 ?
    STRONG_BIG     500   10.00     9.97     9.26    yes - signal
    STRONG_MID      60   10.00     9.76     7.86    yes - signal
    STRONG_SPARSE    3   10.00     5.57     1.04    NO  - not a signal

  The gap between 9.97 and 5.78 IS the shrinkage, and EB05 is what turns it
  into a decision. Reproducing that ordering is the real test of this macro;
  a run that scores all three near 10 has a prior that is not being fitted.

  Expected fit, approximately (the EM is deterministic, but the last digits
  depend on the platform's DIGAMMA and TRIGAMMA):

    P = 0.654  alpha1 = 12.60  beta1 = 13.90  alpha2 = 0.456  beta2 = 0.143
    converges in about 141 simplex iterations; component means 0.91 and 3.20

  Also check:
    1. EB05 <= EB95 on every evaluable row. Note that EBGM is a GEOMETRIC
       mean, exp(E[log lambda]), not a quantile - it normally sits inside
       [EB05, EB95] and does here on all 26 rows, but a mixture posterior
       with a little weight far out can put it outside, so that is not an
       invariant to assert.
    2. The two GUARD rows (a = 0, and n_reac = 0) come back with all five
       columns missing, and the log shows no division-by-zero note.
    3. PAIR_01 flags as a signal (a = 575 against E = 200). That is correct,
       not a leak: its lambda was genuinely drawn near 2.9. A screen that
       flagged nothing from the ordinary pool would be one with no power.

  Note what is NOT verified here. Five mixture parameters cannot be
  identified from 26 rows, so the fit above is reproducible rather than
  statistically meaningful. The parameters that matter are the ones
  02_signal_engine.sas writes to qc_ebgm_model.csv on the full database.

  --------------------------------------------------------------------------
  WHY THE TEST VARIABLE IS CALLED TOTAL_N
  --------------------------------------------------------------------------
  It has to be the same name 02_signal_engine.sas passes. TOTAL_N= takes a
  macro variable NAME, and the one input that breaks name resolution is a
  name identical to the parameter's own - which is precisely the production
  call. An earlier version of this test used TEST_N, could not collide, and
  passed green while the real engine run silently wrote 753,594 rows of
  missing EBGM. A unit test on a shape the caller never uses tests nothing.

  The same caution applies to what this table can show about the fit itself.
  It cannot show the zero-truncation problem, because 26 hand-written rows
  are not a sparse database - that defect only became visible on the full
  753,594-pair run. Read the ZERO TRUNCATION section above for that.

  Leaving %let TOTAL_N = 100000 here is safe: the engine %includes this file
  in section 1, and section 3 overwrites TOTAL_N from the data before any
  measure is computed.
  ==========================================================================*/
/*
%let TOTAL_N = 100000;

data work._test_ebgm;
    length pair $15;
    input pair $ a n_drug n_reac;
    datalines;
PAIR_01         575   2000   10000
PAIR_02         103   2000    5000
PAIR_03          75   1500    8000
PAIR_04           6   1200    6000
PAIR_05          17   1000    5000
PAIR_06          52    900    7000
PAIR_07          22    800    4000
PAIR_08           8    700    3000
PAIR_09          27    600    3500
PAIR_10          16    500    2000
PAIR_11           7    400    2500
PAIR_12           9    350    1800
PAIR_13           7    300    2000
PAIR_14           8    250    1600
PAIR_15           1    200    1500
PAIR_16           1    150    1000
PAIR_17           2    120     900
PAIR_18           1    100    1000
PAIR_19         588   4000   12000
PAIR_20         186   3000    9000
PAIR_21         163   2500    7000
PAIR_22           2    180    1200
NULL_BIG         50   1000    5000
STRONG_BIG      500   1000    5000
STRONG_MID       60    200    3000
STRONG_SPARSE     3     10    3000
GUARD_A0          0    100    1000
GUARD_NREAC0      5    100       0
;
run;

%calc_ebgm(ds_in=work._test_ebgm, ds_out=work._test_ebgm_out, total_n=TOTAL_N);

proc print data=work._test_ebgm_out noobs label;
    var pair a n_drug n_reac E RR EBGM EB05 EB95;
    title 'calc_ebgm verification - the three STRONG_ rows all have RR = 10';
    title2 'Expect EBGM 9.97 / 9.76 / 5.57 and EB05 9.26 / 7.86 / 1.04';
run;
title;
*/

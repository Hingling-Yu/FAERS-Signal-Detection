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
 *           collapse toward 1. This is the method FDA's own FAERS screening
 *           runs, which is why EB05 >= 2 is the criterion a regulator
 *           recognises.
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
    max_iter  EM iteration cap. Default 200.
    converge  EM stops when the log-likelihood stops changing in the first
              -log10(converge) significant digits - the test is RELATIVE,
              not absolute. Default 1e-6. See CONVERGENCE below.
    debug     1 = print the fitted parameters at every EM iteration.
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
    _EBGM_B1    fitted beta1                  _EBGM_ITER EM iterations used
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

  3. Fitting - EM.
       E-step  w_i = posterior probability that pair i came from component 1.
       M-step  P     <- mean(w_i)
               (alpha1, beta1) <- maximise SUM w_i * log NB(a_i; alpha1, p1_i)
               (alpha2, beta2) <- maximise SUM (1-w_i) * log NB(...)
     Each M-step is a two-parameter concave-in-practice problem solved by
     Newton-Raphson with an analytic gradient and Hessian, run in
     (log alpha, log beta) space so the parameters cannot step negative, and
     protected by step-halving so an iteration can never lower the objective.
     Rolling our own beats calling NLPNRA here: the derivatives are cheap in
     closed form, and one vectorised pass over the pairs replaces the finite
     -difference evaluations a generic optimiser would need.

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
  CONVERGENCE - why the tolerance is relative
  --------------------------------------------------------------------------
  The EM stops when

      |L_new - L_old| < converge * (1 + |L|)

  rather than on the absolute difference. This is a deliberate departure
  from the step 2b spec, which asked for |delta_L| < 1e-6 outright, and the
  reason is scale. The log-likelihood is a SUM over pairs, so it grows with
  the table: about -32,000 on a 8,000-pair test, and in the millions on the
  full FAERS database. An absolute threshold of 1e-6 against a value of
  -1e6 is a request for thirteen significant digits, which a double does not
  carry - the test can never pass, the run always burns all 200 iterations,
  and it always reports "did not converge" on a fit that is in fact fine.
  Measured on simulated data: after 300 iterations the absolute change was
  still 1.7e-3, while the relative test was satisfied at iteration 83.

  Scaling by (1 + |L|) keeps the parameter meaning what the spec intended -
  1e-6 is still "six digits" - and makes the same number correct whether the
  macro is handed the 25-row test table at the bottom of this file or the
  whole database. The +1 keeps the test well defined if L is ever near zero.

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
  PROC IML rather than DATA steps: the EM loop touches every pair on every
  iteration, so a DATA step implementation would mean up to 200 passes over
  a multi-million-row table on disk. In IML the counts live in memory as two
  vectors (about 6 MB per million rows) and each iteration is a handful of
  vectorised expressions. Only the five result columns are written back,
  joined to the input by position - the wide character columns such as
  prod_ai never enter IML at all.

  Example
    %calc_ebgm(ds_in=work.with_prr_ror, ds_out=work.with_all_measures,
               total_n=TOTAL_N);
  ==========================================================================*/
%macro calc_ebgm(ds_in=, ds_out=, total_n=, max_iter=200, converge=1e-6, debug=0);

    %local i dsid rc var vnum vtype bad nval nin nout iml_ok nebgm;

    %global _EBGM_P _EBGM_A1 _EBGM_B1 _EBGM_A2 _EBGM_B2
            _EBGM_ITER _EBGM_LL _EBGM_CONV _EBGM_NFIT;

    /* Seeded to missing before anything can fail. A caller that writes
       "value = &_EBGM_P;" into a DATA step must get a valid statement even
       on the paths below that %return early - an empty macro variable there
       is a syntax error three steps away from its real cause. */
    %let _EBGM_P    = .;   %let _EBGM_A1   = .;   %let _EBGM_B1   = .;
    %let _EBGM_A2   = .;   %let _EBGM_B2   = .;   %let _EBGM_ITER = .;
    %let _EBGM_LL   = .;   %let _EBGM_CONV = 0;   %let _EBGM_NFIT = .;

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
          2a. Numerical core, as modules so the EM loop below reads like the
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

        /* E-step. Returns w (responsibility of component 1) and the
           log-likelihood, both computed by subtracting the larger exponent
           first so EXP is never handed a positive argument. */
        start estep(cnt, expc, P, a1, b1, a2, b2, w, ll);
            l1 = lognb(cnt, a1, b1, expc);
            l2 = lognb(cnt, a2, b2, expc);

            t  = l2 - l1;
            t  = choose(t >  700,  700, t);   /* exp(700) is near the double */
            t  = choose(t < -700, -700, t);   /* limit; beyond it w is 0 or 1 */
            w  = 1 / (1 + ((1 - P) / P) # exp(t));

            m  = choose(l1 > l2, l1, l2);
            ll = sum( m + log( P # exp(l1 - m) + (1 - P) # exp(l2 - m) ) );
        finish;

        /* Weighted NB log-likelihood for one component - the M-step objective. */
        start qobj(cnt, expc, wt, alpha, beta);
            return( sum( wt # lognb(cnt, alpha, beta, expc) ) );
        finish;

        /* M-step for one component. Newton-Raphson in (log alpha, log beta):
           the log reparameterisation keeps both parameters positive without
           a constraint, and the chain rule turns the analytic (alpha, beta)
           derivatives below into the log-space gradient and Hessian. Falls
           back to a scaled steepest-ascent step whenever the Hessian is not
           negative definite, and never accepts a step that fails to raise
           the objective. ALPHA and BETA are updated in place. */
        start mstep(cnt, expc, wt, alpha, beta);
            u  = log(alpha);
            v  = log(beta);
            q0 = qobj(cnt, expc, wt, alpha, beta);

            ms_done = 0;
            do mit = 1 to 50 until (ms_done);

                den = beta + expc;

                /* dQ/dalpha and dQ/dbeta */
                ga = sum( wt # (digamma(cnt + alpha) - digamma(alpha)
                                + log(beta) - log(den)) );
                gb = sum( wt # (alpha / beta - (alpha + cnt) / den) );

                /* second derivatives in (alpha, beta) */
                haa = sum( wt # (trigamma(cnt + alpha) - trigamma(alpha)) );
                hab = sum( wt # (1 / beta - 1 / den) );
                hbb = sum( wt # (-alpha / beta##2 + (alpha + cnt) / den##2) );

                /* chain rule into (log alpha, log beta) */
                gu  = alpha * ga;
                gv  = beta  * gb;
                Huu = alpha##2 * haa + alpha * ga;
                Huv = alpha * beta * hab;
                Hvv = beta##2 * hbb + beta * gb;

                if abs(gu) + abs(gv) < 1e-8 then ms_done = 1;
                else do;

                    det = Huu * Hvv - Huv * Huv;
                    if Huu < 0 & det > 0 then do;      /* negative definite */
                        du = -( Hvv * gu - Huv * gv) / det;
                        dv = -(-Huv * gu + Huu * gv) / det;
                    end;
                    else do;                            /* steepest ascent */
                        sc = max(abs(gu), abs(gv), 1);
                        du = gu / sc;
                        dv = gv / sc;
                    end;

                    /* Step-halving. The +/-14 clamp holds alpha and beta
                       inside [8e-7, 1.2e6]; anything outside that is a
                       runaway, not a fit. */
                    step = 1;
                    took = 0;
                    do k = 1 to 40 until (took);
                        ua = min(max(u + step * du, -14), 14);
                        vb = min(max(v + step * dv, -14), 14);
                        q1 = qobj(cnt, expc, wt, exp(ua), exp(vb));
                        if q1 > q0 then took = 1;
                        else step = step / 2;
                    end;

                    if took then do;
                        u = ua;  v = vb;
                        alpha = exp(u);  beta = exp(v);
                        q0 = q1;
                    end;
                    else ms_done = 1;   /* no uphill step exists - stop here */
                end;
            end;
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

            do bi = 1 to 40;
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
              2c. EM. Starting values are DuMouchel's: component 1 broad
                  (mean alpha/beta = 2), component 2 concentrated. Poor
                  starts are the usual way a two-component mixture collapses
                  onto one component, so these are not arbitrary.
              ==============================================================*/
            P = 0.5;  a1 = 0.2;  b1 = 0.1;  a2 = 2.0;  b2 = 4.0;

            llold = -1e300;
            conv  = 0;
            iter  = 0;

            /* IML module arguments are passed by reference, so the two that
               ESTEP writes back must already exist as symbols before the
               first call. */
            w  = .;
            ll = .;

            do it = 1 to &max_iter until (conv);
                iter = it;

                run estep(Nv, Ev, P, a1, b1, a2, b2, w, ll);

                /* RELATIVE tolerance - see the CONVERGENCE note in the
                   macro header. Scaling by (1 + |ll|) makes CONVERGE= mean
                   "this many significant digits of the log-likelihood",
                   which is the same test on 25 rows and on 750,000.

                   "ll ^= ." is not decoration: IML orders missing below
                   every number, so a log-likelihood that went missing would
                   otherwise satisfy the tolerance test and report a
                   converged fit built on nothing. */
                if ll ^= . & abs(ll - llold) < &converge * (1 + abs(ll))
                    then conv = 1;
                llold = ll;
%if &debug %then %do;
                print it P a1 b1 a2 b2 ll;
%end;

                if ^conv then do;
                    /* P is clamped off 0 and 1: a degenerate weight would
                       divide by zero in the next E-step. */
                    P  = sum(w) / nfit;
                    P  = min(max(P, 1e-10), 1 - 1e-10);

                    run mstep(Nv, Ev, w, a1, b1);
                    w2 = 1 - w;
                    run mstep(Nv, Ev, w2, a2, b2);
                    free w2;
                end;
            end;

            /* Label switching. The likelihood is invariant to swapping the
               two components, so which one the EM lands on is arbitrary.
               Fixing component 1 as the larger-weight background component
               makes the reported parameters comparable across runs. */
            if P < 0.5 then do;
                P    = 1 - P;
                tmpa = a1;  a1 = a2;  a2 = tmpa;
                tmpb = b1;  b1 = b2;  b2 = tmpb;
            end;

            /* One more E-step so Q holds the responsibilities implied by the
               FINAL parameters - after a non-converged run, or after the
               swap above, W from the loop would belong to earlier ones. */
            Q = .;
            run estep(Nv, Ev, P, a1, b1, a2, b2, Q, ll);
            free w;

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
            iter = .;  ll = .;  conv = 0;
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

        create work._ebgm_parms
            var {EB_P EB_A1 EB_B1 EB_A2 EB_B2 EB_ITER EB_LL EB_CONV EB_NFIT};
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
        select EB_P, EB_A1, EB_B1, EB_A2, EB_B2, EB_ITER, EB_LL, EB_CONV, EB_NFIT
            into :_EBGM_P    trimmed, :_EBGM_A1   trimmed, :_EBGM_B1 trimmed,
                 :_EBGM_A2   trimmed, :_EBGM_B2   trimmed, :_EBGM_ITER trimmed,
                 :_EBGM_LL   trimmed, :_EBGM_CONV trimmed, :_EBGM_NFIT trimmed
            from work._ebgm_parms;
    quit;

    %put NOTE: [calc_ebgm] fitted P=&_EBGM_P alpha1=&_EBGM_A1 beta1=&_EBGM_B1;
    %put NOTE: [calc_ebgm]         alpha2=&_EBGM_A2 beta2=&_EBGM_B2;
    %put NOTE: [calc_ebgm] iterations=&_EBGM_ITER logL=&_EBGM_LL rows fitted=&_EBGM_NFIT;

    %if &_EBGM_CONV ne 1 %then %do;
        %put WARNING: [calc_ebgm] EM did not converge in &max_iter iterations.;
        %put WARNING- [calc_ebgm] Results use the last-iteration parameters.;
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
    STRONG_SPARSE    3   10.00     5.78     1.10    NO  - not a signal

  The gap between 9.97 and 5.78 IS the shrinkage, and EB05 is what turns it
  into a decision. Reproducing that ordering is the real test of this macro;
  a run that scores all three near 10 has a prior that is not being fitted.

  Expected fit, approximately (the EM is deterministic, but the last digits
  depend on the platform's DIGAMMA and TRIGAMMA):

    P = 0.68   alpha1 = 12.1   beta1 = 13.2   alpha2 = 0.69   beta2 = 0.17
    converges in about 10 iterations; component means 0.92 and 4.08

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
    title2 'Expect EBGM 9.97 / 9.76 / 5.78 and EB05 9.26 / 7.86 / 1.10';
run;
title;
*/

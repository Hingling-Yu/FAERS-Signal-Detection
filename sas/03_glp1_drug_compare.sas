/*****************************************************************************
 * 03_glp1_drug_compare.sas - GLP-1 three-layer drug comparison
 *
 * Purpose:  Phase 3 Step 3. Answer two questions: do the four GLP-1
 *           molecules carry different reporting profiles, and does the newer
 *           generation differ from the older one? Each is answered twice -
 *           once per MedDRA PT, once per class-effect group.
 *
 * Inputs:   CLEAN.GLP1_CASES     Step 1 cohort, primaryid x drug_label
 *           CLEAN.GLP1_REAC      Step 1 reactions, primaryid x drug x pt
 *           CLEAN.DRUG           full database, for the universe
 *           CLEAN.REAC           full database, for n_reac and the PT map
 *           WORK.REF_PT_GROUP    class-effect groups, 00_ref_pt_group.sas
 *           SIGNAL.GLP1_SIGNALS  Step 2 - QC reconciliation ONLY
 *
 * Outputs:  SIGNAL.GLP1_BASE_SIGNALS            every rebuilt 2x2, 4 grains
 *           SIGNAL.GLP1_COMPARE_SEMA_TIRZ       Layer 1
 *           SIGNAL.GLP1_COMPARE_GENERATION      Layer 2
 *           SIGNAL.GLP1_COMPARE_OVERVIEW        Layer 3
 *           &OUT_TABLES/glp1_base_signals.csv
 *           &OUT_TABLES/glp1_compare_sema_tirz.csv
 *           &OUT_TABLES/glp1_compare_generation.csv
 *           &OUT_TABLES/glp1_compare_overview.csv
 *           &OUT_QC/qc_glp1_drug_compare.csv
 *
 * -----------------------------------------------------------------------
 * THE RULE THIS PROGRAM RUNS ON
 * -----------------------------------------------------------------------
 * Every 2x2 here is rebuilt from DISTINCT CASES. Nothing is summed across
 * PTs, across prod_ai strings, or across molecules. Three separate reasons,
 * each measured rather than assumed:
 *
 *   Across prod_ai - SIGNAL.GLP1_SIGNALS is keyed on prod_ai, so
 *     'SEMAGLUTIDE' and 'CYANOCOBALAMIN\SEMAGLUTIDE' are two rows and one
 *     drug. 473 of its 9,026 drug_label x pt combinations hold more than one
 *     row, up to 9. Reading it as drug_label grain turns the Layer 1 join
 *     into a many-to-many: 2,306 shared PTs would emit 2,980 rows.
 *
 *   Across molecules - a case reporting both SEMAGLUTIDE and TIRZEPATIDE is
 *     one case. This is why generation pooling is rebuilt in section 4 and
 *     not obtained by adding the two molecules' cell a.
 *
 *   Across PTs in a group - for the PANCREATITIS group's 49 PTs, summing the
 *     per-PT n_reac gives 9,232 where the distinct case count is 8,352. A
 *     10.5% inflation of cell c, and it would propagate into every group PRR.
 *
 * SIGNAL.GLP1_SIGNALS therefore appears exactly once below, in the section 8
 * reconciliation, and never in a number that reaches an output table.
 *
 * -----------------------------------------------------------------------
 * TWO GRAINS IN ONE TABLE - AND WHY THEY MUST NOT BE MIXED
 * -----------------------------------------------------------------------
 * Every output carries EVENT_TYPE ('PT' or 'GROUP') and EVENT. Both grains
 * share a table so Tableau reads one source, but a group's cases are also
 * counted in each of its member PTs, so a total taken across both grains
 * counts the same case repeatedly. Every consumer filters EVENT_TYPE first.
 * Nothing in this program ranks or sums the two together.
 *
 * -----------------------------------------------------------------------
 * WHY EBGM IS NOT HERE
 * -----------------------------------------------------------------------
 * %calc_ebgm fits its mixture across whatever table it is handed, so
 * refitting on four molecules would shrink toward a GLP-1-specific
 * background. The result would be called EBGM, would print beside Step 2's
 * EBGM, and would mean something different. The engine's fitted prior is
 * persisted in output/qc/qc_ebgm_model.csv, so a comparable EBGM is
 * obtainable - but only by adding a fixed-prior mode to a macro already
 * validated at Gate 2, which is a change nobody has asked for. Every flag in
 * this program is PRR-based, so nothing here needs it.
 *
 * -----------------------------------------------------------------------
 * CI_OVERLAP - WHY A PRR DIFFERENCE IS NOT YET A DIFFERENCE
 * -----------------------------------------------------------------------
 * prr_diff and prr_ratio will separate pairs whose confidence intervals
 * overlap completely. CI_OVERLAP = 0 marks the subset where the two 95%
 * intervals are disjoint, which is the defensible reading of "these two
 * differ". It is reported, never used to filter: an overlapping pair is
 * evidence of no difference, not an absence of evidence.
 *
 * Author:   Hingling Yu
 * Created:  2026-09-06
 *****************************************************************************/

/*==========================================================================
  1. SETUP
  ==========================================================================*/

/* Literal path: &BASE is defined BY this file, so it cannot be used to find
   it. Every include after this line derives from &SAS_PATH. */
%include "/home/u64291357/mydata/sas/00_config.sas";
%include "&SAS_PATH./00_ref_pt_group.sas";
%include "&SAS_PATH./macros/calc_prr.sas";
%include "&SAS_PATH./macros/calc_ror.sas";

options nosymbolgen nomprint;

%let _T0 = %sysfunc(datetime());

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

title "Phase 3 Step 3 - GLP-1 Drug Comparison (3 layers, 2 grains)";

%macro require_inputs;
    %local i tbl missing;
    %let missing = 0;

    %do i = 1 %to 6;
        %let tbl = %scan(clean.glp1_cases clean.glp1_reac clean.drug clean.reac
                         work.ref_glp1_drug work.ref_pt_group, &i);
        %if %sysfunc(exist(&tbl)) = 0 %then %do;
            %put ERROR: &tbl does not exist.;
            %let missing = %eval(&missing + 1);
        %end;
    %end;

    /* Not fatal: only section 8 reads it, and a reconciliation that cannot
       run is worth a warning rather than a dead program. */
    %if %sysfunc(exist(signal.glp1_signals)) = 0 %then
        %put WARNING: SIGNAL.GLP1_SIGNALS not found - the Step 2 reconciliation will be skipped.;

    %if &missing > 0 %then %do;
        %put ERROR- Run 01_import_clean.sas, 03_glp1_extract.sas and upload;
        %put ERROR- 00_ref_pt_group.sas before this program.;
        %abort cancel;
    %end;
%mend require_inputs;

%require_inputs

%_stamp(03_glp1_drug_compare.sas started.)


/*==========================================================================
  2. THE ANALYSIS UNIVERSE
  --------------------------------------------------------------------------
  02_signal_engine.sas defined N as the set of PS cases carrying at least one
  coded PT, and every PRR in Step 2 sits on it. A PRR computed here on a
  different denominator would not be comparable to one computed there, so the
  definition is rebuilt rather than approximated.

  Built as two DISTINCT sets and then joined, not as one DISTINCT over the
  DRUG x REAC join. The join alone is roughly 7M rows; two keyed sets of
  ~1.5M each and a merge is the same answer for a fraction of the work.
  ==========================================================================*/
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

/* A changed universe means CLEAN.DRUG or CLEAN.REAC was rebuilt, which makes
   every Step 2 number stale. That is a stop, not a warning. */
%macro assert_universe;
    %if &N_UNIVERSE ne 1529453 %then %do;
        %put ERROR: Analysis universe is &N_UNIVERSE, expected 1529453.;
        %put ERROR- 02_signal_engine.sas computed its PRRs on 1,529,453 cases.;
        %put ERROR- Re-run the engine before comparing anything against Step 2.;
        %abort cancel;
    %end;
    %put NOTE: Analysis universe N = %sysfunc(putn(&N_UNIVERSE, comma16.)) - matches the engine.;
%mend assert_universe;

%assert_universe

%_stamp(Section 2 - analysis universe built.)


/*==========================================================================
  3. PT TO CLASS-EFFECT GROUP MAP
  --------------------------------------------------------------------------
  Built from the DISTINCT PTs of CLEAN.REAC, not from CLEAN.REAC itself. The
  cross join is unavoidable - a prefix rule cannot be an equijoin - so it has
  to run against the ~20K distinct PTs rather than the ~7M reaction rows.

  It covers the whole database, not only the PTs GLP-1 cases reported,
  because a group's n_reac is a full-database count.
  ==========================================================================*/
proc sql;
    create table work._all_pt as
        select distinct pt from clean.reac where not missing(pt);

    create table work.pt_to_group as
        select      g.pt_group, g.group_label, p.pt
        from        work._all_pt      as p,
                    work.ref_pt_group as g
        where      (g.match_type = 'exact'
                    and upcase(strip(p.pt)) = upcase(strip(g.match_string)))
               or  (g.match_type = 'prefix'
                    and find(p.pt, strip(g.match_string), 'i') = 1);
quit;

proc datasets library=work nolist;
    delete _all_pt;
quit;

proc sql;
    create table work.group_map_qc as
        select      r.pt_group,
                    r.group_label,
                    count(m.pt) as n_pt_mapped
        from        (select distinct pt_group, group_label from work.ref_pt_group) as r
        left join   work.pt_to_group as m on r.pt_group = m.pt_group
        group by    r.pt_group, r.group_label
        order by    r.pt_group;
quit;

data _null_;
    set work.group_map_qc;
    if n_pt_mapped = 0 then
        put 'WARNING: group ' pt_group 'maps no PT in CLEAN.REAC - 00_ref_pt_group.sas and the extract disagree.';
    else put 'NOTE: group ' pt_group 'maps ' n_pt_mapped 'PT(s).';
run;

%_stamp(Section 3 - PT to group map built.)


/*==========================================================================
  4. THE 2x2 BUILDER
  --------------------------------------------------------------------------
  4a builds the two denominators once each, because they do not vary with the
  other axis: a molecule's cohort size is the same whether events are counted
  per PT or per group, and a PT's full-database total is the same whether the
  cohort is a molecule or a generation.

  4b assembles a, b, c, d at whichever grain it is asked for. Every count is
  COUNT(DISTINCT primaryid) - see the RULE note in the header.
  ==========================================================================*/

/* --- 4a. Denominators ---------------------------------------------------
   n_drug is restricted to the universe: CLEAN.GLP1_CASES holds cases with no
   coded reaction, and those belong to no 2x2 on either side. */
proc sql;
    create table work.ndrug_drug_label as
        select      c.drug_label as cohort length=20,
                    count(distinct c.primaryid) as n_drug
        from        clean.glp1_cases as c
        inner join  work.universe    as u on c.primaryid = u.primaryid
        group by    c.drug_label;

    create table work.ndrug_generation as
        select      c.generation as cohort length=20,
                    count(distinct c.primaryid) as n_drug
        from        clean.glp1_cases as c
        inner join  work.universe    as u on c.primaryid = u.primaryid
        group by    c.generation;

    create table work.nreac_pt as
        select      r.pt as event length=100,
                    count(distinct r.primaryid) as n_reac
        from        clean.reac    as r
        inner join  work.universe as u on r.primaryid = u.primaryid
        where       not missing(r.pt)
        group by    r.pt;

    /* COUNT(DISTINCT primaryid) over the group's member PTs, never a sum of
       their individual n_reac - a case reporting two members is one case. */
    create table work.nreac_pt_group as
        select      m.pt_group as event length=100,
                    count(distinct r.primaryid) as n_reac
        from        clean.reac        as r
        inner join  work.pt_to_group  as m on r.pt        = m.pt
        inner join  work.universe     as u on r.primaryid = u.primaryid
        group by    m.pt_group;
quit;

%_stamp(Section 4a - denominators built.)

/* --- 4b. The builder ----------------------------------------------------
   EVENT_TYPE is passed rather than derived. %substr(&event,1,2) returns 'PT'
   for both 'pt' and 'pt_group', which would merge the two grains silently. */
%macro build_2x2(cohort=, event=, event_type=, out=);
    %local evcol evjoin;

    %if %upcase(&event) = PT %then %do;
        %let evcol  = gr.pt;
        %let evjoin = ;
    %end;
    %else %do;
        %let evcol  = m.pt_group;
        %let evjoin = inner join work.pt_to_group as m on gr.pt = m.pt;
    %end;

    proc sql;
        create table work._a as
            select      gr.&cohort as cohort length=20,
                        &evcol     as event  length=100,
                        count(distinct gr.primaryid) as a
            from        clean.glp1_reac as gr
            inner join  work.universe   as u on gr.primaryid = u.primaryid
            &evjoin
            group by    gr.&cohort, &evcol;

        create table &out as
            select      "&cohort"     as cohort_type length=12,
                        ct.cohort,
                        "&event_type" as event_type  length=8,
                        ct.event,
                        ct.a,
                        nd.n_drug - ct.a                            as b,
                        nr.n_reac - ct.a                            as c,
                        &N_UNIVERSE - nd.n_drug - nr.n_reac + ct.a  as d,
                        nd.n_drug,
                        nr.n_reac
            /* aliased CT, not A: the cell-a column is also called A, and
               "a.a" is legal SQL that no reviewer should have to parse. */
            from        work._a               as ct
            inner join  work.ndrug_&cohort    as nd on ct.cohort = nd.cohort
            inner join  work.nreac_&event     as nr on ct.event  = nr.event;
    quit;

    %calc_prr(ds_in=&out, ds_out=&out);
    %calc_ror(ds_in=&out, ds_out=&out);

    data &out;
        set &out;
        length signal_flag signal_ror 8;
        signal_flag = (a >= &MIN_CASES
                       and PRR      >= &PRR_THRESHOLD
                       and PRR_CHI2 >= &CHI2_THRESHOLD);
        signal_ror  = (ROR_LCL > 1);
        label signal_flag = 'Evans signal (PRR)'
              signal_ror  = 'ROR signal (LCL > 1)';
    run;

    proc datasets library=work nolist; delete _a; quit;
%mend build_2x2;

%build_2x2(cohort=drug_label, event=pt,       event_type=PT,    out=work.base_drug_pt)
%build_2x2(cohort=drug_label, event=pt_group, event_type=GROUP, out=work.base_drug_grp)
%build_2x2(cohort=generation, event=pt,       event_type=PT,    out=work.base_gen_pt)
%build_2x2(cohort=generation, event=pt_group, event_type=GROUP, out=work.base_gen_grp)

data work.base_drug; set work.base_drug_pt work.base_drug_grp; run;
data work.base_gen;  set work.base_gen_pt  work.base_gen_grp;  run;
data work.base_all;  set work.base_drug    work.base_gen;      run;

/* The one failure mode of this design: a negative or missing cell means the
   cohort and the universe drifted apart, and it would surface downstream as
   quietly wrong PRRs rather than as an error. Same check as
   02_signal_engine.sas section 4c. */
%macro assert_cells;
    %global N_BADCELL;
    proc sql noprint;
        select count(*) into :N_BADCELL trimmed
            from work.base_all
            where nmiss(a, b, c, d) > 0 or min(a, b, c, d) < 0;
    quit;

    %if &N_BADCELL > 0 %then %do;
        %put ERROR: &N_BADCELL row(s) have a missing or negative 2x2 cell.;
        %put ERROR- The cohort, event and universe counts are not on one universe.;

        proc print data=work.base_all(obs=20) noobs;
            where nmiss(a, b, c, d) > 0 or min(a, b, c, d) < 0;
            var cohort_type cohort event_type event a b c d n_drug n_reac;
            title2 'ERROR - inconsistent 2x2 cells (first 20)';
        run;
        title2;
    %end;
    %else %put NOTE: 2x2 assertion passed - no missing or negative cells.;
%mend assert_cells;

%assert_cells

%_stamp(Section 4b - all four grains built.)


/*==========================================================================
  5. LAYER 1 - SEMAGLUTIDE vs TIRZEPATIDE
  --------------------------------------------------------------------------
  FULL JOIN, not INNER. A reaction that signals on one molecule and not the
  other is the finding; an inner join would delete exactly the rows worth
  reading.

  The join key carries EVENT_TYPE as well as EVENT so a PT can never be
  matched to a group of the same name.
  ==========================================================================*/
proc sql;
    create table work.compare_sema_tirz as
        select  coalesce(s.event_type, t.event_type) as event_type length=8,
                coalesce(s.event, t.event)           as event      length=100,

                s.a as sema_a,  s.PRR as sema_PRR,
                s.PRR_LCL as sema_PRR_LCL, s.PRR_UCL as sema_PRR_UCL,
                s.signal_flag as sema_signal,

                t.a as tirz_a,  t.PRR as tirz_PRR,
                t.PRR_LCL as tirz_PRR_LCL, t.PRR_UCL as tirz_PRR_UCL,
                t.signal_flag as tirz_signal,

                t.PRR - s.PRR as prr_diff label='TIRZ PRR minus SEMA PRR',

                /* Missing is tested before the ratio: a PT evaluable on one
                   molecule only would otherwise divide by a missing PRR and
                   land in whichever branch came last. */
                case when s.PRR is missing and t.PRR is missing
                         then 'Not evaluable'
                     when s.PRR is missing then 'Only TIRZ'
                     when t.PRR is missing then 'Only SEMA'
                     when abs(t.PRR - s.PRR) / max(s.PRR, t.PRR) <= 0.20
                         then 'Similar'
                     when t.PRR > s.PRR then 'TIRZ higher'
                     else 'SEMA higher'
                end as direction length=13,

                /* Disjoint 95% intervals. Reported, never used to filter -
                   an overlap is evidence of no difference, not missing
                   evidence. */
                case when nmiss(s.PRR_LCL, s.PRR_UCL, t.PRR_LCL, t.PRR_UCL) > 0
                         then .
                     else (s.PRR_LCL <= t.PRR_UCL and t.PRR_LCL <= s.PRR_UCL)
                end as ci_overlap
                    label='95% CIs overlap (0 = disjoint)'

        from        (select * from work.base_drug where cohort = "&DRUG_SEMA") as s
        full join   (select * from work.base_drug where cohort = "&DRUG_TIRZ") as t
               on   s.event_type = t.event_type and s.event = t.event
        where       coalesce(s.signal_flag, 0) = 1
               or   coalesce(t.signal_flag, 0) = 1
        order by    calculated event_type,
                    coalesce(s.a, 0) + coalesce(t.a, 0) desc;
quit;

%_stamp(Section 5 - Layer 1 built.)


/*==========================================================================
  6. LAYER 2 - NEWER vs OLDER GENERATION
  --------------------------------------------------------------------------
  The pooled cohorts come from %build_2x2(cohort=generation), which counts
  DISTINCT primaryid. A case naming both SEMAGLUTIDE and TIRZEPATIDE is one
  newer-generation case, which is precisely what adding the two molecules'
  cell a would have got wrong.

  'newer' and 'comparator' are the generation values in REF_GLP1_DRUG.
  ==========================================================================*/
proc sql;
    create table work.compare_generation as
        select  coalesce(n.event_type, o.event_type) as event_type length=8,
                coalesce(n.event, o.event)           as event      length=100,

                n.a as newer_a, n.PRR as newer_PRR,
                n.PRR_LCL as newer_PRR_LCL, n.PRR_UCL as newer_PRR_UCL,
                n.signal_flag as newer_signal,

                o.a as older_a, o.PRR as older_PRR,
                o.PRR_LCL as older_PRR_LCL, o.PRR_UCL as older_PRR_UCL,
                o.signal_flag as older_signal,

                case when o.PRR > 0 and n.PRR is not missing
                         then n.PRR / o.PRR
                     else . end as prr_ratio
                    label='Newer PRR / older PRR',

                case when nmiss(n.PRR_LCL, n.PRR_UCL, o.PRR_LCL, o.PRR_UCL) > 0
                         then .
                     else (n.PRR_LCL <= o.PRR_UCL and o.PRR_LCL <= n.PRR_UCL)
                end as ci_overlap
                    label='95% CIs overlap (0 = disjoint)',

                case when n.signal_flag = 1 and coalesce(o.signal_flag, 0) = 0
                         then 'NEWER ONLY'
                     when coalesce(n.signal_flag, 0) = 0 and o.signal_flag = 1
                         then 'OLDER ONLY'
                     when n.signal_flag = 1 and o.signal_flag = 1
                          and calculated prr_ratio > 1.5   then 'NEWER HIGHER'
                     when n.signal_flag = 1 and o.signal_flag = 1
                          and calculated prr_ratio < 0.67  then 'OLDER HIGHER'
                     when n.signal_flag = 1 and o.signal_flag = 1
                         then 'SIMILAR'
                     else ''
                end as flag length=14

        from        (select * from work.base_gen where cohort = 'newer')      as n
        full join   (select * from work.base_gen where cohort = 'comparator') as o
               on   n.event_type = o.event_type and n.event = o.event
        where       coalesce(n.signal_flag, 0) = 1
               or   coalesce(o.signal_flag, 0) = 1
        order by    calculated event_type,
                    coalesce(n.a, 0) + coalesce(o.a, 0) desc;
quit;

%_stamp(Section 6 - Layer 2 built.)


/*==========================================================================
  7. LAYER 3 - FOUR-MOLECULE OVERVIEW
  --------------------------------------------------------------------------
  n_drugs_signal is COUNT(DISTINCT cohort), not SUM(signal_flag). The base
  table holds one row per cohort per event, so the two would agree here - but
  the distinct count is what makes the column mean "how many molecules", and
  it is what the section 8 assertion can then check against a hard range of
  1 to 4.
  ==========================================================================*/
proc sql;
    create table work.compare_overview as
        select      event_type,
                    event,
                    max(case when cohort = "&DRUG_SEMA" then a   end) as sema_a,
                    max(case when cohort = "&DRUG_SEMA" then PRR end) as sema_PRR,
                    max(case when cohort = "&DRUG_TIRZ" then a   end) as tirz_a,
                    max(case when cohort = "&DRUG_TIRZ" then PRR end) as tirz_PRR,
                    max(case when cohort = "&DRUG_DULA" then a   end) as dula_a,
                    max(case when cohort = "&DRUG_DULA" then PRR end) as dula_PRR,
                    max(case when cohort = "&DRUG_LIRA" then a   end) as lira_a,
                    max(case when cohort = "&DRUG_LIRA" then PRR end) as lira_PRR,
                    count(distinct case when signal_flag = 1 then cohort end)
                        as n_drugs_signal label='Molecules flagging this event'
        from        work.base_drug
        group by    event_type, event
        having      calculated n_drugs_signal >= 1
        order by    event_type,
                    calculated n_drugs_signal desc,
                    calculated sema_a desc;
quit;

%_stamp(Section 7 - Layer 3 built.)


/*==========================================================================
  8. QC, SAVE AND WRAP UP
  ==========================================================================*/

/* Reconciliation against Step 2. Deliberately NOT an equality test: Step 2
   computed SEMAGLUTIDE x Pancreatitis at prod_ai grain on 35,651 cases,
   while this program works at drug_label grain and so includes the
   compounded variants - 35,705 cases. The two must be close; they cannot be
   identical, and a gate demanding equality would fail on correct output. */
%let RECON_OK = 1;

%macro reconcile;
    %global N_RECON_OOT;
    %let N_RECON_OOT = 0;

    /* The shell is created before the early return, not after it. The QC
       DATA step in this section SETs WORK.RECON unconditionally, and a
       skipped reconciliation must leave it empty rather than absent. */
    data work.recon;
        length drug_label $20 step2_prr 8 step3_prr 8 pct_diff 8;
        format pct_diff 8.2;
        stop;
    run;

    %if %sysfunc(exist(signal.glp1_signals)) = 0 %then %do;
        %put WARNING: Step 2 reconciliation skipped - SIGNAL.GLP1_SIGNALS not found.;
        %let RECON_OK = 0;
        %return;
    %end;

    proc sql;
        create table work.recon as
            select      b.cohort as drug_label length=20,
                        s.PRR as step2_prr,
                        b.PRR as step3_prr,
                        100 * (b.PRR - s.PRR) / s.PRR as pct_diff format=8.2
            from        (select cohort, PRR from work.base_drug_pt
                         where upcase(strip(event)) = 'PANCREATITIS') as b
            inner join  (select drug_label, PRR from signal.glp1_signals
                         where single_ingredient = 1
                           and upcase(strip(pt)) = 'PANCREATITIS')    as s
                   on   b.cohort = s.drug_label
            order by    b.cohort;
    quit;

    proc sql noprint;
        select count(*) into :N_RECON_OOT trimmed
            from work.recon where abs(pct_diff) > 5;
    quit;

    data _null_;
        set work.recon;
        length msg $200;
        msg = catx(' ', strip(drug_label), 'x Pancreatitis - Step 2 (prod_ai)',
                        strip(put(step2_prr, 10.4)), 'vs Step 3 (drug_label)',
                        strip(put(step3_prr, 10.4)),
                        cats('(', strip(put(pct_diff, 8.2)), '%)'));
        if abs(pct_diff) > 5 then put 'WARNING: ' msg ' - outside the 5% band.';
        else                      put 'NOTE: '    msg ' - reconciles.';
    run;
%mend reconcile;

%reconcile

proc sql noprint;
    select count(*) into :N_BASE  trimmed from work.base_all;
    select count(*) into :N_L1    trimmed from work.compare_sema_tirz;
    select count(*) into :N_L2    trimmed from work.compare_generation;
    select count(*) into :N_L3    trimmed from work.compare_overview;

    select count(*) into :N_GRP_BASE trimmed
        from work.base_all where event_type = 'GROUP';

    /* Layer 1 */
    select count(*) into :N_L1_BOTH trimmed from work.compare_sema_tirz
        where sema_signal = 1 and tirz_signal = 1;
    select count(*) into :N_L1_SEMA trimmed from work.compare_sema_tirz
        where sema_signal = 1 and coalesce(tirz_signal, 0) = 0;
    select count(*) into :N_L1_TIRZ trimmed from work.compare_sema_tirz
        where coalesce(sema_signal, 0) = 0 and tirz_signal = 1;
    select count(*) into :N_L1_DISJ trimmed from work.compare_sema_tirz
        where ci_overlap = 0;

    /* Layer 2 */
    select count(*) into :N_L2_NEWONLY trimmed from work.compare_generation where flag = 'NEWER ONLY';
    select count(*) into :N_L2_OLDONLY trimmed from work.compare_generation where flag = 'OLDER ONLY';
    select count(*) into :N_L2_NEWHI   trimmed from work.compare_generation where flag = 'NEWER HIGHER';
    select count(*) into :N_L2_OLDHI   trimmed from work.compare_generation where flag = 'OLDER HIGHER';
    select count(*) into :N_L2_SIM     trimmed from work.compare_generation where flag = 'SIMILAR';
    select count(*) into :N_L2_DISJ    trimmed from work.compare_generation where ci_overlap = 0;

    /* Layer 3 */
    select count(*) into :N_L3_4 trimmed from work.compare_overview where n_drugs_signal = 4;
    select count(*) into :N_L3_3 trimmed from work.compare_overview where n_drugs_signal = 3;
    select count(*) into :N_L3_2 trimmed from work.compare_overview where n_drugs_signal = 2;
    select count(*) into :N_L3_1 trimmed from work.compare_overview where n_drugs_signal = 1;
    select count(*) into :N_L3_BAD trimmed from work.compare_overview
        where n_drugs_signal < 1 or n_drugs_signal > 4;
quit;

data work.qc_drug_compare;
    length metric $60 value 8 note $90;

    metric = 'Analysis universe N';
    value  = &N_UNIVERSE;
    note   = 'Must equal 1,529,453 - the engine universe';           output;

    metric = 'Rows with a missing or negative 2x2 cell';
    value  = &N_BADCELL;
    note   = 'Must be 0';                                            output;

    metric = 'Layer 3 n_drugs_signal out of range';
    value  = &N_L3_BAD;
    note   = 'Must be 0 - the range is 1 to 4';                      output;

    metric = 'Base rows (all four grains)';
    value  = &N_BASE;
    note   = 'Rows in SIGNAL.GLP1_BASE_SIGNALS';                     output;

    metric = 'Base rows at GROUP grain';
    value  = &N_GRP_BASE;
    note   = 'Class-effect rows - never additive with PT rows';      output;

    /* Step 2 reconciliation, per molecule */
    do until (_eof1);
        set work.recon end=_eof1;
        metric = '  ' || strip(drug_label) || ' x Pancreatitis PRR';
        value  = step3_prr;
        note   = catx(' ', 'Step 2 prod_ai grain', strip(put(step2_prr, 10.4)),
                           '- difference', strip(put(pct_diff, 8.2)), '%');
        output;
    end;

    metric = 'Layer 1 rows';
    value  = &N_L1;
    note   = 'Evans signal on SEMA or TIRZ, both grains';            output;

    metric = '  signalling on both molecules';
    value  = &N_L1_BOTH;
    note   = 'Shared signals';                                       output;

    metric = '  SEMAGLUTIDE only';
    value  = &N_L1_SEMA;
    note   = 'Evans on SEMA, not on TIRZ';                           output;

    metric = '  TIRZEPATIDE only';
    value  = &N_L1_TIRZ;
    note   = 'Evans on TIRZ, not on SEMA';                           output;

    metric = '  with disjoint 95% CIs';
    value  = &N_L1_DISJ;
    note   = 'ci_overlap=0 - the defensible difference subset';      output;

    metric = 'Layer 2 rows';
    value  = &N_L2;
    note   = 'Evans signal on either generation, both grains';       output;

    metric = '  NEWER ONLY';
    value  = &N_L2_NEWONLY;
    note   = 'Signals in SEMA+TIRZ and not in DULA+LIRA';            output;

    metric = '  OLDER ONLY';
    value  = &N_L2_OLDONLY;
    note   = 'Signals in DULA+LIRA and not in SEMA+TIRZ';            output;

    metric = '  NEWER HIGHER / OLDER HIGHER';
    value  = &N_L2_NEWHI + &N_L2_OLDHI;
    note   = catx(' ', 'ratio >1.5:', "&N_L2_NEWHI", '- ratio <0.67:', "&N_L2_OLDHI"); output;

    metric = '  SIMILAR';
    value  = &N_L2_SIM;
    note   = 'Both signal, ratio between 0.67 and 1.5';              output;

    metric = '  with disjoint 95% CIs';
    value  = &N_L2_DISJ;
    note   = 'ci_overlap=0 - the defensible difference subset';      output;

    metric = 'Layer 3 events flagged by 4 molecules';
    value  = &N_L3_4;
    note   = 'Class-wide - the strongest consistency evidence';      output;

    metric = '  by 3 / 2 / 1 molecule(s)';
    value  = &N_L3_3 + &N_L3_2 + &N_L3_1;
    note   = catx(' ', '3:', "&N_L3_3", '- 2:', "&N_L3_2", '- 1:', "&N_L3_1"); output;

    stop;
    label metric = 'Metric' value = 'Value' note = 'Note';
    keep  metric value note;
run;

%macro compare_verdict;
    %if &N_BADCELL = 0 and &N_L3_BAD = 0 %then
        %put NOTE: Structural assertions passed - cells consistent, n_drugs_signal in range.;
    %else %do;
        %if &N_BADCELL > 0 %then %put ERROR: &N_BADCELL row(s) with an inconsistent 2x2 cell.;
        %if &N_L3_BAD  > 0 %then %put ERROR: &N_L3_BAD Layer 3 row(s) with n_drugs_signal outside 1-4.;
    %end;

    %if &RECON_OK = 1 %then %do;
        %if &N_RECON_OOT = 0 %then
            %put NOTE: Step 2 reconciliation passed - all four molecules within 5%%.;
        %else %do;
            %put WARNING: &N_RECON_OOT molecule(s) more than 5%% from the Step 2 PRR.;
            %put WARNING- Expected a small gap: Step 2 is prod_ai grain, this is drug_label.;
            %put WARNING- A large one means the cohorts differ, not just the grain.;
        %end;
    %end;
%mend compare_verdict;

%compare_verdict

title2 'Table 1: Class-effect group coverage';
proc print data=work.group_map_qc noobs label;
    var pt_group group_label n_pt_mapped;
    label pt_group = 'Group' group_label = 'Label' n_pt_mapped = 'PTs mapped';
run;

title2 'Table 2: Drug comparison QC';
proc print data=work.qc_drug_compare noobs label;
    format value comma14.4;
run;

title2 'Table 3: Layer 2 at GROUP grain - the class-effect comparison';
proc print data=work.compare_generation noobs label;
    where event_type = 'GROUP';
    var event newer_a newer_PRR older_a older_PRR prr_ratio ci_overlap flag;
    format newer_a older_a comma10. newer_PRR older_PRR prr_ratio 10.2;
    label event = 'Class effect' newer_a = 'Newer cases' older_a = 'Older cases'
          newer_PRR = 'Newer PRR' older_PRR = 'Older PRR' prr_ratio = 'Ratio'
          ci_overlap = 'CI overlap' flag = 'Flag';
run;

title2 'Table 4: Layer 1 at GROUP grain - SEMA vs TIRZ';
proc print data=work.compare_sema_tirz noobs label;
    where event_type = 'GROUP';
    var event sema_a sema_PRR tirz_a tirz_PRR prr_diff ci_overlap direction;
    format sema_a tirz_a comma10. sema_PRR tirz_PRR prr_diff 10.2;
    label event = 'Class effect' sema_a = 'SEMA cases' tirz_a = 'TIRZ cases'
          sema_PRR = 'SEMA PRR' tirz_PRR = 'TIRZ PRR' prr_diff = 'Difference'
          ci_overlap = 'CI overlap' direction = 'Direction';
run;
title2;

/* --- Save ------------------------------------------------------------- */
data signal.glp1_base_signals (compress=yes
        label='GLP-1 2x2 rebuilt from cases - 4 grains, PT and class-effect group');
    length cohort_type $12 cohort $20 event_type $8 event $100;
    set work.base_all;
run;

data signal.glp1_compare_sema_tirz (compress=yes
        label='Layer 1 - SEMAGLUTIDE vs TIRZEPATIDE');
    length event_type $8 event $100;
    set work.compare_sema_tirz;
run;

data signal.glp1_compare_generation (compress=yes
        label='Layer 2 - newer vs older GLP-1 generation');
    length event_type $8 event $100;
    set work.compare_generation;
run;

data signal.glp1_compare_overview (compress=yes
        label='Layer 3 - four-molecule overview');
    length event_type $8 event $100;
    set work.compare_overview;
run;

proc export data=work.base_all
            outfile="&OUT_TABLES./glp1_base_signals.csv" dbms=csv replace;
run;
proc export data=work.compare_sema_tirz
            outfile="&OUT_TABLES./glp1_compare_sema_tirz.csv" dbms=csv replace;
run;
proc export data=work.compare_generation
            outfile="&OUT_TABLES./glp1_compare_generation.csv" dbms=csv replace;
run;
proc export data=work.compare_overview
            outfile="&OUT_TABLES./glp1_compare_overview.csv" dbms=csv replace;
run;
proc export data=work.qc_drug_compare
            outfile="&OUT_QC./qc_glp1_drug_compare.csv" dbms=csv replace;
run;

%macro finish;
    %local e;
    %let e = %sysevalf(%sysfunc(datetime()) - &_T0);

    %put NOTE: ============================================;
    %put NOTE: 03_glp1_drug_compare.sas complete.;
    %put NOTE: Universe N        = &N_UNIVERSE;
    %put NOTE: Base rows         = &N_BASE (&N_GRP_BASE at GROUP grain);
    %put NOTE: Layer 1 rows      = &N_L1 (both: &N_L1_BOTH, SEMA only: &N_L1_SEMA, TIRZ only: &N_L1_TIRZ);
    %put NOTE: Layer 2 rows      = &N_L2 (NEWER ONLY: &N_L2_NEWONLY, OLDER ONLY: &N_L2_OLDONLY);
    %put NOTE: Layer 3 rows      = &N_L3 (all four molecules: &N_L3_4);
    %put NOTE: Disjoint CIs      = &N_L1_DISJ (Layer 1) / &N_L2_DISJ (Layer 2);
    %put NOTE: Datasets          = SIGNAL.GLP1_BASE_SIGNALS + 3 comparison tables;
    %put NOTE: QC                = &OUT_QC./qc_glp1_drug_compare.csv;
    %put NOTE: Elapsed           = %sysfunc(putn(&e, time12.2));
    %put NOTE: ============================================;

    %if &N_BADCELL = 0 and &N_L3_BAD = 0
        and &RECON_OK = 1 and &N_RECON_OOT = 0 %then
        %put NOTE: GLP-1 DRUG COMPARISON PASSED - ready for Phase 3 Step 4.;
    %else %if &RECON_OK = 0 %then
        %put WARNING: Structural checks passed but the Step 2 reconciliation never ran.;
    %else
        %put WARNING: GLP-1 DRUG COMPARISON needs review - see the warnings above.;
%mend finish;

%finish

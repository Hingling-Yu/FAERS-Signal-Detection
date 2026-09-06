/*****************************************************************************
 * 03_glp1_subgroup.sas - GLP-1 stratified signal detection
 *
 * Purpose:  Phase 3 Step 4. Compute disproportionality within demographic
 *           strata for SEMAGLUTIDE and TIRZEPATIDE, and identify reactions
 *           whose signal strength depends on age. Every estimate is reported
 *           beside the fraction of cases it was actually computed on.
 *
 * Inputs:   CLEAN.GLP1_CASES     Step 1 cohort, carries age_grp, sex, country
 *           CLEAN.GLP1_REAC      Step 1 reactions, primaryid x drug x pt
 *           CLEAN.DEMO           full FAERS demographics, for the strata
 *           CLEAN.DRUG           full FAERS, for the universe
 *           CLEAN.REAC           full FAERS, for subgroup c, d and N
 *           WORK.REF_PT_GROUP    class-effect groups, 00_ref_pt_group.sas
 *
 * Outputs:  SIGNAL.GLP1_SUBGROUP_AGE / _SEX / _COUNTRY
 *           SIGNAL.GLP1_AGE_DEPENDENT
 *           &OUT_TABLES/glp1_subgroup_{age,sex,country}.csv
 *           &OUT_TABLES/glp1_age_dependent.csv
 *           &OUT_QC/qc_glp1_subgroup.csv
 *
 * -----------------------------------------------------------------------
 * THE COVERAGE PROBLEM - WHY THIS PROGRAM REPORTS ITS OWN LIMITS
 * -----------------------------------------------------------------------
 * A subgroup PRR can only be computed on cases that carry a value for the
 * stratifying variable. A case with no recorded age belongs to no age
 * stratum and contributes to none of a, b, c or d. That is unavoidable, and
 * it is not the problem. The problem is that the surviving fraction differs
 * by molecule:
 *
 *     TIRZEPATIDE   66.0% of cases have a usable age
 *     SEMAGLUTIDE   50.6%
 *
 * Fifteen points apart, so restricting each arm to age-known cases does not
 * remove the same kind of case from both. Sex runs the other way -
 * SEMAGLUTIDE 86.0%, TIRZEPATIDE 75.9% - which rules out "one molecule just
 * has better data" as an explanation and makes it a per-dimension property.
 *
 * Three guardrails follow, and none of them filter anything out:
 *
 *   COVERAGE_PCT      every output row carries its molecule's coverage for
 *                     that dimension, so no estimate can be read without it.
 *
 *   PT_AGE_COVERAGE   the same rate computed for the specific event, with
 *                     COVERAGE_DELTA against the molecule's baseline. An
 *                     event whose age-recording rate is far from baseline is
 *                     stratified on a selected subset of its own cases, and
 *                     COVERAGE_FLAG says so.
 *
 *   Within-molecule   AGE_PATTERN compares age strata inside one molecule.
 *   reading only      SEMAGLUTIDE's elderly-concentrated list and
 *                     TIRZEPATIDE's rest on 50.6% and 66.0% of their
 *                     cohorts; counting them against each other measures
 *                     which molecule records age more often. See note 12 of
 *                     the spec, and the SORT in section 6.
 *
 * -----------------------------------------------------------------------
 * CLINICAL AE vs MEDICATION ERROR
 * -----------------------------------------------------------------------
 * Off-label weight-loss use is concentrated in younger patients, so PTs like
 * 'Off label use' (3,863 cases) and 'Product use in unapproved indication'
 * (1,714) are youth-concentrated by construction and would fill the headline
 * table. PT_CATEGORY splits them out. They are reported, in their own table,
 * because the age skew is a real finding about how these drugs are used -
 * just not a finding about their safety.
 *
 * The PT list lives in section 2 of this program rather than in
 * 00_config.sas: no other step uses it, and a list that travels with its
 * only consumer cannot drift out of step with it.
 *
 * -----------------------------------------------------------------------
 * TWO GRAINS, AS IN STEP 3
 * -----------------------------------------------------------------------
 * Every output carries EVENT_TYPE ('PT' or 'GROUP') and EVENT. A group's
 * cases are also counted in its member PTs, so the two grains are never
 * additive and every consumer filters EVENT_TYPE first. The group grain
 * exists because the fragmentation Step 3 measured applies here too: an age
 * pattern split across five pancreatitis PTs surfaces at none of them.
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

/* DULAGLUTIDE (4,028 cases) and LIRAGLUTIDE (1,830) are excluded: split
   three ways by age they leave cells too thin for a stable PRR. */
%let SUBGROUP_DRUGS = SEMAGLUTIDE TIRZEPATIDE;

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

title "Phase 3 Step 4 - GLP-1 Subgroup Analysis";

/* The drug list as a quoted, comma-separated IN clause. Built once here
   rather than expanded inline at each use: the same %do loop written five
   times is five places for it to drift. */
%macro drug_in_list;
    %local i n;
    %let n = %sysfunc(countw(&SUBGROUP_DRUGS));
    %do i = 1 %to &n;
        "%scan(&SUBGROUP_DRUGS, &i, %str( ))"
        %if &i < &n %then ,;
    %end;
%mend drug_in_list;

%macro require_inputs;
    %local i tbl missing;
    %let missing = 0;

    /* %SCAN needs the explicit blank delimiter: its default list includes
       the period, which would split CLEAN.GLP1_CASES in two. */
    %do i = 1 %to 6;
        %let tbl = %scan(clean.glp1_cases clean.glp1_reac clean.demo clean.drug
                         clean.reac work.ref_pt_group, &i, %str( ));
        %if %sysfunc(exist(&tbl)) = 0 %then %do;
            %put ERROR: &tbl does not exist.;
            %let missing = %eval(&missing + 1);
        %end;
    %end;

    %if &missing > 0 %then %do;
        %put ERROR- Run 01_import_clean.sas and 03_glp1_extract.sas, and upload;
        %put ERROR- 00_ref_pt_group.sas to &SAS_PATH, before this program.;
        %abort cancel;
    %end;
%mend require_inputs;

%require_inputs

%_stamp(03_glp1_subgroup.sas started.)


/*==========================================================================
  2. ANALYSIS UNIVERSE, PT GROUP MAP, MEDICATION ERROR LIST
  ==========================================================================*/

/* Universe - identical to Steps 2 and 3. Built as two DISTINCT sets and
   joined rather than one DISTINCT over the 7M-row DRUG x REAC join. */
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
    %if &N_UNIVERSE ne 1529453 %then %do;
        %put ERROR: Analysis universe is &N_UNIVERSE, expected 1529453.;
        %put ERROR- Steps 2 and 3 computed their PRRs on 1,529,453 cases.;
        %put ERROR- A subgroup PRR on a different universe is not comparable to them.;
        %abort cancel;
    %end;
    %put NOTE: Analysis universe N = %sysfunc(putn(&N_UNIVERSE, comma16.)) - matches Steps 2 and 3.;
%mend assert_universe;

%assert_universe

/* PT to class-effect group. Built from the DISTINCT PTs of CLEAN.REAC, not
   from CLEAN.REAC itself: a prefix rule cannot be an equijoin, so the cross
   join has to run against ~17K distinct PTs and not ~7M reaction rows. */
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

/* Medication error and product-use PTs. Kept here rather than in
   00_config.sas because Step 4 is the only consumer: a list that travels
   with its only consumer cannot drift out of step with it.

   The FIND catch-all in section 6 covers every PT beginning 'Medication
   error', so those variants are deliberately not enumerated. */
data work.ref_med_error_pts;
    length pt $100;
    infile datalines truncover;
    input pt $char100.;
    datalines;
Off label use
Product use in unapproved indication
Incorrect dose administered
Accidental underdose
Drug use for unknown indication
Intentional product misuse
Product dose omission
Wrong technique in product usage process
Accidental overdose
Intentional overdose
Prescribed overdose
Product administered to patient of inappropriate age
;
run;

%_stamp(Section 2 - universe, PT group map and medication error list built.)


/*==========================================================================
  3. COVERAGE - MEASURED BEFORE ANYTHING IS ESTIMATED
  --------------------------------------------------------------------------
  Restricted to the universe, because that is the population every subgroup
  PRR below is computed on. A coverage rate quoted over a wider set than the
  analysis uses would be the wrong baseline for the section 6 bias probe.

  COUNT(DISTINCT ...) rather than SUM(CASE ...): GLP1_CASES is one row per
  primaryid x drug_label, so the two agree here, but the distinct count stays
  correct if that grain ever changes.
  ==========================================================================*/
proc sql;
    create table work.coverage as
        select      c.drug_label,
                    count(distinct c.primaryid) as n_total,

                    count(distinct case when c.age_grp not in ('Unknown', '')
                                         and not missing(c.age_grp)
                                        then c.primaryid end) as n_age_known,
                    count(distinct case when c.sex in ('M', 'F')
                                        then c.primaryid end) as n_sex_known,
                    count(distinct case when c.reporter_country = 'US'
                                        then c.primaryid end) as n_us,

                    calculated n_age_known / calculated n_total as pct_age_known format=percent8.1,
                    calculated n_sex_known / calculated n_total as pct_sex_known format=percent8.1,
                    calculated n_us        / calculated n_total as pct_us        format=percent8.1
        from        clean.glp1_cases as c
        inner join  work.universe    as u on c.primaryid = u.primaryid
        where       c.drug_label in (%drug_in_list)
        group by    c.drug_label;
quit;

title2 'Table 1: Demographic coverage - READ BEFORE INTERPRETING ANY SUBGROUP PRR';
proc print data=work.coverage noobs label;
    var drug_label n_total n_age_known pct_age_known
        n_sex_known pct_sex_known n_us pct_us;
    format n_total n_age_known n_sex_known n_us comma10.;
    label drug_label    = 'Molecule'      n_total       = 'Cases'
          n_age_known   = 'Age known'     pct_age_known = 'Age coverage'
          n_sex_known   = 'Sex known'     pct_sex_known = 'Sex coverage'
          n_us          = 'US reports'    pct_us        = 'US share';
run;
title2;

%_stamp(Section 3 - coverage measured.)


/*==========================================================================
  4. THE STRATIFIED 2x2 BUILDER
  --------------------------------------------------------------------------
  4a builds three reference tables ONCE. The alternative - deriving the
  stratification inside the macro - would repeat a CASE expression six times
  and give six chances for the GLP-1 side and the full-FAERS side to disagree
  about what '46-64' means.

  The age cut points come from 00_config.sas (&AGE_CUT1, &AGE_CUT2), the same
  numbers behind the AGEGRPF format that 03_glp1_extract.sas used to derive
  age_grp on the GLP-1 side. A CASE expression rather than PUT(age, agegrpf.):
  PUT returns 5 characters, PROC SQL takes a CASE result's length from its
  first branch, and 'Unknown' would arrive as 'Unkno'.
  ==========================================================================*/

/* --- 4a. Reference tables, built once ---------------------------------- */
proc sql;
    /* Full-FAERS demographics carrying all three strata, universe only.
       A missing reporter_country lands in 'Non-US' - stated rather than
       hidden, since it makes the US share a floor and not an estimate. */
    create table work.demo_strat as
        select      u.primaryid,
                    case when d.age_cod = 'YR' and not missing(d.age) then
                              case when d.age <= &AGE_CUT1 then '<=45'
                                   when d.age <= &AGE_CUT2 then '46-64'
                                   else '>=65' end
                         else 'Unknown'
                    end as age_grp     length=10,
                    case when d.sex in ('M', 'F') then d.sex
                         else 'Unknown'
                    end as sex         length=10,
                    case when d.reporter_country = 'US' then 'US'
                         else 'Non-US'
                    end as country_grp length=10
        from        work.universe as u
        inner join  clean.demo    as d on u.primaryid = d.primaryid;

    /* GLP-1 cases for the two analysed molecules, universe only. age_grp
       arrives already derived from Step 1 at length=10; only country_grp
       has to be built. */
    create table work.sub_cases as
        select      c.primaryid,
                    c.drug_label,
                    c.age_grp,
                    case when c.sex in ('M', 'F') then c.sex
                         else 'Unknown'
                    end as sex         length=10,
                    case when c.reporter_country = 'US' then 'US'
                         else 'Non-US'
                    end as country_grp length=10
        from        clean.glp1_cases as c
        inner join  work.universe    as u on c.primaryid = u.primaryid
        where       c.drug_label in (%drug_in_list);

    create table work.sub_reac as
        select      r.primaryid, r.drug_label, r.pt
        from        clean.glp1_reac as r
        inner join  work.universe   as u on r.primaryid = u.primaryid
        where       r.drug_label in (%drug_in_list);
quit;

%_stamp(Section 4a - stratified reference tables built.)

/* --- 4b. The builder ---------------------------------------------------
   EVENT_TYPE is passed rather than derived: %substr(&event,1,2) returns 'PT'
   for both 'pt' and 'pt_group' and would merge the two grains silently.

   The event column and its join are held in macro variables rather than
   written as %IF branches inside the SELECT. A %THEN carrying a bare column
   name into a GROUP BY has to be terminated by a semicolon that also ends
   the %IF, which is a construction that reads as if it works and does not.
   Same shape as %build_2x2 in 03_glp1_drug_compare.sas.
   ------------------------------------------------------------------------*/
%macro build_subgroup_2x2(strat_var=, strat_name=, event=, event_type=, out=);
    %local evcol_a evcol_r evjoin_a evjoin_r covcol bad_cells nrows;

    %if %upcase(&event) = PT %then %do;
        %let evcol_a  = sr.pt;
        %let evcol_r  = r.pt;
        %let evjoin_a = ;
        %let evjoin_r = ;
    %end;
    %else %do;
        %let evcol_a  = m.pt_group;
        %let evcol_r  = m.pt_group;
        %let evjoin_a = inner join work.pt_to_group as m on sr.pt = m.pt;
        %let evjoin_r = inner join work.pt_to_group as m on r.pt  = m.pt;
    %end;

    /* Which coverage column belongs to this dimension. */
    %if %upcase(&strat_var) = AGE_GRP   %then %let covcol = pct_age_known;
    %else %if %upcase(&strat_var) = SEX %then %let covcol = pct_sex_known;
    %else                                     %let covcol = pct_us;

    %put NOTE: Building subgroup 2x2 - &strat_name x &event_type;

    proc sql;
        /* a - cases on this molecule, in this stratum, reporting this event */
        create table work._sg_a as
            select      sc.drug_label,
                        sc.&strat_var as stratum length=10,
                        &evcol_a      as event   length=100,
                        count(distinct sr.primaryid) as a
            from        work.sub_reac  as sr
            inner join  work.sub_cases as sc
                   on   sr.primaryid  = sc.primaryid
                  and   sr.drug_label = sc.drug_label
            &evjoin_a
            where       sc.&strat_var not in ('Unknown', '')
            group by    sc.drug_label, sc.&strat_var, &evcol_a;

        /* n_drug - the molecule's cohort size within the stratum */
        create table work._sg_ndrug as
            select      drug_label,
                        &strat_var as stratum length=10,
                        count(distinct primaryid) as n_drug
            from        work.sub_cases
            where       &strat_var not in ('Unknown', '')
            group by    drug_label, &strat_var;

        /* n_reac - FULL-DATABASE cases in the stratum reporting this event.
           COUNT(DISTINCT), never a sum over a group's member PTs: a case
           reporting two members of one group is one case. */
        create table work._sg_nreac as
            select      ds.&strat_var as stratum length=10,
                        &evcol_r      as event   length=100,
                        count(distinct r.primaryid) as n_reac
            from        clean.reac      as r
            inner join  work.demo_strat as ds on r.primaryid = ds.primaryid
            &evjoin_r
            where       ds.&strat_var not in ('Unknown', '')
                  and   not missing(r.pt)
            group by    ds.&strat_var, &evcol_r;

        /* N - the stratum's own universe. This is what makes the estimate a
           stratified PRR rather than a filtered one. */
        create table work._sg_ntotal as
            select      &strat_var as stratum length=10,
                        count(distinct primaryid) as N_stratum
            from        work.demo_strat
            where       &strat_var not in ('Unknown', '')
            group by    &strat_var;

        create table &out as
            select      "&strat_name" as strat_name length=20,
                        ct.stratum,
                        "&event_type" as event_type length=8,
                        ct.event,
                        ct.drug_label,
                        ct.a,
                        nd.n_drug - ct.a                              as b,
                        nr.n_reac - ct.a                              as c,
                        nt.N_stratum - nd.n_drug - nr.n_reac + ct.a   as d,
                        nd.n_drug,
                        nr.n_reac,
                        nt.N_stratum as N,
                        cv.&covcol   as coverage_pct format=percent8.1
                            label="Share of the molecule's cases with a known &strat_name"
            /* aliased CT: the cell-a column is also called A, and "a.a" is
               legal SQL that no reviewer should have to parse. */
            from        work._sg_a       as ct
            inner join  work._sg_ndrug   as nd on ct.drug_label = nd.drug_label
                                              and ct.stratum    = nd.stratum
            inner join  work._sg_nreac   as nr on ct.stratum    = nr.stratum
                                              and ct.event      = nr.event
            inner join  work._sg_ntotal  as nt on ct.stratum    = nt.stratum
            inner join  work.coverage    as cv on ct.drug_label = cv.drug_label
            where       ct.a >= &MIN_CASES;
    quit;

    /* The one failure mode of this design: a negative or missing cell means
       the molecule, the stratum and the universe are not counting the same
       people. It would surface downstream as quietly wrong PRRs. */
    proc sql noprint;
        select count(*) into :bad_cells trimmed
            from &out
            where nmiss(a, b, c, d) > 0 or min(a, b, c, d) < 0;
    quit;

    %if &bad_cells > 0 %then %do;
        %put ERROR: &bad_cells row(s) in &out have a missing or negative 2x2 cell.;
        %put ERROR- The cohort, the stratum and the universe are not on one population.;

        proc print data=&out(obs=20) noobs;
            where nmiss(a, b, c, d) > 0 or min(a, b, c, d) < 0;
            var strat_name stratum event_type event drug_label a b c d n_drug n_reac N;
            title2 'ERROR - inconsistent stratified 2x2 cells (first 20)';
        run;
        title2;
        %abort cancel;
    %end;

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

    proc sql noprint;
        select count(*) into :nrows trimmed from &out;
    quit;
    %put NOTE: &strat_name x &event_type complete - &nrows row(s).;

    proc datasets library=work nolist;
        delete _sg_a _sg_ndrug _sg_nreac _sg_ntotal;
    quit;
%mend build_subgroup_2x2;


/*==========================================================================
  5. SIX INVOCATIONS - THREE DIMENSIONS, TWO GRAINS
  --------------------------------------------------------------------------
  One dimension at a time, never crossed. Age x sex x country would be twelve
  strata and would thin the cells past the point where a >= 3 means anything.
  ==========================================================================*/
%build_subgroup_2x2(strat_var=age_grp,     strat_name=Age Group, event=pt,       event_type=PT,    out=work.sg_age_pt)
%build_subgroup_2x2(strat_var=age_grp,     strat_name=Age Group, event=pt_group, event_type=GROUP, out=work.sg_age_grp)
%_stamp(Section 5 - age stratification complete.)

%build_subgroup_2x2(strat_var=sex,         strat_name=Sex,       event=pt,       event_type=PT,    out=work.sg_sex_pt)
%build_subgroup_2x2(strat_var=sex,         strat_name=Sex,       event=pt_group, event_type=GROUP, out=work.sg_sex_grp)
%_stamp(Section 5 - sex stratification complete.)

%build_subgroup_2x2(strat_var=country_grp, strat_name=Country,   event=pt,       event_type=PT,    out=work.sg_country_pt)
%build_subgroup_2x2(strat_var=country_grp, strat_name=Country,   event=pt_group, event_type=GROUP, out=work.sg_country_grp)
%_stamp(Section 5 - country stratification complete.)

data signal.glp1_subgroup_age (compress=yes
        label='GLP-1 age-stratified disproportionality, PT and class-effect grains');
    length strat_name $20 stratum $10 event_type $8 event $100 drug_label $20;
    set work.sg_age_pt work.sg_age_grp;
run;

data signal.glp1_subgroup_sex (compress=yes
        label='GLP-1 sex-stratified disproportionality');
    length strat_name $20 stratum $10 event_type $8 event $100 drug_label $20;
    set work.sg_sex_pt work.sg_sex_grp;
run;

data signal.glp1_subgroup_country (compress=yes
        label='GLP-1 country-stratified disproportionality');
    length strat_name $20 stratum $10 event_type $8 event $100 drug_label $20;
    set work.sg_country_pt work.sg_country_grp;
run;


/*==========================================================================
  6. AGE-DEPENDENT SIGNAL DETECTION
  --------------------------------------------------------------------------
  The headline analysis, and the one most exposed to the coverage problem.
  Everything here is computed within a molecule; nothing compares one
  molecule's age pattern to another's. See the header.
  ==========================================================================*/

/* --- 6a. Pivot the age strata wide ------------------------------------- */
proc sql;
    create table work.age_wide as
        select      drug_label, event_type, event, coverage_pct,
                    max(case when stratum = '<=45'  then a           end) as a_young,
                    max(case when stratum = '<=45'  then PRR         end) as prr_young,
                    max(case when stratum = '<=45'  then PRR_LCL     end) as prr_lcl_young,
                    max(case when stratum = '<=45'  then PRR_UCL     end) as prr_ucl_young,
                    max(case when stratum = '<=45'  then signal_flag end) as sig_young,
                    max(case when stratum = '46-64' then a           end) as a_middle,
                    max(case when stratum = '46-64' then PRR         end) as prr_middle,
                    max(case when stratum = '46-64' then signal_flag end) as sig_middle,
                    max(case when stratum = '>=65'  then a           end) as a_elderly,
                    max(case when stratum = '>=65'  then PRR         end) as prr_elderly,
                    max(case when stratum = '>=65'  then PRR_LCL     end) as prr_lcl_elderly,
                    max(case when stratum = '>=65'  then PRR_UCL     end) as prr_ucl_elderly,
                    max(case when stratum = '>=65'  then signal_flag end) as sig_elderly
        from        signal.glp1_subgroup_age
        group by    drug_label, event_type, event, coverage_pct;
quit;

/* --- 6b. Classify the pattern ------------------------------------------
   An event evaluable in only one age band is 'concentrated' there rather
   than 'elevated': there is no ratio to take, and calling it elevated would
   imply a comparison that was never made. */
data work.age_classified;
    set work.age_wide;
    length age_pattern $24;

    if      sig_elderly = 1 and coalesce(sig_young, 0)   = 0 then age_pattern = 'Elderly-concentrated';
    else if sig_young   = 1 and coalesce(sig_elderly, 0) = 0 then age_pattern = 'Youth-concentrated';
    else if sig_elderly = 1 and sig_young = 1
            and prr_elderly > 0 and prr_young > 0 then do;
        prr_ratio_ey = prr_elderly / prr_young;
        if      prr_ratio_ey >= 2.0 then age_pattern = 'Elderly-elevated';
        else if prr_ratio_ey <= 0.5 then age_pattern = 'Youth-elevated';
        else                             age_pattern = 'Age-independent';
    end;
    else if sig_elderly = 1 or sig_young = 1 or sig_middle = 1
                                then age_pattern = 'Age-independent';
    else                             age_pattern = 'No signal any age';

    label prr_ratio_ey = 'PRR >=65 / PRR <=45';

    /* Only the age-dependent patterns travel on. */
    if age_pattern in ('Elderly-concentrated', 'Youth-concentrated',
                       'Elderly-elevated', 'Youth-elevated');
run;

/* --- 6c. Clinical AE or medication error -------------------------------
   All eight class-effect groups are clinical by construction, so the
   classification only has to decide at PT level. */
proc sql;
    create table work.age_dep_classified as
        select      a.*,
                    case when a.event_type = 'GROUP' then 'CLINICAL_AE'
                         when exists (select 1 from work.ref_med_error_pts as me
                                      where upcase(strip(a.event)) = upcase(strip(me.pt)))
                              then 'MEDICATION_ERROR'
                         when find(a.event, 'Medication error', 'i') = 1
                              then 'MEDICATION_ERROR'
                         else 'CLINICAL_AE'
                    end as pt_category length=20
        from        work.age_classified as a;
quit;

/* --- 6d. Bias probe -----------------------------------------------------
   The molecule-level coverage says how much of the cohort has an age. This
   says how much of THIS event's cases have one. When the two diverge, the
   age strata for that event are drawn from a selected slice of its own
   reports and the pattern may be an artefact of who gets an age recorded.

   COUNT(DISTINCT ... primaryid) and not SUM(CASE ...): at group grain a case
   reporting three PTs of one group produces three rows, and a SUM would
   count it three times against a denominator that counts it once. */
proc sql;
    create table work.bias_probe_pt as
        select      sc.drug_label,
                    sr.pt as event length=100,
                    count(distinct sr.primaryid) as n_event_cases,
                    count(distinct case when sc.age_grp not in ('Unknown', '')
                                         and not missing(sc.age_grp)
                                        then sr.primaryid end) as n_event_age_known
        from        work.sub_reac  as sr
        inner join  work.sub_cases as sc
               on   sr.primaryid  = sc.primaryid
              and   sr.drug_label = sc.drug_label
        group by    sc.drug_label, sr.pt;

    create table work.bias_probe_grp as
        select      sc.drug_label,
                    m.pt_group as event length=100,
                    count(distinct sr.primaryid) as n_event_cases,
                    count(distinct case when sc.age_grp not in ('Unknown', '')
                                         and not missing(sc.age_grp)
                                        then sr.primaryid end) as n_event_age_known
        from        work.sub_reac  as sr
        inner join  work.sub_cases as sc
               on   sr.primaryid  = sc.primaryid
              and   sr.drug_label = sc.drug_label
        inner join  work.pt_to_group as m on sr.pt = m.pt
        group by    sc.drug_label, m.pt_group;
quit;

data work.bias_probe;
    length event_type $8 event $100;
    set work.bias_probe_pt  (in=_pt)
        work.bias_probe_grp (in=_gp);
    event_type = ifc(_pt, 'PT', 'GROUP');
    if n_event_cases > 0 then pt_age_coverage = n_event_age_known / n_event_cases;
    format pt_age_coverage percent8.1;
    label pt_age_coverage = 'Share of this event''s cases with a known age';
run;

/* --- 6e. Assemble the deliverable -------------------------------------- */
proc sql;
    create table work.age_dependent as
        select      a.*,
                    bp.n_event_cases,
                    bp.pt_age_coverage                       format=percent8.1,
                    cv.pct_age_known as drug_age_coverage    format=percent8.1,
                    bp.pt_age_coverage - cv.pct_age_known as coverage_delta
                        format=percent8.1
                        label='Event age coverage minus molecule baseline',

                    /* Pragmatic, not statistical - it flags, it does not filter. */
                    case when bp.pt_age_coverage is missing then 'NO PROBE'
                         when abs(calculated coverage_delta) > 0.15 then 'SELECTION BIAS'
                         else 'OK'
                    end as coverage_flag length=16

        from        work.age_dep_classified as a
        left join   work.bias_probe         as bp
               on   a.drug_label = bp.drug_label
              and   a.event      = bp.event
              and   a.event_type = bp.event_type
        left join   work.coverage           as cv
               on   a.drug_label = cv.drug_label

        /* Molecule first, and deliberately so: the sort is what keeps a
           reader from scanning down a single ranked list that mixes two
           differently-selected cohorts. */
        order by    a.drug_label,
                    a.pt_category,
                    a.event_type,
                    case a.age_pattern
                        when 'Elderly-concentrated' then 1
                        when 'Youth-concentrated'   then 2
                        when 'Elderly-elevated'     then 3
                        when 'Youth-elevated'       then 4
                        else 5
                    end,
                    coalesce(a.a_elderly, 0) + coalesce(a.a_young, 0) desc;
quit;

data signal.glp1_age_dependent (compress=yes
        label='GLP-1 age-dependent signals with coverage and selection flags');
    length drug_label $20 event_type $8 event $100
           age_pattern $24 pt_category $20 coverage_flag $16;
    set work.age_dependent;
run;

%_stamp(Section 6 - age-dependent signals classified.)


/*==========================================================================
  7. REPORTING TABLES
  ==========================================================================*/
title2 'Table 2: Age-dependent CLINICAL signals';
title3 "coverage_flag = 'SELECTION BIAS' means this event's age-recorded cases";
title4 'are not representative of its own reports - read those with caution.';
proc report data=signal.glp1_age_dependent nowd;
    where pt_category = 'CLINICAL_AE';
    columns drug_label event_type event age_pattern
            a_young prr_young a_middle prr_middle a_elderly prr_elderly
            coverage_pct pt_age_coverage coverage_flag;
    define drug_label      / order   'Molecule';
    define event_type      / display 'Grain';
    define event           / display 'Event';
    define age_pattern     / display 'Pattern';
    define a_young         / display 'N <=45'      format=comma8.;
    define prr_young       / display 'PRR <=45'    format=8.2;
    define a_middle        / display 'N 46-64'     format=comma8.;
    define prr_middle      / display 'PRR 46-64'   format=8.2;
    define a_elderly       / display 'N >=65'      format=comma8.;
    define prr_elderly     / display 'PRR >=65'    format=8.2;
    define coverage_pct    / display 'Drug age cov' format=percent8.1;
    define pt_age_coverage / display 'Event age cov' format=percent8.1;
    define coverage_flag   / display 'Bias flag';
run;
title3; title4;

title2 'Table 3: Age-dependent MEDICATION ERROR PTs - informational';
title3 'Off-label weight-loss use skews young by construction. Reported so the';
title4 'skew is on the record, and separated so it cannot crowd out Table 2.';
proc report data=signal.glp1_age_dependent nowd;
    where pt_category = 'MEDICATION_ERROR';
    columns drug_label event age_pattern a_young prr_young a_elderly prr_elderly;
    define drug_label  / order   'Molecule';
    define event       / display 'Event';
    define age_pattern / display 'Pattern';
    define a_young     / display 'N <=45'   format=comma8.;
    define prr_young   / display 'PRR <=45' format=8.2;
    define a_elderly   / display 'N >=65'   format=comma8.;
    define prr_elderly / display 'PRR >=65' format=8.2;
run;
title3; title4;

title2 'Table 4: Age-dependent class effects at GROUP grain';
proc print data=signal.glp1_age_dependent noobs label;
    where event_type = 'GROUP';
    var drug_label event age_pattern a_young prr_young a_elderly prr_elderly
        prr_ratio_ey coverage_flag;
    format a_young a_elderly comma8. prr_young prr_elderly prr_ratio_ey 8.2;
    label drug_label = 'Molecule' event = 'Class effect' age_pattern = 'Pattern'
          a_young = 'N <=45' prr_young = 'PRR <=45'
          a_elderly = 'N >=65' prr_elderly = 'PRR >=65'
          prr_ratio_ey = 'Ratio' coverage_flag = 'Bias flag';
run;
title2;

%_stamp(Section 7 - reporting tables printed.)


/*==========================================================================
  8. QC REPORT
  ==========================================================================*/
proc sql noprint;
    select count(*) into :N_AGE     trimmed from signal.glp1_subgroup_age;
    select count(*) into :N_SEX     trimmed from signal.glp1_subgroup_sex;
    select count(*) into :N_COUNTRY trimmed from signal.glp1_subgroup_country;

    select count(*) into :N_BADCELL trimmed
        from (select a, b, c, d from signal.glp1_subgroup_age
              union all select a, b, c, d from signal.glp1_subgroup_sex
              union all select a, b, c, d from signal.glp1_subgroup_country)
        where nmiss(a, b, c, d) > 0 or min(a, b, c, d) < 0;

    select count(*) into :N_DEP     trimmed from signal.glp1_age_dependent;
    select count(*) into :N_DEP_CLIN trimmed
        from signal.glp1_age_dependent where pt_category = 'CLINICAL_AE';
    select count(*) into :N_DEP_MED trimmed
        from signal.glp1_age_dependent where pt_category = 'MEDICATION_ERROR';
    select count(*) into :N_DEP_BIAS trimmed
        from signal.glp1_age_dependent
        where pt_category = 'CLINICAL_AE' and coverage_flag = 'SELECTION BIAS';
    select count(*) into :N_DEP_OK trimmed
        from signal.glp1_age_dependent
        where pt_category = 'CLINICAL_AE' and coverage_flag = 'OK';
    select count(*) into :N_DEP_GRP trimmed
        from signal.glp1_age_dependent where event_type = 'GROUP';

    select count(*) into :N_ELD_CONC trimmed from signal.glp1_age_dependent
        where pt_category = 'CLINICAL_AE' and age_pattern = 'Elderly-concentrated';
    select count(*) into :N_YTH_CONC trimmed from signal.glp1_age_dependent
        where pt_category = 'CLINICAL_AE' and age_pattern = 'Youth-concentrated';
    select count(*) into :N_ELD_ELEV trimmed from signal.glp1_age_dependent
        where pt_category = 'CLINICAL_AE' and age_pattern = 'Elderly-elevated';
    select count(*) into :N_YTH_ELEV trimmed from signal.glp1_age_dependent
        where pt_category = 'CLINICAL_AE' and age_pattern = 'Youth-elevated';

    /* The differential that this whole program is built around. */
    select 100 * (max(pct_age_known) - min(pct_age_known)) into :AGE_COV_GAP trimmed
        from work.coverage;
quit;

/* Per molecule x dimension x grain pair counts, built from the data rather
   than typed out, so a third molecule would need no edit here. */
proc sql;
    create table work.pair_counts as
        select      strat_name, drug_label, event_type, count(*) as n_pairs
        from        (select strat_name, drug_label, event_type from signal.glp1_subgroup_age
                     union all
                     select strat_name, drug_label, event_type from signal.glp1_subgroup_sex
                     union all
                     select strat_name, drug_label, event_type from signal.glp1_subgroup_country)
        group by    strat_name, drug_label, event_type
        order by    strat_name, drug_label, event_type;
quit;

data work.qc_subgroup;
    length metric $60 value 8 note $90;

    /* Coverage comes first: it is the frame for everything below it. */
    do until (_eof1);
        set work.coverage end=_eof1;
        metric = '  ' || strip(drug_label) || ' age coverage';
        value  = 100 * pct_age_known;
        note   = catx(' ', strip(put(n_age_known, comma10.)), 'of',
                           strip(put(n_total, comma10.)), 'cases carry a usable age');
        output;

        metric = '  ' || strip(drug_label) || ' sex coverage';
        value  = 100 * pct_sex_known;
        note   = catx(' ', strip(put(n_sex_known, comma10.)), 'cases coded M or F'); output;

        metric = '  ' || strip(drug_label) || ' US share';
        value  = 100 * pct_us;
        note   = 'Missing reporter_country counts as Non-US';                        output;
    end;

    metric = 'Age coverage gap between molecules';
    value  = &AGE_COV_GAP;
    note   = 'Percentage points - the reason for every guardrail below';    output;

    metric = 'Analysis universe N';
    value  = &N_UNIVERSE;
    note   = 'Must equal 1,529,453 - the Step 2 and 3 universe';            output;

    metric = 'Rows with a missing or negative 2x2 cell';
    value  = &N_BADCELL;
    note   = 'Must be 0 across all three dimensions';                       output;

    metric = 'Age-stratified rows';
    value  = &N_AGE;
    note   = 'SIGNAL.GLP1_SUBGROUP_AGE, both grains';                       output;

    metric = 'Sex-stratified rows';
    value  = &N_SEX;
    note   = 'SIGNAL.GLP1_SUBGROUP_SEX, both grains';                       output;

    metric = 'Country-stratified rows';
    value  = &N_COUNTRY;
    note   = 'SIGNAL.GLP1_SUBGROUP_COUNTRY, both grains';                   output;

    /* Per molecule x dimension x grain */
    do until (_eof2);
        set work.pair_counts end=_eof2;
        metric = '  ' || strip(strat_name) || ' / ' || strip(drug_label)
                 || ' / ' || strip(event_type);
        value  = n_pairs;
        note   = 'Stratified pairs with a >= 3';                            output;
    end;

    metric = 'Age-dependent signals (all)';
    value  = &N_DEP;
    note   = 'Elderly/Youth concentrated or elevated';                      output;

    metric = '  CLINICAL_AE';
    value  = &N_DEP_CLIN;
    note   = 'The deliverable - Table 2';                                   output;

    metric = '  MEDICATION_ERROR';
    value  = &N_DEP_MED;
    note   = 'Off-label use and dosing errors - Table 3, informational';    output;

    metric = '  at GROUP grain';
    value  = &N_DEP_GRP;
    note   = 'Class effects - never additive with PT rows';                 output;

    metric = '  CLINICAL_AE flagged SELECTION BIAS';
    value  = &N_DEP_BIAS;
    note   = 'Event age coverage more than 15 points from its baseline';    output;

    metric = '  CLINICAL_AE with coverage OK';
    value  = &N_DEP_OK;
    note   = 'The defensible subset - read these first';                    output;

    metric = '  Elderly-concentrated / Youth-concentrated';
    value  = &N_ELD_CONC + &N_YTH_CONC;
    note   = catx(' ', 'elderly', "&N_ELD_CONC", '- youth', "&N_YTH_CONC"); output;

    metric = '  Elderly-elevated / Youth-elevated';
    value  = &N_ELD_ELEV + &N_YTH_ELEV;
    note   = catx(' ', 'elderly', "&N_ELD_ELEV", '- youth', "&N_YTH_ELEV"); output;

    stop;
    label metric = 'Metric' value = 'Value' note = 'Note';
    keep  metric value note;
run;

title2 'Table 5: Subgroup QC';
proc print data=work.qc_subgroup noobs label;
    format value comma12.2;
run;
title2;

%macro subgroup_verdict;
    %if &N_BADCELL = 0 %then
        %put NOTE: 2x2 assertion passed - no missing or negative cells in any dimension.;
    %else
        %put ERROR: &N_BADCELL stratified row(s) have an inconsistent 2x2 cell.;

    %put NOTE: Age coverage gap between the two molecules = &AGE_COV_GAP percentage points.;
    %put NOTE- Every age-stratified estimate below rests on the share for its own molecule.;

    %if &N_DEP_CLIN = 0 %then
        %put WARNING: No clinical age-dependent signal found - check the age strata are populated.;
    %else %do;
        %put NOTE: &N_DEP_CLIN clinical age-dependent signal(s), &N_DEP_OK with coverage OK.;
        %if &N_DEP_BIAS > 0 %then
            %put NOTE- &N_DEP_BIAS carry SELECTION BIAS and are reported, not filtered.;
    %end;
%mend subgroup_verdict;

%subgroup_verdict

%_stamp(Section 8 - QC complete.)


/*==========================================================================
  9. EXPORT AND WRAP UP
  ==========================================================================*/
proc export data=signal.glp1_subgroup_age
            outfile="&OUT_TABLES./glp1_subgroup_age.csv" dbms=csv replace;
run;
proc export data=signal.glp1_subgroup_sex
            outfile="&OUT_TABLES./glp1_subgroup_sex.csv" dbms=csv replace;
run;
proc export data=signal.glp1_subgroup_country
            outfile="&OUT_TABLES./glp1_subgroup_country.csv" dbms=csv replace;
run;
proc export data=signal.glp1_age_dependent
            outfile="&OUT_TABLES./glp1_age_dependent.csv" dbms=csv replace;
run;
proc export data=work.qc_subgroup
            outfile="&OUT_QC./qc_glp1_subgroup.csv" dbms=csv replace;
run;

proc datasets library=work nolist;
    delete sg_age_pt sg_age_grp sg_sex_pt sg_sex_grp
           sg_country_pt sg_country_grp
           age_wide age_classified age_dep_classified age_dependent
           bias_probe_pt bias_probe_grp;
quit;

%macro finish;
    %local e;
    %let e = %sysevalf(%sysfunc(datetime()) - &_T0);

    %put NOTE: ============================================;
    %put NOTE: 03_glp1_subgroup.sas complete.;
    %put NOTE: Universe N          = &N_UNIVERSE;
    %put NOTE: Age coverage gap    = &AGE_COV_GAP percentage points;
    %put NOTE: Stratified rows     = &N_AGE age / &N_SEX sex / &N_COUNTRY country;
    %put NOTE: Age-dependent       = &N_DEP (clinical &N_DEP_CLIN, med-error &N_DEP_MED);
    %put NOTE: Defensible subset   = &N_DEP_OK clinical rows with coverage OK;
    %put NOTE: Flagged for bias    = &N_DEP_BIAS clinical rows;
    %put NOTE: Datasets            = SIGNAL.GLP1_SUBGROUP_AGE / _SEX / _COUNTRY;
    %put NOTE:                       SIGNAL.GLP1_AGE_DEPENDENT;
    %put NOTE: QC                  = &OUT_QC./qc_glp1_subgroup.csv;
    %put NOTE: Elapsed             = %sysfunc(putn(&e, time12.2));
    %put NOTE: ============================================;

    %if &N_BADCELL = 0 and &N_DEP_CLIN > 0 %then
        %put NOTE: GLP-1 SUBGROUP ANALYSIS PASSED - ready for Phase 3 Step 5.;
    %else
        %put WARNING: GLP-1 SUBGROUP ANALYSIS needs review - see the warnings above.;
%mend finish;

%finish

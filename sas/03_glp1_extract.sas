/*****************************************************************************
 * 03_glp1_extract.sas - GLP-1 cohort extraction
 *
 * Purpose:  Phase 3 Step 1. Build the GLP-1 analytical dataset. Every case
 *           in which a GLP-1 receptor agonist is the Primary Suspect drug is
 *           pulled from CLEAN.DRUG, labelled with its molecule and
 *           generation, and joined to demographics, reactions, indications
 *           and outcomes. Steps 2-7 read these four datasets and nothing
 *           else, so the grain decisions made here propagate to every
 *           downstream PRR, ROR and EBGM.
 *
 * Inputs:   CLEAN.DEMO            deduplicated demographics
 *           CLEAN.DRUG            all drug records
 *           CLEAN.REAC            reactions (MedDRA Preferred Terms)
 *           CLEAN.INDI            indications
 *           CLEAN.OUTC            outcome codes
 *           WORK.REF_GLP1_DRUG    class definition, from 00_config.sas
 *
 * Outputs:  CLEAN.GLP1_CASES                  primaryid x drug_label
 *           CLEAN.GLP1_REAC                   primaryid x drug_label x pt
 *           CLEAN.GLP1_INDI                   primaryid x drug_label x indi_pt
 *           CLEAN.GLP1_OUTC                   primaryid x outc_cod
 *           &OUT_QC/qc_glp1_extract.csv       extraction QC metrics
 *
 * THER and RPSR are deliberately excluded. THER mixes 8-, 6- and 4-digit
 * dates and report-level signal detection needs no therapy duration; RPSR
 * covers 3% of cases, too sparse to stratify on.
 *
 * -----------------------------------------------------------------------
 * METHOD - why a cross join and not %glp1_match()
 * -----------------------------------------------------------------------
 * %glp1_match() answers "is this drug in the class". It cannot answer
 * "which member is it", because a compounded prod_ai such as
 * 'INSULIN DEGLUDEC\LIRAGLUTIDE' names one member inside a longer string
 * and a combination product can name two. Section 2 therefore joins
 * CLEAN.DRUG to the four-row WORK.REF_GLP1_DRUG as a cross join filtered by
 * FIND, which is what carries drug_label and generation back out and what
 * keeps a combination product attributed to every molecule it contains.
 * Same formulation as the LIKE join behind glp1_ps_case in
 * sql/03_queries.sql section 3, so the two cohorts reconcile.
 *
 * -----------------------------------------------------------------------
 * GRAIN - one row per case per molecule
 * -----------------------------------------------------------------------
 * FAERS writes one DRUG row per drug line, so a case whose dose changed
 * mid-report carries the same molecule on three drug_seq values. Left
 * alone, those three rows become three cases in every downstream
 * denominator and inflate the PRR background. The NODUPKEY in section 2 is
 * what makes one row equal one case, and it is not optional.
 *
 * The same reasoning drives SELECT DISTINCT in section 4. CLEAN.REAC,
 * CLEAN.INDI and CLEAN.OUTC were filtered to surviving primaryids by
 * 01_import_clean.sas but never deduplicated on their own key, so a case
 * that reports one PT twice would otherwise contribute two rows to a
 * COUNT(*). DISTINCT collapses each child table to its declared grain,
 * matching what 02_signal_engine.sas section 2 does for the full database.
 *
 * -----------------------------------------------------------------------
 * TWO PLACES THIS PROGRAM DEPARTS FROM THE SPEC
 * -----------------------------------------------------------------------
 * 1. init_fda_dt and fda_dt are NUMERIC SAS dates here, not the 8-character
 *    strings the spec assumed. 01_import_clean.sas parses init_fda_dt_c
 *    into a formatted numeric and drops the character original, so
 *    SUBSTR(strip(init_fda_dt),1,4) would silently read a five-digit date
 *    serial. The quarter is derived with YEAR() and QTR() instead, which is
 *    both correct and shorter.
 *
 * 2. init_fda_dt_prec is carried into GLP1_CASES. A date reported as a bare
 *    year is imputed to January 1 by the import macro and so lands in Q1
 *    without ever having been a Q1 report. Step 5 tracks PRR quarter by
 *    quarter and needs to be able to see, or exclude, those rows.
 *
 * A third point is left as the spec wrote it and flagged rather than
 * changed: the indication join runs on the drug_seq that survived NODUPKEY,
 * so indications attached to the other drug_seq rows of the same molecule
 * are dropped. The QC report counts exactly how many, so the decision can
 * be revisited with a number rather than a guess.
 *
 * NOTE: CLEAN.DEMO already carries a FAERS-supplied age_grp $1. The
 * age_grp built here is the project's own three-band grouping and is $10.
 * They are different variables that share a name; GLP1_CASES holds only the
 * derived one.
 *
 * Author:   Hingling Yu
 * Created:  2026-09-05
 *****************************************************************************/

/*==========================================================================
  1. SETUP
  ==========================================================================*/

/* Literal path, for the same reason as 02_signal_engine.sas and
   02_positive_controls.sas: &BASE is defined BY this file, so it cannot be
   used to find it. Every path after this line derives from &BASE. */
%include "/home/u64291357/mydata/sas/00_config.sas";

/* 00_config.sas turns MPRINT and SYMBOLGEN on. The joins below are plain
   SQL; the macro trace would bury the QC table this program exists to
   print. */
options nosymbolgen nomprint;

%let _T0 = %sysfunc(datetime());

%macro _stamp(label);
    %local e;
    %let e = %sysevalf(%sysfunc(datetime()) - &_T0);
    %put NOTE: [%sysfunc(putn(&e, time12.2))] &label;
%mend _stamp;

/* &OUT_QC must exist before PROC EXPORT writes into it. XCMD is disabled on
   SAS ODA, so DCREATE is the only way to create a directory from code; it is
   a no-op when the directory is already there. */
%macro _ensure_dir(subdir);
    %local rc;
    %if %sysfunc(fileexist(&BASE./output/&subdir)) = 0 %then %do;
        %let rc = %sysfunc(dcreate(&subdir, &BASE./output));
        %if %length(&rc) = 0 %then
            %put WARNING: Could not create &BASE./output/&subdir - the CSV export will fail.;
    %end;
%mend _ensure_dir;

%_ensure_dir(qc)

title "Phase 3 Step 1 - GLP-1 Cohort Extraction";

/* Prerequisites, checked before the first join rather than discovered
   inside it. A missing table makes PROC SQL blame its own FROM clause and
   then every later step fails on the empty result, so one real problem
   arrives as forty ERRORs with the cause buried at the top. */
%macro require_inputs;
    %local i tbl missing;
    %let missing = 0;

    /* The five CLEAN tables 01_import_clean.sas builds. */
    %do i = 1 %to 5;
        %let tbl = %scan(DEMO DRUG REAC INDI OUTC, &i);
        %if %sysfunc(exist(clean.&tbl)) = 0 %then %do;
            %put ERROR: CLEAN.&tbl does not exist.;
            %let missing = %eval(&missing + 1);
        %end;
    %end;
    %if &missing > 0 %then %do;
        %put ERROR- Run 01_import_clean.sas before this program.;
        %abort cancel;
    %end;

    /* WORK.REF_GLP1_DRUG is created by 00_config.sas. Its absence does not
       mean the include failed - it means the copy of 00_config.sas on SAS
       ODA predates the class-definition rewrite, back when the class was a
       quoted %nrstr(&GLP1_DRUGS) list and no reference table existed. The
       fix is to re-upload sas/00_config.sas, not to edit this program. */
    %if %sysfunc(exist(work.ref_glp1_drug)) = 0 %then %do;
        %put ERROR: WORK.REF_GLP1_DRUG does not exist after including 00_config.sas.;
        %put ERROR- The copy of 00_config.sas on SAS ODA is out of date.;
        %put ERROR- Re-upload sas/00_config.sas from the repo to &SAS_PATH, then re-run.;
        %abort cancel;
    %end;
%mend require_inputs;

%require_inputs

%_stamp(03_glp1_extract.sas started.)


/*==========================================================================
  2. EXTRACT GLP-1 PRIMARY SUSPECT DRUG RECORDS
  --------------------------------------------------------------------------
  The cross join is deliberate: WORK.REF_GLP1_DRUG holds four rows, so the
  expansion is trivial and FIND does the real filtering. A blank prod_ai is
  excluded up front - it is a drug line with no ingredient, not a drug.
  ==========================================================================*/
proc sql;
    create table work.glp1_drug_all as
        select  d.primaryid,
                d.caseid,
                d.drug_seq,
                d.prod_ai,
                d.drugname,
                d.route,
                d.dose_vbm,
                g.drug_label,
                g.generation
        from    clean.drug          as d,
                work.ref_glp1_drug  as g
        where   d.role_cod = 'PS'
          and   not missing(d.prod_ai)
          and   find(d.prod_ai, strip(g.match_string), 'i') > 0;
quit;

%_stamp(Section 2 - GLP-1 PS drug records extracted.)

/* Collapse to the analytical grain. Sorting by drug_seq before the NODUPKEY
   makes the surviving row the lowest drug_seq for that molecule, so the
   result is reproducible rather than whatever order the join happened to
   emit. */
proc sort data=work.glp1_drug_all out=work.glp1_drug nodupkey;
    by primaryid drug_label drug_seq;
run;

%_stamp(Section 2 - deduplicated to primaryid x drug_label.)


/*==========================================================================
  3. JOIN DEMOGRAPHICS
  --------------------------------------------------------------------------
  LEFT JOIN, not INNER. Every GLP-1 drug record should have a DEMO row -
  01_import_clean.sas filtered the child tables to surviving primaryids -
  but an INNER JOIN would make a broken referential link look like a smaller
  cohort instead of an error. The QC report counts unmatched rows.
  ==========================================================================*/
proc sql;
    create table work.glp1_cases as
        select  g.primaryid,
                g.caseid,
                g.drug_label,
                g.generation,
                g.drug_seq,
                g.prod_ai,
                g.drugname,
                g.route,

                /* --- Demographics --- */
                dm.age,
                dm.age_cod,
                dm.sex,
                dm.wt,
                dm.reporter_country,
                dm.occr_country,
                dm.init_fda_dt,
                dm.fda_dt,
                dm.event_dt,
                dm.init_fda_dt_prec,

                /* --- Derived: age group ---
                   Only YR ages are grouped. DEC, MON, WK, DY and HR are rare
                   and would need converting; grouping them as reported would
                   file a 9-month-old under '<=45' as if it meant the same
                   thing. length=10 is required: PUT() of agegrpf. returns 5
                   characters, which would truncate 'Unknown' to 'Unkno'. */
                case when upcase(strip(dm.age_cod)) = 'YR'
                          and dm.age is not missing
                         then put(dm.age, agegrpf.)
                     else 'Unknown'
                end as age_grp length=10
                    label='Age group (derived)',

                /* --- Derived: reporting quarter ---
                   init_fda_dt is the FDA initial receive date and is the
                   right clock for an emerging-signal trend: it does not move
                   when a case is revised. fda_dt is the fallback for the
                   handful of cases where the initial date failed to parse. */
                case when dm.init_fda_dt is not missing
                         then put(year(dm.init_fda_dt), 4.)
                     when dm.fda_dt is not missing
                         then put(year(dm.fda_dt), 4.)
                     else ''
                end as report_year length=4
                    label='Report year',

                case when dm.init_fda_dt is not missing then qtr(dm.init_fda_dt)
                     when dm.fda_dt      is not missing then qtr(dm.fda_dt)
                     else .
                end as report_qtr
                    label='Report quarter (1-4)',

                /* Sorts correctly as a string: '2025Q3' < '2025Q4' < '2026Q1'. */
                case when dm.init_fda_dt is not missing
                         then cats(put(year(dm.init_fda_dt), 4.), 'Q',
                                   put(qtr(dm.init_fda_dt), 1.))
                     when dm.fda_dt is not missing
                         then cats(put(year(dm.fda_dt), 4.), 'Q',
                                   put(qtr(dm.fda_dt), 1.))
                     else ''
                end as year_qtr length=6
                    label='Report year-quarter'

        from        work.glp1_drug as g
        left join   clean.demo     as dm
               on   g.primaryid = dm.primaryid;
quit;

%_stamp(Section 3 - demographics joined.)


/*==========================================================================
  4. REACTION, INDICATION AND OUTCOME DATASETS
  --------------------------------------------------------------------------
  Kept as three datasets rather than folded into GLP1_CASES because the
  grain differs. Flattening them would multiply the case rows by the number
  of reactions and destroy the one-row-per-case property section 2 just
  established.

  SELECT DISTINCT on all three: see the GRAIN note in the header.
  ==========================================================================*/

/* Reactions. Joined on primaryid alone - REAC is case-level in FAERS, with
   no drug_seq to tie a PT to the drug that caused it. Every reaction on a
   GLP-1 case is therefore attributed to that case's GLP-1 molecule, which is
   the standard disproportionality assumption and the same one
   02_signal_engine.sas makes for the full database. */
proc sql;
    create table work.glp1_reac as
        select  distinct
                g.primaryid,
                g.drug_label,
                g.generation,
                r.pt
        from    work.glp1_drug as g
                inner join clean.reac as r
                     on g.primaryid = r.primaryid
        where   not missing(r.pt)
        order by g.drug_label, r.pt;
quit;

%_stamp(Section 4 - reactions linked.)

/* Indications. INDI does carry indi_drug_seq, so the indication is matched
   to the specific drug line rather than to the case. The cost is stated in
   the header: only the drug_seq that survived NODUPKEY is joined. */
proc sql;
    create table work.glp1_indi as
        select  distinct
                g.primaryid,
                g.drug_label,
                g.generation,
                i.indi_pt
        from    work.glp1_drug as g
                inner join clean.indi as i
                     on g.primaryid    = i.primaryid
                    and g.drug_seq     = i.indi_drug_seq
        where   not missing(i.indi_pt)
        order by g.drug_label, i.indi_pt;
quit;

%_stamp(Section 4 - indications linked.)

/* Outcomes. OUTC is case-level with no drug_seq, so this is a filter on the
   GLP-1 primaryids rather than a join carrying drug_label. Steps 2-7 join
   it back to GLP1_CASES on primaryid when they need the molecule. */
proc sql;
    create table work.glp1_outc as
        select  distinct
                o.primaryid,
                o.outc_cod
        from    clean.outc as o
        where   o.primaryid in (select distinct primaryid from work.glp1_drug)
          and   not missing(o.outc_cod)
        order by o.primaryid, o.outc_cod;
quit;

%_stamp(Section 4 - outcomes linked.)


/*==========================================================================
  5. QC REPORT
  --------------------------------------------------------------------------
  The gate here is reconciliation against the MySQL warehouse. SAS matches
  with FIND and MySQL with LIKE, and the two can disagree at the margins, so
  the tolerance is 5% rather than exact equality. A larger gap means the two
  layers are not selecting the same cohort and every cross-layer number in
  the final report would be indefensible.
  ==========================================================================*/

/* Counts the MySQL warehouse produced, from STATUS.md. Held as a dataset,
   not four macro variables, so a fifth molecule is one line. */
data work.mysql_expected;
    length drug_label $20;
    input drug_label $ expected_cases;
    datalines;
TIRZEPATIDE 70111
SEMAGLUTIDE 35705
DULAGLUTIDE 4028
LIRAGLUTIDE 1830
;
run;

proc sql;
    create table work.count_check as
        select      e.drug_label,
                    e.expected_cases,
                    coalesce(a.actual_cases, 0) as actual_cases,
                    calculated actual_cases - e.expected_cases as diff,
                    100 * (calculated actual_cases - e.expected_cases)
                        / e.expected_cases as pct_diff format=8.2
        from        work.mysql_expected as e
        left join   (select drug_label, count(distinct primaryid) as actual_cases
                     from   work.glp1_drug
                     group by drug_label) as a
               on   e.drug_label = a.drug_label
        order by    e.drug_label;
quit;

/* Scalars for the QC table. Every case count is COUNT(DISTINCT primaryid):
   after section 2 one row already equals one case per molecule, but a case
   on both SEMAGLUTIDE and TIRZEPATIDE still holds two rows. */
proc sql noprint;
    select count(*)                  into :N_DRUG_RAW    trimmed from work.glp1_drug_all;
    select count(*)                  into :N_PAIRS       trimmed from work.glp1_drug;
    select count(distinct primaryid) into :N_CASES       trimmed from work.glp1_drug;

    select count(distinct primaryid) into :N_NEWER       trimmed
        from work.glp1_drug where generation = 'newer';
    select count(distinct primaryid) into :N_OLDER       trimmed
        from work.glp1_drug where generation = 'comparator';

    /* A case naming more than one class member - a compounded or combination
       product, or genuine switching within the reporting window. */
    select count(*) into :N_OVERLAP trimmed
        from (select primaryid from work.glp1_drug
              group by primaryid having count(distinct drug_label) > 1);

    select count(*) into :N_REAC trimmed from work.glp1_reac;
    select count(*) into :N_INDI trimmed from work.glp1_indi;
    select count(*) into :N_OUTC trimmed from work.glp1_outc;

    /* Indication rows the drug_seq dedup costs us. See the header. */
    select count(*) into :N_INDI_ALL trimmed
        from (select distinct a.primaryid, a.drug_label, i.indi_pt
              from  work.glp1_drug_all as a
                    inner join clean.indi as i
                         on a.primaryid = i.primaryid
                        and a.drug_seq  = i.indi_drug_seq
              where not missing(i.indi_pt));

    /* Referential check on the LEFT JOIN in section 3. */
    select count(*) into :N_NO_DEMO trimmed
        from work.glp1_cases where missing(sex) and missing(age)
                              and missing(init_fda_dt) and missing(fda_dt);

    select count(*) into :N_NO_AGE  trimmed
        from work.glp1_cases where age_grp = 'Unknown';
    select count(*) into :N_NO_QTR  trimmed
        from work.glp1_cases where year_qtr = '';

    /* Year-only dates imputed to January 1, so counted in Q1 without ever
       having been Q1 reports. Step 5 needs to know the size of this. */
    select count(*) into :N_QTR_IMPUTED trimmed
        from work.glp1_cases where init_fda_dt_prec in ('Y', 'M');

    select count(*) into :N_OOT trimmed
        from work.count_check where abs(pct_diff) > 5;
quit;

%let N_INDI_DROPPED = %eval(&N_INDI_ALL - &N_INDI);

data work.qc_extract;
    length metric $60 value 8 note $90;

    metric = 'GLP-1 PS drug records (before dedup)';
    value  = &N_DRUG_RAW;
    note   = 'Raw rows from the DRUG x REF_GLP1_DRUG join';              output;

    metric = 'Unique primaryid x drug_label pairs';
    value  = &N_PAIRS;
    note   = 'After NODUPKEY - the GLP1_CASES row count';                output;

    metric = 'Unique primaryids (cases)';
    value  = &N_CASES;
    note   = 'COUNT(DISTINCT primaryid) - expected ~111,673';            output;

    /* Per-molecule reconciliation against MySQL */
    do until (_eof);
        set work.count_check end=_eof;
        metric = catx(' ', strip(drug_label), 'cases');
        value  = actual_cases;
        note   = catx(' ', 'MySQL expected', strip(put(expected_cases, comma12.)),
                           '- difference', strip(put(pct_diff, 8.2)), '%');
        output;
    end;

    metric = 'Newer generation cases';
    value  = &N_NEWER;
    note   = 'SEMAGLUTIDE + TIRZEPATIDE';                                output;

    metric = 'Older generation cases (comparator)';
    value  = &N_OLDER;
    note   = 'DULAGLUTIDE + LIRAGLUTIDE';                                output;

    metric = 'Cross-cohort overlap (>1 drug_label)';
    value  = &N_OVERLAP;
    note   = 'Combination products or within-window switching';          output;

    metric = 'Reactions linked';
    value  = &N_REAC;
    note   = 'Rows in GLP1_REAC (distinct case x drug x PT)';            output;

    metric = 'Indications linked';
    value  = &N_INDI;
    note   = 'Rows in GLP1_INDI (distinct case x drug x indication)';    output;

    metric = 'Indication rows lost to drug_seq dedup';
    value  = &N_INDI_DROPPED;
    note   = 'Attached to a drug_seq NODUPKEY dropped - see header';     output;

    metric = 'Outcomes linked';
    value  = &N_OUTC;
    note   = 'Rows in GLP1_OUTC (distinct case x outcome code)';         output;

    metric = 'Cases with no DEMO match';
    value  = &N_NO_DEMO;
    note   = 'Must be 0 - a broken referential link, not a data gap';    output;

    metric = 'Cases with age_grp = Unknown';
    value  = &N_NO_AGE;
    note   = 'Missing age or a non-YR age unit - informational';         output;

    metric = 'Cases with missing year_qtr';
    value  = &N_NO_QTR;
    note   = 'Neither init_fda_dt nor fda_dt parsed - informational';    output;

    metric = 'Cases with imputed date precision';
    value  = &N_QTR_IMPUTED;
    note   = 'init_fda_dt reported as year or month - Step 5 must see';  output;

    stop;
    label metric = 'Metric' value = 'Value' note = 'Note';
    keep  metric value note;
run;

/* Per-molecule assertions in the log. The log is the artefact reviewed after
   a SAS ODA run, so a mismatch has to be visible there, not only in the CSV. */
data _null_;
    set work.count_check;
    length msg $200;

    /* Built as one string rather than a multi-item PUT so the numbers arrive
       stripped of format padding and the log line reads as a sentence. */
    msg = catx(' ', strip(drug_label),
                    'SAS', strip(put(actual_cases,   comma12.)),
                    'vs MySQL', strip(put(expected_cases, comma12.)),
                    cats('(', strip(put(pct_diff, 8.2)), '%)'));

    if abs(pct_diff) > 5 then put 'WARNING: ' msg ' - outside the 5% tolerance.';
    else                      put 'NOTE: '    msg ' - reconciles.';
run;

%macro extract_verdict;
    %if &N_OOT = 0 %then
        %put NOTE: GLP-1 EXTRACT PASSED - case counts within tolerance of MySQL warehouse.;
    %else %do;
        %put WARNING: &N_OOT of &N_GLP1_DRUGS molecules differ from the MySQL warehouse by more than 5%%.;
        %put WARNING- SAS FIND and MySQL LIKE are not selecting the same cohort. Investigate before Step 2.;

        proc print data=work.count_check noobs label;
            where abs(pct_diff) > 5;
            var drug_label expected_cases actual_cases diff pct_diff;
            format expected_cases actual_cases diff comma12.;
            title2 'Molecules outside the 5 percent reconciliation tolerance';
        run;
        title2;
    %end;

    %if &N_NO_DEMO > 0 %then %do;
        %put ERROR: &N_NO_DEMO GLP-1 drug record(s) have no matching CLEAN.DEMO row.;
        %put ERROR- Referential integrity is broken upstream. Re-check 01_import_clean.sas.;
    %end;
%mend extract_verdict;

%extract_verdict

title2 'Table 1: MySQL Reconciliation';
proc print data=work.count_check noobs label;
    var drug_label expected_cases actual_cases diff pct_diff;
    format expected_cases actual_cases diff comma12.;
    label drug_label     = 'Molecule'
          expected_cases = 'MySQL Expected'
          actual_cases   = 'SAS Actual'
          diff           = 'Difference'
          pct_diff       = 'Difference (%)';
run;

title2 'Table 2: Extraction QC';
proc print data=work.qc_extract noobs label;
    format value comma12.;
run;
title2;

%_stamp(Section 5 - QC complete.)


/*==========================================================================
  6. SAVE AND WRAP UP
  --------------------------------------------------------------------------
  compress=yes on all four: the cohort is ~112K cases with a $500 prod_ai and
  Steps 2-7 read these datasets repeatedly.

  The LENGTH statement before each SET pins the lengths the spec requires -
  prod_ai $500, pt $100, drug_label $20, generation $12 - rather than
  trusting them to survive the joins, and fixes column order at the same
  time so a downstream PROC PRINT reads the same way every run.
  ==========================================================================*/
data clean.glp1_cases (compress=yes
        label='GLP-1 PS cases, one row per primaryid x drug_label');
    length primaryid 8 caseid 8 drug_label $20 generation $12
           drug_seq 8 prod_ai $500;
    set work.glp1_cases;
run;

data clean.glp1_reac (compress=yes
        label='Reactions for GLP-1 PS cases');
    length primaryid 8 drug_label $20 generation $12 pt $100;
    set work.glp1_reac;
run;

data clean.glp1_indi (compress=yes
        label='Indications for GLP-1 PS drug records');
    length primaryid 8 drug_label $20 generation $12 indi_pt $100;
    set work.glp1_indi;
run;

data clean.glp1_outc (compress=yes
        label='Outcome codes for GLP-1 PS cases');
    length primaryid 8 outc_cod $2;
    set work.glp1_outc;
run;

proc export data=work.qc_extract
            outfile="&OUT_QC./qc_glp1_extract.csv" dbms=csv replace;
run;

%macro finish;
    %local e;
    %let e = %sysevalf(%sysfunc(datetime()) - &_T0);

    %put NOTE: ============================================;
    %put NOTE: 03_glp1_extract.sas complete.;
    %put NOTE: PS drug records (raw) = &N_DRUG_RAW;
    %put NOTE: Case x drug pairs     = &N_PAIRS;
    %put NOTE: Unique cases          = &N_CASES;
    %put NOTE: Newer / older         = &N_NEWER / &N_OLDER;
    %put NOTE: Cross-cohort overlap  = &N_OVERLAP;
    %put NOTE: Reactions             = &N_REAC;
    %put NOTE: Indications           = &N_INDI (dropped by dedup: &N_INDI_DROPPED);
    %put NOTE: Outcomes              = &N_OUTC;
    %put NOTE: Datasets              = CLEAN.GLP1_CASES GLP1_REAC GLP1_INDI GLP1_OUTC;
    %put NOTE: QC                    = &OUT_QC./qc_glp1_extract.csv;
    %put NOTE: Elapsed               = %sysfunc(putn(&e, time12.2));
    %put NOTE: ============================================;

    %if &N_OOT = 0 %then
        %put NOTE: GLP-1 EXTRACT PASSED - ready for Phase 3 Step 2.;
    %else
        %put WARNING: &N_OOT molecule(s) outside tolerance - resolve before Step 2.;
%mend finish;

%finish

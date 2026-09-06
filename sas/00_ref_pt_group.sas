/*****************************************************************************
 * 00_ref_pt_group.sas - MedDRA PT groupings for the GLP-1 class effects
 *
 * Purpose:  Reference data. Maps individual MedDRA Preferred Terms to the
 *           eight class-effect groups Phase 3 compares molecules on.
 *           %include it AFTER 00_config.sas in any program that reports a
 *           class effect rather than a single PT.
 *
 * Creates:  WORK.REF_PT_GROUP   one row per PT, or per matching rule
 *
 * -----------------------------------------------------------------------
 * WHY THIS FILE EXISTS
 * -----------------------------------------------------------------------
 * 03_glp1_signal_profile.sas ranks signals one PT at a time, and its first
 * run showed what that costs. SEMAGLUTIDE reports pancreatitis mostly as
 * 'Pancreatitis' - 456 cases, EBGM rank 92 of 363. TIRZEPATIDE's most
 * disproportionate pancreatitis term is 'Obstructive pancreatitis' - 93
 * cases, rank 13, inside the top 20. Same class effect, different MedDRA
 * term, opposite conclusions. A head-to-head on either single PT would
 * answer a question about coding practice rather than about the molecules.
 *
 * The fragmentation is not marginal. SEMAGLUTIDE's pancreatitis family is
 * spread over ranks 62, 92, 114, 249 and 312, and those terms cover 655
 * distinct cases against the 456 that 'Pancreatitis' alone carries.
 *
 * MedDRA publishes SMQs (Standardised MedDRA Queries) for exactly this
 * purpose, but SMQ mappings require a MedDRA subscription and ship with
 * neither the FAERS ASCII extract nor SAS. These groups are the hand-built
 * substitute: narrower than an SMQ, scoped to the class effects this project
 * reports, and derived from the PTs actually present in the data rather than
 * from a term list that may not match what reporters wrote. Two terms in the
 * original draft, 'Gastroparesis' and 'Gastric emptying decreased', do not
 * occur in this extract at all. The term reporters actually use is 'Impaired
 * gastric emptying' - 4,006 reports, an Evans signal on all four molecules.
 *
 * -----------------------------------------------------------------------
 * TWO MATCH TYPES
 * -----------------------------------------------------------------------
 *   match_type = 'exact'    match_string is one PT, compared with =
 *   match_type = 'prefix'   match_string is a stem, compared with FIND() = 1
 *
 * Only INJECTION_SITE uses the prefix rule. Its family runs to 52 PTs in
 * this extract alone and grows with every new device and formulation, so an
 * enumeration would be both long and permanently out of date.
 *
 * FIND(..., 'i') = 1 rather than > 0: position 1 means the PT STARTS with
 * the stem, so an unrelated term that merely mentions an injection site
 * cannot be swept in. The one PT this misses, 'Lack of injection site
 * rotation', is a technique error rather than an injection site reaction and
 * carries 4 reports with no signal on any molecule.
 *
 * Every other group is enumerated, because enumeration keeps a clinical
 * judgement visible and reviewable. Three worth stating:
 *
 *   - 'Cholecystectomy' and 'Gallbladder operation' are in GALLBLADDER.
 *     Neither is an adverse event, but nobody has a gallbladder removed for
 *     no reason, so excluding them would understate the class effect. They
 *     carry pt_subtype='procedure' so a reviewer can drop them in one WHERE.
 *
 *   - THYROID_NEO and THYROID_DYS are separate groups, not one 'Thyroid'
 *     group. The GLP-1 boxed warning is about C-cell tumours, not thyroid
 *     function, and merging them would make 'a stronger thyroid signal'
 *     unreadable. The split earns itself: THYROID_NEO holds 7 rows that are
 *     Evans signals on some molecule, THYROID_DYS holds none at all.
 *
 *   - PANC_MALIG is separate from PANCREATITIS for the same reason.
 *     Pancreatic malignancy and acute pancreatic inflammation are different
 *     safety questions. 'Pancreatic cystadenoma' is benign and is therefore
 *     in neither group.
 *
 * -----------------------------------------------------------------------
 * GRAIN
 * -----------------------------------------------------------------------
 * One row per PT per group, and no PT currently belongs to two groups - the
 * assertion in section 3 fails loudly if that stops being true, because a
 * duplicate would silently double-count cases in every group-level total.
 *
 * -----------------------------------------------------------------------
 * HOW TO JOIN
 * -----------------------------------------------------------------------
 *     proc sql;
 *         create table work.grouped as
 *             select  g.pt_group, g.group_label, g.pt_subtype, s.*
 *             from    signal.glp1_signals as s,
 *                     work.ref_pt_group   as g
 *             where  (g.match_type = 'exact'
 *                     and upcase(strip(s.pt)) = upcase(strip(g.match_string)))
 *                or  (g.match_type = 'prefix'
 *                     and find(s.pt, strip(g.match_string), 'i') = 1);
 *     quit;
 *
 * A cross join filtered by the match rule, the same shape as the
 * REF_GLP1_DRUG join in 03_glp1_extract.sas section 2. Note it is a FILTER,
 * not a classification of every PT: a PT in no group simply does not appear,
 * which is intended - these eight groups cover the class effects this
 * project reports on, not the 4,917 PTs in the extract.
 *
 * IMPORTANT - do not sum a group's member PRRs. A group-level rate must be
 * rebuilt from cases: count DISTINCT primaryid over the group's PTs, then
 * recompute the 2x2. A case reporting both 'Pancreatitis' and 'Pancreatitis
 * acute' is one case, not two.
 *
 * Author:   Hingling Yu
 * Created:  2026-09-06
 *****************************************************************************/

/*==========================================================================
  1. THE GROUPING TABLE
  --------------------------------------------------------------------------
  Membership was derived from the PTs present in SIGNAL.GLP1_SIGNALS, so
  every enumerated term below is one a GLP-1 reporter actually used.

  Nothing but data may appear between DATALINES and its terminating
  semicolon - SAS reads a comment there as a data row, and the semicolon has
  to sit alone on its own line - so the per-group breakdown lives here:

 *     PANCREATITIS     49 row(s)    2,260 reports   Pancreatitis
 *     PANC_MALIG        8 row(s)      205 reports   Pancreatic malignancy
 *     GALLBLADDER      58 row(s)    2,460 reports   Gallbladder / biliary
 *     THYROID_NEO      19 row(s)      334 reports   Thyroid neoplasm
 *     THYROID_DYS      13 row(s)      204 reports   Thyroid dysfunction
 *     GASTROPARESIS     6 row(s)    4,985 reports   Gastroparesis / hypomotility
 *     GI_COMMON        33 row(s)   48,530 reports   Common GI events
 *     INJECTION_SITE    1 row(s)   17,540 reports   Injection site events

  Report counts are the sum of cell a across the four molecules and
  double-count a case reported on two of them. They size a group; they are
  not case counts.
  ==========================================================================*/
data work.ref_pt_group;
    length pt_group $14 group_label $30 match_type $6
           match_string $100 pt_subtype $10;
    infile datalines dlm='|' truncover;
    input pt_group $ group_label $ match_type $ match_string $ pt_subtype $;

    label pt_group     = 'Class effect group'
          group_label  = 'Group display label'
          match_type   = 'exact or prefix'
          match_string = 'MedDRA PT, or stem for a prefix rule'
          pt_subtype   = 'condition, procedure or lab';
    datalines;
PANCREATITIS|Pancreatitis|exact|Pancreatitis|condition
PANCREATITIS|Pancreatitis|exact|Pancreatitis acute|condition
PANCREATITIS|Pancreatitis|exact|Lipase increased|lab
PANCREATITIS|Pancreatitis|exact|Obstructive pancreatitis|condition
PANCREATITIS|Pancreatitis|exact|Pancreatic disorder|condition
PANCREATITIS|Pancreatitis|exact|Amylase increased|lab
PANCREATITIS|Pancreatitis|exact|Pancreatitis necrotising|condition
PANCREATITIS|Pancreatitis|exact|Pancreatic enzymes increased|lab
PANCREATITIS|Pancreatitis|exact|Pancreatic cyst|condition
PANCREATITIS|Pancreatitis|exact|Pancreatitis chronic|condition
PANCREATITIS|Pancreatitis|exact|Pancreatic failure|condition
PANCREATITIS|Pancreatitis|exact|Oedematous pancreatitis|condition
PANCREATITIS|Pancreatitis|exact|Pancreatic mass|condition
PANCREATITIS|Pancreatitis|exact|Pancreatolithiasis|condition
PANCREATITIS|Pancreatitis|exact|Pancreatic pseudocyst|condition
PANCREATITIS|Pancreatitis|exact|Autoimmune pancreatitis|condition
PANCREATITIS|Pancreatitis|exact|Pancreatic enlargement|condition
PANCREATITIS|Pancreatitis|exact|Pancreatic atrophy|condition
PANCREATITIS|Pancreatitis|exact|Pancreatic injury|condition
PANCREATITIS|Pancreatitis|exact|Pancreatitis relapsing|condition
PANCREATITIS|Pancreatitis|exact|Amylase abnormal|lab
PANCREATITIS|Pancreatitis|exact|Pancreatic duct dilatation|condition
PANCREATITIS|Pancreatitis|exact|Pancreatic steatosis|condition
PANCREATITIS|Pancreatitis|exact|Lipase abnormal|lab
PANCREATITIS|Pancreatitis|exact|Pancreatic duct obstruction|condition
PANCREATITIS|Pancreatitis|exact|Pancreatic enzyme abnormality|lab
PANCREATITIS|Pancreatitis|exact|Pancreatic enzymes decreased|lab
PANCREATITIS|Pancreatitis|exact|Peripancreatic fluid collection|condition
PANCREATITIS|Pancreatitis|exact|Alcoholic pancreatitis|condition
PANCREATITIS|Pancreatitis|exact|Pancreatic fibrosis|condition
PANCREATITIS|Pancreatitis|exact|Amylase decreased|lab
PANCREATITIS|Pancreatitis|exact|Benign pancreatic neoplasm|condition
PANCREATITIS|Pancreatitis|exact|Haemorrhagic necrotic pancreatitis|condition
PANCREATITIS|Pancreatitis|exact|Pancreatic fistula|condition
PANCREATITIS|Pancreatitis|exact|Pancreatic haemorrhage|condition
PANCREATITIS|Pancreatitis|exact|Pancreatic islets hyperplasia|condition
PANCREATITIS|Pancreatitis|exact|Pancreatogenous diabetes|condition
PANCREATITIS|Pancreatitis|exact|Subacute pancreatitis|condition
PANCREATITIS|Pancreatitis|exact|Cystic fibrosis pancreatic|condition
PANCREATITIS|Pancreatitis|exact|Idiopathic pancreatitis|condition
PANCREATITIS|Pancreatitis|exact|Lipase decreased|lab
PANCREATITIS|Pancreatitis|exact|Pancreatic calcification|condition
PANCREATITIS|Pancreatitis|exact|Pancreatic duct stenosis|condition
PANCREATITIS|Pancreatitis|exact|Pancreatic enzymes|lab
PANCREATITIS|Pancreatitis|exact|Pancreatic operation|procedure
PANCREATITIS|Pancreatitis|exact|Pancreatic pseudoaneurysm|condition
PANCREATITIS|Pancreatitis|exact|Pancreaticoduodenectomy|procedure
PANCREATITIS|Pancreatitis|exact|Pancreatitis bacterial|condition
PANCREATITIS|Pancreatitis|exact|Pancreatitis haemorrhagic|condition
PANC_MALIG|Pancreatic malignancy|exact|Pancreatic carcinoma|condition
PANC_MALIG|Pancreatic malignancy|exact|Pancreatic carcinoma metastatic|condition
PANC_MALIG|Pancreatic malignancy|exact|Pancreatic neoplasm|condition
PANC_MALIG|Pancreatic malignancy|exact|Pancreatic neuroendocrine tumour|condition
PANC_MALIG|Pancreatic malignancy|exact|Pancreatic carcinoma stage IV|condition
PANC_MALIG|Pancreatic malignancy|exact|Pancreatic neuroendocrine tumour metastatic|condition
PANC_MALIG|Pancreatic malignancy|exact|Pancreatic carcinoma recurrent|condition
PANC_MALIG|Pancreatic malignancy|exact|Pancreaticobiliary carcinoma|condition
GALLBLADDER|Gallbladder / biliary|exact|Cholelithiasis|condition
GALLBLADDER|Gallbladder / biliary|exact|Cholecystitis|condition
GALLBLADDER|Gallbladder / biliary|exact|Gallbladder disorder|condition
GALLBLADDER|Gallbladder / biliary|exact|Cholecystectomy|procedure
GALLBLADDER|Gallbladder / biliary|exact|Gallbladder injury|condition
GALLBLADDER|Gallbladder / biliary|exact|Biliary colic|condition
GALLBLADDER|Gallbladder / biliary|exact|Cholecystitis acute|condition
GALLBLADDER|Gallbladder / biliary|exact|Cholangitis|condition
GALLBLADDER|Gallbladder / biliary|exact|Bile duct stone|condition
GALLBLADDER|Gallbladder / biliary|exact|Cholecystitis infective|condition
GALLBLADDER|Gallbladder / biliary|exact|Biliary obstruction|condition
GALLBLADDER|Gallbladder / biliary|exact|Acute cholecystitis necrotic|condition
GALLBLADDER|Gallbladder / biliary|exact|Gallbladder enlargement|condition
GALLBLADDER|Gallbladder / biliary|exact|Cholecystitis chronic|condition
GALLBLADDER|Gallbladder / biliary|exact|Gallbladder operation|procedure
GALLBLADDER|Gallbladder / biliary|exact|Biliary dilatation|condition
GALLBLADDER|Gallbladder / biliary|exact|Biliary tract disorder|condition
GALLBLADDER|Gallbladder / biliary|exact|Gallbladder polyp|condition
GALLBLADDER|Gallbladder / biliary|exact|Gallbladder rupture|condition
GALLBLADDER|Gallbladder / biliary|exact|Bile duct stenosis|condition
GALLBLADDER|Gallbladder / biliary|exact|Cholangitis acute|condition
GALLBLADDER|Gallbladder / biliary|exact|Biliary dyskinesia|condition
GALLBLADDER|Gallbladder / biliary|exact|Cholangiocarcinoma|condition
GALLBLADDER|Gallbladder / biliary|exact|Gallbladder hypofunction|condition
GALLBLADDER|Gallbladder / biliary|exact|Cholelithotomy|condition
GALLBLADDER|Gallbladder / biliary|exact|Gallbladder cancer|condition
GALLBLADDER|Gallbladder / biliary|exact|Primary biliary cholangitis|condition
GALLBLADDER|Gallbladder / biliary|exact|Biliary sepsis|condition
GALLBLADDER|Gallbladder / biliary|exact|Cholelithiasis obstructive|condition
GALLBLADDER|Gallbladder / biliary|exact|Gallbladder oedema|condition
GALLBLADDER|Gallbladder / biliary|exact|Bile duct cancer|condition
GALLBLADDER|Gallbladder / biliary|exact|Hydrocholecystis|condition
GALLBLADDER|Gallbladder / biliary|exact|Cholangitis infective|condition
GALLBLADDER|Gallbladder / biliary|exact|Cholesterosis|condition
GALLBLADDER|Gallbladder / biliary|exact|Gallbladder adhesion|condition
GALLBLADDER|Gallbladder / biliary|exact|Gallbladder atrophy|condition
GALLBLADDER|Gallbladder / biliary|exact|Hepatobiliary cancer|condition
GALLBLADDER|Gallbladder / biliary|exact|Hepatobiliary disease|condition
GALLBLADDER|Gallbladder / biliary|exact|Post cholecystectomy syndrome|procedure
GALLBLADDER|Gallbladder / biliary|exact|Bile duct stent insertion|procedure
GALLBLADDER|Gallbladder / biliary|exact|Biliary ascites|condition
GALLBLADDER|Gallbladder / biliary|exact|Biliary catheter insertion|condition
GALLBLADDER|Gallbladder / biliary|exact|Biliary cyst|condition
GALLBLADDER|Gallbladder / biliary|exact|Biliary fibrosis|condition
GALLBLADDER|Gallbladder / biliary|exact|Cholangitis chronic|condition
GALLBLADDER|Gallbladder / biliary|exact|Cholangitis sclerosing|condition
GALLBLADDER|Gallbladder / biliary|exact|Cholecystostomy|condition
GALLBLADDER|Gallbladder / biliary|exact|Cholelithiasis migration|condition
GALLBLADDER|Gallbladder / biliary|exact|Cholera|condition
GALLBLADDER|Gallbladder / biliary|exact|Gallbladder abscess|condition
GALLBLADDER|Gallbladder / biliary|exact|Gallbladder empyema|condition
GALLBLADDER|Gallbladder / biliary|exact|Gallbladder hyperfunction|condition
GALLBLADDER|Gallbladder / biliary|exact|Gallbladder mucocoele|condition
GALLBLADDER|Gallbladder / biliary|exact|Gallbladder neoplasm|condition
GALLBLADDER|Gallbladder / biliary|exact|Gallbladder obstruction|condition
GALLBLADDER|Gallbladder / biliary|exact|Hepatobiliary infection|condition
GALLBLADDER|Gallbladder / biliary|exact|Hyperplastic cholecystopathy|condition
GALLBLADDER|Gallbladder / biliary|exact|Perforation bile duct|condition
THYROID_NEO|Thyroid neoplasm|exact|Thyroid mass|condition
THYROID_NEO|Thyroid neoplasm|exact|Thyroid cancer|condition
THYROID_NEO|Thyroid neoplasm|exact|Papillary thyroid cancer|condition
THYROID_NEO|Thyroid neoplasm|exact|Medullary thyroid cancer|condition
THYROID_NEO|Thyroid neoplasm|exact|Thyroid neoplasm|condition
THYROID_NEO|Thyroid neoplasm|exact|Benign neoplasm of thyroid gland|condition
THYROID_NEO|Thyroid neoplasm|exact|Blood calcitonin increased|lab
THYROID_NEO|Thyroid neoplasm|exact|Thyroidectomy|procedure
THYROID_NEO|Thyroid neoplasm|exact|Thyroid cancer metastatic|condition
THYROID_NEO|Thyroid neoplasm|exact|Anaplastic thyroid cancer|condition
THYROID_NEO|Thyroid neoplasm|exact|Follicular thyroid cancer|condition
THYROID_NEO|Thyroid neoplasm|exact|Thyroid adenoma|condition
THYROID_NEO|Thyroid neoplasm|exact|Parathyroid tumour|condition
THYROID_NEO|Thyroid neoplasm|exact|Parathyroid tumour benign|condition
THYROID_NEO|Thyroid neoplasm|exact|Parathyroidectomy|procedure
THYROID_NEO|Thyroid neoplasm|exact|Thyroid C-cell hyperplasia|condition
THYROID_NEO|Thyroid neoplasm|exact|Thyroid cancer recurrent|condition
THYROID_NEO|Thyroid neoplasm|exact|Thyroid cancer stage I|condition
THYROID_NEO|Thyroid neoplasm|exact|Thyroid nodule removal|condition
THYROID_DYS|Thyroid dysfunction|exact|Hyperthyroidism|condition
THYROID_DYS|Thyroid dysfunction|exact|Hypothyroidism|condition
THYROID_DYS|Thyroid dysfunction|exact|Blood thyroid stimulating hormone increased|lab
THYROID_DYS|Thyroid dysfunction|exact|Autoimmune thyroiditis|condition
THYROID_DYS|Thyroid dysfunction|exact|Blood thyroid stimulating hormone decreased|lab
THYROID_DYS|Thyroid dysfunction|exact|Thyroiditis|condition
THYROID_DYS|Thyroid dysfunction|exact|Thyroid function test abnormal|lab
THYROID_DYS|Thyroid dysfunction|exact|Blood thyroid stimulating hormone abnormal|lab
THYROID_DYS|Thyroid dysfunction|exact|Thyroiditis acute|condition
THYROID_DYS|Thyroid dysfunction|exact|Thyroiditis subacute|condition
THYROID_DYS|Thyroid dysfunction|exact|Autoimmune hypothyroidism|condition
THYROID_DYS|Thyroid dysfunction|exact|Post procedural hypothyroidism|condition
THYROID_DYS|Thyroid dysfunction|exact|Primary hypothyroidism|condition
GASTROPARESIS|Gastroparesis / hypomotility|exact|Impaired gastric emptying|condition
GASTROPARESIS|Gastroparesis / hypomotility|exact|Gastrointestinal hypomotility|condition
GASTROPARESIS|Gastroparesis / hypomotility|exact|Gastric hypomotility|condition
GASTROPARESIS|Gastroparesis / hypomotility|exact|Gastrointestinal motility disorder|condition
GASTROPARESIS|Gastroparesis / hypomotility|exact|Gastric dilatation|condition
GASTROPARESIS|Gastroparesis / hypomotility|exact|Diabetic gastroparesis|condition
GI_COMMON|Common GI events|exact|Nausea|condition
GI_COMMON|Common GI events|exact|Diarrhoea|condition
GI_COMMON|Common GI events|exact|Vomiting|condition
GI_COMMON|Common GI events|exact|Constipation|condition
GI_COMMON|Common GI events|exact|Abdominal pain upper|condition
GI_COMMON|Common GI events|exact|Abdominal pain|condition
GI_COMMON|Common GI events|exact|Abdominal discomfort|condition
GI_COMMON|Common GI events|exact|Abdominal distension|condition
GI_COMMON|Common GI events|exact|Vomiting projectile|condition
GI_COMMON|Common GI events|exact|Abdominal pain lower|condition
GI_COMMON|Common GI events|exact|Abdominal tenderness|condition
GI_COMMON|Common GI events|exact|Abdominal rigidity|condition
GI_COMMON|Common GI events|exact|Abdominal infection|condition
GI_COMMON|Common GI events|exact|Abdominal adhesions|condition
GI_COMMON|Common GI events|exact|Abdominal hernia|condition
GI_COMMON|Common GI events|exact|Abdominal mass|condition
GI_COMMON|Common GI events|exact|Abdominal abscess|condition
GI_COMMON|Common GI events|exact|Abdominal operation|procedure
GI_COMMON|Common GI events|exact|Abdominal injury|condition
GI_COMMON|Common GI events|exact|Abdominal sepsis|condition
GI_COMMON|Common GI events|exact|Abdominal fat apron|condition
GI_COMMON|Common GI events|exact|Abdominal neoplasm|condition
GI_COMMON|Common GI events|exact|Abdominal compartment syndrome|condition
GI_COMMON|Common GI events|exact|Abdominal hernia obstructive|condition
GI_COMMON|Common GI events|exact|Abdominal wall disorder|condition
GI_COMMON|Common GI events|exact|Abdominal hernia repair|condition
GI_COMMON|Common GI events|exact|Abdominal lymphadenopathy|condition
GI_COMMON|Common GI events|exact|Abdominal panniculectomy|procedure
GI_COMMON|Common GI events|exact|Abdominal symptom|condition
GI_COMMON|Common GI events|exact|Abdominal wall abscess|condition
GI_COMMON|Common GI events|exact|Abdominal wall haematoma|condition
GI_COMMON|Common GI events|exact|Abdominal wall haemorrhage|condition
GI_COMMON|Common GI events|exact|Abdominal wall infection|condition
INJECTION_SITE|Injection site events|prefix|Injection site|condition
;
run;

/*==========================================================================
  2. DERIVED MACRO VARIABLES
  --------------------------------------------------------------------------
  Built FROM the dataset, never typed twice, so the table stays the single
  source of truth for what a class effect contains.
  ==========================================================================*/
proc sql noprint;
    select count(distinct pt_group) into :N_PT_GROUPS     trimmed from work.ref_pt_group;
    select count(*)                 into :N_PT_GROUP_ROWS trimmed from work.ref_pt_group;
    select distinct pt_group        into :PT_GROUP_LIST separated by ' '
        from work.ref_pt_group;
quit;

/*==========================================================================
  3. ASSERTION - no PT may belong to two groups
  --------------------------------------------------------------------------
  A duplicate would double-count cases in every group-level total, and would
  do so silently. Checked here so the file that introduces the problem is the
  file that reports it.
  ==========================================================================*/
%macro _check_pt_group;
    %local ndup;
    proc sql noprint;
        select count(*) into :ndup trimmed
            from (select match_string from work.ref_pt_group
                  where match_type = 'exact'
                  group by upcase(strip(match_string))
                  having count(*) > 1);
    quit;

    %if &ndup > 0 %then %do;
        %put ERROR: &ndup PT(s) in WORK.REF_PT_GROUP belong to more than one group.;
        %put ERROR- Group totals would double-count those cases. Fix 00_ref_pt_group.sas.;

        proc sql;
            select pt_group, group_label, match_string
                from work.ref_pt_group
                where upcase(strip(match_string)) in
                      (select upcase(strip(match_string)) from work.ref_pt_group
                       where match_type = 'exact'
                       group by upcase(strip(match_string)) having count(*) > 1)
                order by match_string, pt_group;
        quit;
    %end;
    %else %put NOTE: PT group assertion passed - no PT belongs to two groups.;
%mend _check_pt_group;

%_check_pt_group

%put NOTE: ============================================;
%put NOTE: 00_ref_pt_group.sas loaded successfully.;
%put NOTE: Groups     = &N_PT_GROUPS (&N_PT_GROUP_ROWS rows);
%put NOTE: Group list = &PT_GROUP_LIST;
%put NOTE: ============================================;

# FAERS GLP-1 Signal Detection — Tableau Dashboard Spec

**Version:** 3.0
**Date:** 2026-09-16
**Audience:** RWE / Drug Safety Analyst (single dashboard, single persona)
**Platform:** Tableau Desktop → Tableau Public
**Data window:** FAERS 2025Q3–2026Q2 (1.53M reports, 111,673 GLP-1 subset)
**Delivery format:** Tableau Story (6 storypoints), each storypoint is an interactive dashboard sheet

---

## Change Log from v2 → v3

| # | Change | Rationale |
|---|--------|-----------|
| 1 | SP1: 3 bar charts → **Treemap + Population Pyramid + Dumbbell** | Eliminate all-bar-chart monotony; each chart type matches its data shape |
| 2 | SP3: Butterfly chart → **Dumbbell Chart** | Cleaner comparison, modern Tableau technique, shows gap magnitude at a glance |
| 3 | SP5: Static small multiples → **Bump Chart** (signal ranking over time) | Shows rank shifts, not just levels — more visually dynamic and multi-dimensional |
| 4 | SP5: Trend distribution stacked bar → **Waffle/Unit Chart** | Visual impact, shows proportion intuitively |
| 5 | SP6: Static table → **Interactive Scorecard + Waffle** for 7/8 | Boring table → visual validation result with click-to-expand |
| 6 | **Viz-in-Tooltip** added to SP2, SP3, SP4, SP5 | Hover = embedded mini-chart; adds hidden depth without clutter |
| 7 | **Highlight Actions** added to SP1, SP2, SP3 | Click a drug → all charts on that storypoint highlight; cross-chart linkage |
| 8 | **Parameter Toggle** on SP3 | Switch between "Group level" and "PT level" view within one storypoint |
| 9 | **Show/Hide Detail Panels** on SP6 | Click a Crown Jewel row → floating container reveals the full story |
| 10 | **Custom Navigation Buttons** replace default Story navigator | Branded, color-matched nav bar with progress indicator |
| 11 | KPI styling adopted from SellerOps | Title 22 Bold #333333, Big number 18 Bold #555555, KPI label 10 #999999 |

---

## Design Principles (unchanged + additions)

1. **Controlled narrative, not exploratory dashboard.** Story format for interview pacing.
2. **One analytical chain.** Cohort → Screening → Comparative → Stratified → Temporal → Validation.
3. **Crown jewels visible, not buried.** NAION, suicidality, gastroparesis at maximum narrative impact.
4. **Honest about limitations at every step.**
5. **PV terminology, not generic data science.**
6. 🆕 **Interaction serves depth, not distraction.** Every interactive element reveals a DEEPER layer of the same analysis — it does not let the viewer wander to unrelated data. Hover = detail. Click = cross-reference. Toggle = alternate dimension. Nothing requires the interviewer to "explore" — you control what they see; interactivity rewards curiosity.
7. 🆕 **No chart type repeats across storypoints.** Each storypoint uses a distinct primary visualization: treemap, forest plot, heatmap + dumbbell, slope chart, bump chart, scorecard + waffle. This demonstrates Tableau range.
8. 🆕 **Three-layer information architecture.** Surface (what you see) → Hover (viz-in-tooltip detail) → Click (cross-highlight context). The interviewer gets the story at surface level; engaged interviewers discover the depth.

---

## Data Sources (unchanged from v2)

| File | Used In | Notes |
|---|---|---|
| `report_executive_summary.csv` | SP1 KPIs | 23 rows, section/metric/value |
| `report_cohort_summary.csv` | SP1 | drug_label × category |
| `report_top_signals.csv` | SP2 | 80 rows: 20 per drug |
| `report_four_drug.csv` | SP3a | GROUP-level 4-drug comparison |
| `report_drug_compare.csv` | SP3b | PT-level SEMA vs TIRZ |
| `glp1_compare_overview.csv` | SP3a alt | Full event_type × drug matrix |
| `glp1_age_dependent.csv` | SP4 | Age-stratified PRR |
| `report_subgroup_highlights.csv` | SP4 | Curated highlights |
| `glp1_emerging_signals.csv` | SP5 | Emerging + accelerating with quarterly PRR |
| `glp1_trend_summary.csv` | SP5 | Full trend data |
| `report_validation.csv` | SP6 | 12-group validation reference set |
| `report_crown_jewels.csv` | SP3, SP5, SP6 | 6 interview talking points |

---

## Global Interaction Layer

These interactions apply across multiple storypoints:

### 1. Highlight Actions (Drug-Level)

On SP1, SP2, SP3: clicking any mark colored by drug triggers a **Highlight Action** that dims all other drugs across every sheet on that storypoint.

- **Trigger:** Select mark → Highlight
- **Source field:** `drug_label`
- **Target:** All sheets on the same dashboard
- **Effect:** Selected drug = full opacity; others = 20% opacity
- **Clear:** Click whitespace to reset
- **Interview use:** "Let me isolate semaglutide for you—" *click* → everything else fades

### 2. Viz-in-Tooltip

On SP2, SP3, SP4, SP5: hovering over a primary mark shows an embedded mini-chart in the tooltip.

- **Implementation:** Create a separate "tooltip sheet" for each, sized 300×200px
- **Design:** Minimal — no axis titles, no gridlines, just the data marks and reference line
- **Content per storypoint:** Defined below in each SP section

### 3. Parameter Toggle (SP3)

A parameter control switches between two pre-built views:

- **Parameter name:** `View Level`
- **Values:** "Signal Groups" (default) / "Preferred Terms"
- **Mechanism:** Two sheets stacked in a vertical container; Dynamic Zone Visibility shows/hides based on parameter
- **Interview use:** "Let me drill from group level to individual PTs—" *click toggle*

### 4. Custom Navigation Bar

Replace the default Story navigator strip with custom navigation:

- **Implementation:** Horizontal container at top of each storypoint dashboard
- **Content:** 6 buttons (one per storypoint), labeled with short titles
- **Active state:** Current storypoint button = dark teal fill + white text
- **Inactive state:** Light gray fill + dark text
- **Progress line:** Thin teal line connecting completed storypoints (left of active)
- **Mechanism:** Each button is a Dashboard Navigation action pointing to the target storypoint

```
┌─────────────────────────────────────────────────────────────────────┐
│ ● Cohort   ● Signals   ● Compare   ● Age   ● Trends   ● Validate │
│ ═══════════════●                                                    │
└─────────────────────────────────────────────────────────────────────┘
```

---

## KPI Styling (from SellerOps, applied globally)

| Element | Font Size | Weight | Color | Hex |
|---|---|---|---|---|
| Dashboard/Storypoint title | 22 | Bold | Deep gray | #333333 |
| KPI big number | 18 | Bold | Medium gray | #555555 |
| KPI subtitle/label | 10 | Regular | Light gray | #999999 |
| Chart title | 14 | Bold | Deep gray | #333333 |
| Annotation text | 10 | Regular | Medium gray | #666666 |
| Axis label | 9 | Regular | Gray | #888888 |

---

## Color Palette (FINAL — locked 2026-09-23)

Rule: one color = one meaning across all 6 storypoints. Text on dark fills = white; on light fills = #333333.

### Drug Colors (newer = teal/mint, comparator = grey-green)
| Drug | Hex | Label text |
|---|---|---|
| SEMAGLUTIDE | #1A7878 | white |
| TIRZEPATIDE | #6EB3A7 | #333333 |
| DULAGLUTIDE | #52736A | white |
| LIRAGLUTIDE | #A2B9AD | #333333 |

Derived uses (no new colors): Generation (SP1 age) newer = #1A7878, comparator = #52736A. SP3 direction: SEMA higher = #1A7878, TIRZ higher = #6EB3A7.

### Status & Accent
| Role | Hex | Where |
|---|---|---|
| Replicated | #7FB08A | SP6 |
| Caution (false positive) | #F5C889 | SP6 |
| Youth-elevated (Youth ↑) | #F5C889 | SP4 slope |
| Elderly-elevated (Elderly ↑) | #DD7560 | SP4 slope (coral — redder than heatmap #E87C52 so it separates from Youth ↑ amber) |
| Not Detected | #BDBDBD | SP6 (pure grey, never slate) |

Status/accent chosen 2026-09-23 (replaces #649552 / #E49832 / #C85C42 — too green/dark, not clinical). Text on all status fills = #333333. #F5C889 is light (~1.5:1 on white): SP4 lines ≥ 3 px, add direct end labels.

### PRR Intensity (SP3 heatmap, sequential brick)
| Range | Hex |
|---|---|
| PRR < 2 | #E5E5E5 |
| PRR 2–5 | #F9C8B2 |
| PRR 5–20 | #E87C52 |
| PRR 20–100 | #A83C32 |

### Neutrals
| Role | Hex |
|---|---|
| Text | #333333 / #555555 / #666666 / #888888 / #999999 |
| Gridlines, dividers | #E5E5E5 |
| SP2 background bands (PRR 2–5 / 5–20 / ≥20) | keep current cool-grey bands (unlabelled) |

---

## Storypoint 1: GLP-1 Cohort Overview

**Analytical question:** What population is under surveillance, and how is it distributed?
**Interview time:** 30 seconds
**Proves:** "I can define and characterize a pharmacoepidemiologic cohort"

### Layout

```
┌─────────────────────────────────────────────────────┐
│  [Custom Nav Bar]                                    │
├───────────┬───────────┬───────────┬─────────────────┤
│  KPI 1    │  KPI 2    │  KPI 3    │  KPI 4          │
│  111,673  │  9,630    │  704      │  7/8             │
│  GLP-1    │  Pairs    │  Evans    │  Validated       │
│  Cases    │  Screened │  Signals  │                  │
├───────────┴───────────┼───────────┴─────────────────┤
│                       │                              │
│  Chart A: Treemap     │  Chart B: Population Pyramid │
│  (Drug volume)        │  (Age × Drug)                │
│                       │                              │
├───────────────────────┴──────────────────────────────┤
│  Chart C: Dumbbell (Serious outcome % by drug)       │
├──────────────────────────────────────────────────────┤
│  Pipeline annotation + limitations                    │
└──────────────────────────────────────────────────────┘
```

### KPI Banner (4 tiles)

Same values as v2. Apply SellerOps styling:
- Big number: 18 Bold #555555
- Label: 10 Regular #999999
- Background: white card with subtle shadow or 1px #E2E8F0 border

| KPI | Value | Label |
|---|---|---|
| 111,673 | GLP-1 Cases | Total cases in cohort |
| 9,630 | Pairs Screened | Drug × PT combinations evaluated |
| 704 | Evans Signals | Clinical AE pairs flagging all 3 Evans criteria |
| 7/8 | Validated | Category A known risks replicated |

### Chart A: Treemap (Drug Report Volume) — replaces horizontal bar

- **Source:** `report_cohort_summary.csv` WHERE category = 'Overall'
- **Why treemap:** Immediately communicates proportion — TIRZ's dominance (63%) is visceral when its rectangle dwarfs the others. A bar chart makes you read numbers; a treemap makes you feel the imbalance.
- **Color:** Drug palette (dark teal / medium teal / dark slate / light slate)
- **Label on each rectangle:** Drug name + n_cases + pct (e.g., "TIRZEPATIDE\n70,111 (63%)")
- **Size:** Proportional to n_cases

**Highlight Action:** Click a drug rectangle → highlights that drug in Charts B and C

### Chart B: Population Pyramid (Age × Drug) — replaces stacked bar

- **Source:** `report_cohort_summary.csv` WHERE category = 'Age group'
- **Format:** Back-to-back horizontal bars, split by generation
  - Left side: Newer generation (SEMA + TIRZ combined or stacked)
  - Right side: Comparator generation (DULA + LIRA combined or stacked)
  - Y-axis: Age strata (≤45 / 46–64 / ≥65 / Unknown)
  - X-axis: Case count or percentage
- **Why population pyramid:** Standard epidemiological visualization for age distributions. Immediately shows the younger skew of TIRZ vs the older profile of comparators. Also demonstrates you know epi visualization conventions.
- **Alternative if pyramid is complex:** Butterfly-style diverging bar with SEMA/TIRZ on left and DULA/LIRA on right, y-axis = age group

**Annotation:** "Age coverage varies: SEMA 50.6%, TIRZ 66.0%. 'Unknown' is excluded from age-stratified analyses in SP4."

### Chart C: Dumbbell Chart (Outcome Seriousness) — replaces grouped bar

- **Source:** `report_cohort_summary.csv` WHERE category = 'Outcome'
- **Format:** Horizontal dumbbell (connected dot plot)
  - Y-axis: Outcome type (Hospitalization, Death, Life-Threatening, Other Serious, Non-Serious)
  - Each row shows 4 dots (one per drug) connected by a line
  - Dot color: drug palette
  - X-axis: Percentage of drug's cohort
- **Why dumbbell:** Shows the SPREAD between drugs on each outcome — LIRA 61.9% serious vs TIRZ 19.7% is dramatic when you see dots far apart on the same line. Grouped bars make you compare bar heights across groups; dumbbells make the gap the story.
- **Key callout:** "LIRAGLUTIDE: 61.9% serious outcomes — older, sicker, diabetes-indication reporters. TIRZEPATIDE: 19.7% — younger, weight-loss consumer reporters. This explains why denominators differ and why PRR comparisons must account for reporting context."

### Pipeline Annotation

> "1.53M FAERS reports (2025Q3–2026Q2) → SAS pipeline: import, deduplication (6.9%), cleaning → MySQL warehouse → 111,673 GLP-1 cases (primary suspect role, active-substance pattern matching)"

---

## Storypoint 2: Signal Screening

**Analytical question:** What does the engine's output look like, and which drug–event pairs merit investigation?
**Interview time:** 45 seconds
**Proves:** "I can build a signal detection engine and interpret its output"

### Layout

```
┌──────────────────────────────────────────────────────┐
│  [Custom Nav Bar]                                     │
├──────────────────────────────────────────────────────┤
│  Title: "704 clinical signals flagged by Evans"       │
├──────────────────────────────────────────────────────┤
│                                                       │
│  Forest Plot (lollipop + CI, 20 curated signals)     │
│  Y: PT name, sorted by PRR desc                      │
│  X: PRR (log scale)                                  │
│  Dot color: drug    Whisker: 95% CI                  │
│  Reference line: PRR = 2                             │
│                                                       │
│  [Hover any dot → VIZ-IN-TOOLTIP: mini bar chart     │
│   showing that PT across all 4 drugs]                │
│                                                       │
├──────────────────────────────────────────────────────┤
│  NAION callout ↗ | Gastroparesis callout ↗           │
├──────────────────────────────────────────────────────┤
│  Limitations footer                                   │
└──────────────────────────────────────────────────────┘
```

### Main Chart: Forest Plot (unchanged from v2 — already excellent)

Spec is identical to v2. This is the one chart type we do NOT change — forest plots are the PV literature standard.

- 20 curated signals (5 per drug or mixed for narrative)
- Lollipop: dot = PRR, whisker = 95% CI
- Log scale X-axis (mandatory — PRR range 2 to 478)
- Reference line at PRR = 2
- Color by drug

### 🆕 Viz-in-Tooltip: Cross-Drug Mini Bar

When you hover over any signal dot, a tooltip sheet appears showing:

- **Content:** Horizontal bar chart with 4 bars (one per drug), showing that SAME PT's PRR on each drug
- **Data source:** Need a lookup — `report_top_signals.csv` joined back to a wider signal table, OR pre-compute a cross-drug PRR table for the 20 curated PTs
- **Tooltip sheet size:** 300 × 180 px
- **Design:** Drug-colored bars, PRR = 2 reference line, no axis title, just drug label + PRR value
- **Why:** Interviewer hovers on "DULA Gastrointestinal hypomotility (PRR 471)" → sees it's also flagged on SEMA (PRR 26), TIRZ (PRR 4), and LIRA (PRR 28). Instant class-effect read without a separate chart.

### Highlight Action

Click any dot → all dots of that drug highlight, others dim to 20% opacity.

### Curation Strategy (unchanged from v2)

| Slot | Purpose | Example |
|---|---|---|
| 3–4 | High-PRR, high-case (robust) | DULA GI hypomotility (PRR 471), SEMA Cyclic vomiting (PRR 359) |
| 2–3 | Moderate-PRR, high-case (clinically important) | SEMA Pancreatitis (PRR ~6), TIRZ Injection site |
| 2–3 | Class effects (same PT, multiple drugs) | Nausea, Vomiting, Decreased appetite |
| 2 | Crown jewel anchors | SEMA NAION (PRR 101), DULA Gastric hypomotility (PRR 478) |
| 2–3 | Low-case / wide-CI (honest about power) | Any with a < 10 |

---

## Storypoint 3: Comparative Signal Profile

**Analytical question:** Which signals are class effects and which are molecule-specific?
**Interview time:** 60 seconds
**Proves:** "I can do comparative safety profiling, not just single-drug analysis"

### Layout

```
┌──────────────────────────────────────────────────────┐
│  [Custom Nav Bar]                                     │
├──────────────────────────────────────────────────────┤
│  Title + [Toggle: Signal Groups | Preferred Terms]    │
├──────────────────────────────────────────────────────┤
│                                                       │
│  View A (default): 4-Drug Signal Heatmap              │
│  Rows: event groups  Cols: drugs  Color: PRR          │
│  Bold border on n_drugs_signal = 4 (class effect)     │
│                                                       │
│  [Hover cell → VIZ-IN-TOOLTIP: mini forest plot       │
│   showing that event group's PRR + CI per drug]       │
│                                                       │
│  --- OR (toggle) ---                                  │
│                                                       │
│  View B: SEMA vs TIRZ Dumbbell Chart                  │
│  Center: PT name, dots at each drug's PRR             │
│  Connected by line, color = direction                 │
│                                                       │
├──────────────────────────────────────────────────────┤
│  🏆 Gastroparesis Litigation Annotation               │
├──────────────────────────────────────────────────────┤
│  Limitations footer                                   │
└──────────────────────────────────────────────────────┘
```

### Parameter Toggle: View Level

- **"Signal Groups" (default):** Shows Chart A — 4-drug heatmap at GROUP level
- **"Preferred Terms":** Shows Chart B — SEMA vs TIRZ dumbbell at PT level
- **Implementation:** Parameter + Dynamic Zone Visibility (two sheets in a vertical container, one visible at a time)
- **Interview use:** Start on Groups ("here's the class-level picture"), then toggle to PTs ("let me drill into the head-to-head")

### Chart A: 4-Drug Signal Heatmap (when toggle = "Signal Groups")

- **Source:** `report_four_drug.csv` (GROUP-level rows)
- **Format:** Heatmap matrix
  - Rows: 8–12 event groups (GASTROPARESIS, GALLBLADDER, PANCREATITIS, THYROID_NEO, INJECTION_SITE, GI_COMMON, ILEUS, HYPOGLYCAEMIA, etc.)
  - Columns: SEMA / TIRZ / DULA / LIRA
  - Cell color: PRR intensity (sequential single-hue, log-scaled)
  - Cell label: PRR value
  - **Bold border on rows where n_drugs_signal = 4** → "class effect"
  - Gray cell where PRR < 2

### 🆕 Viz-in-Tooltip on Heatmap: Mini Forest Plot

Hover over a heatmap cell → embedded tooltip shows:

- **Content:** Horizontal lollipop for that event group — 4 dots (one per drug), each with its PRR point estimate
- **Size:** 300 × 150 px
- **Reference line:** PRR = 2
- **Why:** The heatmap shows color intensity; the tooltip adds the numeric precision and cross-drug comparison for that one row

### Chart B: Dumbbell Chart — SEMA vs TIRZ (when toggle = "Preferred Terms")

- **Source:** `report_drug_compare.csv`
- **Format:** Horizontal dumbbell / connected dot plot
  - Y-axis: PT name (top 15–20 by |prr_diff|, curated across both directions)
  - Two dots per row: SEMA PRR (teal) and TIRZ PRR (amber)
  - Connected by a line — line length = magnitude of difference
  - **Sort:** By prr_diff (largest SEMA > TIRZ at top, largest TIRZ > SEMA at bottom)
  - X-axis: PRR (log scale)
  - Reference line: PRR = 2

- **Why dumbbell over butterfly:** The butterfly chart uses direction (left/right) to separate the two drugs, which duplicates information already in the position. The dumbbell puts both on the SAME scale so the gap between dots IS the finding. It's also more compact and modern.

- **Key highlight:** Injection-site row
  - TIRZ dot at PRR 3.84 (10,111 cases, 14.4%)
  - SEMA dot at PRR 1.00 (1,518 cases, 4.3%)
  - "Same class, same route, one measured difference."

### Highlight Action

Click either drug's dot → highlights all of that drug's dots on the current view.

### 🏆 Crown Jewel — Gastroparesis Annotation (unchanged from v2)

> "DULA gastroparesis: PRR 81, 974 cases — 24.2% of all dulaglutide reports. Compare: SEMA 5.9%, TIRZ 1.3%, LIRA 9.9%. A quarter of one molecule's entire reporting is one syndrome — the fingerprint of litigation-driven stimulated reporting."

---

## Storypoint 4: Stratified Analysis (Age-Dependent Signals)

**Analytical question:** Does age modify signal strength, and in which direction?
**Interview time:** 45 seconds
**Proves:** "I can stratify and identify effect modification"

### Layout

```
┌──────────────────────────────────────────────────────┐
│  [Custom Nav Bar]                                     │
├──────────────────────────────────────────────────────┤
│  Title: "Age modifies signal strength"                │
├────────────────────────────┬─────────────────────────┤
│                            │  Coverage Gauge          │
│  Slope Chart               │  SEMA: ████░ 50.6%      │
│  (PRR by age stratum)      │  TIRZ: ██████░ 66.0%    │
│                            │                          │
│  X: ≤45 / 46-64 / ≥65     ├─────────────────────────┤
│  Y: PRR (log)              │  Pattern Legend          │
│  Lines colored by drug     │  ↗ Elderly-elevated      │
│  Thickness by case count   │  ↘ Youth-concentrated   │
│                            │                          │
│  [Hover line → TOOLTIP:    │                          │
│   case counts per stratum  │                          │
│   + coverage %]            │                          │
│                            │                          │
├────────────────────────────┴─────────────────────────┤
│  Coverage bias annotation (mandatory, prominent)      │
└──────────────────────────────────────────────────────┘
```

### Main Chart: Slope Chart (kept from v2 — good fit for age strata)

- **Source:** `glp1_age_dependent.csv` + `report_subgroup_highlights.csv`
- **Format:** Connected dot plot / slope chart
  - X-axis: Age stratum (≤45 / 46–64 / ≥65) — 3 discrete points
  - Y-axis: PRR (log scale)
  - Lines: one per drug × event, colored by drug
  - **Line style:** Solid = elderly-elevated pattern; Dashed = youth-concentrated pattern
  - **Line thickness:** Mapped to total case count (thicker = more cases = more robust)
  - Reference line: PRR = 2

### 🆕 Viz-in-Tooltip: Stratum Detail Card

Hover over any point on a slope line → tooltip shows:

- **Content:** Text tooltip (not embedded chart — too complex for this data)
  - Drug × PT name
  - Age stratum: [stratum]
  - Cases in this stratum: [a_value]
  - PRR: [value] (CI: [lcl] – [ucl])
  - Coverage: [coverage_pct]%
  - Signal flag: [Yes/No]
- **Why text not viz:** Each line has only 3 points (3 age strata). A mini-chart for 3 bars adds no value over a well-formatted text card.

### 🆕 Coverage Gauge (sidebar)

- **Format:** Two horizontal progress bars (one per drug)
  - SEMA: 50.6% filled (teal)
  - TIRZ: 66.0% filled (teal, lighter)
  - Background: light gray
  - Label: "Age Coverage" title
- **Why:** Makes the coverage limitation visually present, not just a text note

### Curated Signals (8–10 lines, unchanged from v2)

**Elderly-elevated:** Weight increased, Pancreatitis necrotising, Drug dose titration not performed, Hyperphagia
**Youth-concentrated:** Biliary colic, Gallbladder group, Thyroid dysfunction group

### Coverage Bias Annotation (mandatory, unchanged)

> "Coverage: SEMA 50.6% / TIRZ 66.0%. Unknown excluded, not imputed. PRR are within-stratum comparisons — NOT prevalence, incidence, or absolute risk."

---

## Storypoint 5: Temporal Signal Tracking

**Analytical question:** Are signals stable, emerging, or declining across the 4-quarter window?
**Interview time:** 60 seconds
**Proves:** "I can track temporal signal dynamics"

### Layout

```
┌──────────────────────────────────────────────────────┐
│  [Custom Nav Bar]                                     │
├──────────────────────────────────────────────────────┤
│  Title: "Signals evolve quarter by quarter"           │
├──────────────────────────────────────────────────────┤
│                                                       │
│  Chart A: Bump Chart (Signal Rank Evolution)          │
│  X: Q3 2025 → Q4 2025 → Q1 2026 → Q2 2026          │
│  Y: Rank (1 = highest PRR)                           │
│  Lines: 8-10 curated drug × PT combinations          │
│  Color: drug palette                                 │
│  Line crossing = rank shift = story                  │
│                                                       │
│  [Hover line → VIZ-IN-TOOLTIP: sparkline of           │
│   actual PRR values + case counts per quarter]        │
│                                                       │
├───────────────────────┬──────────────────────────────┤
│  Chart B: Waffle      │  Trend velocity callout       │
│  (Trend Distribution) │  "SEMA Appetite disorder:     │
│  264 Emerging (teal)  │   PRR 14.8 → 34.1            │
│  57 Accelerating (dk) │   +6.4 PRR/quarter"           │
│  170 Declining (gray) │                               │
├───────────────────────┴──────────────────────────────┤
│  SEMA quarterly volume caveat + limitations           │
└──────────────────────────────────────────────────────┘
```

### Chart A: Bump Chart (Signal Rank Evolution) — replaces small multiples

- **Source:** `glp1_emerging_signals.csv` (filter to pt_category = 'CLINICAL_AE')
- **Format:** Bump chart
  - X-axis: 4 quarters (2025Q3 → 2026Q2)
  - Y-axis: Rank position (1 at top = highest PRR that quarter)
  - Lines: 8–10 curated drug × PT combinations
  - Color: drug palette
  - **Dot at each quarter position** — size proportional to case count (a_q1 through a_q4)
  - Labels on leftmost and rightmost dots: PT name (abbreviated)
  - **Key visual:** Lines that cross each other = signals trading rank positions over time

- **Why bump chart over small multiples:** Small multiples show each signal in isolation — you see individual trajectories but miss the competitive landscape. A bump chart shows HOW signals move RELATIVE to each other: a rising line that crosses above others is immediately dramatic. It's also a more advanced Tableau technique that demonstrates skill.

- **Rank computation:** For each quarter, rank the selected signals by PRR descending. If PRR is not computable (zero cases), that signal "drops off" — use a dotted line to the edge or omit the dot.

### 🆕 Viz-in-Tooltip: PRR Sparkline + Case Counts

Hover over any point on the bump chart → tooltip shows:

- **Content:** Mini line chart (sparkline) of actual PRR values across 4 quarters, plus text with:
  - Drug × PT
  - This quarter: PRR = X, cases = Y
  - Trend: [Emerging/Accelerating/Declining]
  - Velocity: [+/- X PRR per quarter]
- **Size:** 300 × 200 px
- **Reference line:** PRR = 2 in the sparkline
- **Why:** The bump chart shows RANK; the tooltip reveals the ACTUAL PRR values driving those ranks. Rank 1 with PRR = 939 and Rank 2 with PRR = 621 have very different clinical meaning.

### Curated Bump Chart Signals (8–10)

| # | Drug × PT | Trend | What it shows |
|---|-----------|-------|---------------|
| 1 | TIRZ × Neck mass | Emerging | Thyroid monitoring, rising through ranks |
| 2 | TIRZ × Pancreatic cyst | Emerging | New pancreatic safety concern |
| 3 | SEMA × Dysaesthesia | Emerging | Neuropathy-adjacent |
| 4 | SEMA × Appetite disorder | Accelerating | PRR 14.8→34.1, monotonic rise — climbs ranks |
| 5 | SEMA × [Declining example] | Declining | Falls through ranks — shows method works both directions |
| 6 | DULA × [Stable high example] | Stable | Stays at same rank — baseline |
| 7 | TIRZ × [Fast riser] | Accelerating | Dramatic rank jump mid-period |
| 8 | SEMA × [Inferred basis] | Emerging (Low) | Shows coverage-bias limitation |

### Chart B: Waffle Chart (Trend Distribution) — replaces stacked bar

- **Source:** `report_executive_summary.csv` Trends section
- **Format:** 10×10 waffle grid (or adjusted to fit proportions)
  - Each cell = ~10 signals (or 1% depending on total)
  - Colors: Emerging (medium teal), Accelerating (dark teal), Declining (slate gray)
  - Inconsistent (2,017) shown as a footnote count, NOT in the waffle — it would overwhelm
- **Counts:** Emerging 264, Accelerating 57, Declining 170
- **Label beneath:** Category name + count
- **Why waffle over stacked bar:** Waffle charts make proportions intuitive — you can literally count the cells. They're also visually distinctive and demonstrate a non-default Tableau technique.

### Volume Caveat (mandatory, unchanged)

> "SEMA quarterly volumes: Q1=13,519 / Q2=2,726 / Q3=2,895 / Q4=15,137. Middle quarters are 5× thinner — rank changes may reflect volume shifts, not true signal evolution."

---

## Storypoint 6: Validation & Crown Jewels

**Analytical question:** How do you know the engine works — and what did validation itself reveal?
**Interview time:** 45 seconds
**Proves:** "I validated before trusting, and validation itself produced findings"

### Layout

```
┌──────────────────────────────────────────────────────┐
│  [Custom Nav Bar]                                     │
├──────────────────────────────────────────────────────┤
│  Title: "7 of 8 known risks replicated"               │
├─────────────────────┬────────────────────────────────┤
│  Waffle: 7/8        │                                │
│  ███████░            │  Validation Scorecard          │
│  (7 green, 1 gray)  │  (12 rows, styled table)       │
│                     │                                │
│  Gate 3: PASS       │  Click row → detail panel ↓    │
│                     │                                │
├─────────────────────┴────────────────────────────────┤
│                                                       │
│  🏆 Crown Jewel Detail Panel (Show/Hide)             │
│  [Appears when clicking NAION, Suicidality, or       │
│   Gastroparesis row in scorecard]                     │
│                                                       │
│  Card 1: NAION — Independent Detection               │
│  Card 2: Suicidality — Engine Stays Quiet            │
│  Card 3: Gastroparesis — Litigation Fingerprint      │
│                                                       │
├──────────────────────────────────────────────────────┤
│  Full limitations footer                              │
└──────────────────────────────────────────────────────┘
```

### 🆕 Waffle Chart: 7/8 Validation Result

- **Format:** 2×4 grid (8 cells)
  - 7 cells: Green (#16A34A) with ✅
  - 1 cell: Gray (#94A3B8) with ⬜ — labeled "AKI (method limitation)"
- **Label below:** "Gate 3: 7 of 8 Category A signals replicated (87.5% ≥ 75%) — PASS"
- **Why waffle:** A number "7/8" is forgettable. Eight squares with seven green and one gray is immediate. This is the hero moment for the validation story — make it visual.

### Scorecard Table (12 rows, styled)

- **Source:** `report_validation.csv`
- **Format:** Custom-styled table using Tableau text marks or a worksheet formatted as a table
  - Columns: Status Icon | # | Category | Signal Group | Replicated | Best PRR | Interpretation
  - Row colors: Green background for REPLICATED, gray for PRR_BELOW_1, amber for CAUTION
  - **Click interaction:** Clicking rows D10 (NAION), C9 (Suicidality), or A8 (Gastroparesis) reveals the detail panel

### 🆕 Show/Hide Crown Jewel Detail Panel

- **Mechanism:** Floating container with Dynamic Zone Visibility, controlled by a Set Action on the scorecard
- **Default:** Hidden (collapsed to zero height)
- **Trigger:** Click a scorecard row that has a crown jewel → panel appears below with the full story card
- **Content:** Same crown jewel text as v2, but now revealed on-demand instead of always visible
- **Interview use:** "Let me show you what makes this validation interesting—" *clicks NAION row* → panel slides in with the full NAION discovery story

### Crown Jewel Cards (content unchanged from v2)

**🏆 Card 1 — NAION: Independent Detection**
> Engine detected NAION on SEMA (PRR 100, 625 cases) without being told to look. EMA PRAC concluded NAION as a side effect June 2025 — inside this data window. Time-indexed validation.

**🏆 Card 2 — Suicidality: Engine Stays Quiet**
> SEMA suicidal ideation: PRR 1.43, below Evans. Agrees with EMA and FDA. Two rare PTs cross Evans on small counts → false positive, reported honestly.

**🏆 Card 3 — Gastroparesis: Litigation Fingerprint**
> DULA gastroparesis: 24.2% of all reports. Litigation-driven stimulated reporting artifact. PRR is correct; interpreting it as comparative risk would be wrong.

### AKI Annotation (on the gray waffle cell or scorecard row)

> "AKI: labelled W&P on all 4 molecules, PRR < 1 on all four. Dehydration-mediated mechanism is real; the consumer-reporting-inflated denominator is what fails."

### Full Limitations Footer (unchanged from v2)

---

## Layout Per Storypoint

Each storypoint = a fixed-size Tableau dashboard:

```
Width:  1200px
Height: 800px (laptop screen, no scroll)
```

### Shared Components (present on every storypoint)

1. **Custom Nav Bar** — top, 40px height
2. **Storypoint Title** — 22 Bold #333333, left-aligned below nav
3. **Limitations Footer** — bottom, 30px height, 10pt #888888

### Spacing Guidelines

- Outer padding: 12px all sides
- Between charts: 8px
- Chart title to chart: 4px
- KPI tiles: Equal width, 8px gap between

---

## Interaction Summary Table

| Storypoint | Highlight Action | Viz-in-Tooltip | Parameter Toggle | Show/Hide Panel |
|---|---|---|---|---|
| SP1 | ✅ Drug click → cross-highlight | — | — | — |
| SP2 | ✅ Drug click → highlight dots | ✅ Cross-drug bar for hovered PT | — | — |
| SP3 | ✅ Drug click → highlight | ✅ Mini forest plot on heatmap cell | ✅ Group ↔ PT toggle | — |
| SP4 | — | ✅ Text detail card | — | — |
| SP5 | — | ✅ PRR sparkline + velocity | — | — |
| SP6 | — | — | — | ✅ Crown Jewel panels |

---

## Chart Type Inventory (no repeats)

| Storypoint | Primary Chart | Secondary Chart | Demonstrates |
|---|---|---|---|
| SP1 | Treemap | Population Pyramid + Dumbbell | Area-proportional + comparative dot |
| SP2 | Forest Plot (lollipop + CI) | — | PV literature standard |
| SP3 | Heatmap | Dumbbell (toggled) | Matrix comparison + paired comparison |
| SP4 | Slope Chart | Coverage gauge | Connected dots across strata |
| SP5 | Bump Chart | Waffle Chart | Rank evolution + proportional unit |
| SP6 | Waffle (7/8) | Interactive Scorecard | Unit visualization + table |

**Total distinct chart types used: 9** (treemap, pyramid, dumbbell, forest plot, heatmap, slope, bump, waffle, scorecard)

---

## Data Prep Notes for Tableau

1. **All CSVs in `output/tables/`.** Use `report_*.csv` as primary.
2. **PRR_CI parsing:** `report_top_signals.csv` stores CI as "478.0 (342.1 - 668.0)". Create calculated fields to extract LCL and UCL for forest plot whiskers.
3. **PRR log scale:** Mandatory on SP2, SP3b, SP4. Range spans 0.05 to 478.
4. **Bump chart rank computation:** Calculated field: `RANK_DENSE(SUM([PRR_Qx]), 'desc')` per quarter, filtered to curated signals.
5. **Waffle chart:** Built with a 10×10 grid using `INDEX()` and `INT()` table calculations, colored by trend category.
6. **Viz-in-Tooltip sheets:** Create as separate worksheets, sized 300×200 or 300×150, then inserted via Tooltip > Insert > Sheets.
7. **Parameter for SP3 toggle:** String parameter "View Level" with values "Signal Groups" and "Preferred Terms". Show parameter control as a button/radio selector.
8. **Dynamic Zone Visibility:** On SP3 and SP6, use calculated fields referencing the parameter or set to control container visibility.
9. **Custom navigation:** Dashboard > Actions > Change Storypoint (or use navigation buttons).
10. **Comma in numbers:** Some `best_a` values have comma formatting. Force numeric type.
11. **Quarter mapping:** prr_q1=2025Q3, prr_q2=2025Q4, prr_q3=2026Q1, prr_q4=2026Q2.

---

## Interview Script Anchors (unchanged from v2)

| SP | Opening line |
|---|---|
| 1 | "I built a SAS pipeline that imports, deduplicates, and cleans four quarters of FAERS data into a MySQL warehouse — 1.53 million reports, 111,000 in the GLP-1 cohort." |
| 2 | "The engine screens every drug-event pair against Evans criteria — three simultaneous thresholds — and flags 704 clinical signals. Here are the top 20 by PRR with confidence intervals." |
| 3 | "Running four molecules against a common comparator lets me separate class effects from molecule-specific signals — and this is where you see the dulaglutide litigation fingerprint." *[toggle to PT view]* "Drilling into the SEMA vs TIRZ head-to-head—" |
| 4 | "When I stratify by age, some signals reverse direction — gallbladder risk concentrates in younger patients, pancreatitis in elderly. Coverage is 50-66%, so these are hypothesis-generating." |
| 5 | "Quarter-by-quarter PRR lets me rank and track signals — watch how this thyroid signal on tirzepatide climbs from rank 8 to rank 2 over four quarters." |
| 6 | "Before trusting any of this, I validated against 8 known risks." *[point to waffle]* "Seven green, one gray. The gray is AKI — a method limitation I can explain." *[click NAION row]* "And the engine independently detected NAION—" |

---

## Build Priority Order

When building in Tableau, construct in this order (dependencies):

1. **Data connections** — connect all CSVs, set types, create calculated fields
2. **SP1** — simplest charts, establishes KPI styling and drug colors
3. **SP2** — forest plot (most critical chart; CI parsing is the hardest calculated field)
4. **SP3** — heatmap + dumbbell + parameter toggle (most interactive)
5. **SP4** — slope chart (uses age data)
6. **SP5** — bump chart + waffle (most advanced chart construction)
7. **SP6** — scorecard + waffle + show/hide (interaction polish)
8. **Viz-in-Tooltip sheets** — create after primary charts exist
9. **Highlight Actions** — add after all sheets are on dashboards
10. **Custom Nav Bar** — final polish
11. **Color and font pass** — apply palette consistently

---

## Files NOT Used (unchanged from v2)

| File | Why excluded |
|---|---|
| `all_signals_flagged.csv` | Full 748K rows, too large |
| `glp1_signals.csv` / `glp1_base_signals.csv` | Pre-report versions |
| `glp1_subgroup_sex.csv` / `glp1_subgroup_country.csv` | Adds complexity without advancing narrative |
| `positive_controls.csv` / `negative_controls.csv` | Gate 2 evidence — mention in script, not dashboard |
| `glp1_validation_by_drug.csv` / `glp1_validation_detail.csv` | Too granular |
| `glp1_compare_generation.csv` / `report_gen_compare.csv` | Interesting but adds 7th concept |

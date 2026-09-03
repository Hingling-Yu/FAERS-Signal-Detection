#!/usr/bin/env python3
"""Verify that the SAS import cannot truncate any FAERS field.

Why this exists
---------------
`sas/macros/import_faers_table.sas` reads every character column with an
explicit informat (``mfr_sndr : $70.``). SAS truncates silently at that width,
so a column whose longest surviving value equals its declared length is
ambiguous: either the FDA extract is itself capped there, or our declaration is
too short and real data was lost. The SAS-side QC report (section 8 of
``01_import_clean.sas``) flags those columns but cannot resolve the ambiguity,
because by then the data has already passed through the informat.

This script resolves it from the other side: it measures the true maximum width
of every field directly in the raw ``$``-delimited ASCII, before SAS touches it,
and compares that against the lengths declared in the import macro. A field is
only safe when its raw maximum is less than or equal to what we declared.

    raw_max  > declared  ->  TRUNCATED   data was lost, fix the macro
    raw_max == declared  ->  AT_CAP      source-side cap, expected
    raw_max  < declared  ->  OK          headroom

Declared lengths are parsed out of the macro rather than restated here, so the
two can never drift apart.

Also reported, since the files are being read line by line anyway:
  * data row counts per file - the independent check behind the expected counts
    in section 3 of ``01_import_clean.sas``
  * ragged rows - rows whose field count differs from the header, which is how
    an unescaped delimiter inside a value would show up
  * DELETE files - valid case IDs under the same digits-only rule the SAS side
    applies (DQ2), so the row-count report covers all 32 input files

Usage
-----
    python3 python/01_verify_raw_widths.py [RAW_ROOT]

RAW_ROOT is optional; without it the script locates the quarter folders itself.
Stdlib only - no virtualenv, no install step. Exits 1 if any field would be
truncated, so it can be wired into CI later.
"""

from __future__ import annotations

import csv
import re
import sys
import time
from pathlib import Path

# Repo root is the parent of python/, so the script runs from any working
# directory and survives the whole project folder being moved or renamed.
REPO = Path(__file__).resolve().parent.parent
MACRO = REPO / "sas" / "macros" / "import_faers_table.sas"
OUT_QC = REPO / "output" / "qc"

TABLES = ["DEMO", "DRUG", "REAC", "INDI", "OUTC", "THER", "RPSR"]

SEP = b"$"
EOL = b"\r\n"

# Character variables the import macro creates rather than reads: QUARTER is
# stamped from the folder name and the _PREC flags are derived by the date
# parser. Neither exists in the source file, so neither can be truncated.
DERIVED = re.compile(r"^(quarter|.*_prec)$")


def parse_declared_lengths(macro_path: Path) -> dict[str, dict[str, int]]:
    """Return {TABLE: {raw_column_name: declared_length}} for character columns.

    Reads the LENGTH statement inside each `%if &tbl = <TABLE>` branch of the
    import macro. Numeric columns are ignored - width is a character concept.

    Date columns are read as text into a companion variable (`event_dt_c`) and
    converted to a numeric of the same base name afterwards. Only the `_c`
    variable touches the raw file, so the trailing `_c` is stripped to recover
    the source column name; this also avoids matching the derived numeric.
    """
    full = macro_path.read_text(encoding="utf-8")

    # Restrict the search to the import DATA step. The macro declares LENGTH
    # elsewhere too - the QC accumulator (`length table $8 ... dataset $41`)
    # sits after the last `%if &tbl =` branch, so an unbounded search attributes
    # its columns to whichever table was matched last.
    step = re.search(r"\bdata\s+&out\s*;(.*?)\n\s*run\s*;", full, re.DOTALL | re.IGNORECASE)
    if not step:
        sys.exit(f"ERROR: could not locate the 'data &out;' step in {macro_path}")
    text = step.group(1)

    # Branch starts, in file order, so each branch can be bounded by the next.
    starts = [(m.start(), m.group(1).upper())
              for m in re.finditer(r"%(?:else\s+)?%?if\s+&tbl\s*=\s*(\w+)\s*%then", text)]
    if not starts:
        sys.exit(f"ERROR: no '%if &tbl = <TABLE>' branches found in {macro_path}")

    declared: dict[str, dict[str, int]] = {}
    for idx, (pos, table) in enumerate(starts):
        end = starts[idx + 1][0] if idx + 1 < len(starts) else len(text)
        branch = text[pos:end]

        # The date-parsing branches later in the macro carry no LENGTH statement.
        m = re.search(r"\blength\b(.*?);", branch, re.DOTALL | re.IGNORECASE)
        if not m:
            continue

        cols = declared.setdefault(table, {})
        for name, spec in re.findall(r"(\w+)\s+(\$?\d+)", m.group(1)):
            if not spec.startswith("$"):
                continue  # numeric
            name = name.lower()
            if DERIVED.match(name):
                continue
            cols[re.sub(r"_c$", "", name)] = int(spec[1:])

    missing = [t for t in TABLES if t not in declared]
    if missing:
        sys.exit(f"ERROR: no LENGTH statement parsed for: {', '.join(missing)}")
    return declared


def find_quarter_dirs(raw_root: Path | None) -> list[Path]:
    """Locate the quarter folders under either supported layout.

    CHARTER puts them in raw-data/; on SAS ODA and in the current working copy
    they sit at the repo root as faers_ascii_<quarter>/. Both are accepted so
    the script does not have to be edited when the data moves.
    """
    roots = [raw_root] if raw_root else [REPO / "raw-data", REPO]
    dirs: list[Path] = []
    for root in roots:
        if not root or not root.is_dir():
            continue
        dirs = sorted(p for p in root.iterdir() if p.is_dir() and (p / "ASCII").is_dir())
        if dirs:
            break
    if not dirs:
        sys.exit("ERROR: no quarter folders with an ASCII/ subdirectory found. "
                 "Pass the raw data root as the first argument.")
    return dirs


def quarter_label(folder_name: str) -> str:
    """faers_ascii_2025q3 -> 2025Q3 (matches the SAS QUARTER variable)."""
    m = re.search(r"(\d{4})\s*[qQ]\s*(\d)", folder_name)
    return f"{m.group(1)}Q{m.group(2)}" if m else folder_name


def scan_file(path: Path) -> tuple[list[str], list[int], int, int]:
    """One pass: header names, max width per column, data rows, ragged rows.

    Read as bytes rather than text - FAERS is plain ASCII and skipping the
    decode is a large fraction of the runtime across 1.4 GB.
    """
    with path.open("rb") as fh:
        first = fh.readline()
        if not first:
            return [], [], 0, 0
        header = [h.decode("ascii", "replace").strip().lower()
                  for h in first.rstrip(EOL).split(SEP)]
        ncols = len(header)
        widths = [0] * ncols
        rows = ragged = 0

        for line in fh:
            fields = line.rstrip(EOL).split(SEP)
            rows += 1
            if len(fields) != ncols:
                ragged += 1
            for i, field in enumerate(fields[:ncols]):
                n = len(field)
                if n > widths[i]:
                    widths[i] = n

    return header, widths, rows, ragged


def scan_delete_file(path: Path) -> tuple[int, int]:
    """Count raw lines and valid case IDs in a Deleted/DELETE*.txt file.

    Replicates the digits-only rule the SAS side applies (DQ2): three of the
    four files open with a line holding a single space, so a naive line count
    over-reports by one. Returns (raw_lines, valid_ids).
    """
    raw = valid = 0
    with path.open("rb") as fh:
        for line in fh:
            raw += 1
            token = line.strip()
            if token and token.isdigit():
                valid += 1
    return raw, valid


def main() -> int:
    raw_root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else None
    declared = parse_declared_lengths(MACRO)
    quarters = find_quarter_dirs(raw_root)

    print(f"Repo:     {REPO}")
    print(f"Macro:    {MACRO.relative_to(REPO)}")
    print(f"Quarters: {', '.join(q.name for q in quarters)}\n")

    # Widest value seen for each column across every quarter.
    observed: dict[str, dict[str, int]] = {t: {} for t in TABLES}
    counts: list[dict[str, object]] = []
    started = time.time()

    for qdir in quarters:
        qtr = quarter_label(qdir.name)
        for table in TABLES:
            matches = sorted((qdir / "ASCII").glob(f"{table}*.txt"))
            if not matches:
                print(f"  WARNING: {table} not found in {qdir.name}/ASCII")
                continue
            path = matches[0]

            t0 = time.time()
            header, widths, rows, ragged = scan_file(path)
            for name, width in zip(header, widths):
                if width > observed[table].get(name, 0):
                    observed[table][name] = width

            counts.append({"table": table, "quarter": qtr, "file": path.name,
                           "data_rows": rows, "ragged_rows": ragged})
            flag = f"  <-- {ragged} RAGGED" if ragged else ""
            print(f"  {qtr} {table:<5} {rows:>9,} rows  {time.time() - t0:5.1f}s{flag}")

        # DELETE files: no header, no delimiter, one case ID per line. Counted
        # here so the row-count report covers every file the SAS program reads.
        for path in sorted((qdir / "Deleted").glob("DELETE*.txt")):
            raw_lines, valid_ids = scan_delete_file(path)
            counts.append({"table": "DELETE", "quarter": qtr, "file": path.name,
                           "data_rows": valid_ids, "ragged_rows": raw_lines - valid_ids})
            note = f"  ({raw_lines - valid_ids} non-numeric line dropped)" if raw_lines != valid_ids else ""
            print(f"  {qtr} DELETE {valid_ids:>8,} ids {note}")

    # ---- Compare declared vs observed -----------------------------------
    findings = []
    for table in TABLES:
        for column, declared_len in sorted(declared[table].items()):
            raw_max = observed[table].get(column)
            if raw_max is None:
                verdict = "NOT_IN_SOURCE"  # declared but absent from the header
            elif raw_max > declared_len:
                verdict = "TRUNCATED"
            elif raw_max == declared_len:
                verdict = "AT_CAP"
            else:
                verdict = "OK"
            findings.append({
                "table": table,
                "column": column,
                "declared_len": declared_len,
                "raw_max": "" if raw_max is None else raw_max,
                "headroom": "" if raw_max is None else declared_len - raw_max,
                "verdict": verdict,
            })

    OUT_QC.mkdir(parents=True, exist_ok=True)
    widths_csv = OUT_QC / "qc_raw_field_widths.csv"
    counts_csv = OUT_QC / "qc_raw_row_counts.csv"
    for target, rows_out in ((widths_csv, findings), (counts_csv, counts)):
        with target.open("w", newline="", encoding="utf-8") as fh:
            writer = csv.DictWriter(fh, fieldnames=list(rows_out[0].keys()))
            writer.writeheader()
            writer.writerows(rows_out)

    # ---- Report ----------------------------------------------------------
    truncated = [f for f in findings if f["verdict"] == "TRUNCATED"]
    at_cap = [f for f in findings if f["verdict"] == "AT_CAP"]

    print(f"\nScanned {len(counts)} files in {time.time() - started:.0f}s")
    print(f"Wrote {widths_csv.relative_to(REPO)}")
    print(f"Wrote {counts_csv.relative_to(REPO)}")

    print(f"\nAT_CAP - source-side caps, expected ({len(at_cap)}):")
    for f in at_cap:
        print(f"  {f['table']:<5} {f['column']:<18} declared {f['declared_len']:>3}"
              f"  raw max {f['raw_max']:>3}")

    ascii_ragged = sum(int(c["ragged_rows"]) for c in counts if c["table"] != "DELETE")
    print(f"\nRagged rows in the delimited files (field count != header): {ascii_ragged}")

    if truncated:
        print(f"\nFAIL - {len(truncated)} field(s) exceed the declared length; "
              f"the import is losing data:")
        for f in truncated:
            print(f"  {f['table']:<5} {f['column']:<18} declared {f['declared_len']:>3}"
                  f"  raw max {f['raw_max']:>3}  -> widen it in {MACRO.name}")
        return 1

    print("\nPASS - no raw field exceeds its declared length. "
          "The import cannot truncate any value.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

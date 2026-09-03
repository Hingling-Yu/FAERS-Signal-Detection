# MySQL load staging (`output/csv/`)

Landing directory for the CSVs exported from SAS OnDemand for Academics.
The path mirrors SAS ODA's own `mydata/output/csv/`, so a downloaded file keeps
the same relative location it had on the server.
Everything here except this file is git-ignored: the set is roughly 2 GB and
is fully regenerable from `sas/01b_export_csv.sas`.

## Expected contents

| File                 | Rows      | Approx. size |
|----------------------|-----------|--------------|
| `demo.csv`           | 1,529,536 | ~230 MB      |
| `drug.csv`           | 6,299,773 | ~1.2 GB      |
| `reac.csv`           | 4,983,301 | ~300 MB      |
| `indi.csv`           | 4,206,546 | ~230 MB      |
| `outc.csv`           | 1,127,292 | ~35 MB       |
| `ther.csv`           | 1,486,320 | ~70 MB       |
| `rpsr.csv`           | 44,521    | ~2 MB        |
| `deleted_cases.csv`  | union of the 4 quarterly DELETE files | <1 MB |

## Workflow

1. Run `sas/01b_export_csv.sas` in SAS Studio. Export in batches — SAS ODA
   allows 5 GB and the raw extract plus the CLEAN library already occupy most
   of it. The batch plan is in that program's header.
2. Download each batch from SAS Studio into this directory, then delete the
   files from SAS ODA before starting the next batch.
3. Load into MySQL from the repo root:

   ```bash
   sed "s|__CSV_DIR__|$(pwd)/output/csv|g" sql/02_load.sql \
     | /usr/local/mysql/bin/mysql --local-infile=1 -u faers_app -p faers
   ```

4. Check the verification block at the end of `sql/02_load.sql` — row counts
   must match the table above.

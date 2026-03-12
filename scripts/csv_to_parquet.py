"""
Convert MIMIC-IV CSV.GZ files to Parquet format using DuckDB.

Reads from data/mimiciv/3.1/{hosp,icu}/*.csv.gz and writes to
data/mimiciv_as_parquet/{mimiciv_hosp,mimiciv_icu}.{table_name}/.
"""
import duckdb
from pathlib import Path

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
MIMIC_CSV = DATA_DIR / "mimiciv" / "3.1"
MIMIC_PARQUET = DATA_DIR / "mimiciv_as_parquet"

# Tables that need all_varchar=true due to mixed-type columns
ALL_VARCHAR_TABLES = {"emar_detail", "pharmacy"}


def main():
    MIMIC_PARQUET.mkdir(parents=True, exist_ok=True)

    for schema_dir in sorted(MIMIC_CSV.iterdir()):
        if not schema_dir.is_dir():
            continue
        schema_name = f"mimiciv_{schema_dir.name}"  # e.g. mimiciv_hosp

        for csv_file in sorted(schema_dir.glob("*.csv.gz")):
            if csv_file.stat().st_size == 0:
                print(f"  SKIP (empty): {csv_file.name}")
                continue

            table_name = csv_file.stem.replace(".csv", "")
            out_dir = MIMIC_PARQUET / f"{schema_name}.{table_name}"
            out_dir.mkdir(exist_ok=True)

            # Skip if already converted
            if list(out_dir.glob("*.parquet")):
                print(f"  EXISTS: {schema_name}.{table_name}")
                continue

            print(f"  Converting: {schema_name}.{table_name}")
            con = duckdb.connect()
            try:
                read_opts = "all_varchar=true" if table_name in ALL_VARCHAR_TABLES else ""
                con.execute(f"""
                    COPY (SELECT * FROM read_csv_auto('{csv_file}', {read_opts}))
                    TO '{out_dir}' (FORMAT PARQUET, PER_THREAD_OUTPUT TRUE);
                """)
            except Exception as e:
                print(f"  ERROR on {table_name}: {e}")
            finally:
                con.close()

    # Consolidate multi-file parquet directories into single files
    # (polars 0.17 reads single files, not directories)
    print("\n=== Consolidating parquet directories ===")
    for d in sorted(MIMIC_PARQUET.glob("mimiciv_*.*")):
        if not d.is_dir():
            continue
        parquet_files = list(d.glob("*.parquet"))
        if len(parquet_files) <= 1:
            continue
        print(f"  Consolidating: {d.name} ({len(parquet_files)} files)")
        con = duckdb.connect()
        try:
            tmp = d.parent / f"{d.name}.tmp.parquet"
            con.execute(f"COPY (SELECT * FROM read_parquet('{d}/*.parquet')) TO '{tmp}' (FORMAT PARQUET);")
            for p in parquet_files:
                p.unlink()
            tmp.rename(d / "part-0.parquet")
        except Exception as e:
            print(f"  ERROR consolidating {d.name}: {e}")
        finally:
            con.close()

    print("\nDone! Tables:")
    for d in sorted(MIMIC_PARQUET.glob("mimiciv_*.*")):
        if d.is_dir():
            n = len(list(d.glob("*.parquet")))
            print(f"  {d.name}: {n} parquet file(s)")


if __name__ == "__main__":
    main()

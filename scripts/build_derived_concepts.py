"""
Build MIMIC-IV derived concept tables using DuckDB.

Loads base parquet tables into DuckDB schemas, runs the mimic-code
concept SQL scripts, then exports derived tables as parquet files.
"""
import duckdb
import os
from pathlib import Path

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
MIMIC_PARQUET = DATA_DIR / "mimiciv_as_parquet"
MIMIC_CODE_CONCEPTS = Path(__file__).resolve().parent.parent.parent / "mimic-code" / "mimic-iv" / "concepts_duckdb"

def main():
    con = duckdb.connect()

    # Create schemas
    con.execute("CREATE SCHEMA IF NOT EXISTS mimiciv_hosp;")
    con.execute("CREATE SCHEMA IF NOT EXISTS mimiciv_icu;")
    con.execute("CREATE SCHEMA IF NOT EXISTS mimiciv_derived;")

    # Load base tables as views from parquet directories
    for schema in ["mimiciv_hosp", "mimiciv_icu"]:
        schema_dirs = sorted(MIMIC_PARQUET.glob(f"{schema}.*"))
        for d in schema_dirs:
            if not d.is_dir():
                continue
            table_name = d.name.split(".", 1)[1]  # e.g. "admissions"
            parquet_files = list(d.glob("*.parquet"))
            if not parquet_files:
                print(f"  SKIP (no parquet files): {d.name}")
                continue
            parquet_path = str(d / "*.parquet")
            print(f"  Loading {schema}.{table_name}")
            con.execute(f"""
                CREATE OR REPLACE VIEW {schema}.{table_name} AS
                SELECT * FROM read_parquet('{parquet_path}');
            """)

    print("\n=== Running concept SQL scripts ===")

    # Read the master duckdb.sql to get the ordered list of SQL files
    master_sql = (MIMIC_CODE_CONCEPTS / "duckdb.sql").read_text()
    sql_files = []
    for line in master_sql.splitlines():
        line = line.strip()
        if line.startswith(".read "):
            sql_files.append(line.replace(".read ", "").strip())

    for sql_file in sql_files:
        sql_path = MIMIC_CODE_CONCEPTS / sql_file
        if not sql_path.exists():
            print(f"  SKIP (not found): {sql_file}")
            continue
        print(f"  Running: {sql_file}")
        sql = sql_path.read_text()
        try:
            con.execute(sql)
        except Exception as e:
            print(f"  ERROR on {sql_file}: {e}")

    # Export all derived tables to parquet
    print("\n=== Exporting derived tables to parquet ===")
    derived_tables = con.execute(
        "SELECT table_name FROM information_schema.tables WHERE table_schema = 'mimiciv_derived'"
    ).fetchall()

    for (table_name,) in derived_tables:
        out_path = MIMIC_PARQUET / f"mimiciv_derived.{table_name}"
        out_path.mkdir(exist_ok=True)
        # Clean existing parquet files
        for p in out_path.glob("*.parquet"):
            p.unlink()
        print(f"  Exporting mimiciv_derived.{table_name}")
        try:
            con.execute(f"""
                COPY mimiciv_derived.{table_name}
                TO '{out_path}' (FORMAT PARQUET, PER_THREAD_OUTPUT TRUE);
            """)
        except Exception as e:
            print(f"  ERROR exporting {table_name}: {e}")

    print("\nDone! Derived tables:")
    for d in sorted(MIMIC_PARQUET.glob("mimiciv_derived.*")):
        n = len(list(d.glob("*.parquet")))
        print(f"  {d.name}: {n} parquet file(s)")

if __name__ == "__main__":
    main()

"""
Consolidate multi-file parquet directories under mimiciv_derived.* into single files.
Polars 0.17 expects single parquet files, not directories with multiple parts.
"""
import duckdb
from pathlib import Path

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
MIMIC_PARQUET = DATA_DIR / "mimiciv_as_parquet"


def main():
    for d in sorted(MIMIC_PARQUET.glob("mimiciv_derived.*")):
        if not d.is_dir():
            continue
        parquet_files = list(d.glob("*.parquet"))
        if len(parquet_files) == 0:
            print(f"  SKIP (empty): {d.name}")
            continue
        if len(parquet_files) == 1:
            # Already a single file — just ensure it's named consistently
            single = parquet_files[0]
            target = d.parent / d.name
            # Convert directory to single file
            print(f"  Converting dir→file: {d.name}")
            tmp = d.parent / f"{d.name}.tmp.parquet"
            single.rename(tmp)
            d.rmdir()
            tmp.rename(target)
            continue

        print(f"  Consolidating: {d.name} ({len(parquet_files)} files → 1)")
        con = duckdb.connect()
        try:
            tmp = d.parent / f"{d.name}.tmp.parquet"
            con.execute(f"""
                COPY (SELECT * FROM read_parquet('{d}/*.parquet'))
                TO '{tmp}' (FORMAT PARQUET);
            """)
            # Remove directory and replace with single file
            for p in parquet_files:
                p.unlink()
            d.rmdir()
            tmp.rename(d)
        except Exception as e:
            print(f"  ERROR: {d.name}: {e}")
        finally:
            con.close()

    print("\nDone! Derived tables:")
    for p in sorted(MIMIC_PARQUET.glob("mimiciv_derived.*")):
        if p.is_file():
            print(f"  {p.name} (file)")
        elif p.is_dir():
            n = len(list(p.glob("*.parquet")))
            print(f"  {p.name} (dir, {n} files)")


if __name__ == "__main__":
    main()

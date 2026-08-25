"""
data_cleaning.py
Phase 2: Data Engineering Layer

Orchestrates the ETL pipeline:
    1. Read the raw Excel workbook (Sales Data, People)
    2. Load them into PostgreSQL as raw landing tables
    3. Run schema.sql to (re)create the table structure
    4. Run cleaning.sql to dedupe, validate, and build the analytical tables
    5. Pull the clean tables back into pandas
    6. Export them to data/processed/ (parquet + csv) for the notebooks
    7. Print the data_quality_log so issues are visible, not silent

Usage:
    python src/data_cleaning.py

Requires a running PostgreSQL instance and a .env file (see .env.example)
with DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD.
"""

import os
import sys
from pathlib import Path

import pandas as pd
from sqlalchemy import create_engine, text
from dotenv import load_dotenv

# ------------------------------------------------------------------
# Paths (relative to project root, matching the VS Code tree)
# ------------------------------------------------------------------
PROJECT_ROOT = Path(__file__).resolve().parents[1]
RAW_XLSX = PROJECT_ROOT / "data" / "raw" / "company_sales.xlsx"
SQL_DIR = PROJECT_ROOT / "sql"
PROCESSED_DIR = PROJECT_ROOT / "data" / "processed"

SCHEMA_SQL = SQL_DIR / "schema.sql"
CLEANING_SQL = SQL_DIR / "cleaning.sql"


def get_engine():
    """Build a SQLAlchemy engine from environment variables."""
    load_dotenv(PROJECT_ROOT / ".env")

    db_host = os.getenv("DB_HOST", "localhost")
    db_port = os.getenv("DB_PORT", "5432")
    db_name = os.getenv("DB_NAME", "product_market_analysis")
    db_user = os.getenv("DB_USER", "postgres")
    db_password = os.getenv("DB_PASSWORD", "")

    url = f"postgresql+psycopg2://{db_user}:{db_password}@{db_host}:{db_port}/{db_name}"
    return create_engine(url)


def load_raw_excel_to_postgres(engine):
    """Step 1-2: read the workbook and land it as raw tables, unmodified."""
    print(f"Reading {RAW_XLSX} ...")
    sales = pd.read_excel(RAW_XLSX, sheet_name="Sales Data")
    people = pd.read_excel(RAW_XLSX, sheet_name="People")

    # Standardize column names to match schema.sql (snake_case), but keep
    # values completely untouched -- this is the raw landing layer.
    sales = sales.rename(columns={
        "Opportunity ID": "opportunity_id",
        "Opp Owner User ID": "opp_owner_user_id",
        "Opp Owner Geo": "opp_owner_geo",
        "Segment": "segment",
        "Opportunity Type": "opportunity_type",
        "Close Date": "close_date",
        "Product Line": "product_line",
        "Product Family": "product_family",
        "Total Price": "total_price",
        "Rep Name": "rep_name",
    })
    people = people.rename(columns={
        "Opp Owner User ID": "opp_owner_user_id",
        "Name": "name",
    })

    # Cast close_date/total_price to text on load -- schema.sql defines raw
    # columns as TEXT on purpose, so bad values surface as DQ findings in
    # cleaning.sql instead of failing silently (or failing the whole load).
    sales["close_date"] = sales["close_date"].astype(str)
    sales["total_price"] = sales["total_price"].astype(str)

    sales.to_sql("raw_sales", engine, if_exists="append", index=False)
    people.to_sql("raw_people", engine, if_exists="append", index=False)

    print(f"Loaded raw_sales: {len(sales)} rows, raw_people: {len(people)} rows")


def run_sql_file(engine, path: Path):
    """Execute a .sql file as a single multi-statement block (avoids issues
    with semicolons appearing inside SQL comments)."""
    print(f"Running {path.name} ...")
    sql_text = path.read_text()
    raw_conn = engine.raw_connection()
    try:
        cursor = raw_conn.cursor()
        cursor.execute(sql_text)
        raw_conn.commit()
        cursor.close()
    finally:
        raw_conn.close()


def export_clean_tables(engine):
    """Pull the clean analytical tables back into pandas and save them."""
    PROCESSED_DIR.mkdir(parents=True, exist_ok=True)

    stg_sales = pd.read_sql("SELECT * FROM stg_sales_clean", engine)
    opportunities = pd.read_sql("SELECT * FROM opportunities", engine)

    stg_sales.to_parquet(PROCESSED_DIR / "stg_sales_clean.parquet", index=False)
    opportunities.to_parquet(PROCESSED_DIR / "opportunities.parquet", index=False)
    stg_sales.to_csv(PROCESSED_DIR / "stg_sales_clean.csv", index=False)
    opportunities.to_csv(PROCESSED_DIR / "opportunities.csv", index=False)

    print(f"Exported stg_sales_clean: {len(stg_sales)} rows -> {PROCESSED_DIR}")
    print(f"Exported opportunities:   {len(opportunities)} rows -> {PROCESSED_DIR}")

    return stg_sales, opportunities


def print_data_quality_report(engine):
    """Step 7: surface every DQ finding instead of hiding them."""
    log = pd.read_sql(
        "SELECT check_name, severity, affected_rows, details "
        "FROM data_quality_log ORDER BY check_id",
        engine,
    )
    print("\n" + "=" * 70)
    print("DATA QUALITY REPORT")
    print("=" * 70)
    with pd.option_context("display.max_colwidth", 100, "display.width", 140):
        print(log.to_string(index=False))
    print("=" * 70)

    n_errors = (log["severity"] == "ERROR").sum()
    n_warnings = (log["severity"] == "WARNING").sum()
    print(f"\n{n_errors} ERROR-level finding(s), {n_warnings} WARNING-level finding(s). "
          f"Review above before trusting downstream analysis.\n")

    return log


def main():
    engine = get_engine()

    print("Recreating schema ...")
    run_sql_file(engine, SCHEMA_SQL)

    load_raw_excel_to_postgres(engine)

    run_sql_file(engine, CLEANING_SQL)

    print_data_quality_report(engine)

    export_clean_tables(engine)

    print("Phase 2 ETL complete.")


if __name__ == "__main__":
    sys.exit(main())
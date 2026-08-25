-- ============================================================
-- schema.sql
-- Phase 2: Data Engineering Layer
-- Defines the raw landing tables (mirror of the Excel sheets)
-- and the clean analytical tables the rest of the project reads from.
-- ============================================================

-- ------------------------------------------------------------
-- 1. RAW LANDING TABLES
-- These are a 1:1 mirror of the Excel sheets. Nothing is cleaned
-- here — this is the "as received" layer. Python loads the xlsx
-- straight into these tables with pandas.to_sql(if_exists="replace").
-- ------------------------------------------------------------

DROP TABLE IF EXISTS raw_sales CASCADE;
CREATE TABLE raw_sales (
    row_id              SERIAL PRIMARY KEY,   -- surrogate key, since raw rows have no natural PK
    opportunity_id      TEXT,
    opp_owner_user_id   TEXT,
    opp_owner_geo       TEXT,
    segment             TEXT,
    opportunity_type    TEXT,
    close_date          TEXT,                 -- kept as TEXT on load; cast/validated in cleaning.sql
    product_line        TEXT,
    product_family      TEXT,
    total_price         TEXT,                 -- kept as TEXT on load; cast/validated in cleaning.sql
    rep_name            TEXT
);

DROP TABLE IF EXISTS raw_people CASCADE;
CREATE TABLE raw_people (
    row_id              SERIAL PRIMARY KEY,
    opp_owner_user_id   TEXT,
    name                TEXT
);

-- ------------------------------------------------------------
-- 2. DATA QUALITY LOG
-- Every check in cleaning.sql writes its findings here instead of
-- silently fixing/dropping data. This is the audit trail for Phase 2.
-- ------------------------------------------------------------

DROP TABLE IF EXISTS data_quality_log CASCADE;
CREATE TABLE data_quality_log (
    check_id            SERIAL PRIMARY KEY,
    check_name          TEXT NOT NULL,
    severity            TEXT NOT NULL CHECK (severity IN ('INFO', 'WARNING', 'ERROR')),
    affected_rows       INTEGER,
    details             TEXT,
    checked_at          TIMESTAMP DEFAULT NOW()
);

-- ------------------------------------------------------------
-- 3. CLEAN ANALYTICAL TABLES
-- Two grains, matching Phase 3 of the project doc:
--   - stg_sales_clean: deduplicated, typed, line-item grain (product-family rows)
--   - opportunities:   aggregated, one row per Opportunity ID
-- Populated by cleaning.sql.
-- ------------------------------------------------------------

DROP TABLE IF EXISTS stg_sales_clean CASCADE;
CREATE TABLE stg_sales_clean (
    opportunity_id      TEXT NOT NULL,
    opp_owner_user_id   TEXT,
    opp_owner_geo       TEXT,
    segment             TEXT,
    opportunity_type    TEXT,
    close_date          DATE,
    product_line        TEXT,
    product_family      TEXT,
    total_price         NUMERIC(14, 2),
    rep_name            TEXT
);

DROP TABLE IF EXISTS opportunities CASCADE;
CREATE TABLE opportunities (
    opportunity_id       TEXT PRIMARY KEY,
    opp_owner_user_id    TEXT,
    opp_owner_geo        TEXT,
    segment              TEXT,
    opportunity_type     TEXT,
    close_date           DATE,
    opportunity_value    NUMERIC(14, 2),
    product_family_count INTEGER,
    rep_name             TEXT,
    year                 INTEGER,
    quarter              INTEGER,
    month                INTEGER
);

-- Helpful indexes for the grouping/joins the analysis notebooks will do
CREATE INDEX idx_stg_sales_opp_id ON stg_sales_clean (opportunity_id);
CREATE INDEX idx_stg_sales_product_line ON stg_sales_clean (product_line);
CREATE INDEX idx_opportunities_segment ON opportunities (segment);
CREATE INDEX idx_opportunities_geo ON opportunities (opp_owner_geo);
CREATE INDEX idx_opportunities_close_date ON opportunities (close_date);
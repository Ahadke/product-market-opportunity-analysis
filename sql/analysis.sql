-- ============================================================
-- analysis.sql
-- Phase 2 validation queries: confirm the cleaned tables match what
-- Phase 1 (pandas) found, and give a quick first look at the
-- analytical tables before moving to EDA/statistics in Python.
-- Safe to re-run any time; read-only (no INSERT/UPDATE/DELETE).
-- ============================================================

-- 1. Row-count reconciliation: raw vs clean
SELECT
    (SELECT COUNT(*) FROM raw_sales)          AS raw_sales_rows,
    (SELECT COUNT(*) FROM stg_sales_clean)    AS clean_sales_rows,
    (SELECT COUNT(*) FROM opportunities)      AS opportunity_rows,
    (SELECT COUNT(DISTINCT opportunity_id) FROM raw_sales) AS raw_unique_opportunities;

-- 2. Full data-quality log, most recent run first
SELECT check_name, severity, affected_rows, details, checked_at
FROM data_quality_log
ORDER BY checked_at DESC, check_id DESC;

-- 3. Value reconciliation: total recorded value before vs after cleaning
SELECT
    (SELECT SUM(total_price::NUMERIC) FROM raw_sales
       WHERE total_price ~ '^\s*-?\d+(\.\d+)?\s*$')      AS raw_total_value,
    (SELECT SUM(total_price) FROM stg_sales_clean)        AS clean_total_value,
    (SELECT SUM(opportunity_value) FROM opportunities)    AS opportunity_total_value;

-- 4. Revenue landscape sanity check: total value by Product Line
SELECT product_line, COUNT(*) AS line_items, SUM(total_price) AS total_value
FROM stg_sales_clean
GROUP BY product_line
ORDER BY total_value DESC;

-- 5. Revenue landscape sanity check: total value by Segment (opportunity grain)
SELECT segment, COUNT(*) AS opportunities, SUM(opportunity_value) AS total_value,
       ROUND(AVG(opportunity_value), 2) AS avg_deal,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY opportunity_value) AS median_deal
FROM opportunities
GROUP BY segment
ORDER BY total_value DESC;

-- 6. Rep-mapping coverage check
SELECT
    COUNT(*) FILTER (WHERE rep_name = 'Unknown Rep')  AS unmapped_opportunities,
    COUNT(*)                                          AS total_opportunities,
    ROUND(100.0 * COUNT(*) FILTER (WHERE rep_name = 'Unknown Rep') / COUNT(*), 1) AS pct_unmapped
FROM opportunities;

-- 7. Opportunity value distribution by year (time check)
SELECT year, COUNT(*) AS opportunities, SUM(opportunity_value) AS total_value
FROM opportunities
GROUP BY year
ORDER BY year;

-- 8. Product-family count distribution per opportunity (should mirror Phase 1's rows_per_opportunity stats)
SELECT product_family_count, COUNT(*) AS num_opportunities
FROM opportunities
GROUP BY product_family_count
ORDER BY product_family_count;
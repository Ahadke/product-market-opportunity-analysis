-- ============================================================
-- cleaning.sql
-- Phase 2: Data Engineering Layer
-- Transforms raw_sales / raw_people -> stg_sales_clean -> opportunities.
-- Every issue found is LOGGED into data_quality_log, matching the
-- project rule: findings are documented, not silently fixed.
-- Run this AFTER schema.sql and AFTER raw_sales/raw_people are loaded.
-- ============================================================

-- ------------------------------------------------------------
-- CHECK 1: Exact duplicate rows in raw_sales
-- (mirrors the 52 duplicates found in Phase 1)
-- ------------------------------------------------------------
INSERT INTO data_quality_log (check_name, severity, affected_rows, details)
SELECT
    'exact_duplicate_rows',
    'WARNING',
    COUNT(*) - COUNT(DISTINCT (opportunity_id, opp_owner_user_id, opp_owner_geo, segment,
                                opportunity_type, close_date, product_line, product_family,
                                total_price, rep_name)),
    'Rows that are 100% identical across all columns. These are removed before building stg_sales_clean.'
FROM raw_sales;

-- ------------------------------------------------------------
-- CHECK 2: Invalid / unparseable close dates
-- ------------------------------------------------------------
INSERT INTO data_quality_log (check_name, severity, affected_rows, details)
SELECT
    'invalid_close_date',
    'ERROR',
    COUNT(*),
    'Rows where close_date could not be cast to a valid DATE.'
FROM raw_sales
WHERE close_date IS NULL
   OR NOT (close_date ~ '^\d{4}-\d{2}-\d{2}' OR close_date ~ '^\d{1,2}/\d{1,2}/\d{4}');

-- ------------------------------------------------------------
-- CHECK 3: Missing or non-numeric / non-positive Total Price
-- ------------------------------------------------------------
INSERT INTO data_quality_log (check_name, severity, affected_rows, details)
SELECT
    'invalid_total_price',
    'ERROR',
    COUNT(*),
    'Rows where total_price is null, non-numeric, or <= 0.'
FROM raw_sales
WHERE total_price IS NULL
   OR total_price !~ '^\s*-?\d+(\.\d+)?\s*$'
   OR total_price::NUMERIC <= 0;

-- ------------------------------------------------------------
-- CHECK 4: Missing dimension values (opportunity_id, geo, segment, type, product line/family)
-- ------------------------------------------------------------
INSERT INTO data_quality_log (check_name, severity, affected_rows, details)
SELECT 'missing_opportunity_id', 'ERROR', COUNT(*), 'Rows with a null/blank Opportunity ID.'
FROM raw_sales WHERE opportunity_id IS NULL OR TRIM(opportunity_id) = '';

INSERT INTO data_quality_log (check_name, severity, affected_rows, details)
SELECT 'missing_segment', 'ERROR', COUNT(*), 'Rows with a null/blank Segment.'
FROM raw_sales WHERE segment IS NULL OR TRIM(segment) = '';

INSERT INTO data_quality_log (check_name, severity, affected_rows, details)
SELECT 'missing_geo', 'ERROR', COUNT(*), 'Rows with a null/blank Opp Owner Geo.'
FROM raw_sales WHERE opp_owner_geo IS NULL OR TRIM(opp_owner_geo) = '';

INSERT INTO data_quality_log (check_name, severity, affected_rows, details)
SELECT 'missing_product_family', 'ERROR', COUNT(*), 'Rows with a null/blank Product Family.'
FROM raw_sales WHERE product_family IS NULL OR TRIM(product_family) = '';

-- ------------------------------------------------------------
-- CHECK 5: Inconsistent categorical values (whitespace / casing variants)
-- Flags any category that only differs from another by case or padding —
-- these should usually be the SAME category, not two different ones.
-- ------------------------------------------------------------
INSERT INTO data_quality_log (check_name, severity, affected_rows, details)
SELECT
    'inconsistent_category_casing',
    'WARNING',
    COUNT(*),
    'Distinct raw category values across segment/geo/type/product_line/product_family that collapse to the same value after trim+lower.'
FROM (
    SELECT LOWER(TRIM(segment)) AS norm, COUNT(DISTINCT segment) AS n FROM raw_sales GROUP BY 1
    UNION ALL
    SELECT LOWER(TRIM(opp_owner_geo)), COUNT(DISTINCT opp_owner_geo) FROM raw_sales GROUP BY 1
    UNION ALL
    SELECT LOWER(TRIM(opportunity_type)), COUNT(DISTINCT opportunity_type) FROM raw_sales GROUP BY 1
    UNION ALL
    SELECT LOWER(TRIM(product_line)), COUNT(DISTINCT product_line) FROM raw_sales GROUP BY 1
    UNION ALL
    SELECT LOWER(TRIM(product_family)), COUNT(DISTINCT product_family) FROM raw_sales GROUP BY 1
) x
WHERE n > 1;

-- ------------------------------------------------------------
-- CHECK 6: Unmapped sales reps (owner ID in raw_sales with no match in raw_people)
-- (mirrors the 52-of-61 unmapped owner IDs found in Phase 1)
-- ------------------------------------------------------------
INSERT INTO data_quality_log (check_name, severity, affected_rows, details)
SELECT
    'unmapped_owner_ids',
    'WARNING',
    COUNT(DISTINCT s.opp_owner_user_id),
    'Distinct Opp Owner User IDs present in raw_sales with no matching row in raw_people. Rep name will be set to Unknown Rep.'
FROM raw_sales s
LEFT JOIN raw_people p ON s.opp_owner_user_id = p.opp_owner_user_id
WHERE p.opp_owner_user_id IS NULL;

-- ------------------------------------------------------------
-- CHECK 7: Extreme / outlier total_price values (basic IQR flag, logged not removed)
-- ------------------------------------------------------------
INSERT INTO data_quality_log (check_name, severity, affected_rows, details)
WITH stats AS (
    SELECT
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY total_price::NUMERIC) AS q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY total_price::NUMERIC) AS q3
    FROM raw_sales
    WHERE total_price ~ '^\s*-?\d+(\.\d+)?\s*$'
)
SELECT
    'extreme_total_price_outliers',
    'INFO',
    COUNT(*),
    'Rows where total_price falls outside Q1-1.5*IQR / Q3+1.5*IQR. Logged for awareness only, NOT removed (real large deals are expected in B2B sales data).'
FROM raw_sales, stats
WHERE total_price ~ '^\s*-?\d+(\.\d+)?\s*$'
  AND (
        total_price::NUMERIC < q1 - 1.5 * (q3 - q1)
     OR total_price::NUMERIC > q3 + 1.5 * (q3 - q1)
  );

-- ------------------------------------------------------------
-- CHECK 8: Opportunities with inconsistent attributes across their line items
-- (an Opportunity ID should have ONE segment/geo/type/close_date — flag if not)
-- ------------------------------------------------------------
INSERT INTO data_quality_log (check_name, severity, affected_rows, details)
SELECT
    'inconsistent_opportunity_attributes',
    'ERROR',
    COUNT(*),
    'Opportunity IDs where segment, geo, opportunity_type, or close_date is NOT identical across all their line-item rows.'
FROM (
    SELECT opportunity_id
    FROM raw_sales
    GROUP BY opportunity_id
    HAVING COUNT(DISTINCT segment) > 1
        OR COUNT(DISTINCT opp_owner_geo) > 1
        OR COUNT(DISTINCT opportunity_type) > 1
        OR COUNT(DISTINCT close_date) > 1
) inconsistent;

-- ============================================================
-- BUILD STAGE 1: stg_sales_clean (line-item grain)
-- - drops exact duplicates
-- - casts close_date / total_price to proper types
-- - drops rows that fail hard validation (missing id, bad price, bad date)
-- - standardizes categorical text (trim)
-- ============================================================

TRUNCATE TABLE stg_sales_clean;

INSERT INTO stg_sales_clean (
    opportunity_id, opp_owner_user_id, opp_owner_geo, segment,
    opportunity_type, close_date, product_line, product_family,
    total_price, rep_name
)
SELECT DISTINCT
    TRIM(opportunity_id),
    TRIM(opp_owner_user_id),
    TRIM(opp_owner_geo),
    TRIM(segment),
    TRIM(opportunity_type),
    close_date::DATE,
    TRIM(product_line),
    TRIM(product_family),
    total_price::NUMERIC(14, 2),
    NULLIF(TRIM(rep_name), '')
FROM raw_sales
WHERE opportunity_id IS NOT NULL AND TRIM(opportunity_id) <> ''
  AND segment IS NOT NULL AND TRIM(segment) <> ''
  AND opp_owner_geo IS NOT NULL AND TRIM(opp_owner_geo) <> ''
  AND product_family IS NOT NULL AND TRIM(product_family) <> ''
  AND total_price ~ '^\s*-?\d+(\.\d+)?\s*$' AND total_price::NUMERIC > 0
  AND close_date ~ '^\d{4}-\d{2}-\d{2}';

INSERT INTO data_quality_log (check_name, severity, affected_rows, details)
SELECT 'stg_sales_clean_row_count', 'INFO', COUNT(*),
       'Final row count after dedup + validation in stg_sales_clean.'
FROM stg_sales_clean;

-- ============================================================
-- BUILD STAGE 2: opportunities (opportunity grain)
-- Aggregates stg_sales_clean up to one row per Opportunity ID and
-- fills in rep_name from raw_people, defaulting unmapped reps to
-- 'Unknown Rep' (explicit, not silently blank).
-- ============================================================

TRUNCATE TABLE opportunities;

INSERT INTO opportunities (
    opportunity_id, opp_owner_user_id, opp_owner_geo, segment,
    opportunity_type, close_date, opportunity_value,
    product_family_count, rep_name, year, quarter, month
)
SELECT
    s.opportunity_id,
    MIN(s.opp_owner_user_id)                         AS opp_owner_user_id,
    MIN(s.opp_owner_geo)                              AS opp_owner_geo,
    MIN(s.segment)                                    AS segment,
    MIN(s.opportunity_type)                           AS opportunity_type,
    MIN(s.close_date)                                 AS close_date,
    SUM(s.total_price)                                AS opportunity_value,
    COUNT(*)                                          AS product_family_count,
    COALESCE(MIN(p.name), 'Unknown Rep')              AS rep_name,
    EXTRACT(YEAR  FROM MIN(s.close_date))::INT         AS year,
    EXTRACT(QUARTER FROM MIN(s.close_date))::INT       AS quarter,
    EXTRACT(MONTH FROM MIN(s.close_date))::INT         AS month
FROM stg_sales_clean s
LEFT JOIN raw_people p ON s.opp_owner_user_id = p.opp_owner_user_id
GROUP BY s.opportunity_id;

INSERT INTO data_quality_log (check_name, severity, affected_rows, details)
SELECT 'opportunities_row_count', 'INFO', COUNT(*),
       'Final row count after aggregation in opportunities table.'
FROM opportunities; 
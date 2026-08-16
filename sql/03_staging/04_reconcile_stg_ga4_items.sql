-- Measurement 360
-- Reconciliation for stg_ga4_items
--
-- Confirms that every nested source item becomes exactly one staging row.

WITH source_by_event_name AS (
  SELECT
    event_name,
    SUM(COALESCE(ARRAY_LENGTH(items), 0)) AS source_item_rows

  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`

  WHERE
    _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'

  GROUP BY event_name

  HAVING SUM(COALESCE(ARRAY_LENGTH(items), 0)) > 0
),

staging_by_event_name AS (
  SELECT
    event_name,
    COUNT(*) AS staging_item_rows

  FROM
    `measurement-360-portfolio.measurement_360_stg.stg_ga4_items`

  GROUP BY event_name
),

event_name_comparison AS (
  SELECT
    COALESCE(source.event_name, staging.event_name) AS event_name,
    COALESCE(source.source_item_rows, 0) AS source_item_rows,
    COALESCE(staging.staging_item_rows, 0) AS staging_item_rows

  FROM source_by_event_name AS source

  FULL OUTER JOIN staging_by_event_name AS staging
    USING (event_name)
),

event_name_summary AS (
  SELECT
    COUNT(*) AS compared_event_names,

    COUNTIF(
      source_item_rows != staging_item_rows
    ) AS event_names_with_item_row_mismatch,

    SUM(source_item_rows) AS source_item_rows,
    SUM(staging_item_rows) AS staging_item_rows

  FROM event_name_comparison
),

source_purchase_summary AS (
  SELECT
    SUM(
      IF(
        event_name = 'purchase',
        COALESCE(ARRAY_LENGTH(items), 0),
        0
      )
    ) AS source_purchase_item_rows

  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`

  WHERE
    _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
),

staging_quality_summary AS (
  SELECT
    COUNTIF(is_purchase_event) AS staging_purchase_item_rows,

    COUNTIF(
      is_purchase_event
      AND item_revenue_in_usd IS NOT NULL
    ) AS purchase_item_rows_with_item_revenue,

    COUNTIF(
      is_purchase_event
      AND item_revenue_in_usd IS NULL
    ) AS purchase_item_rows_without_item_revenue,

    COUNTIF(item_offset IS NULL OR item_offset < 0)
      AS invalid_item_offset_rows,

    COUNTIF(item_record_fingerprint IS NULL)
      AS null_item_fingerprint_rows,

    COUNTIF(item_identity IS NULL)
      AS rows_without_item_identity,

    COUNTIF(
      has_session_id
      AND session_key IS NULL
    ) AS invalid_session_key_rows,

    COUNTIF(
      transaction_id_status = 'VALID'
      AND transaction_id_normalized IS NULL
    ) AS invalid_transaction_normalization_rows,

    COUNT(*) - COUNT(DISTINCT item_record_fingerprint)
      AS duplicate_item_fingerprints

  FROM
    `measurement-360-portfolio.measurement_360_stg.stg_ga4_items`
)

SELECT
  source_item_rows,
  staging_item_rows,
  staging_item_rows - source_item_rows AS item_row_difference,
  source_item_rows = staging_item_rows AS item_rows_match,

  compared_event_names,
  event_names_with_item_row_mismatch,

  source_purchase_item_rows,
  staging_purchase_item_rows,

  source_purchase_item_rows = staging_purchase_item_rows
    AS purchase_item_rows_match,

  purchase_item_rows_with_item_revenue,
  purchase_item_rows_without_item_revenue,

  invalid_item_offset_rows,
  null_item_fingerprint_rows,
  rows_without_item_identity,
  invalid_session_key_rows,
  invalid_transaction_normalization_rows,
  duplicate_item_fingerprints,

  CASE
    WHEN
      source_item_rows = staging_item_rows
      AND event_names_with_item_row_mismatch = 0
      AND source_purchase_item_rows = staging_purchase_item_rows
      AND invalid_item_offset_rows = 0
      AND null_item_fingerprint_rows = 0
      AND invalid_session_key_rows = 0
      AND invalid_transaction_normalization_rows = 0
    THEN 'PASS'
    ELSE 'REVIEW'
  END AS reconciliation_status

FROM event_name_summary
CROSS JOIN source_purchase_summary
CROSS JOIN staging_quality_summary;
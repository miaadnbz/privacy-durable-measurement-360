-- Measurement 360
-- Reconciliation test for measurement_360_stg.stg_ga4_events
--
-- A passing result demonstrates that the staging view preserves the
-- source event grain and expected source coverage.

WITH source_summary AS (
  SELECT
    COUNT(*) AS source_event_rows,
    COUNT(DISTINCT user_pseudo_id) AS source_unique_users,
    COUNT(DISTINCT event_name) AS source_distinct_event_names,
    MIN(PARSE_DATE('%Y%m%d', event_date)) AS source_first_event_date,
    MAX(PARSE_DATE('%Y%m%d', event_date)) AS source_last_event_date,
    COUNTIF(event_name = 'purchase') AS source_purchase_event_rows

  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`

  WHERE
    _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
),

staging_summary AS (
  SELECT
    COUNT(*) AS staging_event_rows,
    COUNT(DISTINCT user_pseudo_id) AS staging_unique_users,
    COUNT(DISTINCT event_name) AS staging_distinct_event_names,
    MIN(event_date) AS staging_first_event_date,
    MAX(event_date) AS staging_last_event_date,
    COUNTIF(is_purchase_event) AS staging_purchase_event_rows,

    COUNTIF(
      is_purchase_event
      AND has_session_id
    ) AS staging_purchase_events_with_session_id,

    COUNTIF(
      is_purchase_event
      AND currency IS NOT NULL
    ) AS staging_purchase_events_with_currency,

    COUNTIF(event_date IS NULL) AS null_event_date_rows,
    COUNTIF(event_timestamp_utc IS NULL) AS null_event_timestamp_rows,

    COUNTIF(
      has_user_pseudo_id
      AND has_session_id
      AND session_key IS NULL
    ) AS invalid_session_key_rows,

    COUNTIF(
      transaction_id_status = 'VALID'
      AND transaction_id_normalized IS NULL
    ) AS invalid_transaction_normalization_rows

  FROM
    `measurement-360-portfolio.measurement_360_stg.stg_ga4_events`
)

SELECT
  source_event_rows,
  staging_event_rows,
  staging_event_rows - source_event_rows AS event_row_difference,
  source_event_rows = staging_event_rows AS event_rows_match,

  source_unique_users,
  staging_unique_users,
  source_unique_users = staging_unique_users AS unique_users_match,

  source_distinct_event_names,
  staging_distinct_event_names,
  source_distinct_event_names = staging_distinct_event_names
    AS event_name_counts_match,

  source_first_event_date,
  staging_first_event_date,
  source_last_event_date,
  staging_last_event_date,

  source_first_event_date = staging_first_event_date
    AND source_last_event_date = staging_last_event_date
    AS date_range_matches,

  source_purchase_event_rows,
  staging_purchase_event_rows,
  source_purchase_event_rows = staging_purchase_event_rows
    AS purchase_event_rows_match,

  staging_purchase_events_with_session_id,
  staging_purchase_events_with_currency,

  null_event_date_rows,
  null_event_timestamp_rows,
  invalid_session_key_rows,
  invalid_transaction_normalization_rows,

  CASE
    WHEN
      source_event_rows = staging_event_rows
      AND source_unique_users = staging_unique_users
      AND source_distinct_event_names = staging_distinct_event_names
      AND source_first_event_date = staging_first_event_date
      AND source_last_event_date = staging_last_event_date
      AND source_purchase_event_rows = staging_purchase_event_rows
      AND staging_purchase_events_with_session_id
        = staging_purchase_event_rows
      AND staging_purchase_events_with_currency
        = staging_purchase_event_rows
      AND null_event_date_rows = 0
      AND null_event_timestamp_rows = 0
      AND invalid_session_key_rows = 0
      AND invalid_transaction_normalization_rows = 0
    THEN 'PASS'
    ELSE 'REVIEW'
  END AS reconciliation_status

FROM source_summary
CROSS JOIN staging_summary;
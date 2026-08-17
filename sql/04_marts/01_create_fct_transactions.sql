-- Measurement 360
-- Transaction fact table
--
-- Grain:
-- One row per inferred transaction.
--
-- Revenue policy:
-- ecommerce_purchase_revenue_in_usd is the canonical revenue measure.
--
-- Transaction-key policy:
-- 1. Use a valid transaction ID when it belongs to one user and has
--    no conflicting revenue values.
-- 2. Use an event fingerprint when the transaction ID is conflicting,
--    missing or set to "(not set)".
-- 3. Collapse repeated measurement events for reliable transaction IDs.
-- The previous version was partitioned by historical transaction dates.
-- In BigQuery Sandbox, those 2020–2021 partitions expire immediately.
-- This small mart is therefore stored as an unpartitioned clustered table.

DROP TABLE IF EXISTS
  `measurement-360-portfolio.measurement_360_mart.fct_transactions`;

CREATE TABLE
  `measurement-360-portfolio.measurement_360_mart.fct_transactions`

CLUSTER BY
  transaction_date,
  transaction_key_method,
  user_pseudo_id

  
OPTIONS (
  description = 'One row per conflict-aware, deduplicated ecommerce transaction using event-level USD purchase revenue.'
)

AS

WITH purchase_events AS (
  SELECT
    source_event_fingerprint,
    event_date,
    event_timestamp_utc,
    event_timestamp_micros,
    user_pseudo_id,
    ga_session_id,
    ga_session_number,
    session_key,

    transaction_id_raw,
    transaction_id_normalized,
    transaction_id_status,

    ecommerce_purchase_revenue_in_usd,
    ecommerce_total_item_quantity,
    item_record_count,
    currency,

    event_source,
    event_medium,
    event_campaign,

    first_user_source,
    first_user_medium,
    first_user_campaign,

    page_location,

    geo_country,
    geo_region,
    geo_city,

    device_category,
    device_operating_system,
    device_browser,

    analytics_storage,
    ads_storage,
    uses_transient_token

  FROM
    `measurement-360-portfolio.measurement_360_stg.stg_ga4_events`

  WHERE is_purchase_event
),

valid_transaction_id_profiles AS (
  SELECT
    transaction_id_normalized,

    COUNT(*) AS transaction_id_purchase_event_rows,

    COUNT(DISTINCT user_pseudo_id)
      AS transaction_id_distinct_users,

    COUNT(
      DISTINCT ROUND(ecommerce_purchase_revenue_in_usd, 6)
    ) AS transaction_id_distinct_revenue_values

  FROM purchase_events

  WHERE transaction_id_status = 'VALID'

  GROUP BY transaction_id_normalized
),

method_classification AS (
  SELECT
    purchase.*,

    profile.transaction_id_purchase_event_rows,
    profile.transaction_id_distinct_users,
    profile.transaction_id_distinct_revenue_values,

    CASE
      WHEN
        purchase.transaction_id_status = 'VALID'
        AND profile.transaction_id_distinct_users = 1
        AND profile.transaction_id_distinct_revenue_values <= 1
        THEN 'RELIABLE_TRANSACTION_ID'

      WHEN purchase.transaction_id_status = 'VALID'
        THEN 'FALLBACK_CONFLICTING_TRANSACTION_ID'

      WHEN purchase.transaction_id_status = 'NOT_SET'
        THEN 'FALLBACK_NOT_SET'

      ELSE 'FALLBACK_MISSING_ID'
    END AS transaction_key_method

  FROM purchase_events AS purchase

  LEFT JOIN valid_transaction_id_profiles AS profile
    USING (transaction_id_normalized)
),

keyed_purchase_events AS (
  SELECT
    classified.*,

    CASE
      WHEN transaction_key_method = 'RELIABLE_TRANSACTION_ID'
        THEN CONCAT(
          'TRANSACTION_ID|',
          transaction_id_normalized
        )

      WHEN transaction_key_method
        = 'FALLBACK_CONFLICTING_TRANSACTION_ID'
        THEN CONCAT(
          'CONFLICTING_ID|',
          source_event_fingerprint
        )

      WHEN transaction_key_method = 'FALLBACK_NOT_SET'
        THEN CONCAT(
          'NOT_SET|',
          source_event_fingerprint
        )

      ELSE CONCAT(
        'MISSING_ID|',
        source_event_fingerprint
      )
    END AS transaction_key

  FROM method_classification AS classified
),

ranked_purchase_events AS (
  SELECT
    keyed.*,

    COUNT(*) OVER (
      PARTITION BY transaction_key
    ) AS measurement_event_rows,

    MIN(event_timestamp_utc) OVER (
      PARTITION BY transaction_key
    ) AS first_measurement_timestamp_utc,

    MAX(event_timestamp_utc) OVER (
      PARTITION BY transaction_key
    ) AS last_measurement_timestamp_utc,

    ROW_NUMBER() OVER (
      PARTITION BY transaction_key

      ORDER BY
        event_timestamp_utc,
        event_timestamp_micros,
        source_event_fingerprint
    ) AS canonical_row_number

  FROM keyed_purchase_events AS keyed
)

SELECT
  transaction_key,
  transaction_key_method,

  event_date AS transaction_date,
  event_timestamp_utc AS transaction_timestamp_utc,
  event_timestamp_micros AS transaction_timestamp_micros,

  source_event_fingerprint
    AS canonical_source_event_fingerprint,

  -- Customer and session
  user_pseudo_id,
  ga_session_id,
  ga_session_number,
  session_key,

  -- Source identifiers
  transaction_id_raw,
  transaction_id_normalized,
  transaction_id_status,

  -- Canonical financial metrics
  ecommerce_purchase_revenue_in_usd
    AS transaction_revenue_usd,

  currency AS transaction_currency,
  ecommerce_total_item_quantity
    AS transaction_item_quantity,
  item_record_count,

  -- Measurement duplication audit
  measurement_event_rows,
  measurement_event_rows - 1 AS duplicate_measurement_rows,

  first_measurement_timestamp_utc,
  last_measurement_timestamp_utc,

  TIMESTAMP_DIFF(
    last_measurement_timestamp_utc,
    first_measurement_timestamp_utc,
    SECOND
  ) AS measurement_span_seconds,

  -- Transaction-ID profile
  transaction_id_purchase_event_rows,
  transaction_id_distinct_users,
  transaction_id_distinct_revenue_values,

  COALESCE(transaction_id_distinct_users, 0) > 1
    AS transaction_id_cross_user_conflict,

  COALESCE(transaction_id_distinct_revenue_values, 0) > 1
    AS transaction_id_revenue_conflict,

  transaction_key_method != 'RELIABLE_TRANSACTION_ID'
    AS uses_fallback_transaction_key,

  -- Acquisition context at conversion
  event_source,
  event_medium,
  event_campaign,

  first_user_source,
  first_user_medium,
  first_user_campaign,

  -- Conversion page
  page_location,

  -- Geography
  geo_country,
  geo_region,
  geo_city,

  -- Device
  device_category,
  device_operating_system,
  device_browser,

  -- Privacy context
  analytics_storage,
  ads_storage,
  uses_transient_token

FROM ranked_purchase_events

WHERE canonical_row_number = 1;
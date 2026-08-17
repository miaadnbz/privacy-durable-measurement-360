-- Measurement 360
-- Reconciliation for fct_transactions
--
-- This test confirms that:
-- 1. All purchase measurement events are represented.
-- 2. Duplicate measurement events are removed correctly.
-- 3. Transaction keys are unique.
-- 4. Canonical revenue reconciles to the raw event-level revenue.
-- 5. Key-method counts agree with the profiled source contract.

WITH source_summary AS (
  SELECT
    COUNT(*) AS source_purchase_event_rows,

    SUM(ecommerce_purchase_revenue_in_usd)
      AS source_raw_purchase_revenue_usd

  FROM
    `measurement-360-portfolio.measurement_360_stg.stg_ga4_events`

  WHERE is_purchase_event
),

fact_summary AS (
  SELECT
    COUNT(*) AS fact_transaction_rows,
    COUNT(DISTINCT transaction_key)
      AS distinct_transaction_keys,

    SUM(measurement_event_rows)
      AS represented_purchase_event_rows,

    SUM(duplicate_measurement_rows)
      AS duplicate_measurement_rows_removed,

    SUM(transaction_revenue_usd)
      AS canonical_transaction_revenue_usd,

    SUM(
      transaction_revenue_usd
      * measurement_event_rows
    ) AS represented_raw_purchase_revenue_usd,

    COUNTIF(
      transaction_key_method = 'RELIABLE_TRANSACTION_ID'
    ) AS reliable_transaction_id_rows,

    COUNTIF(
      transaction_key_method
        = 'FALLBACK_CONFLICTING_TRANSACTION_ID'
    ) AS conflicting_id_fallback_rows,

    COUNTIF(
      transaction_key_method = 'FALLBACK_MISSING_ID'
    ) AS missing_id_fallback_rows,

    COUNTIF(
      transaction_key_method = 'FALLBACK_NOT_SET'
    ) AS not_set_fallback_rows,

    COUNTIF(transaction_key IS NULL)
      AS null_transaction_key_rows,

    COUNTIF(transaction_revenue_usd IS NULL)
      AS null_transaction_revenue_rows,

    COUNTIF(
      transaction_key_method = 'RELIABLE_TRANSACTION_ID'
      AND (
        transaction_id_cross_user_conflict
        OR transaction_id_revenue_conflict
      )
    ) AS unreliable_rows_classified_as_reliable,

    COUNTIF(
      transaction_key_method != 'RELIABLE_TRANSACTION_ID'
      AND measurement_event_rows != 1
    ) AS grouped_fallback_transaction_rows

  FROM
    `measurement-360-portfolio.measurement_360_mart.fct_transactions`
)

SELECT
  source_purchase_event_rows,
  represented_purchase_event_rows,

  source_purchase_event_rows
    = represented_purchase_event_rows
    AS all_purchase_events_represented,

  fact_transaction_rows,
  distinct_transaction_keys,

  fact_transaction_rows - distinct_transaction_keys
    AS duplicate_transaction_keys,

  source_purchase_event_rows - fact_transaction_rows
    AS purchase_rows_removed_by_deduplication,

  duplicate_measurement_rows_removed,

  source_raw_purchase_revenue_usd,
  represented_raw_purchase_revenue_usd,

  ROUND(source_raw_purchase_revenue_usd, 6)
    = ROUND(represented_raw_purchase_revenue_usd, 6)
    AS raw_revenue_reconciles,

  canonical_transaction_revenue_usd,

  source_raw_purchase_revenue_usd
    - canonical_transaction_revenue_usd
    AS duplicate_measurement_revenue_removed_usd,

  reliable_transaction_id_rows,
  conflicting_id_fallback_rows,
  missing_id_fallback_rows,
  not_set_fallback_rows,

  null_transaction_key_rows,
  null_transaction_revenue_rows,
  unreliable_rows_classified_as_reliable,
  grouped_fallback_transaction_rows,

  CASE
    WHEN
      source_purchase_event_rows = represented_purchase_event_rows
      AND fact_transaction_rows = distinct_transaction_keys
      AND fact_transaction_rows = 5375
      AND duplicate_measurement_rows_removed = 317

      AND reliable_transaction_id_rows = 4436
      AND conflicting_id_fallback_rows = 33
      AND missing_id_fallback_rows = 23
      AND not_set_fallback_rows = 883

      AND ROUND(source_raw_purchase_revenue_usd, 6)
        = ROUND(represented_raw_purchase_revenue_usd, 6)

      AND null_transaction_key_rows = 0
      AND null_transaction_revenue_rows = 0
      AND unreliable_rows_classified_as_reliable = 0
      AND grouped_fallback_transaction_rows = 0

    THEN 'PASS'
    ELSE 'REVIEW'
  END AS reconciliation_status

FROM source_summary
CROSS JOIN fact_summary;
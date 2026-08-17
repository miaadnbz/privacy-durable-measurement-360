-- Measurement 360
-- Reconciliation for fct_sessions

WITH source_event_summary AS (
  SELECT
    COUNT(*) AS source_event_rows,
    COUNT(DISTINCT session_key)
      AS source_distinct_sessions,
    COUNT(DISTINCT user_pseudo_id)
      AS source_unique_users,
    COUNTIF(session_key IS NULL)
      AS source_events_without_session_key,
    COUNTIF(event_name = 'purchase')
      AS source_purchase_measurement_events

  FROM
    `measurement-360-portfolio.measurement_360_stg.stg_ga4_events`
),

transaction_summary AS (
  SELECT
    COUNT(*) AS source_canonical_transactions,
    SUM(transaction_revenue_usd)
      AS source_canonical_revenue_usd,
    COUNTIF(session_key IS NULL)
      AS transactions_without_session_key

  FROM
    `measurement-360-portfolio.measurement_360_mart.fct_transactions`
),

session_summary AS (
  SELECT
    COUNT(*) AS fact_session_rows,
    COUNT(DISTINCT session_key)
      AS distinct_fact_session_keys,
    COUNT(DISTINCT user_pseudo_id)
      AS fact_unique_users,

    SUM(event_count)
      AS represented_event_rows,

    SUM(raw_purchase_measurement_event_count)
      AS represented_purchase_measurement_events,

    SUM(canonical_transaction_count)
      AS represented_canonical_transactions,

    SUM(canonical_revenue_usd)
      AS represented_canonical_revenue_usd,

    SUM(duplicate_purchase_measurement_rows)
      AS duplicate_purchase_measurement_rows,

    COUNTIF(is_converting_session)
      AS converting_sessions,

    COUNTIF(canonical_transaction_count > 1)
      AS sessions_with_multiple_transactions,

    COUNTIF(session_start_event_count = 0)
      AS sessions_without_session_start_event,

    COUNTIF(session_duration_seconds < 0)
      AS negative_session_duration_rows,

    COUNTIF(session_source IS NULL)
      AS null_session_source_rows,

    COUNTIF(session_medium IS NULL)
      AS null_session_medium_rows,

    COUNTIF(session_channel_group IS NULL)
      AS null_session_channel_group_rows

  FROM
    `measurement-360-portfolio.measurement_360_mart.fct_sessions`
)

SELECT
  source_event_rows,
  represented_event_rows,
  source_event_rows = represented_event_rows
    AS all_events_represented,

  source_distinct_sessions,
  fact_session_rows,
  distinct_fact_session_keys,

  source_distinct_sessions = fact_session_rows
    AS session_counts_match,

  fact_session_rows = distinct_fact_session_keys
    AS session_keys_are_unique,

  source_unique_users,
  fact_unique_users,
  source_unique_users = fact_unique_users
    AS user_counts_match,

  source_events_without_session_key,

  source_purchase_measurement_events,
  represented_purchase_measurement_events,

  source_purchase_measurement_events
    = represented_purchase_measurement_events
    AS purchase_measurement_events_match,

  source_canonical_transactions,
  represented_canonical_transactions,

  source_canonical_transactions
    = represented_canonical_transactions
    AS canonical_transactions_match,

  source_canonical_revenue_usd,
  represented_canonical_revenue_usd,

  ROUND(source_canonical_revenue_usd, 6)
    = ROUND(represented_canonical_revenue_usd, 6)
    AS canonical_revenue_matches,

  source_purchase_measurement_events
    - source_canonical_transactions
    AS expected_duplicate_purchase_measurement_rows,

  duplicate_purchase_measurement_rows,

  converting_sessions,
  sessions_with_multiple_transactions,
  sessions_without_session_start_event,

  transactions_without_session_key,
  negative_session_duration_rows,
  null_session_source_rows,
  null_session_medium_rows,
  null_session_channel_group_rows,

  CASE
    WHEN
      source_event_rows = represented_event_rows
      AND source_distinct_sessions = fact_session_rows
      AND fact_session_rows = distinct_fact_session_keys
      AND source_unique_users = fact_unique_users
      AND source_events_without_session_key = 0

      AND source_purchase_measurement_events
        = represented_purchase_measurement_events

      AND source_canonical_transactions
        = represented_canonical_transactions

      AND ROUND(source_canonical_revenue_usd, 6)
        = ROUND(represented_canonical_revenue_usd, 6)

      AND duplicate_purchase_measurement_rows
        = source_purchase_measurement_events
          - source_canonical_transactions

      AND transactions_without_session_key = 0
      AND negative_session_duration_rows = 0
      AND null_session_source_rows = 0
      AND null_session_medium_rows = 0
      AND null_session_channel_group_rows = 0

    THEN 'PASS'
    ELSE 'REVIEW'
  END AS reconciliation_status

FROM source_event_summary
CROSS JOIN transaction_summary
CROSS JOIN session_summary;
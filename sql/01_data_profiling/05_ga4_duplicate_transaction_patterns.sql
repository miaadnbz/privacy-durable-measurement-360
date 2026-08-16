-- File: 05_ga4_duplicate_transaction_patterns.sql
-- Purpose:
--   Classify unique, missing, and duplicated ecommerce transaction IDs
--   according to user, timestamp, session, and revenue consistency.
--
-- Source:
--   Google Analytics 4 obfuscated ecommerce sample dataset.
--
-- Output grain:
--   One row per transaction-quality pattern.

WITH purchase_events AS (
  SELECT
    NULLIF(
      TRIM(ecommerce.transaction_id),
      ''
    ) AS transaction_id,

    user_pseudo_id,
    event_date,
    event_timestamp,
    ecommerce.purchase_revenue_in_usd AS revenue_usd,

    (
      SELECT
        COALESCE(
          parameter.value.int_value,
          SAFE_CAST(parameter.value.string_value AS INT64)
        )
      FROM
        UNNEST(event_params) AS parameter
      WHERE
        parameter.key = 'ga_session_id'
      LIMIT 1
    ) AS ga_session_id

  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE
    _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    AND event_name = 'purchase'
),

prepared_events AS (
  SELECT
    *,
    CONCAT(
      COALESCE(user_pseudo_id, '[NULL_USER]'),
      '|',
      COALESCE(CAST(ga_session_id AS STRING), '[NULL_SESSION]')
    ) AS composite_session_key
  FROM
    purchase_events
),

transaction_profiles AS (
  SELECT
    transaction_id,
    COUNT(*) AS purchase_event_rows,
    COUNT(DISTINCT user_pseudo_id) AS distinct_users,
    COUNT(DISTINCT composite_session_key) AS distinct_sessions,
    COUNT(DISTINCT event_date) AS distinct_dates,
    COUNT(DISTINCT event_timestamp) AS distinct_event_timestamps,
    COUNT(DISTINCT revenue_usd) AS distinct_revenue_values,
    MIN(TIMESTAMP_MICROS(event_timestamp)) AS first_event_timestamp,
    MAX(TIMESTAMP_MICROS(event_timestamp)) AS last_event_timestamp,
    TIMESTAMP_DIFF(
      MAX(TIMESTAMP_MICROS(event_timestamp)),
      MIN(TIMESTAMP_MICROS(event_timestamp)),
      SECOND
    ) AS event_span_seconds
  FROM
    prepared_events
  GROUP BY
    transaction_id
),

classified_transactions AS (
  SELECT
    *,
    CASE
      WHEN transaction_id IS NULL
        THEN 'MISSING_TRANSACTION_ID'

      WHEN purchase_event_rows = 1
        THEN 'UNIQUE_TRANSACTION_ID'

      WHEN distinct_users > 1
        THEN 'ID_REUSED_ACROSS_USERS'

      WHEN distinct_revenue_values > 1
        THEN 'SAME_ID_DIFFERENT_REVENUE'

      WHEN distinct_event_timestamps = 1
        THEN 'SAME_ID_SAME_TIMESTAMP'

      WHEN distinct_sessions = 1
        THEN 'SAME_ID_REPEATED_WITHIN_SESSION'

      ELSE 'SAME_ID_REPEATED_ACROSS_SESSIONS'
    END AS transaction_pattern
  FROM
    transaction_profiles
)

SELECT
  transaction_pattern,

  COUNTIF(transaction_id IS NOT NULL)
    AS transaction_id_groups,

  SUM(purchase_event_rows)
    AS purchase_event_rows,

  SUM(
    CASE
      WHEN transaction_id IS NOT NULL
        THEN purchase_event_rows - 1
      ELSE 0
    END
  ) AS excess_purchase_event_rows,

  ROUND(
    AVG(
      IF(
        transaction_id IS NOT NULL,
        purchase_event_rows,
        NULL
      )
    ),
    2
  ) AS average_event_rows_per_transaction_id,

  MAX(
    IF(
      transaction_id IS NOT NULL,
      purchase_event_rows,
      NULL
    )
  ) AS maximum_event_rows_for_one_transaction_id,

  MAX(event_span_seconds)
    AS maximum_event_span_seconds,

  ARRAY_AGG(
    transaction_id
    IGNORE NULLS
    ORDER BY purchase_event_rows DESC, transaction_id
    LIMIT 5
  ) AS sample_transaction_ids

FROM
  classified_transactions
GROUP BY
  transaction_pattern
ORDER BY
  CASE transaction_pattern
    WHEN 'UNIQUE_TRANSACTION_ID' THEN 1
    WHEN 'MISSING_TRANSACTION_ID' THEN 2
    WHEN 'ID_REUSED_ACROSS_USERS' THEN 3
    WHEN 'SAME_ID_DIFFERENT_REVENUE' THEN 4
    WHEN 'SAME_ID_SAME_TIMESTAMP' THEN 5
    WHEN 'SAME_ID_REPEATED_WITHIN_SESSION' THEN 6
    WHEN 'SAME_ID_REPEATED_ACROSS_SESSIONS' THEN 7
    ELSE 8
  END;
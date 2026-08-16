-- File: 06_ga4_canonical_transaction_key_profile.sql
-- Purpose:
--   Evaluate a canonical transaction-key strategy using normalized
--   ecommerce transaction IDs and a conservative fallback signature.
--
-- Source:
--   Google Analytics 4 obfuscated ecommerce sample dataset.
--
-- Output grain:
--   One row per proposed transaction-key method.

WITH raw_purchase_events AS (
  SELECT
    ecommerce.transaction_id AS raw_transaction_id,
    user_pseudo_id,
    event_timestamp,
    ecommerce.purchase_revenue_in_usd AS revenue_usd,
    TO_JSON_STRING(items) AS items_json,

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

normalized_purchase_events AS (
  SELECT
    *,

    CASE
      WHEN raw_transaction_id IS NULL
        OR TRIM(raw_transaction_id) = ''
        THEN 'MISSING_ID'

      WHEN LOWER(TRIM(raw_transaction_id)) = '(not set)'
        THEN 'NOT_SET_SENTINEL'

      ELSE 'VALID_ID'
    END AS transaction_id_status,

    CASE
      WHEN raw_transaction_id IS NULL
        OR TRIM(raw_transaction_id) = ''
        OR LOWER(TRIM(raw_transaction_id)) = '(not set)'
        THEN NULL

      ELSE TRIM(raw_transaction_id)
    END AS normalized_transaction_id,

    CONCAT(
      COALESCE(user_pseudo_id, '[NULL_USER]'),
      '|',
      COALESCE(CAST(ga_session_id AS STRING), '[NULL_SESSION]')
    ) AS composite_session_key

  FROM
    raw_purchase_events
),

keyed_purchase_events AS (
  SELECT
    *,

    CASE
      WHEN transaction_id_status = 'VALID_ID'
        THEN 'VALID_TRANSACTION_ID'

      WHEN transaction_id_status = 'NOT_SET_SENTINEL'
        THEN 'FALLBACK_SIGNATURE_NOT_SET'

      ELSE 'FALLBACK_SIGNATURE_MISSING_ID'
    END AS transaction_key_method,

    CASE
      WHEN transaction_id_status = 'VALID_ID'
        THEN normalized_transaction_id

      ELSE TO_HEX(
        SHA256(
          CONCAT(
            COALESCE(user_pseudo_id, '[NULL_USER]'),
            '|',
            COALESCE(CAST(ga_session_id AS STRING), '[NULL_SESSION]'),
            '|',
            CAST(event_timestamp AS STRING),
            '|',
            COALESCE(CAST(revenue_usd AS STRING), '[NULL_REVENUE]'),
            '|',
            COALESCE(items_json, '[NULL_ITEMS]')
          )
        )
      )
    END AS candidate_transaction_key

  FROM
    normalized_purchase_events
),

candidate_key_profiles AS (
  SELECT
    transaction_key_method,
    candidate_transaction_key,

    COUNT(*) AS purchase_event_rows,
    COUNT(DISTINCT user_pseudo_id) AS distinct_users,
    COUNT(DISTINCT composite_session_key) AS distinct_sessions,
    COUNT(DISTINCT revenue_usd) AS distinct_revenue_values

  FROM
    keyed_purchase_events
  GROUP BY
    transaction_key_method,
    candidate_transaction_key
),

method_summary AS (
  SELECT
    transaction_key_method,

    COUNT(*) AS candidate_transaction_keys,
    SUM(purchase_event_rows) AS purchase_event_rows,

    COUNTIF(purchase_event_rows > 1)
      AS duplicated_candidate_keys,

    SUM(purchase_event_rows - 1)
      AS excess_purchase_event_rows,

    COUNTIF(distinct_users > 1)
      AS cross_user_candidate_keys,

    COUNTIF(distinct_revenue_values > 1)
      AS conflicting_revenue_candidate_keys,

    MAX(purchase_event_rows)
      AS maximum_event_rows_for_one_candidate_key

  FROM
    candidate_key_profiles
  GROUP BY
    transaction_key_method
)

SELECT
  transaction_key_method,
  candidate_transaction_keys,
  purchase_event_rows,

  ROUND(
    100 * SAFE_DIVIDE(
      purchase_event_rows,
      SUM(purchase_event_rows) OVER ()
    ),
    2
  ) AS purchase_event_share_pct,

  duplicated_candidate_keys,
  excess_purchase_event_rows,
  cross_user_candidate_keys,
  conflicting_revenue_candidate_keys,
  maximum_event_rows_for_one_candidate_key

FROM
  method_summary
ORDER BY
  CASE transaction_key_method
    WHEN 'VALID_TRANSACTION_ID' THEN 1
    WHEN 'FALLBACK_SIGNATURE_MISSING_ID' THEN 2
    WHEN 'FALLBACK_SIGNATURE_NOT_SET' THEN 3
    ELSE 4
  END;
-- File: 07_ga4_final_transaction_key_profile.sql
-- Purpose:
--   Finalize a conflict-aware canonical transaction-key strategy.
--   Reliable ecommerce transaction IDs are retained, while missing,
--   sentinel, cross-user, and conflicting-revenue IDs use a
--   conservative event signature.
--
-- Output grain:
--   One row per final transaction-key method.

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

valid_id_profiles AS (
  SELECT
    normalized_transaction_id,

    COUNT(
      DISTINCT COALESCE(
        user_pseudo_id,
        '[NULL_USER]'
      )
    ) AS distinct_users,

    COUNT(
      DISTINCT COALESCE(
        CAST(revenue_usd AS STRING),
        '[NULL_REVENUE]'
      )
    ) AS distinct_revenue_values

  FROM
    normalized_purchase_events
  WHERE
    transaction_id_status = 'VALID_ID'
  GROUP BY
    normalized_transaction_id
),

classified_purchase_events AS (
  SELECT
    events.*,
    profiles.distinct_users AS id_distinct_users,
    profiles.distinct_revenue_values AS id_distinct_revenue_values,

    CASE
      WHEN events.transaction_id_status = 'VALID_ID'
        AND profiles.distinct_users = 1
        AND profiles.distinct_revenue_values = 1
        THEN TRUE

      ELSE FALSE
    END AS reliable_transaction_id

  FROM
    normalized_purchase_events AS events
  LEFT JOIN
    valid_id_profiles AS profiles
  USING
    (normalized_transaction_id)
),

keyed_purchase_events AS (
  SELECT
    *,

    CASE
      WHEN reliable_transaction_id
        THEN 'RELIABLE_TRANSACTION_ID'

      WHEN transaction_id_status = 'VALID_ID'
        THEN 'FALLBACK_CONFLICTING_TRANSACTION_ID'

      WHEN transaction_id_status = 'NOT_SET_SENTINEL'
        THEN 'FALLBACK_NOT_SET'

      ELSE 'FALLBACK_MISSING_ID'
    END AS final_key_method,

    CASE
      WHEN reliable_transaction_id
        THEN CONCAT(
          'TXN|',
          normalized_transaction_id
        )

      ELSE CONCAT(
        'SIG|',
        TO_HEX(
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
      )
    END AS final_candidate_transaction_key

  FROM
    classified_purchase_events
),

candidate_key_profiles AS (
  SELECT
    final_key_method,
    final_candidate_transaction_key,

    COUNT(*) AS purchase_event_rows,

    COUNT(
      DISTINCT COALESCE(
        user_pseudo_id,
        '[NULL_USER]'
      )
    ) AS distinct_users,

    COUNT(
      DISTINCT COALESCE(
        CAST(revenue_usd AS STRING),
        '[NULL_REVENUE]'
      )
    ) AS distinct_revenue_values

  FROM
    keyed_purchase_events
  GROUP BY
    final_key_method,
    final_candidate_transaction_key
),

method_summary AS (
  SELECT
    final_key_method,

    COUNT(*) AS final_candidate_transaction_keys,
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
    final_key_method
)

SELECT
  final_key_method,
  final_candidate_transaction_keys,
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
  CASE final_key_method
    WHEN 'RELIABLE_TRANSACTION_ID' THEN 1
    WHEN 'FALLBACK_CONFLICTING_TRANSACTION_ID' THEN 2
    WHEN 'FALLBACK_MISSING_ID' THEN 3
    WHEN 'FALLBACK_NOT_SET' THEN 4
    ELSE 5
  END;
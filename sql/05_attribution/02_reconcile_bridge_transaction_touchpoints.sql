-- Measurement 360
-- Stage 5A.2: Reconcile the transaction-to-touchpoint bridge

DECLARE lookback_days INT64 DEFAULT 30;
DECLARE expected_transaction_count INT64 DEFAULT 5375;
DECLARE expected_canonical_revenue FLOAT64 DEFAULT 340859.0;

WITH source_transactions AS (
  SELECT
    COUNT(*) AS source_transaction_count,
    COUNT(DISTINCT user_pseudo_id) AS source_transaction_users,
    SUM(transaction_revenue_usd) AS source_canonical_revenue_usd,
    COUNTIF(uses_fallback_transaction_key)
      AS source_fallback_transactions
  FROM
    `measurement-360-portfolio.measurement_360_mart.fct_transactions`
),

bridge_transaction_level AS (
  SELECT
    transaction_key,
    MAX(user_pseudo_id) AS user_pseudo_id,
    MAX(transaction_revenue_usd) AS transaction_revenue_usd,
    LOGICAL_OR(uses_fallback_transaction_key)
      AS uses_fallback_transaction_key,

    COUNT(*) AS touchpoint_count,
    COUNTIF(NOT is_direct_touchpoint)
      AS non_direct_touchpoint_count,

    COUNTIF(is_conversion_session)
      AS conversion_session_count,

    COUNTIF(is_first_touchpoint)
      AS first_touchpoint_flag_count,

    COUNTIF(is_last_touchpoint)
      AS last_touchpoint_flag_count,

    COUNTIF(is_last_non_direct_attribution_touchpoint)
      AS last_non_direct_attribution_flag_count,

    LOGICAL_OR(is_lookback_left_censored)
      AS is_lookback_left_censored

  FROM
    `measurement-360-portfolio.measurement_360_mart.bridge_transaction_touchpoints`

  GROUP BY
    transaction_key
),

bridge_summary AS (
  SELECT
    COUNT(*) AS represented_transaction_count,
    COUNT(DISTINCT user_pseudo_id)
      AS represented_transaction_users,
    SUM(transaction_revenue_usd)
      AS represented_canonical_revenue_usd,
    COUNTIF(uses_fallback_transaction_key)
      AS represented_fallback_transactions,

    SUM(touchpoint_count) AS bridge_row_count,
    MIN(touchpoint_count) AS minimum_touchpoints_per_transaction,
    ROUND(AVG(touchpoint_count), 2)
      AS average_touchpoints_per_transaction,
    MAX(touchpoint_count) AS maximum_touchpoints_per_transaction,

    COUNTIF(touchpoint_count > 1)
      AS multi_touch_transactions,

    COUNTIF(non_direct_touchpoint_count = 0)
      AS direct_only_transactions,

    COUNTIF(is_lookback_left_censored)
      AS left_censored_transactions,

    COUNTIF(conversion_session_count != 1)
      AS conversion_session_errors,

    COUNTIF(first_touchpoint_flag_count != 1)
      AS first_touchpoint_flag_errors,

    COUNTIF(last_touchpoint_flag_count != 1)
      AS last_touchpoint_flag_errors,

    COUNTIF(last_non_direct_attribution_flag_count != 1)
      AS last_non_direct_flag_errors

  FROM
    bridge_transaction_level
),

bridge_row_quality AS (
  SELECT
    COUNTIF(seconds_before_transaction < 0)
      AS future_touchpoint_rows,

    COUNTIF(
      seconds_before_transaction > lookback_days * 86400
    ) AS outside_lookback_rows,

    COUNTIF(
      transaction_key IS NULL
      OR user_pseudo_id IS NULL
      OR transaction_session_key IS NULL
      OR touchpoint_session_key IS NULL
    ) AS null_required_identifier_rows,

    COUNTIF(
      touchpoint_source IS NULL
      OR touchpoint_medium IS NULL
      OR touchpoint_channel_group IS NULL
    ) AS null_attribution_dimension_rows

  FROM
    `measurement-360-portfolio.measurement_360_mart.bridge_transaction_touchpoints`
),

duplicate_pairs AS (
  SELECT
    COUNT(*) AS duplicate_transaction_touchpoint_pairs
  FROM (
    SELECT
      transaction_key,
      touchpoint_session_key
    FROM
      `measurement-360-portfolio.measurement_360_mart.bridge_transaction_touchpoints`
    GROUP BY
      transaction_key,
      touchpoint_session_key
    HAVING COUNT(*) > 1
  )
),

metrics AS (
  SELECT
    s.source_transaction_count,
    b.represented_transaction_count,
    s.source_transaction_count =
      b.represented_transaction_count
      AS transaction_counts_match,

    s.source_transaction_users,
    b.represented_transaction_users,
    s.source_transaction_users =
      b.represented_transaction_users
      AS transaction_user_counts_match,

    s.source_canonical_revenue_usd,
    b.represented_canonical_revenue_usd,
    ABS(
      s.source_canonical_revenue_usd
      - b.represented_canonical_revenue_usd
    ) < 0.01 AS canonical_revenue_matches,

    s.source_fallback_transactions,
    b.represented_fallback_transactions,
    s.source_fallback_transactions =
      b.represented_fallback_transactions
      AS fallback_transaction_counts_match,

    b.bridge_row_count,
    b.minimum_touchpoints_per_transaction,
    b.average_touchpoints_per_transaction,
    b.maximum_touchpoints_per_transaction,
    b.multi_touch_transactions,
    b.direct_only_transactions,
    b.left_censored_transactions,

    b.conversion_session_errors,
    b.first_touchpoint_flag_errors,
    b.last_touchpoint_flag_errors,
    b.last_non_direct_flag_errors,

    q.future_touchpoint_rows,
    q.outside_lookback_rows,
    q.null_required_identifier_rows,
    q.null_attribution_dimension_rows,

    d.duplicate_transaction_touchpoint_pairs

  FROM
    source_transactions AS s

  CROSS JOIN
    bridge_summary AS b

  CROSS JOIN
    bridge_row_quality AS q

  CROSS JOIN
    duplicate_pairs AS d
)

SELECT
  *,

  CASE
    WHEN source_transaction_count = expected_transaction_count
      AND represented_transaction_count = expected_transaction_count
      AND transaction_counts_match
      AND transaction_user_counts_match
      AND canonical_revenue_matches
      AND ABS(
        represented_canonical_revenue_usd
        - expected_canonical_revenue
      ) < 0.01
      AND fallback_transaction_counts_match
      AND minimum_touchpoints_per_transaction >= 1
      AND conversion_session_errors = 0
      AND first_touchpoint_flag_errors = 0
      AND last_touchpoint_flag_errors = 0
      AND last_non_direct_flag_errors = 0
      AND future_touchpoint_rows = 0
      AND outside_lookback_rows = 0
      AND null_required_identifier_rows = 0
      AND null_attribution_dimension_rows = 0
      AND duplicate_transaction_touchpoint_pairs = 0
    THEN 'PASS'
    ELSE 'FAIL'
  END AS reconciliation_status

FROM
  metrics;
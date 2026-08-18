-- Measurement 360
-- Stage 5B: Reconcile all multi-touch attribution models

DECLARE expected_transaction_count INT64 DEFAULT 5375;
DECLARE expected_bridge_row_count INT64 DEFAULT 13446;
DECLARE expected_credit_row_count INT64 DEFAULT 43017;
DECLARE expected_canonical_revenue FLOAT64 DEFAULT 340859.0;

WITH source_summary AS (
  SELECT
    COUNT(*) AS source_transactions,
    COUNT(DISTINCT user_pseudo_id) AS source_users,
    SUM(transaction_revenue_usd) AS source_revenue_usd
  FROM
    `measurement-360-portfolio.measurement_360_mart.fct_transactions`
),

expected_model_rows AS (
  SELECT *
  FROM UNNEST([
    STRUCT(
      'first_touch' AS attribution_model,
      1 AS attribution_model_order,
      5375 AS expected_model_credit_rows
    ),
    STRUCT(
      'last_touch' AS attribution_model,
      2 AS attribution_model_order,
      5375 AS expected_model_credit_rows
    ),
    STRUCT(
      'last_non_direct' AS attribution_model,
      3 AS attribution_model_order,
      5375 AS expected_model_credit_rows
    ),
    STRUCT(
      'linear' AS attribution_model,
      4 AS attribution_model_order,
      13446 AS expected_model_credit_rows
    ),
    STRUCT(
      'position_based' AS attribution_model,
      5 AS attribution_model_order,
      13446 AS expected_model_credit_rows
    )
  ])
),

transaction_model_summary AS (
  SELECT
    attribution_model,
    transaction_key,
    SUM(attribution_weight)
      AS transaction_weight,
    SUM(attributed_conversion_credit)
      AS transaction_conversion_credit,
    SUM(attributed_revenue_usd)
      AS transaction_attributed_revenue
  FROM
    `measurement-360-portfolio.measurement_360_mart.fct_attribution_credits`
  GROUP BY
    attribution_model,
    transaction_key
),

transaction_model_quality AS (
  SELECT
    attribution_model,

    COUNTIF(
      ABS(transaction_weight - 1.0) > 0.000000001
    ) AS transaction_weight_errors,

    COUNTIF(
      ABS(transaction_conversion_credit - 1.0)
        > 0.000000001
    ) AS transaction_conversion_credit_errors

  FROM
    transaction_model_summary

  GROUP BY
    attribution_model
),

model_summary AS (
  SELECT
    attribution_model,
    MIN(attribution_model_order)
      AS attribution_model_order,

    COUNT(*) AS model_credit_rows,

    COUNT(DISTINCT transaction_key)
      AS represented_transactions,

    COUNT(DISTINCT user_pseudo_id)
      AS represented_users,

    COUNT(DISTINCT IF(
      is_complete_lookback_window,
      transaction_key,
      NULL
    )) AS complete_window_transactions,

    SUM(attribution_weight)
      AS total_attribution_weight,

    SUM(attributed_conversion_credit)
      AS total_attributed_conversions,

    SUM(attributed_revenue_usd)
      AS total_attributed_revenue_usd,

    SUM(IF(
      is_complete_lookback_window,
      attributed_revenue_usd,
      0
    )) AS complete_window_attributed_revenue_usd,

    SUM(IF(
      is_lookback_left_censored,
      attributed_revenue_usd,
      0
    )) AS left_censored_attributed_revenue_usd,

    SUM(IF(
      is_direct_touchpoint,
      attributed_conversion_credit,
      0
    )) AS direct_attributed_conversions,

    SUM(IF(
      is_direct_touchpoint,
      attributed_revenue_usd,
      0
    )) AS direct_attributed_revenue_usd,

    COUNT(DISTINCT touchpoint_channel_group)
      AS credited_channel_count

  FROM
    `measurement-360-portfolio.measurement_360_mart.fct_attribution_credits`

  GROUP BY
    attribution_model
),

duplicate_credit_rows AS (
  SELECT
    COUNT(*) AS duplicate_credit_pair_groups
  FROM (
    SELECT
      attribution_model,
      transaction_key,
      touchpoint_session_key
    FROM
      `measurement-360-portfolio.measurement_360_mart.fct_attribution_credits`
    GROUP BY
      attribution_model,
      transaction_key,
      touchpoint_session_key
    HAVING COUNT(*) > 1
  )
),

overall_quality AS (
  SELECT
    COUNT(*) AS total_credit_rows,
    COUNT(DISTINCT attribution_model)
      AS distinct_attribution_models,

    COUNTIF(
      attribution_weight IS NULL
      OR attribution_weight <= 0
      OR attribution_weight > 1
    ) AS invalid_weight_rows,

    COUNTIF(
      transaction_key IS NULL
      OR touchpoint_session_key IS NULL
      OR attribution_model IS NULL
      OR touchpoint_channel_group IS NULL
      OR attributed_revenue_usd IS NULL
    ) AS null_required_field_rows

  FROM
    `measurement-360-portfolio.measurement_360_mart.fct_attribution_credits`
)

SELECT
  e.attribution_model_order,
  e.attribution_model,

  e.expected_model_credit_rows,
  m.model_credit_rows,
  e.expected_model_credit_rows = m.model_credit_rows
    AS model_credit_row_count_matches,

  s.source_transactions,
  m.represented_transactions,
  s.source_transactions = m.represented_transactions
    AS transaction_count_matches,

  s.source_users,
  m.represented_users,
  s.source_users = m.represented_users
    AS user_count_matches,

  m.complete_window_transactions,

  ROUND(m.total_attribution_weight, 6)
    AS total_attribution_weight,

  ROUND(m.total_attributed_conversions, 6)
    AS total_attributed_conversions,

  s.source_revenue_usd,
  ROUND(m.total_attributed_revenue_usd, 2)
    AS total_attributed_revenue_usd,

  ABS(
    s.source_revenue_usd
    - m.total_attributed_revenue_usd
  ) < 0.01 AS revenue_matches,

  ROUND(m.complete_window_attributed_revenue_usd, 2)
    AS complete_window_attributed_revenue_usd,

  ROUND(m.left_censored_attributed_revenue_usd, 2)
    AS left_censored_attributed_revenue_usd,

  ROUND(m.direct_attributed_conversions, 6)
    AS direct_attributed_conversions,

  ROUND(m.direct_attributed_revenue_usd, 2)
    AS direct_attributed_revenue_usd,

  m.credited_channel_count,

  q.transaction_weight_errors,
  q.transaction_conversion_credit_errors,

  o.total_credit_rows,
  o.distinct_attribution_models,
  o.invalid_weight_rows,
  o.null_required_field_rows,
  d.duplicate_credit_pair_groups,

  CASE
    WHEN e.expected_model_credit_rows = m.model_credit_rows
      AND s.source_transactions = expected_transaction_count
      AND m.represented_transactions =
        expected_transaction_count
      AND s.source_transactions =
        m.represented_transactions
      AND s.source_users = m.represented_users
      AND ABS(
        m.total_attribution_weight
        - expected_transaction_count
      ) < 0.000000001
      AND ABS(
        m.total_attributed_conversions
        - expected_transaction_count
      ) < 0.000000001
      AND ABS(
        m.total_attributed_revenue_usd
        - expected_canonical_revenue
      ) < 0.01
      AND q.transaction_weight_errors = 0
      AND q.transaction_conversion_credit_errors = 0
      AND o.total_credit_rows =
        expected_credit_row_count
      AND o.distinct_attribution_models = 5
      AND o.invalid_weight_rows = 0
      AND o.null_required_field_rows = 0
      AND d.duplicate_credit_pair_groups = 0
    THEN 'PASS'
    ELSE 'FAIL'
  END AS model_reconciliation_status

FROM
  expected_model_rows AS e

INNER JOIN
  model_summary AS m
  USING (attribution_model)

INNER JOIN
  transaction_model_quality AS q
  USING (attribution_model)

CROSS JOIN
  source_summary AS s

CROSS JOIN
  overall_quality AS o

CROSS JOIN
  duplicate_credit_rows AS d

ORDER BY
  e.attribution_model_order;
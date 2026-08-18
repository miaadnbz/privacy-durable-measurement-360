-- Measurement 360
-- Stage 5B: Create long-format multi-touch attribution credits
--
-- Grain:
-- One row per canonical transaction, credited session touchpoint,
-- and attribution model.
--
-- Models:
-- 1. First touch
-- 2. Last touch
-- 3. Last non-direct
-- 4. Linear
-- 5. Position-based: 40% first, 40% last, 20% middle
--
-- Revenue is not rounded at the row level. This preserves exact
-- reconciliation when fractional credit is distributed.

DECLARE expected_transaction_count INT64 DEFAULT 5375;
DECLARE expected_bridge_row_count INT64 DEFAULT 13446;
DECLARE expected_credit_row_count INT64 DEFAULT 43017;
DECLARE expected_canonical_revenue FLOAT64 DEFAULT 340859.0;

CREATE TEMP TABLE attribution_credit_build AS

SELECT
  model.attribution_model,
  model.attribution_model_order,

  -- Transaction identifiers
  b.transaction_key,
  b.transaction_key_method,
  b.transaction_id_status,
  b.transaction_date,
  b.transaction_timestamp_utc,
  b.user_pseudo_id,
  b.transaction_session_key,
  b.transaction_ga_session_id,
  b.transaction_ga_session_number,

  -- Original transaction measures retained for auditing
  b.transaction_revenue_usd,
  b.transaction_currency,
  b.transaction_item_quantity,
  b.transaction_item_record_count,
  b.measurement_event_rows,
  b.duplicate_measurement_rows,
  b.uses_fallback_transaction_key,

  -- Credited touchpoint
  b.touchpoint_session_key,
  b.touchpoint_ga_session_id,
  b.touchpoint_ga_session_number,
  b.touchpoint_session_date,
  b.touchpoint_start_timestamp_utc,
  b.touchpoint_end_timestamp_utc,

  b.touchpoint_source,
  b.touchpoint_medium,
  b.touchpoint_campaign,
  b.touchpoint_channel_group,

  b.touchpoint_event_count,
  b.touchpoint_page_view_count,
  b.touchpoint_view_item_count,
  b.touchpoint_add_to_cart_count,
  b.touchpoint_begin_checkout_count,
  b.touchpoint_engagement_seconds,
  b.is_engaged_touchpoint,
  b.is_new_user_touchpoint,

  b.touchpoint_entry_page_location,
  b.touchpoint_entry_page_title,

  b.touchpoint_geo_country,
  b.touchpoint_geo_region,
  b.touchpoint_geo_city,
  b.touchpoint_device_category,
  b.touchpoint_operating_system,
  b.touchpoint_browser,

  -- Privacy indicators
  b.touchpoint_analytics_storage,
  b.touchpoint_ads_storage,
  b.touchpoint_uses_transient_token,

  -- Journey metadata
  b.lookback_window_start_utc,
  b.lookback_window_end_utc,
  b.seconds_before_transaction,
  b.calendar_days_before_transaction,
  b.touchpoint_count,
  b.non_direct_touchpoint_count,
  b.touchpoint_position_asc,
  b.touchpoint_position_desc,
  b.is_conversion_session,
  b.is_direct_touchpoint,
  b.is_first_touchpoint,
  b.is_last_touchpoint,
  b.is_first_non_direct_touchpoint,
  b.is_last_non_direct_touchpoint,
  b.is_last_non_direct_attribution_touchpoint,

  b.source_data_start_date,
  b.source_data_end_date,
  b.is_lookback_left_censored,
  NOT b.is_lookback_left_censored
    AS is_complete_lookback_window,

  -- Attribution measures
  model.attribution_weight,

  model.attribution_weight
    AS attributed_conversion_credit,

  b.transaction_revenue_usd * model.attribution_weight
    AS attributed_revenue_usd

FROM
  `measurement-360-portfolio.measurement_360_mart.bridge_transaction_touchpoints`
  AS b

CROSS JOIN UNNEST([
  STRUCT(
    'first_touch' AS attribution_model,
    1 AS attribution_model_order,
    IF(
      b.is_first_touchpoint,
      CAST(1 AS FLOAT64),
      CAST(0 AS FLOAT64)
    ) AS attribution_weight
  ),

  STRUCT(
    'last_touch' AS attribution_model,
    2 AS attribution_model_order,
    IF(
      b.is_last_touchpoint,
      CAST(1 AS FLOAT64),
      CAST(0 AS FLOAT64)
    ) AS attribution_weight
  ),

  STRUCT(
    'last_non_direct' AS attribution_model,
    3 AS attribution_model_order,
    IF(
      b.is_last_non_direct_attribution_touchpoint,
      CAST(1 AS FLOAT64),
      CAST(0 AS FLOAT64)
    ) AS attribution_weight
  ),

  STRUCT(
    'linear' AS attribution_model,
    4 AS attribution_model_order,
    SAFE_DIVIDE(
      CAST(1 AS FLOAT64),
      b.touchpoint_count
    ) AS attribution_weight
  ),

  STRUCT(
    'position_based' AS attribution_model,
    5 AS attribution_model_order,
    CASE
      WHEN b.touchpoint_count = 1 THEN
        CAST(1 AS FLOAT64)

      WHEN b.touchpoint_count = 2 THEN
        CAST(0.5 AS FLOAT64)

      WHEN b.is_first_touchpoint
        OR b.is_last_touchpoint THEN
        CAST(0.4 AS FLOAT64)

      ELSE
        SAFE_DIVIDE(
          CAST(0.2 AS FLOAT64),
          b.touchpoint_count - 2
        )
    END AS attribution_weight
  )
]) AS model

-- Zero-credit rows are excluded from the credit fact.
WHERE
  model.attribution_weight > 0;


-- ============================================================
-- Input contracts
-- ============================================================

ASSERT (
  SELECT COUNT(*)
  FROM
    `measurement-360-portfolio.measurement_360_mart.bridge_transaction_touchpoints`
) = expected_bridge_row_count
AS 'The validated touchpoint bridge must contain 13,446 rows.';


ASSERT (
  SELECT COUNT(DISTINCT transaction_key)
  FROM
    `measurement-360-portfolio.measurement_360_mart.bridge_transaction_touchpoints`
) = expected_transaction_count
AS 'The bridge must represent exactly 5,375 transactions.';


-- ============================================================
-- Credit-table contracts
-- ============================================================

ASSERT (
  SELECT COUNT(*)
  FROM attribution_credit_build
) = expected_credit_row_count
AS 'The attribution credit build must contain exactly 43,017 rows.';


ASSERT (
  SELECT COUNT(DISTINCT attribution_model)
  FROM attribution_credit_build
) = 5
AS 'Exactly five attribution models must be present.';


ASSERT (
  SELECT COUNTIF(
    attribution_weight IS NULL
    OR attribution_weight <= 0
    OR attribution_weight > 1
  )
  FROM attribution_credit_build
) = 0
AS 'Every retained attribution weight must be greater than 0 and at most 1.';


ASSERT (
  SELECT COUNTIF(
    transaction_key IS NULL
    OR touchpoint_session_key IS NULL
    OR attribution_model IS NULL
    OR touchpoint_channel_group IS NULL
    OR attributed_revenue_usd IS NULL
  )
  FROM attribution_credit_build
) = 0
AS 'Required attribution-credit fields must not be null.';


ASSERT (
  SELECT COUNT(*)
  FROM (
    SELECT
      attribution_model,
      transaction_key,
      touchpoint_session_key
    FROM attribution_credit_build
    GROUP BY
      attribution_model,
      transaction_key,
      touchpoint_session_key
    HAVING COUNT(*) > 1
  )
) = 0
AS 'Model-transaction-touchpoint credit rows must be unique.';


ASSERT (
  SELECT COUNT(*)
  FROM (
    SELECT
      attribution_model,
      transaction_key,
      SUM(attribution_weight) AS transaction_weight
    FROM attribution_credit_build
    GROUP BY
      attribution_model,
      transaction_key
    HAVING ABS(transaction_weight - 1.0) > 0.000000001
  )
) = 0
AS 'Every transaction must receive exactly one unit of credit in every model.';


ASSERT (
  SELECT COUNT(*)
  FROM (
    SELECT
      attribution_model,
      COUNT(DISTINCT transaction_key)
        AS represented_transactions,
      SUM(attributed_conversion_credit)
        AS attributed_conversions,
      SUM(attributed_revenue_usd)
        AS attributed_revenue_usd
    FROM attribution_credit_build
    GROUP BY
      attribution_model
    HAVING
      represented_transactions != expected_transaction_count
      OR ABS(
        attributed_conversions - expected_transaction_count
      ) > 0.000000001
      OR ABS(
        attributed_revenue_usd - expected_canonical_revenue
      ) > 0.01
  )
) = 0
AS 'Every model must allocate all transactions and canonical revenue.';


-- ============================================================
-- Publish the validated attribution-credit fact
-- ============================================================

DROP TABLE IF EXISTS
  `measurement-360-portfolio.measurement_360_mart.fct_attribution_credits`;


CREATE TABLE
  `measurement-360-portfolio.measurement_360_mart.fct_attribution_credits`

CLUSTER BY
  transaction_date,
  attribution_model,
  touchpoint_channel_group,
  user_pseudo_id

OPTIONS (
  description = '''
    Long-format multi-touch attribution credits for five heuristic
    models: first touch, last touch, last non-direct, linear, and
    position-based. Each transaction receives one unit of conversion
    credit and its full canonical revenue within each model. The
    is_complete_lookback_window field supports sensitivity analysis
    excluding left-censored customer journeys.
  '''
)

AS
SELECT
  *
FROM
  attribution_credit_build;


-- ============================================================
-- Persisted-table contracts
-- ============================================================

ASSERT (
  SELECT COUNT(*)
  FROM
    `measurement-360-portfolio.measurement_360_mart.fct_attribution_credits`
) = expected_credit_row_count
AS 'Published attribution fact must contain 43,017 rows.';


ASSERT (
  SELECT COUNT(*)
  FROM (
    SELECT
      attribution_model,
      transaction_key,
      SUM(attribution_weight) AS transaction_weight
    FROM
      `measurement-360-portfolio.measurement_360_mart.fct_attribution_credits`
    GROUP BY
      attribution_model,
      transaction_key
    HAVING ABS(transaction_weight - 1.0) > 0.000000001
  )
) = 0
AS 'Published model weights must reconcile to one per transaction.';


-- ============================================================
-- Build summary
-- ============================================================

SELECT
  attribution_model_order,
  attribution_model,
  COUNT(*) AS credit_row_count,
  COUNT(DISTINCT transaction_key)
    AS represented_transactions,
  COUNT(DISTINCT user_pseudo_id)
    AS represented_users,
  COUNT(DISTINCT IF(
    is_complete_lookback_window,
    transaction_key,
    NULL
  )) AS complete_window_transactions,
  ROUND(SUM(attributed_conversion_credit), 6)
    AS attributed_conversions,
  ROUND(SUM(attributed_revenue_usd), 2)
    AS attributed_revenue_usd,
  ROUND(SUM(IF(
    is_complete_lookback_window,
    attributed_revenue_usd,
    0
  )), 2) AS complete_window_attributed_revenue_usd

FROM
  `measurement-360-portfolio.measurement_360_mart.fct_attribution_credits`

GROUP BY
  attribution_model_order,
  attribution_model

ORDER BY
  attribution_model_order;
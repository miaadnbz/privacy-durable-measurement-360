-- Measurement 360
-- Stage 5A.2: Transaction-to-touchpoint attribution bridge
--
-- Grain:
-- One row per canonical transaction and eligible preceding session.
--
-- Attribution window:
-- Sessions beginning within 30 days before the canonical transaction.
--
-- Important:
-- Direct sessions are preserved. They are needed for full journey analysis
-- and for last-non-direct attribution fallback logic.
--
-- Storage:
-- The table is intentionally unpartitioned because the historical source
-- dates would immediately expire under BigQuery Sandbox partition rules.

DECLARE lookback_days INT64 DEFAULT 30;
DECLARE expected_transaction_count INT64 DEFAULT 5375;
DECLARE expected_canonical_revenue FLOAT64 DEFAULT 340859.0;

CREATE TEMP TABLE touchpoint_build AS

WITH data_bounds AS (
  SELECT
    MIN(session_date) AS source_data_start_date,
    MAX(session_date) AS source_data_end_date
  FROM
    `measurement-360-portfolio.measurement_360_mart.fct_sessions`
),

eligible_touchpoints AS (
  SELECT
    -- Canonical transaction
    t.transaction_key,
    t.transaction_key_method,
    t.transaction_id_status,
    t.transaction_date,
    t.transaction_timestamp_utc,
    t.user_pseudo_id,
    t.session_key AS transaction_session_key,
    t.ga_session_id AS transaction_ga_session_id,
    t.ga_session_number AS transaction_ga_session_number,
    t.transaction_revenue_usd,
    t.transaction_currency,
    t.transaction_item_quantity,
    t.item_record_count AS transaction_item_record_count,
    t.measurement_event_rows,
    t.duplicate_measurement_rows,
    t.uses_fallback_transaction_key,

    -- Eligible session touchpoint
    s.session_key AS touchpoint_session_key,
    s.ga_session_id AS touchpoint_ga_session_id,
    s.ga_session_number AS touchpoint_ga_session_number,
    s.session_date AS touchpoint_session_date,
    s.session_start_timestamp_utc AS touchpoint_start_timestamp_utc,
    s.session_end_timestamp_utc AS touchpoint_end_timestamp_utc,
    s.attribution_timestamp_utc AS touchpoint_attribution_timestamp_utc,
    s.session_duration_seconds AS touchpoint_duration_seconds,

    -- Acquisition dimensions
    COALESCE(s.session_source, '(not set)') AS touchpoint_source,
    COALESCE(s.session_medium, '(not set)') AS touchpoint_medium,
    COALESCE(s.session_campaign, '(not set)') AS touchpoint_campaign,
    COALESCE(s.session_channel_group, 'Other') AS touchpoint_channel_group,

    s.first_user_source,
    s.first_user_medium,
    s.first_user_campaign,

    -- Session behaviour
    s.event_count AS touchpoint_event_count,
    s.page_view_count AS touchpoint_page_view_count,
    s.view_item_event_count AS touchpoint_view_item_count,
    s.add_to_cart_event_count AS touchpoint_add_to_cart_count,
    s.begin_checkout_event_count AS touchpoint_begin_checkout_count,
    s.raw_purchase_measurement_event_count
      AS touchpoint_purchase_measurement_event_count,
    s.total_engagement_time_seconds AS touchpoint_engagement_seconds,
    s.is_engaged_session AS is_engaged_touchpoint,
    s.is_new_user_session AS is_new_user_touchpoint,

    -- Landing context
    s.entry_page_location AS touchpoint_entry_page_location,
    s.entry_page_title AS touchpoint_entry_page_title,

    -- Geography and device
    s.geo_country AS touchpoint_geo_country,
    s.geo_region AS touchpoint_geo_region,
    s.geo_city AS touchpoint_geo_city,
    s.device_category AS touchpoint_device_category,
    s.device_operating_system AS touchpoint_operating_system,
    s.device_browser AS touchpoint_browser,

    -- Privacy signals
    s.analytics_storage AS touchpoint_analytics_storage,
    s.ads_storage AS touchpoint_ads_storage,
    s.uses_transient_token AS touchpoint_uses_transient_token,

    -- Journey timing
    TIMESTAMP_SUB(
      t.transaction_timestamp_utc,
      INTERVAL lookback_days DAY
    ) AS lookback_window_start_utc,

    t.transaction_timestamp_utc AS lookback_window_end_utc,

    TIMESTAMP_DIFF(
      t.transaction_timestamp_utc,
      s.session_start_timestamp_utc,
      SECOND
    ) AS seconds_before_transaction,

    DATE_DIFF(
      t.transaction_date,
      s.session_date,
      DAY
    ) AS calendar_days_before_transaction,

    -- Journey classifications
    s.session_key = t.session_key AS is_conversion_session,

    (
      s.session_channel_group = 'Direct'
      OR (
        LOWER(COALESCE(s.session_source, '')) = '(direct)'
        AND LOWER(COALESCE(s.session_medium, '')) = '(none)'
      )
    ) AS is_direct_touchpoint,

    b.source_data_start_date,
    b.source_data_end_date,

    DATE_SUB(
      t.transaction_date,
      INTERVAL lookback_days DAY
    ) < b.source_data_start_date AS is_lookback_left_censored

  FROM
    `measurement-360-portfolio.measurement_360_mart.fct_transactions` AS t

  INNER JOIN
    `measurement-360-portfolio.measurement_360_mart.fct_sessions` AS s
    ON s.user_pseudo_id = t.user_pseudo_id
    AND s.session_start_timestamp_utc >= TIMESTAMP_SUB(
      t.transaction_timestamp_utc,
      INTERVAL lookback_days DAY
    )
    AND s.session_start_timestamp_utc <= t.transaction_timestamp_utc

  CROSS JOIN
    data_bounds AS b
),

ranked_touchpoints AS (
  SELECT
    e.*,

    COUNT(*) OVER (
      PARTITION BY transaction_key
    ) AS touchpoint_count,

    COUNTIF(NOT is_direct_touchpoint) OVER (
      PARTITION BY transaction_key
    ) AS non_direct_touchpoint_count,

    ROW_NUMBER() OVER (
      PARTITION BY transaction_key
      ORDER BY
        touchpoint_start_timestamp_utc,
        touchpoint_session_key
    ) AS touchpoint_position_asc,

    ROW_NUMBER() OVER (
      PARTITION BY transaction_key
      ORDER BY
        touchpoint_start_timestamp_utc DESC,
        touchpoint_session_key DESC
    ) AS touchpoint_position_desc,

    CASE
      WHEN NOT is_direct_touchpoint THEN
        COUNTIF(NOT is_direct_touchpoint) OVER (
          PARTITION BY transaction_key
          ORDER BY
            touchpoint_start_timestamp_utc,
            touchpoint_session_key
          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )
    END AS non_direct_touchpoint_position_asc,

    CASE
      WHEN NOT is_direct_touchpoint THEN
        COUNTIF(NOT is_direct_touchpoint) OVER (
          PARTITION BY transaction_key
          ORDER BY
            touchpoint_start_timestamp_utc DESC,
            touchpoint_session_key DESC
          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )
    END AS non_direct_touchpoint_position_desc

  FROM
    eligible_touchpoints AS e
)

SELECT
  r.*,

  touchpoint_position_asc = 1
    AS is_first_touchpoint,

  touchpoint_position_desc = 1
    AS is_last_touchpoint,

  IFNULL(
    non_direct_touchpoint_position_asc = 1,
    FALSE
  ) AS is_first_non_direct_touchpoint,

  IFNULL(
    non_direct_touchpoint_position_desc = 1,
    FALSE
  ) AS is_last_non_direct_touchpoint,

  CASE
    WHEN non_direct_touchpoint_count > 0 THEN
      IFNULL(
        non_direct_touchpoint_position_desc = 1,
        FALSE
      )
    ELSE
      touchpoint_position_desc = 1
  END AS is_last_non_direct_attribution_touchpoint

FROM
  ranked_touchpoints AS r;


-- ============================================================
-- Pre-publication data contracts
-- ============================================================

ASSERT (
  SELECT COUNT(*)
  FROM `measurement-360-portfolio.measurement_360_mart.fct_transactions`
) = expected_transaction_count
AS 'Source transaction fact must contain exactly 5,375 transactions.';


ASSERT ABS(
  (
    SELECT SUM(transaction_revenue_usd)
    FROM `measurement-360-portfolio.measurement_360_mart.fct_transactions`
  ) - expected_canonical_revenue
) < 0.01
AS 'Source canonical transaction revenue must equal $340,859.';


ASSERT (
  SELECT COUNTIF(
    transaction_key IS NULL
    OR user_pseudo_id IS NULL
    OR transaction_timestamp_utc IS NULL
    OR transaction_session_key IS NULL
  )
  FROM touchpoint_build
) = 0
AS 'Attribution bridge contains a null required transaction identifier.';


ASSERT (
  SELECT COUNT(DISTINCT transaction_key)
  FROM touchpoint_build
) = expected_transaction_count
AS 'Every canonical transaction must be represented in the bridge.';


ASSERT (
  SELECT COUNT(*)
  FROM (
    SELECT
      transaction_key,
      touchpoint_session_key
    FROM touchpoint_build
    GROUP BY
      transaction_key,
      touchpoint_session_key
    HAVING COUNT(*) > 1
  )
) = 0
AS 'Transaction-touchpoint pairs must be unique.';


ASSERT (
  SELECT COUNT(*)
  FROM (
    SELECT
      transaction_key
    FROM touchpoint_build
    GROUP BY
      transaction_key
    HAVING COUNTIF(is_conversion_session) != 1
  )
) = 0
AS 'Every transaction must have exactly one conversion-session touchpoint.';


ASSERT (
  SELECT COUNTIF(
    seconds_before_transaction < 0
    OR seconds_before_transaction > lookback_days * 86400
  )
  FROM touchpoint_build
) = 0
AS 'All touchpoints must fall inside the 30-day pre-transaction window.';


ASSERT (
  SELECT COUNTIF(
    touchpoint_source IS NULL
    OR touchpoint_medium IS NULL
    OR touchpoint_channel_group IS NULL
  )
  FROM touchpoint_build
) = 0
AS 'Attribution dimensions must not be null.';


ASSERT ABS(
  (
    SELECT SUM(transaction_revenue_usd)
    FROM (
      SELECT
        transaction_key,
        MAX(transaction_revenue_usd) AS transaction_revenue_usd
      FROM touchpoint_build
      GROUP BY transaction_key
    )
  ) - expected_canonical_revenue
) < 0.01
AS 'Deduplicated bridge revenue must equal $340,859.';


-- ============================================================
-- Publish the validated bridge
-- ============================================================

DROP TABLE IF EXISTS
  `measurement-360-portfolio.measurement_360_mart.bridge_transaction_touchpoints`;


CREATE TABLE
  `measurement-360-portfolio.measurement_360_mart.bridge_transaction_touchpoints`

CLUSTER BY
  transaction_date,
  touchpoint_channel_group,
  user_pseudo_id

OPTIONS (
  description = '''
    One row per canonical transaction and eligible session touchpoint
    within a 30-day pre-transaction lookback window. Preserves direct
    sessions, deterministic journey positions, privacy signals, and
    last-non-direct attribution eligibility. Revenue is repeated across
    touchpoint rows and must be allocated using attribution weights
    before channel-level aggregation.
  '''
)

AS
SELECT
  *
FROM
  touchpoint_build;


-- ============================================================
-- Final persisted-table contracts
-- ============================================================

ASSERT (
  SELECT COUNT(DISTINCT transaction_key)
  FROM
    `measurement-360-portfolio.measurement_360_mart.bridge_transaction_touchpoints`
) = expected_transaction_count
AS 'Published bridge must represent all 5,375 transactions.';


ASSERT (
  SELECT COUNT(*)
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
) = 0
AS 'Published transaction-touchpoint pairs must remain unique.';


-- ============================================================
-- Build summary
-- ============================================================

WITH transaction_summary AS (
  SELECT
    transaction_key,
    MAX(user_pseudo_id) AS user_pseudo_id,
    MAX(transaction_revenue_usd) AS transaction_revenue_usd,
    COUNT(*) AS touchpoint_count,
    COUNTIF(NOT is_direct_touchpoint) AS non_direct_touchpoint_count,
    LOGICAL_OR(is_lookback_left_censored)
      AS is_lookback_left_censored
  FROM
    `measurement-360-portfolio.measurement_360_mart.bridge_transaction_touchpoints`
  GROUP BY
    transaction_key
)

SELECT
  SUM(touchpoint_count) AS bridge_row_count,
  COUNT(*) AS represented_transactions,
  COUNT(DISTINCT user_pseudo_id) AS represented_users,
  ROUND(AVG(touchpoint_count), 2) AS average_touchpoints_per_transaction,
  MAX(touchpoint_count) AS maximum_touchpoints_for_one_transaction,
  COUNTIF(touchpoint_count > 1) AS multi_touch_transactions,
  COUNTIF(non_direct_touchpoint_count = 0) AS direct_only_transactions,
  COUNTIF(is_lookback_left_censored) AS left_censored_transactions,
  SUM(transaction_revenue_usd) AS represented_canonical_revenue_usd
FROM
  transaction_summary;
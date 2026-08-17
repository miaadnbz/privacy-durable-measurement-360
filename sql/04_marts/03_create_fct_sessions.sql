-- Measurement 360
-- Session fact table
--
-- Grain:
-- One row per composite session_key.
--
-- Revenue:
-- Canonical transactions and revenue are joined from fct_transactions.
--
-- Acquisition:
-- Session acquisition uses the earliest event containing source,
-- medium or campaign data within the session.
--
-- Storage:
-- This historical Sandbox mart is unpartitioned and clustered.

CREATE TEMP TABLE session_build AS

WITH session_event_aggregation AS (
  SELECT
    session_key,

    -- Session identity
    MAX(user_pseudo_id) AS user_pseudo_id,
    MAX(ga_session_id) AS ga_session_id,
    MAX(ga_session_number) AS ga_session_number,

    -- Session timing
    MIN(event_date) AS session_date,
    MIN(event_timestamp_utc) AS session_start_timestamp_utc,
    MAX(event_timestamp_utc) AS session_end_timestamp_utc,

    TIMESTAMP_DIFF(
      MAX(event_timestamp_utc),
      MIN(event_timestamp_utc),
      SECOND
    ) AS session_duration_seconds,

    -- Overall event activity
    COUNT(*) AS event_count,
    COUNT(DISTINCT event_name) AS distinct_event_name_count,

    COUNTIF(event_name = 'session_start')
      AS session_start_event_count,

    COUNTIF(event_name = 'first_visit')
      AS first_visit_event_count,

    COUNTIF(event_name = 'page_view')
      AS page_view_count,

    COUNTIF(event_name = 'scroll')
      AS scroll_event_count,

    COUNTIF(event_name = 'user_engagement')
      AS user_engagement_event_count,

    -- Ecommerce-funnel activity
    COUNTIF(event_name = 'view_item')
      AS view_item_event_count,

    COUNTIF(event_name = 'view_item_list')
      AS view_item_list_event_count,

    COUNTIF(event_name = 'select_item')
      AS select_item_event_count,

    COUNTIF(event_name = 'add_to_cart')
      AS add_to_cart_event_count,

    COUNTIF(event_name = 'begin_checkout')
      AS begin_checkout_event_count,

    COUNTIF(event_name = 'add_shipping_info')
      AS add_shipping_info_event_count,

    COUNTIF(event_name = 'add_payment_info')
      AS add_payment_info_event_count,

    COUNTIF(event_name = 'purchase')
      AS raw_purchase_measurement_event_count,

    -- Engagement
    SUM(
      COALESCE(engagement_time_msec, 0)
    ) AS total_engagement_time_msec,

    COUNTIF(session_engaged) > 0
      AS is_engaged_session,

    -- Item-array activity across the entire session
    SUM(item_record_count)
      AS item_interaction_record_count,

    -- Earliest available session acquisition record
    ARRAY_AGG(
      IF(
        NULLIF(TRIM(event_source), '') IS NOT NULL
        OR NULLIF(TRIM(event_medium), '') IS NOT NULL
        OR NULLIF(TRIM(event_campaign), '') IS NOT NULL,

        STRUCT(
          event_timestamp_utc AS attribution_timestamp_utc,
          event_timestamp_micros AS attribution_timestamp_micros,
          NULLIF(TRIM(event_source), '') AS source,
          NULLIF(TRIM(event_medium), '') AS medium,
          NULLIF(TRIM(event_campaign), '') AS campaign
        ),

        NULL
      )
      IGNORE NULLS
      ORDER BY
        event_timestamp_utc,
        event_timestamp_micros
      LIMIT 1
    )[SAFE_OFFSET(0)] AS session_acquisition,

    -- First-user acquisition recorded on the first event
    ARRAY_AGG(
      STRUCT(
        first_user_source AS source,
        first_user_medium AS medium,
        first_user_campaign AS campaign
      )
      ORDER BY
        event_timestamp_utc,
        event_timestamp_micros
      LIMIT 1
    )[SAFE_OFFSET(0)] AS first_user_acquisition,

    -- Entry page
    ARRAY_AGG(
      IF(
        NULLIF(TRIM(page_location), '') IS NOT NULL,

        STRUCT(
          event_timestamp_utc AS page_timestamp_utc,
          page_location,
          page_title
        ),

        NULL
      )
      IGNORE NULLS
      ORDER BY
        event_timestamp_utc,
        event_timestamp_micros
      LIMIT 1
    )[SAFE_OFFSET(0)] AS entry_page,

    -- Exit page
    ARRAY_AGG(
      IF(
        NULLIF(TRIM(page_location), '') IS NOT NULL,

        STRUCT(
          event_timestamp_utc AS page_timestamp_utc,
          page_location,
          page_title
        ),

        NULL
      )
      IGNORE NULLS
      ORDER BY
        event_timestamp_utc DESC,
        event_timestamp_micros DESC
      LIMIT 1
    )[SAFE_OFFSET(0)] AS exit_page,

    -- Context from the first event in the session
    ARRAY_AGG(
      STRUCT(
        geo_country,
        geo_region,
        geo_city,
        device_category,
        device_operating_system,
        device_browser,
        analytics_storage,
        ads_storage,
        uses_transient_token
      )
      ORDER BY
        event_timestamp_utc,
        event_timestamp_micros
      LIMIT 1
    )[SAFE_OFFSET(0)] AS session_context

  FROM
    `measurement-360-portfolio.measurement_360_stg.stg_ga4_events`

  WHERE session_key IS NOT NULL

  GROUP BY session_key
),

transactions_by_session AS (
  SELECT
    session_key,

    COUNT(*) AS canonical_transaction_count,

    SUM(transaction_revenue_usd)
      AS canonical_revenue_usd,

    SUM(COALESCE(transaction_item_quantity, 0))
      AS canonical_item_quantity,

    COUNTIF(uses_fallback_transaction_key)
      AS fallback_transaction_count,

    MIN(transaction_timestamp_utc)
      AS first_transaction_timestamp_utc,

    MAX(transaction_timestamp_utc)
      AS last_transaction_timestamp_utc

  FROM
    `measurement-360-portfolio.measurement_360_mart.fct_transactions`

  WHERE session_key IS NOT NULL

  GROUP BY session_key
),

session_with_transactions AS (
  SELECT
    session.*,

    COALESCE(transaction.canonical_transaction_count, 0)
      AS canonical_transaction_count,

    COALESCE(transaction.canonical_revenue_usd, 0)
      AS canonical_revenue_usd,

    COALESCE(transaction.canonical_item_quantity, 0)
      AS canonical_item_quantity,

    COALESCE(transaction.fallback_transaction_count, 0)
      AS fallback_transaction_count,

    transaction.first_transaction_timestamp_utc,
    transaction.last_transaction_timestamp_utc

  FROM session_event_aggregation AS session

  LEFT JOIN transactions_by_session AS transaction
    USING (session_key)
),

normalized_sessions AS (
  SELECT
    session.*,

    -- When both source and medium are absent, classify the session as direct.
    CASE
      WHEN
        session_acquisition.source IS NULL
        AND session_acquisition.medium IS NULL
      THEN '(direct)'

      ELSE COALESCE(
        session_acquisition.source,
        '(not set)'
      )
    END AS session_source,

    CASE
      WHEN
        session_acquisition.source IS NULL
        AND session_acquisition.medium IS NULL
      THEN '(none)'

      ELSE COALESCE(
        session_acquisition.medium,
        '(not set)'
      )
    END AS session_medium,

    COALESCE(
      session_acquisition.campaign,
      '(not set)'
    ) AS session_campaign

  FROM session_with_transactions AS session
)

SELECT
  -- Session identity
  session_key,
  user_pseudo_id,
  ga_session_id,
  ga_session_number,

  -- Time
  session_date,
  session_start_timestamp_utc,
  session_end_timestamp_utc,
  session_duration_seconds,

  -- Event activity
  event_count,
  distinct_event_name_count,
  session_start_event_count,
  first_visit_event_count,
  page_view_count,
  scroll_event_count,
  user_engagement_event_count,

  -- Funnel activity
  view_item_event_count,
  view_item_list_event_count,
  select_item_event_count,
  add_to_cart_event_count,
  begin_checkout_event_count,
  add_shipping_info_event_count,
  add_payment_info_event_count,
  raw_purchase_measurement_event_count,

  -- Engagement
  total_engagement_time_msec,

  SAFE_DIVIDE(
    total_engagement_time_msec,
    1000.0
  ) AS total_engagement_time_seconds,

  SAFE_DIVIDE(
    total_engagement_time_msec,
    event_count * 1000.0
  ) AS average_engagement_seconds_per_event,

  is_engaged_session,
  first_visit_event_count > 0 AS is_new_user_session,
  item_interaction_record_count,

  -- Session acquisition
  session_acquisition.attribution_timestamp_utc,
  session_source,
  session_medium,
  session_campaign,

  CASE
    WHEN
      session_source = '(direct)'
      AND session_medium = '(none)'
      THEN 'Direct'

    WHEN REGEXP_CONTAINS(
      LOWER(session_medium),
      r'^(cpc|ppc|paid search|paid_search|paidsearch)$'
    )
      THEN 'Paid Search'

    WHEN REGEXP_CONTAINS(
      LOWER(session_medium),
      r'organic'
    )
      THEN 'Organic Search'

    WHEN REGEXP_CONTAINS(
      LOWER(session_medium),
      r'(paid.*social|social.*paid)'
    )
      THEN 'Paid Social'

    WHEN REGEXP_CONTAINS(
      LOWER(session_medium),
      r'social'
    )
      THEN 'Organic Social'

    WHEN REGEXP_CONTAINS(
      LOWER(session_medium),
      r'(display|banner|cpm)'
    )
      THEN 'Display'

    WHEN REGEXP_CONTAINS(
      LOWER(session_medium),
      r'email'
    )
      THEN 'Email'

    WHEN REGEXP_CONTAINS(
      LOWER(session_medium),
      r'affiliate'
    )
      THEN 'Affiliate'

    WHEN REGEXP_CONTAINS(
      LOWER(session_medium),
      r'referral'
    )
      THEN 'Referral'

    ELSE 'Other'
  END AS session_channel_group,

  -- First-user acquisition
  first_user_acquisition.source
    AS first_user_source,

  first_user_acquisition.medium
    AS first_user_medium,

  first_user_acquisition.campaign
    AS first_user_campaign,

  -- Entry and exit pages
  entry_page.page_location AS entry_page_location,
  entry_page.page_title AS entry_page_title,
  exit_page.page_location AS exit_page_location,
  exit_page.page_title AS exit_page_title,

  -- Canonical conversions
  canonical_transaction_count,
  canonical_revenue_usd,
  canonical_item_quantity,

  SAFE_DIVIDE(
    canonical_revenue_usd,
    canonical_transaction_count
  ) AS average_order_value_usd,

  fallback_transaction_count,

  GREATEST(
    raw_purchase_measurement_event_count
      - canonical_transaction_count,
    0
  ) AS duplicate_purchase_measurement_rows,

  canonical_transaction_count > 0
    AS is_converting_session,

  first_transaction_timestamp_utc,
  last_transaction_timestamp_utc,

  -- Geographic and device context
  session_context.geo_country,
  session_context.geo_region,
  session_context.geo_city,
  session_context.device_category,
  session_context.device_operating_system,
  session_context.device_browser,

  -- Privacy context
  session_context.analytics_storage,
  session_context.ads_storage,
  session_context.uses_transient_token

FROM normalized_sessions;


-- Validate the temporary build before replacing the permanent table.

ASSERT (
  SELECT COUNT(*) = COUNT(DISTINCT session_key)
  FROM session_build
) AS 'Every session_key must be unique.';

ASSERT (
  SELECT COUNTIF(session_key IS NULL) = 0
  FROM session_build
) AS 'Session keys cannot be null.';

ASSERT (
  SELECT SUM(event_count) = 4295584
  FROM session_build
) AS 'Session fact must represent all 4,295,584 events.';

ASSERT (
  SELECT SUM(canonical_transaction_count) = 5375
  FROM session_build
) AS 'Session fact must represent all 5,375 transactions.';

ASSERT (
  SELECT ROUND(SUM(canonical_revenue_usd), 6) = 340859
  FROM session_build
) AS 'Session fact must reconcile to $340,859 canonical revenue.';


-- Build the permanent clustered table.
-- It remains unpartitioned because this is historical Sandbox data.

DROP TABLE IF EXISTS
  `measurement-360-portfolio.measurement_360_mart.fct_sessions`;

CREATE TABLE
  `measurement-360-portfolio.measurement_360_mart.fct_sessions`

CLUSTER BY
  session_date,
  session_channel_group,
  user_pseudo_id

OPTIONS (
  description = 'One row per GA4 session with engagement, funnel, acquisition and canonical transaction metrics.'
)

AS

SELECT *
FROM session_build;


-- Validate the final physical table.

ASSERT (
  SELECT COUNT(*) = COUNT(DISTINCT session_key)
  FROM
    `measurement-360-portfolio.measurement_360_mart.fct_sessions`
) AS 'Final fct_sessions table must contain unique session keys.';

ASSERT (
  SELECT SUM(event_count) = 4295584
  FROM
    `measurement-360-portfolio.measurement_360_mart.fct_sessions`
) AS 'Final fct_sessions must represent every staged event.';


-- Return a build summary.

SELECT
  COUNT(*) AS session_rows,
  COUNT(DISTINCT user_pseudo_id) AS unique_users,
  SUM(event_count) AS represented_event_rows,

  COUNTIF(is_converting_session)
    AS converting_sessions,

  SUM(canonical_transaction_count)
    AS canonical_transactions,

  SUM(canonical_revenue_usd)
    AS canonical_revenue_usd,

  SUM(duplicate_purchase_measurement_rows)
    AS duplicate_purchase_measurement_rows

FROM
  `measurement-360-portfolio.measurement_360_mart.fct_sessions`;
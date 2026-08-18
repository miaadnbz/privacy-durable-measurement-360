-- Measurement 360
-- Geo-holdout incrementality module
-- Step 1: Profile region-level experiment candidates
--
-- Purpose:
--   1. Measure geographic coverage and data quality.
--   2. Identify countries with enough eligible regions.
--   3. Evaluate region-level pre-period volume and stability.
--
-- Important:
--   Candidate eligibility uses PRE-PERIOD data only.
--   Test-period outcomes must not influence geo selection.

DECLARE analysis_start_date DATE DEFAULT DATE '2020-11-01';
DECLARE pre_period_end_date DATE DEFAULT DATE '2020-12-26';
DECLARE test_period_start_date DATE DEFAULT DATE '2020-12-27';
DECLARE analysis_end_date DATE DEFAULT DATE '2021-01-30';

-- Initial screening thresholds.
-- These are diagnostic thresholds, not final experiment requirements.
DECLARE minimum_pre_sessions INT64 DEFAULT 500;
DECLARE minimum_pre_transactions INT64 DEFAULT 20;
DECLARE minimum_pre_revenue_usd FLOAT64 DEFAULT 1000.0;
DECLARE maximum_pre_revenue_cv FLOAT64 DEFAULT 2.0;

-- The source dataset continues through 2021-01-31.
-- We stop at 2021-01-30 so that the analysis contains exactly:
--   8 complete pre-period weeks
--   5 complete test-period weeks
--
-- Weeks begin on Sunday.

CREATE TEMP TABLE session_base AS
WITH normalized_sessions AS (
  SELECT
    session_key,
    user_pseudo_id,
    session_date,
    DATE_TRUNC(session_date, WEEK(SUNDAY)) AS week_start_date,

    COALESCE(
      NULLIF(TRIM(geo_country), ''),
      '(not set)'
    ) AS geo_country,

    COALESCE(
      NULLIF(TRIM(geo_region), ''),
      '(not set)'
    ) AS geo_region,

    COALESCE(canonical_transaction_count, 0)
      AS canonical_transaction_count,

    COALESCE(canonical_revenue_usd, 0.0)
      AS canonical_revenue_usd

  FROM
    `measurement-360-portfolio.measurement_360_mart.fct_sessions`

  WHERE
    session_date BETWEEN analysis_start_date AND analysis_end_date
)

SELECT
  *,

  LOWER(geo_country) NOT IN (
    '(not set)',
    'not set',
    'unknown',
    '(null)'
  )
  AND LOWER(geo_region) NOT IN (
    '(not set)',
    'not set',
    'unknown',
    '(null)'
  ) AS is_valid_geography

FROM
  normalized_sessions;


-- Build a balanced region-week panel.
--
-- Every valid region receives one row for each of the 13 weeks.
-- Weeks with no observed sessions are represented with zeros.
--
-- This prevents inactive weeks from disappearing from averages,
-- standard deviations and stability measurements.

CREATE TEMP TABLE geo_week_panel AS
WITH week_spine AS (
  SELECT
    week_start_date

  FROM
    UNNEST(
      GENERATE_DATE_ARRAY(
        analysis_start_date,
        analysis_end_date,
        INTERVAL 7 DAY
      )
    ) AS week_start_date
),

geo_universe AS (
  SELECT DISTINCT
    geo_country,
    geo_region

  FROM
    session_base

  WHERE
    is_valid_geography
),

observed_geo_weeks AS (
  SELECT
    geo_country,
    geo_region,
    week_start_date,

    COUNT(*) AS session_count,
    COUNT(DISTINCT user_pseudo_id) AS weekly_unique_users,

    SUM(canonical_transaction_count)
      AS canonical_transaction_count,

    SUM(canonical_revenue_usd)
      AS canonical_revenue_usd

  FROM
    session_base

  WHERE
    is_valid_geography

  GROUP BY
    geo_country,
    geo_region,
    week_start_date
)

SELECT
  geography.geo_country,
  geography.geo_region,

  CONCAT(
    geography.geo_country,
    ' | ',
    geography.geo_region
  ) AS geo_key,

  week.week_start_date,

  CASE
    WHEN week.week_start_date <= pre_period_end_date
      THEN 'PRE'
    ELSE 'TEST'
  END AS period_name,

  COALESCE(observed.session_count, 0)
    AS session_count,

  COALESCE(observed.weekly_unique_users, 0)
    AS weekly_unique_users,

  COALESCE(observed.canonical_transaction_count, 0)
    AS canonical_transaction_count,

  COALESCE(observed.canonical_revenue_usd, 0.0)
    AS canonical_revenue_usd

FROM
  geo_universe AS geography

CROSS JOIN
  week_spine AS week

LEFT JOIN
  observed_geo_weeks AS observed
    ON geography.geo_country = observed.geo_country
    AND geography.geo_region = observed.geo_region
    AND week.week_start_date = observed.week_start_date;


-- Summarize each candidate geography.
--
-- Eligibility is based only on the eight-week pre-period.
-- Test-period metrics are included for later QA, but they are not
-- used to decide whether a geography is initially eligible.

CREATE TEMP TABLE geo_profiles AS
WITH geo_user_totals AS (
  SELECT
    geo_country,
    geo_region,
    COUNT(DISTINCT user_pseudo_id) AS distinct_users

  FROM
    session_base

  WHERE
    is_valid_geography

  GROUP BY
    geo_country,
    geo_region
),

profile_summary AS (
  SELECT
    geo_country,
    geo_region,
    geo_key,

    COUNT(*) AS total_panel_weeks,

    COUNTIF(
      period_name = 'PRE'
      AND session_count > 0
    ) AS pre_active_session_weeks,

    COUNTIF(
      period_name = 'PRE'
      AND canonical_transaction_count > 0
    ) AS pre_transaction_active_weeks,

    SUM(
      IF(period_name = 'PRE', session_count, 0)
    ) AS pre_sessions,

    SUM(
      IF(
        period_name = 'PRE',
        canonical_transaction_count,
        0
      )
    ) AS pre_transactions,

    SUM(
      IF(
        period_name = 'PRE',
        canonical_revenue_usd,
        0.0
      )
    ) AS pre_revenue_usd,

    AVG(
      IF(
        period_name = 'PRE',
        canonical_revenue_usd,
        NULL
      )
    ) AS pre_average_weekly_revenue_usd,

    STDDEV_SAMP(
      IF(
        period_name = 'PRE',
        canonical_revenue_usd,
        NULL
      )
    ) AS pre_weekly_revenue_stddev_usd,

    COUNTIF(
      period_name = 'PRE'
      AND canonical_revenue_usd = 0
    ) AS pre_zero_revenue_weeks,

    COUNTIF(
      period_name = 'TEST'
      AND session_count > 0
    ) AS test_active_session_weeks,

    SUM(
      IF(period_name = 'TEST', session_count, 0)
    ) AS test_sessions,

    SUM(
      IF(
        period_name = 'TEST',
        canonical_transaction_count,
        0
      )
    ) AS test_transactions,

    SUM(
      IF(
        period_name = 'TEST',
        canonical_revenue_usd,
        0.0
      )
    ) AS test_revenue_usd

  FROM
    geo_week_panel

  GROUP BY
    geo_country,
    geo_region,
    geo_key
),

calculated_profiles AS (
  SELECT
    profile.*,
    users.distinct_users,

    SAFE_DIVIDE(
      profile.pre_transactions,
      profile.pre_sessions
    ) AS pre_transaction_rate,

    SAFE_DIVIDE(
      profile.pre_revenue_usd,
      profile.pre_sessions
    ) AS pre_revenue_per_session_usd,

    SAFE_DIVIDE(
      profile.pre_weekly_revenue_stddev_usd,
      profile.pre_average_weekly_revenue_usd
    ) AS pre_revenue_coefficient_of_variation

  FROM
    profile_summary AS profile

  LEFT JOIN
    geo_user_totals AS users
      USING (geo_country, geo_region)
)

SELECT
  *,

  CASE
    WHEN pre_active_session_weeks < 8 THEN FALSE
    WHEN pre_sessions < minimum_pre_sessions THEN FALSE
    WHEN pre_transactions < minimum_pre_transactions THEN FALSE
    WHEN pre_revenue_usd < minimum_pre_revenue_usd THEN FALSE
    WHEN pre_revenue_coefficient_of_variation IS NULL THEN FALSE
    WHEN pre_revenue_coefficient_of_variation
      > maximum_pre_revenue_cv THEN FALSE
    ELSE TRUE
  END AS meets_initial_eligibility,

  CASE
    WHEN pre_active_session_weeks < 8
      THEN 'INSUFFICIENT_ACTIVE_WEEKS'

    WHEN pre_sessions < minimum_pre_sessions
      THEN 'INSUFFICIENT_PRE_SESSIONS'

    WHEN pre_transactions < minimum_pre_transactions
      THEN 'INSUFFICIENT_PRE_TRANSACTIONS'

    WHEN pre_revenue_usd < minimum_pre_revenue_usd
      THEN 'INSUFFICIENT_PRE_REVENUE'

    WHEN pre_revenue_coefficient_of_variation IS NULL
      THEN 'UNDEFINED_PRE_REVENUE_VARIATION'

    WHEN pre_revenue_coefficient_of_variation
      > maximum_pre_revenue_cv
      THEN 'UNSTABLE_PRE_REVENUE'

    ELSE 'ELIGIBLE'
  END AS eligibility_status

FROM
  calculated_profiles;


-- ============================================================
-- RESULT 1: GEOGRAPHIC COVERAGE QA
-- ============================================================
--
-- This result tells us how much session, transaction and revenue
-- activity has a usable country-region combination.

SELECT
  COUNT(*) AS sessions_in_analysis_window,

  COUNTIF(is_valid_geography)
    AS sessions_with_valid_geography,

  ROUND(
    SAFE_DIVIDE(
      COUNTIF(is_valid_geography),
      COUNT(*)
    ),
    4
  ) AS valid_geography_session_share,

  SUM(canonical_transaction_count)
    AS total_transactions,

  SUM(
    IF(
      is_valid_geography,
      canonical_transaction_count,
      0
    )
  ) AS transactions_with_valid_geography,

  ROUND(
    SAFE_DIVIDE(
      SUM(
        IF(
          is_valid_geography,
          canonical_transaction_count,
          0
        )
      ),
      SUM(canonical_transaction_count)
    ),
    4
  ) AS valid_geography_transaction_share,

  ROUND(
    SUM(canonical_revenue_usd),
    2
  ) AS total_revenue_usd,

  ROUND(
    SUM(
      IF(
        is_valid_geography,
        canonical_revenue_usd,
        0.0
      )
    ),
    2
  ) AS revenue_with_valid_geography_usd,

  ROUND(
    SAFE_DIVIDE(
      SUM(
        IF(
          is_valid_geography,
          canonical_revenue_usd,
          0.0
        )
      ),
      SUM(canonical_revenue_usd)
    ),
    4
  ) AS valid_geography_revenue_share

FROM
  session_base;


-- ============================================================
-- RESULT 2: COUNTRY-LEVEL FEASIBILITY
-- ============================================================
--
-- We prefer to run a geo experiment within one country.
-- This reduces major differences in currency, market conditions,
-- regulation, seasonality and customer behaviour.
--
-- The most important field is eligible_regions.

SELECT
  geo_country,

  COUNT(*) AS profiled_regions,

  COUNTIF(meets_initial_eligibility)
    AS eligible_regions,

  SUM(pre_sessions) AS pre_sessions,
  SUM(pre_transactions) AS pre_transactions,

  ROUND(
    SUM(pre_revenue_usd),
    2
  ) AS pre_revenue_usd,

  ROUND(
    SAFE_DIVIDE(
      SUM(pre_transactions),
      SUM(pre_sessions)
    ),
    4
  ) AS pre_transaction_rate,

  SUM(test_sessions) AS historical_test_window_sessions,

  SUM(test_transactions)
    AS historical_test_window_transactions,

  ROUND(
    SUM(test_revenue_usd),
    2
  ) AS historical_test_window_revenue_usd

FROM
  geo_profiles

GROUP BY
  geo_country

ORDER BY
  eligible_regions DESC,
  pre_revenue_usd DESC;


-- ============================================================
-- RESULT 3: REGION-LEVEL CANDIDATE PROFILES
-- ============================================================
--
-- Eligible rows appear first.
-- We will use this result to choose a single country and determine
-- whether region-level matched pairs are feasible.

SELECT
  ROW_NUMBER() OVER (
    ORDER BY
      meets_initial_eligibility DESC,
      pre_revenue_usd DESC
  ) AS display_order,

  DENSE_RANK() OVER (
    PARTITION BY geo_country
    ORDER BY pre_revenue_usd DESC
  ) AS country_pre_revenue_rank,

  geo_country,
  geo_region,
  geo_key,

  total_panel_weeks,
  distinct_users,

  pre_active_session_weeks,
  pre_transaction_active_weeks,
  pre_sessions,
  pre_transactions,

  ROUND(pre_revenue_usd, 2)
    AS pre_revenue_usd,

  ROUND(pre_average_weekly_revenue_usd, 2)
    AS pre_average_weekly_revenue_usd,

  ROUND(pre_weekly_revenue_stddev_usd, 2)
    AS pre_weekly_revenue_stddev_usd,

  ROUND(pre_revenue_coefficient_of_variation, 4)
    AS pre_revenue_coefficient_of_variation,

  pre_zero_revenue_weeks,

  ROUND(pre_transaction_rate, 4)
    AS pre_transaction_rate,

  ROUND(pre_revenue_per_session_usd, 4)
    AS pre_revenue_per_session_usd,

  test_active_session_weeks,
  test_sessions,
  test_transactions,

  ROUND(test_revenue_usd, 2)
    AS test_revenue_usd,

  meets_initial_eligibility,
  eligibility_status

FROM
  geo_profiles

ORDER BY
  meets_initial_eligibility DESC,
  pre_revenue_usd DESC,
  geo_country,
  geo_region;
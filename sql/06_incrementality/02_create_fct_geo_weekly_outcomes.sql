-- Measurement 360
-- Geo-holdout incrementality module
-- Step 2: Create the balanced US region-week outcome table
--
-- Grain:
--   One United States region x one complete calendar week
--
-- Data:
--   Real observed GA4 sessions, transactions and revenue
--
-- Important:
--   This table does not contain treatment assignment,
--   synthetic campaign spend or simulated incremental lift.
--
-- Storage:
--   The table is intentionally not date-partitioned because the
--   historical 2020-2021 partitions would immediately expire in
--   the BigQuery Sandbox environment.
--
--   The table is clustered by region and period instead.

DECLARE analysis_start_date DATE DEFAULT DATE '2020-11-01';
DECLARE pre_period_end_date DATE DEFAULT DATE '2020-12-26';
DECLARE test_period_start_date DATE DEFAULT DATE '2020-12-27';
DECLARE analysis_end_date DATE DEFAULT DATE '2021-01-30';

DECLARE target_country STRING DEFAULT 'United States';

DECLARE minimum_pre_sessions INT64 DEFAULT 500;
DECLARE minimum_pre_transactions INT64 DEFAULT 20;
DECLARE minimum_pre_revenue_usd FLOAT64 DEFAULT 1000.0;
DECLARE maximum_pre_revenue_cv FLOAT64 DEFAULT 2.0;

DECLARE expected_region_count INT64 DEFAULT 51;
DECLARE expected_eligible_region_count INT64 DEFAULT 20;
DECLARE expected_week_count INT64 DEFAULT 13;
DECLARE expected_pre_week_count INT64 DEFAULT 8;
DECLARE expected_test_week_count INT64 DEFAULT 5;


-- ============================================================
-- 1. PREPARE THE TARGET-MARKET SESSION SOURCE
-- ============================================================

CREATE TEMP TABLE target_sessions AS
WITH normalized_sessions AS (
  SELECT
    session_key,
    user_pseudo_id,
    session_date,

    DATE_TRUNC(
      session_date,
      WEEK(SUNDAY)
    ) AS week_start_date,

    COALESCE(
      NULLIF(TRIM(geo_country), ''),
      '(not set)'
    ) AS geo_country,

    COALESCE(
      NULLIF(TRIM(geo_region), ''),
      '(not set)'
    ) AS geo_region,

    COALESCE(is_engaged_session, FALSE)
      AS is_engaged_session,

    COALESCE(is_new_user_session, FALSE)
      AS is_new_user_session,

    COALESCE(view_item_event_count, 0)
      AS view_item_event_count,

    COALESCE(add_to_cart_event_count, 0)
      AS add_to_cart_event_count,

    COALESCE(begin_checkout_event_count, 0)
      AS begin_checkout_event_count,

    COALESCE(canonical_transaction_count, 0)
      AS canonical_transaction_count,

    COALESCE(canonical_revenue_usd, 0.0)
      AS canonical_revenue_usd,

    COALESCE(canonical_item_quantity, 0)
      AS canonical_item_quantity

  FROM
    `measurement-360-portfolio.measurement_360_mart.fct_sessions`

  WHERE
    session_date BETWEEN analysis_start_date AND analysis_end_date

    AND COALESCE(
      NULLIF(TRIM(geo_country), ''),
      '(not set)'
    ) = target_country
)

SELECT
  *

FROM
  normalized_sessions

WHERE
  LOWER(geo_region) NOT IN (
    '(not set)',
    'not set',
    'unknown',
    '(null)'
  );


-- ============================================================
-- 2. BUILD THE BALANCED REGION-WEEK PANEL
-- ============================================================
--
-- The cross join between the region universe and week spine
-- ensures that every region has all 13 expected weeks.
--
-- If no sessions or transactions occurred in a state-week,
-- that week remains in the table with zero-valued outcomes.

CREATE TEMP TABLE balanced_geo_weeks AS
WITH region_universe AS (
  SELECT DISTINCT
    geo_region

  FROM
    target_sessions
),

week_spine AS (
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

observed_region_weeks AS (
  SELECT
    geo_region,
    week_start_date,

    COUNT(*) AS observed_session_count,

    COUNT(DISTINCT user_pseudo_id)
      AS observed_unique_users,

    COUNTIF(is_engaged_session)
      AS observed_engaged_sessions,

    COUNTIF(is_new_user_session)
      AS observed_new_user_sessions,

    SUM(view_item_event_count)
      AS observed_view_item_events,

    SUM(add_to_cart_event_count)
      AS observed_add_to_cart_events,

    SUM(begin_checkout_event_count)
      AS observed_begin_checkout_events,

    SUM(canonical_transaction_count)
      AS observed_transaction_count,

    SUM(canonical_revenue_usd)
      AS observed_revenue_usd,

    SUM(canonical_item_quantity)
      AS observed_item_quantity

  FROM
    target_sessions

  GROUP BY
    geo_region,
    week_start_date
)

SELECT
  target_country AS geo_country,

  region.geo_region,

  CONCAT(
    target_country,
    ' | ',
    region.geo_region
  ) AS geo_key,

  week.week_start_date,

  DATE_ADD(
    week.week_start_date,
    INTERVAL 6 DAY
  ) AS week_end_date,

  1 + DIV(
    DATE_DIFF(
      week.week_start_date,
      analysis_start_date,
      DAY
    ),
    7
  ) AS analysis_week_number,

  CASE
    WHEN week.week_start_date <= pre_period_end_date
      THEN 'PRE'
    ELSE 'TEST'
  END AS period_name,

  CASE
    WHEN week.week_start_date <= pre_period_end_date
      THEN 1 + DIV(
        DATE_DIFF(
          week.week_start_date,
          analysis_start_date,
          DAY
        ),
        7
      )

    ELSE 1 + DIV(
      DATE_DIFF(
        week.week_start_date,
        test_period_start_date,
        DAY
      ),
      7
    )
  END AS period_week_number,

  COALESCE(observed.observed_session_count, 0)
    AS observed_session_count,

  COALESCE(observed.observed_unique_users, 0)
    AS observed_unique_users,

  COALESCE(observed.observed_engaged_sessions, 0)
    AS observed_engaged_sessions,

  COALESCE(observed.observed_new_user_sessions, 0)
    AS observed_new_user_sessions,

  COALESCE(observed.observed_view_item_events, 0)
    AS observed_view_item_events,

  COALESCE(observed.observed_add_to_cart_events, 0)
    AS observed_add_to_cart_events,

  COALESCE(observed.observed_begin_checkout_events, 0)
    AS observed_begin_checkout_events,

  COALESCE(observed.observed_transaction_count, 0)
    AS observed_transaction_count,

  COALESCE(observed.observed_revenue_usd, 0.0)
    AS observed_revenue_usd,

  COALESCE(observed.observed_item_quantity, 0)
    AS observed_item_quantity

FROM
  region_universe AS region

CROSS JOIN
  week_spine AS week

LEFT JOIN
  observed_region_weeks AS observed
    ON region.geo_region = observed.geo_region
    AND week.week_start_date = observed.week_start_date;


-- ============================================================
-- 3. CALCULATE PRE-PERIOD REGION PROFILES
-- ============================================================
--
-- Eligibility is calculated exclusively from the eight-week
-- pre-period. Test-window outcomes do not influence selection.

CREATE TEMP TABLE region_pre_profiles AS
WITH pre_summary AS (
  SELECT
    geo_region,

    COUNTIF(
      period_name = 'PRE'
      AND observed_session_count > 0
    ) AS pre_active_session_weeks,

    COUNTIF(
      period_name = 'PRE'
      AND observed_transaction_count > 0
    ) AS pre_transaction_active_weeks,

    SUM(
      IF(
        period_name = 'PRE',
        observed_session_count,
        0
      )
    ) AS pre_session_count,

    SUM(
      IF(
        period_name = 'PRE',
        observed_transaction_count,
        0
      )
    ) AS pre_transaction_count,

    SUM(
      IF(
        period_name = 'PRE',
        observed_revenue_usd,
        0.0
      )
    ) AS pre_revenue_usd,

    AVG(
      IF(
        period_name = 'PRE',
        observed_revenue_usd,
        NULL
      )
    ) AS pre_average_weekly_revenue_usd,

    STDDEV_SAMP(
      IF(
        period_name = 'PRE',
        observed_revenue_usd,
        NULL
      )
    ) AS pre_weekly_revenue_stddev_usd,

    COUNTIF(
      period_name = 'PRE'
      AND observed_revenue_usd = 0
    ) AS pre_zero_revenue_weeks

  FROM
    balanced_geo_weeks

  GROUP BY
    geo_region
),

calculated_profiles AS (
  SELECT
    *,

    SAFE_DIVIDE(
      pre_transaction_count,
      pre_session_count
    ) AS pre_transaction_rate,

    SAFE_DIVIDE(
      pre_revenue_usd,
      pre_session_count
    ) AS pre_revenue_per_session_usd,

    SAFE_DIVIDE(
      pre_weekly_revenue_stddev_usd,
      pre_average_weekly_revenue_usd
    ) AS pre_revenue_coefficient_of_variation

  FROM
    pre_summary
)

SELECT
  *,

  CASE
    WHEN pre_active_session_weeks < expected_pre_week_count
      THEN FALSE

    WHEN pre_session_count < minimum_pre_sessions
      THEN FALSE

    WHEN pre_transaction_count < minimum_pre_transactions
      THEN FALSE

    WHEN pre_revenue_usd < minimum_pre_revenue_usd
      THEN FALSE

    WHEN pre_revenue_coefficient_of_variation IS NULL
      THEN FALSE

    WHEN pre_revenue_coefficient_of_variation
      > maximum_pre_revenue_cv
      THEN FALSE

    ELSE TRUE
  END AS meets_initial_eligibility,

  CASE
    WHEN pre_active_session_weeks < expected_pre_week_count
      THEN 'INSUFFICIENT_ACTIVE_WEEKS'

    WHEN pre_session_count < minimum_pre_sessions
      THEN 'INSUFFICIENT_PRE_SESSIONS'

    WHEN pre_transaction_count < minimum_pre_transactions
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
-- 4. CREATE THE PERMANENT BASELINE OUTCOME TABLE
-- ============================================================
--
-- This table contains observed outcomes only.
-- Synthetic experiment fields will be added in a separate table
-- after matching and treatment assignment.

CREATE OR REPLACE TABLE
  `measurement-360-portfolio.measurement_360_mart.fct_geo_weekly_outcomes`

CLUSTER BY
  geo_region,
  period_name

OPTIONS (
  description = '''
    Balanced United States region-week outcome table for
    geo-holdout experiment design. Contains real observed GA4
    outcomes only. Treatment assignment and simulated effects
    are intentionally excluded.
  '''
)

AS

SELECT
  weekly.geo_key,
  weekly.geo_country,
  weekly.geo_region,

  weekly.week_start_date,
  weekly.week_end_date,
  weekly.analysis_week_number,
  weekly.period_name,
  weekly.period_week_number,

  weekly.observed_session_count,
  weekly.observed_unique_users,
  weekly.observed_engaged_sessions,
  weekly.observed_new_user_sessions,

  weekly.observed_view_item_events,
  weekly.observed_add_to_cart_events,
  weekly.observed_begin_checkout_events,

  weekly.observed_transaction_count,
  weekly.observed_revenue_usd,
  weekly.observed_item_quantity,

  SAFE_DIVIDE(
    weekly.observed_engaged_sessions,
    weekly.observed_session_count
  ) AS observed_engagement_rate,

  SAFE_DIVIDE(
    weekly.observed_transaction_count,
    weekly.observed_session_count
  ) AS observed_transaction_rate,

  SAFE_DIVIDE(
    weekly.observed_revenue_usd,
    weekly.observed_session_count
  ) AS observed_revenue_per_session_usd,

  SAFE_DIVIDE(
    weekly.observed_revenue_usd,
    weekly.observed_transaction_count
  ) AS observed_average_order_value_usd,

  profile.pre_active_session_weeks,
  profile.pre_transaction_active_weeks,
  profile.pre_session_count,
  profile.pre_transaction_count,
  profile.pre_revenue_usd,
  profile.pre_average_weekly_revenue_usd,
  profile.pre_weekly_revenue_stddev_usd,
  profile.pre_zero_revenue_weeks,
  profile.pre_transaction_rate,
  profile.pre_revenue_per_session_usd,
  profile.pre_revenue_coefficient_of_variation,

  profile.meets_initial_eligibility,
  profile.eligibility_status,

  'PUBLIC_GA4_OBSERVED' AS data_origin,
  'UNASSIGNED' AS treatment_assignment_status,
  FALSE AS is_synthetic_outcome

FROM
  balanced_geo_weeks AS weekly

INNER JOIN
  region_pre_profiles AS profile
    USING (geo_region);


-- ============================================================
-- 5. DATA-QUALITY CONTRACTS
-- ============================================================

ASSERT (
  SELECT COUNT(*)
  FROM
    `measurement-360-portfolio.measurement_360_mart.fct_geo_weekly_outcomes`
) = expected_region_count * expected_week_count
AS 'Geo-week table must contain exactly 51 regions x 13 weeks.';


ASSERT (
  SELECT COUNT(DISTINCT geo_region)
  FROM
    `measurement-360-portfolio.measurement_360_mart.fct_geo_weekly_outcomes`
) = expected_region_count
AS 'Geo-week table must contain exactly 51 United States regions.';


ASSERT (
  SELECT COUNT(
    DISTINCT IF(
      meets_initial_eligibility,
      geo_region,
      NULL
    )
  )
  FROM
    `measurement-360-portfolio.measurement_360_mart.fct_geo_weekly_outcomes`
) = expected_eligible_region_count
AS 'Geo-week table must contain exactly 20 initially eligible regions.';


ASSERT (
  SELECT COUNT(*)

  FROM (
    SELECT
      geo_region

    FROM
      `measurement-360-portfolio.measurement_360_mart.fct_geo_weekly_outcomes`

    GROUP BY
      geo_region

    HAVING
      COUNT(*) != expected_week_count
  )
) = 0
AS 'Every region must have exactly 13 weekly rows.';


ASSERT (
  SELECT COUNT(*)

  FROM (
    SELECT
      geo_region

    FROM
      `measurement-360-portfolio.measurement_360_mart.fct_geo_weekly_outcomes`

    GROUP BY
      geo_region

    HAVING
      COUNTIF(period_name = 'PRE')
        != expected_pre_week_count

      OR COUNTIF(period_name = 'TEST')
        != expected_test_week_count
  )
) = 0
AS 'Every region must contain exactly 8 PRE and 5 TEST weeks.';


ASSERT (
  SELECT COUNT(*)

  FROM
    `measurement-360-portfolio.measurement_360_mart.fct_geo_weekly_outcomes`

  WHERE
    geo_key IS NULL
    OR geo_region IS NULL
    OR week_start_date IS NULL
    OR period_name IS NULL
) = 0
AS 'Geo-week keys, regions, dates and periods cannot be null.';


ASSERT (
  SELECT COUNT(*)

  FROM
    `measurement-360-portfolio.measurement_360_mart.fct_geo_weekly_outcomes`

  WHERE
    observed_session_count < 0
    OR observed_unique_users < 0
    OR observed_transaction_count < 0
    OR observed_revenue_usd < 0
    OR observed_item_quantity < 0
) = 0
AS 'Observed geo-week outcome values cannot be negative.';


ASSERT (
  SELECT SUM(observed_session_count)

  FROM
    `measurement-360-portfolio.measurement_360_mart.fct_geo_weekly_outcomes`
) = (
  SELECT COUNT(*)
  FROM target_sessions
)
AS 'Geo-week session counts must reconcile to the target source.';


ASSERT (
  SELECT SUM(observed_transaction_count)

  FROM
    `measurement-360-portfolio.measurement_360_mart.fct_geo_weekly_outcomes`
) = (
  SELECT SUM(canonical_transaction_count)
  FROM target_sessions
)
AS 'Geo-week transaction counts must reconcile to the target source.';


ASSERT ABS(
  (
    SELECT SUM(observed_revenue_usd)

    FROM
      `measurement-360-portfolio.measurement_360_mart.fct_geo_weekly_outcomes`
  )
  -
  (
    SELECT SUM(canonical_revenue_usd)
    FROM target_sessions
  )
) < 0.01
AS 'Geo-week revenue must reconcile to the target source.';


ASSERT (
  SELECT COUNT(*)

  FROM
    `measurement-360-portfolio.measurement_360_mart.fct_geo_weekly_outcomes`

  WHERE
    treatment_assignment_status != 'UNASSIGNED'
    OR is_synthetic_outcome
) = 0
AS 'Baseline outcomes must remain unassigned and non-synthetic.';


-- ============================================================
-- 6. RECONCILIATION OUTPUT
-- ============================================================

WITH reconciliation AS (
  SELECT
    COUNT(*) AS table_rows,

    COUNT(DISTINCT geo_region)
      AS region_count,

    COUNT(DISTINCT week_start_date)
      AS distinct_week_count,

    COUNT(
      DISTINCT IF(
        meets_initial_eligibility,
        geo_region,
        NULL
      )
    ) AS eligible_region_count,

    COUNTIF(meets_initial_eligibility)
      AS eligible_region_week_rows,

    MIN(week_start_date)
      AS first_week_start_date,

    MAX(week_end_date)
      AS last_week_end_date,

    SUM(observed_session_count)
      AS table_session_count,

    SUM(observed_transaction_count)
      AS table_transaction_count,

    SUM(observed_revenue_usd)
      AS table_revenue_usd,

    SUM(
      IF(
        meets_initial_eligibility
        AND period_name = 'PRE',
        observed_session_count,
        0
      )
    ) AS eligible_pre_session_count,

    SUM(
      IF(
        meets_initial_eligibility
        AND period_name = 'PRE',
        observed_transaction_count,
        0
      )
    ) AS eligible_pre_transaction_count,

    SUM(
      IF(
        meets_initial_eligibility
        AND period_name = 'PRE',
        observed_revenue_usd,
        0.0
      )
    ) AS eligible_pre_revenue_usd,

    SUM(
      IF(
        meets_initial_eligibility,
        observed_session_count,
        0
      )
    ) AS eligible_total_session_count,

    SUM(
      IF(
        meets_initial_eligibility,
        observed_transaction_count,
        0
      )
    ) AS eligible_total_transaction_count,

    SUM(
      IF(
        meets_initial_eligibility,
        observed_revenue_usd,
        0.0
      )
    ) AS eligible_total_revenue_usd

  FROM
    `measurement-360-portfolio.measurement_360_mart.fct_geo_weekly_outcomes`
),

source_totals AS (
  SELECT
    COUNT(*) AS source_session_count,

    SUM(canonical_transaction_count)
      AS source_transaction_count,

    SUM(canonical_revenue_usd)
      AS source_revenue_usd

  FROM
    target_sessions
),

balance_check AS (
  SELECT
    COUNTIF(region_week_count = expected_week_count)
      = expected_region_count
      AS all_regions_have_13_weeks,

    COUNTIF(
      pre_week_count = expected_pre_week_count
      AND test_week_count = expected_test_week_count
    ) = expected_region_count
      AS all_regions_have_8_pre_and_5_test_weeks

  FROM (
    SELECT
      geo_region,

      COUNT(*) AS region_week_count,

      COUNTIF(period_name = 'PRE')
        AS pre_week_count,

      COUNTIF(period_name = 'TEST')
        AS test_week_count

    FROM
      `measurement-360-portfolio.measurement_360_mart.fct_geo_weekly_outcomes`

    GROUP BY
      geo_region
  )
)

SELECT
  reconciliation.table_rows,
  reconciliation.region_count,
  reconciliation.distinct_week_count,
  reconciliation.eligible_region_count,
  reconciliation.eligible_region_week_rows,

  reconciliation.first_week_start_date,
  reconciliation.last_week_end_date,

  reconciliation.table_session_count,
  source_totals.source_session_count,

  reconciliation.table_transaction_count,
  source_totals.source_transaction_count,

  ROUND(
    reconciliation.table_revenue_usd,
    2
  ) AS table_revenue_usd,

  ROUND(
    source_totals.source_revenue_usd,
    2
  ) AS source_revenue_usd,

  reconciliation.eligible_pre_session_count,
  reconciliation.eligible_pre_transaction_count,

  ROUND(
    reconciliation.eligible_pre_revenue_usd,
    2
  ) AS eligible_pre_revenue_usd,

  reconciliation.eligible_total_session_count,
  reconciliation.eligible_total_transaction_count,

  ROUND(
    reconciliation.eligible_total_revenue_usd,
    2
  ) AS eligible_total_revenue_usd,

  balance_check.all_regions_have_13_weeks,

  balance_check.all_regions_have_8_pre_and_5_test_weeks,

  reconciliation.table_session_count
    = source_totals.source_session_count
    AS sessions_reconcile,

  reconciliation.table_transaction_count
    = source_totals.source_transaction_count
    AS transactions_reconcile,

  ABS(
    reconciliation.table_revenue_usd
    - source_totals.source_revenue_usd
  ) < 0.01 AS revenue_reconciles,

  (
    SELECT COUNTIF(is_partitioning_column = 'YES')

    FROM
      `measurement-360-portfolio.measurement_360_mart.INFORMATION_SCHEMA.COLUMNS`

    WHERE
      table_name = 'fct_geo_weekly_outcomes'
  ) AS partitioning_column_count,

  (
    SELECT STRING_AGG(
      column_name,
      ', '
      ORDER BY clustering_ordinal_position
    )

    FROM
      `measurement-360-portfolio.measurement_360_mart.INFORMATION_SCHEMA.COLUMNS`

    WHERE
      table_name = 'fct_geo_weekly_outcomes'
      AND clustering_ordinal_position IS NOT NULL
  ) AS clustering_columns,

  CASE
    WHEN reconciliation.table_rows
      = expected_region_count * expected_week_count

      AND reconciliation.region_count
        = expected_region_count

      AND reconciliation.distinct_week_count
        = expected_week_count

      AND reconciliation.eligible_region_count
        = expected_eligible_region_count

      AND balance_check.all_regions_have_13_weeks

      AND balance_check.all_regions_have_8_pre_and_5_test_weeks

      AND reconciliation.table_session_count
        = source_totals.source_session_count

      AND reconciliation.table_transaction_count
        = source_totals.source_transaction_count

      AND ABS(
        reconciliation.table_revenue_usd
        - source_totals.source_revenue_usd
      ) < 0.01

      THEN 'PASS'

    ELSE 'FAIL'
  END AS reconciliation_status

FROM
  reconciliation

CROSS JOIN
  source_totals

CROSS JOIN
  balance_check;
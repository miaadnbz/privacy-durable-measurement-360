-- Measurement 360
-- Stage 5D: Channel attribution shift and sensitivity analysis
--
-- Purpose:
-- Identify channels potentially undervalued or overvalued by
-- last-touch reporting and test whether the direction remains
-- consistent after excluding left-censored journeys.
--
-- Output grain:
-- One row per comparison model and channel.
--
-- Expected output:
-- 4 comparison models × 7 channels = 28 rows.
--
-- Important:
-- "Undervalued" and "overvalued" refer only to differences between
-- heuristic attribution rules. They do not prove causal media impact.

DECLARE expected_analysis_rows INT64 DEFAULT 28;
DECLARE expected_comparison_models INT64 DEFAULT 4;
DECLARE expected_channels INT64 DEFAULT 7;

CREATE TEMP TABLE channel_shift_analysis AS

WITH full_model_results AS (
  SELECT
    attribution_model_order,
    attribution_model,
    touchpoint_channel_group,

    attributed_conversion_credit,
    attributed_revenue_usd,
    model_conversion_share,
    model_revenue_share,
    attributed_average_order_value_usd,
    channel_revenue_rank_within_model

  FROM
    `measurement-360-portfolio.measurement_360_mart.mart_attribution_channel_comparison`

  WHERE
    analysis_population = 'all_observed'
    AND attribution_model != 'last_touch'
),

complete_model_results AS (
  SELECT
    attribution_model_order,
    attribution_model,
    touchpoint_channel_group,

    attributed_conversion_credit,
    attributed_revenue_usd,
    model_conversion_share,
    model_revenue_share,
    attributed_average_order_value_usd,
    channel_revenue_rank_within_model

  FROM
    `measurement-360-portfolio.measurement_360_mart.mart_attribution_channel_comparison`

  WHERE
    analysis_population = 'complete_window'
    AND attribution_model != 'last_touch'
),

full_last_touch_baseline AS (
  SELECT
    touchpoint_channel_group,

    attributed_conversion_credit
      AS last_touch_conversion_credit,

    attributed_revenue_usd
      AS last_touch_revenue_usd,

    model_conversion_share
      AS last_touch_conversion_share,

    model_revenue_share
      AS last_touch_revenue_share,

    attributed_average_order_value_usd
      AS last_touch_average_order_value_usd,

    channel_revenue_rank_within_model
      AS last_touch_revenue_rank

  FROM
    `measurement-360-portfolio.measurement_360_mart.mart_attribution_channel_comparison`

  WHERE
    analysis_population = 'all_observed'
    AND attribution_model = 'last_touch'
),

complete_last_touch_baseline AS (
  SELECT
    touchpoint_channel_group,

    attributed_conversion_credit
      AS last_touch_conversion_credit,

    attributed_revenue_usd
      AS last_touch_revenue_usd,

    model_conversion_share
      AS last_touch_conversion_share,

    model_revenue_share
      AS last_touch_revenue_share,

    attributed_average_order_value_usd
      AS last_touch_average_order_value_usd,

    channel_revenue_rank_within_model
      AS last_touch_revenue_rank

  FROM
    `measurement-360-portfolio.measurement_360_mart.mart_attribution_channel_comparison`

  WHERE
    analysis_population = 'complete_window'
    AND attribution_model = 'last_touch'
),

joined_populations AS (
  SELECT
    f.attribution_model_order,
    f.attribution_model,
    f.touchpoint_channel_group,

    -- ========================================================
    -- Full observed population
    -- ========================================================

    f.attributed_conversion_credit
      AS full_model_conversion_credit,

    flt.last_touch_conversion_credit
      AS full_last_touch_conversion_credit,

    f.attributed_conversion_credit
      - flt.last_touch_conversion_credit
      AS full_conversion_delta_vs_last_touch,

    f.attributed_revenue_usd
      AS full_model_revenue_usd,

    flt.last_touch_revenue_usd
      AS full_last_touch_revenue_usd,

    f.attributed_revenue_usd
      - flt.last_touch_revenue_usd
      AS full_revenue_delta_vs_last_touch_usd,

    SAFE_DIVIDE(
      f.attributed_revenue_usd
        - flt.last_touch_revenue_usd,
      flt.last_touch_revenue_usd
    ) AS full_relative_revenue_delta_vs_last_touch,

    f.model_revenue_share
      AS full_model_revenue_share,

    flt.last_touch_revenue_share
      AS full_last_touch_revenue_share,

    f.model_revenue_share
      - flt.last_touch_revenue_share
      AS full_revenue_share_delta_vs_last_touch,

    f.channel_revenue_rank_within_model
      AS full_model_revenue_rank,

    flt.last_touch_revenue_rank
      AS full_last_touch_revenue_rank,

    f.channel_revenue_rank_within_model
      - flt.last_touch_revenue_rank
      AS full_revenue_rank_change_vs_last_touch,

    f.attributed_average_order_value_usd
      AS full_model_average_order_value_usd,

    flt.last_touch_average_order_value_usd
      AS full_last_touch_average_order_value_usd,

    -- ========================================================
    -- Complete-window sensitivity population
    -- ========================================================

    c.attributed_conversion_credit
      AS complete_model_conversion_credit,

    clt.last_touch_conversion_credit
      AS complete_last_touch_conversion_credit,

    c.attributed_conversion_credit
      - clt.last_touch_conversion_credit
      AS complete_conversion_delta_vs_last_touch,

    c.attributed_revenue_usd
      AS complete_model_revenue_usd,

    clt.last_touch_revenue_usd
      AS complete_last_touch_revenue_usd,

    c.attributed_revenue_usd
      - clt.last_touch_revenue_usd
      AS complete_revenue_delta_vs_last_touch_usd,

    SAFE_DIVIDE(
      c.attributed_revenue_usd
        - clt.last_touch_revenue_usd,
      clt.last_touch_revenue_usd
    ) AS complete_relative_revenue_delta_vs_last_touch,

    c.model_revenue_share
      AS complete_model_revenue_share,

    clt.last_touch_revenue_share
      AS complete_last_touch_revenue_share,

    c.model_revenue_share
      - clt.last_touch_revenue_share
      AS complete_revenue_share_delta_vs_last_touch,

    c.channel_revenue_rank_within_model
      AS complete_model_revenue_rank,

    clt.last_touch_revenue_rank
      AS complete_last_touch_revenue_rank,

    c.channel_revenue_rank_within_model
      - clt.last_touch_revenue_rank
      AS complete_revenue_rank_change_vs_last_touch,

    c.attributed_average_order_value_usd
      AS complete_model_average_order_value_usd,

    clt.last_touch_average_order_value_usd
      AS complete_last_touch_average_order_value_usd

  FROM
    full_model_results AS f

  INNER JOIN
    complete_model_results AS c
    USING (
      attribution_model_order,
      attribution_model,
      touchpoint_channel_group
    )

  INNER JOIN
    full_last_touch_baseline AS flt
    USING (
      touchpoint_channel_group
    )

  INNER JOIN
    complete_last_touch_baseline AS clt
    USING (
      touchpoint_channel_group
    )
)

SELECT
  *,

  -- Normalizes the dollar change because the two populations
  -- contain different total revenue.
  SAFE_DIVIDE(
    full_revenue_delta_vs_last_touch_usd,
    340859.0
  ) AS full_delta_share_of_population_revenue,

  SAFE_DIVIDE(
    complete_revenue_delta_vs_last_touch_usd,
    215994.0
  ) AS complete_delta_share_of_population_revenue,

  SAFE_DIVIDE(
    complete_revenue_delta_vs_last_touch_usd,
    215994.0
  )
  - SAFE_DIVIDE(
    full_revenue_delta_vs_last_touch_usd,
    340859.0
  ) AS normalized_delta_change_between_populations,

  CASE
    WHEN
      ABS(full_revenue_delta_vs_last_touch_usd) < 0.01
      AND ABS(
        complete_revenue_delta_vs_last_touch_usd
      ) < 0.01
    THEN TRUE

    WHEN
      full_revenue_delta_vs_last_touch_usd > 0
      AND complete_revenue_delta_vs_last_touch_usd > 0
    THEN TRUE

    WHEN
      full_revenue_delta_vs_last_touch_usd < 0
      AND complete_revenue_delta_vs_last_touch_usd < 0
    THEN TRUE

    ELSE FALSE
  END AS attribution_direction_consistent,

  CASE
    WHEN
      ABS(full_revenue_delta_vs_last_touch_usd) < 0.01
      AND ABS(
        complete_revenue_delta_vs_last_touch_usd
      ) < 0.01
    THEN 'No material difference from last touch'

    WHEN
      full_revenue_delta_vs_last_touch_usd > 0
      AND complete_revenue_delta_vs_last_touch_usd > 0
    THEN 'Potentially undervalued by last touch'

    WHEN
      full_revenue_delta_vs_last_touch_usd < 0
      AND complete_revenue_delta_vs_last_touch_usd < 0
    THEN 'Potentially overvalued by last touch'

    ELSE 'Direction changes across populations'
  END AS directional_interpretation

FROM
  joined_populations;


-- ============================================================
-- Analysis contracts
-- ============================================================

ASSERT (
  SELECT COUNT(*)
  FROM channel_shift_analysis
) = expected_analysis_rows
AS 'The analysis must contain 28 model-channel rows.';


ASSERT (
  SELECT COUNT(DISTINCT attribution_model)
  FROM channel_shift_analysis
) = expected_comparison_models
AS 'The analysis must contain four non-baseline models.';


ASSERT (
  SELECT COUNT(DISTINCT touchpoint_channel_group)
  FROM channel_shift_analysis
) = expected_channels
AS 'The analysis must contain all seven channels.';


ASSERT (
  SELECT COUNTIF(
    attribution_model IS NULL
    OR touchpoint_channel_group IS NULL
    OR full_model_revenue_usd IS NULL
    OR full_last_touch_revenue_usd IS NULL
    OR complete_model_revenue_usd IS NULL
    OR complete_last_touch_revenue_usd IS NULL
  )
  FROM channel_shift_analysis
) = 0
AS 'Required analysis fields must not be null.';


-- Every model redistributes revenue, so channel deltas must net to zero.
ASSERT (
  SELECT COUNT(*)
  FROM (
    SELECT
      attribution_model,

      SUM(full_revenue_delta_vs_last_touch_usd)
        AS full_delta_sum,

      SUM(complete_revenue_delta_vs_last_touch_usd)
        AS complete_delta_sum

    FROM
      channel_shift_analysis

    GROUP BY
      attribution_model

    HAVING
      ABS(full_delta_sum) > 0.01
      OR ABS(complete_delta_sum) > 0.01
  )
) = 0
AS 'Channel revenue deltas must net to zero within each model.';


-- ============================================================
-- Final analytical output
-- ============================================================

SELECT
  attribution_model_order,
  attribution_model,
  touchpoint_channel_group,

  ROUND(full_model_revenue_usd, 2)
    AS full_model_revenue_usd,

  ROUND(full_last_touch_revenue_usd, 2)
    AS full_last_touch_revenue_usd,

  ROUND(full_revenue_delta_vs_last_touch_usd, 2)
    AS full_revenue_delta_vs_last_touch_usd,

  ROUND(full_relative_revenue_delta_vs_last_touch, 6)
    AS full_relative_revenue_delta_vs_last_touch,

  ROUND(full_model_revenue_share, 6)
    AS full_model_revenue_share,

  ROUND(full_last_touch_revenue_share, 6)
    AS full_last_touch_revenue_share,

  ROUND(full_revenue_share_delta_vs_last_touch, 6)
    AS full_revenue_share_delta_vs_last_touch,

  full_model_revenue_rank,
  full_last_touch_revenue_rank,
  full_revenue_rank_change_vs_last_touch,

  ROUND(complete_model_revenue_usd, 2)
    AS complete_model_revenue_usd,

  ROUND(complete_last_touch_revenue_usd, 2)
    AS complete_last_touch_revenue_usd,

  ROUND(complete_revenue_delta_vs_last_touch_usd, 2)
    AS complete_revenue_delta_vs_last_touch_usd,

  ROUND(
    complete_relative_revenue_delta_vs_last_touch,
    6
  ) AS complete_relative_revenue_delta_vs_last_touch,

  ROUND(complete_model_revenue_share, 6)
    AS complete_model_revenue_share,

  ROUND(complete_last_touch_revenue_share, 6)
    AS complete_last_touch_revenue_share,

  ROUND(
    complete_revenue_share_delta_vs_last_touch,
    6
  ) AS complete_revenue_share_delta_vs_last_touch,

  complete_model_revenue_rank,
  complete_last_touch_revenue_rank,
  complete_revenue_rank_change_vs_last_touch,

  ROUND(
    full_delta_share_of_population_revenue,
    6
  ) AS full_delta_share_of_population_revenue,

  ROUND(
    complete_delta_share_of_population_revenue,
    6
  ) AS complete_delta_share_of_population_revenue,

  ROUND(
    normalized_delta_change_between_populations,
    6
  ) AS normalized_delta_change_between_populations,

  attribution_direction_consistent,
  directional_interpretation

FROM
  channel_shift_analysis

ORDER BY
  attribution_model_order,
  ABS(full_revenue_delta_vs_last_touch_usd) DESC,
  touchpoint_channel_group;
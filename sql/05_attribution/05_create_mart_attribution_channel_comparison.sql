-- Measurement 360
-- Stage 5C: Channel-level attribution model comparison
--
-- Grain:
-- One row per analysis population, attribution model, and channel.
--
-- Populations:
-- 1. all_observed: all 5,375 canonical transactions
-- 2. complete_window: excludes left-censored journeys
--
-- Baseline:
-- Last-touch attribution is used as the primary comparison baseline.

DECLARE expected_channel_count INT64 DEFAULT 7;
DECLARE expected_model_count INT64 DEFAULT 5;
DECLARE expected_population_count INT64 DEFAULT 2;
DECLARE expected_output_rows INT64 DEFAULT 70;

DECLARE expected_full_conversions FLOAT64 DEFAULT 5375.0;
DECLARE expected_full_revenue FLOAT64 DEFAULT 340859.0;

DECLARE expected_complete_conversions FLOAT64 DEFAULT 3603.0;
DECLARE expected_complete_revenue FLOAT64 DEFAULT 215994.0;


CREATE TEMP TABLE channel_comparison_build AS

WITH population_expanded AS (
  -- Full observed population
  SELECT
    1 AS analysis_population_order,
    'all_observed' AS analysis_population,
    FALSE AS is_complete_window_population,
    c.*
  FROM
    `measurement-360-portfolio.measurement_360_mart.fct_attribution_credits`
    AS c

  UNION ALL

  -- Sensitivity population with a fully observable 30-day lookback
  SELECT
    2 AS analysis_population_order,
    'complete_window' AS analysis_population,
    TRUE AS is_complete_window_population,
    c.*
  FROM
    `measurement-360-portfolio.measurement_360_mart.fct_attribution_credits`
    AS c
  WHERE
    c.is_complete_lookback_window
),

model_list AS (
  SELECT DISTINCT
    attribution_model_order,
    attribution_model
  FROM
    `measurement-360-portfolio.measurement_360_mart.fct_attribution_credits`
),

channel_list AS (
  SELECT DISTINCT
    touchpoint_channel_group
  FROM
    `measurement-360-portfolio.measurement_360_mart.fct_attribution_credits`
),

population_list AS (
  SELECT
    1 AS analysis_population_order,
    'all_observed' AS analysis_population,
    FALSE AS is_complete_window_population

  UNION ALL

  SELECT
    2 AS analysis_population_order,
    'complete_window' AS analysis_population,
    TRUE AS is_complete_window_population
),

comparison_spine AS (
  -- Creates a complete population × model × channel grid.
  -- Channels with zero credit remain visible rather than disappearing.
  SELECT
    p.analysis_population_order,
    p.analysis_population,
    p.is_complete_window_population,
    m.attribution_model_order,
    m.attribution_model,
    ch.touchpoint_channel_group
  FROM
    population_list AS p

  CROSS JOIN
    model_list AS m

  CROSS JOIN
    channel_list AS ch
),

channel_credit_aggregate AS (
  SELECT
    analysis_population_order,
    analysis_population,
    is_complete_window_population,
    attribution_model_order,
    attribution_model,
    touchpoint_channel_group,

    COUNT(*) AS credited_touchpoint_rows,

    COUNT(DISTINCT transaction_key)
      AS credited_transactions,

    SUM(attributed_conversion_credit)
      AS attributed_conversion_credit,

    SUM(attributed_revenue_usd)
      AS attributed_revenue_usd

  FROM
    population_expanded

  GROUP BY
    analysis_population_order,
    analysis_population,
    is_complete_window_population,
    attribution_model_order,
    attribution_model,
    touchpoint_channel_group
),

filled_channel_metrics AS (
  SELECT
    s.analysis_population_order,
    s.analysis_population,
    s.is_complete_window_population,
    s.attribution_model_order,
    s.attribution_model,
    s.touchpoint_channel_group,

    COALESCE(a.credited_touchpoint_rows, 0)
      AS credited_touchpoint_rows,

    COALESCE(a.credited_transactions, 0)
      AS credited_transactions,

    COALESCE(a.attributed_conversion_credit, 0.0)
      AS attributed_conversion_credit,

    COALESCE(a.attributed_revenue_usd, 0.0)
      AS attributed_revenue_usd

  FROM
    comparison_spine AS s

  LEFT JOIN
    channel_credit_aggregate AS a
    USING (
      analysis_population_order,
      analysis_population,
      is_complete_window_population,
      attribution_model_order,
      attribution_model,
      touchpoint_channel_group
    )
),

model_totals AS (
  SELECT
    analysis_population,
    attribution_model,

    SUM(attributed_conversion_credit)
      AS model_total_attributed_conversions,

    SUM(attributed_revenue_usd)
      AS model_total_attributed_revenue_usd

  FROM
    filled_channel_metrics

  GROUP BY
    analysis_population,
    attribution_model
),

last_touch_baseline AS (
  SELECT
    analysis_population,
    touchpoint_channel_group,

    attributed_conversion_credit
      AS last_touch_attributed_conversions,

    attributed_revenue_usd
      AS last_touch_attributed_revenue_usd

  FROM
    filled_channel_metrics

  WHERE
    attribution_model = 'last_touch'
),

last_non_direct_baseline AS (
  SELECT
    analysis_population,
    touchpoint_channel_group,

    attributed_conversion_credit
      AS last_non_direct_attributed_conversions,

    attributed_revenue_usd
      AS last_non_direct_attributed_revenue_usd

  FROM
    filled_channel_metrics

  WHERE
    attribution_model = 'last_non_direct'
),

enriched_comparison AS (
  SELECT
    f.analysis_population_order,
    f.analysis_population,
    f.is_complete_window_population,
    f.attribution_model_order,
    f.attribution_model,
    f.touchpoint_channel_group,

    f.credited_touchpoint_rows,
    f.credited_transactions,
    f.attributed_conversion_credit,
    f.attributed_revenue_usd,

    SAFE_DIVIDE(
      f.attributed_revenue_usd,
      f.attributed_conversion_credit
    ) AS attributed_average_order_value_usd,

    t.model_total_attributed_conversions,
    t.model_total_attributed_revenue_usd,

    SAFE_DIVIDE(
      f.attributed_conversion_credit,
      t.model_total_attributed_conversions
    ) AS model_conversion_share,

    SAFE_DIVIDE(
      f.attributed_revenue_usd,
      t.model_total_attributed_revenue_usd
    ) AS model_revenue_share,

    -- Last-touch baseline
    lt.last_touch_attributed_conversions,
    lt.last_touch_attributed_revenue_usd,

    f.attributed_conversion_credit
      - lt.last_touch_attributed_conversions
      AS conversion_delta_vs_last_touch,

    f.attributed_revenue_usd
      - lt.last_touch_attributed_revenue_usd
      AS revenue_delta_vs_last_touch_usd,

    SAFE_DIVIDE(
      f.attributed_conversion_credit
        - lt.last_touch_attributed_conversions,
      lt.last_touch_attributed_conversions
    ) AS conversion_delta_pct_vs_last_touch,

    SAFE_DIVIDE(
      f.attributed_revenue_usd
        - lt.last_touch_attributed_revenue_usd,
      lt.last_touch_attributed_revenue_usd
    ) AS revenue_delta_pct_vs_last_touch,

    SAFE_DIVIDE(
      f.attributed_revenue_usd,
      t.model_total_attributed_revenue_usd
    )
    - SAFE_DIVIDE(
      lt.last_touch_attributed_revenue_usd,
      t.model_total_attributed_revenue_usd
    ) AS revenue_share_delta_vs_last_touch,

    -- Last-non-direct baseline
    lnd.last_non_direct_attributed_conversions,
    lnd.last_non_direct_attributed_revenue_usd,

    f.attributed_conversion_credit
      - lnd.last_non_direct_attributed_conversions
      AS conversion_delta_vs_last_non_direct,

    f.attributed_revenue_usd
      - lnd.last_non_direct_attributed_revenue_usd
      AS revenue_delta_vs_last_non_direct_usd

  FROM
    filled_channel_metrics AS f

  INNER JOIN
    model_totals AS t
    USING (
      analysis_population,
      attribution_model
    )

  INNER JOIN
    last_touch_baseline AS lt
    USING (
      analysis_population,
      touchpoint_channel_group
    )

  INNER JOIN
    last_non_direct_baseline AS lnd
    USING (
      analysis_population,
      touchpoint_channel_group
    )
)

SELECT
  *,

  ROW_NUMBER() OVER (
    PARTITION BY
      analysis_population,
      attribution_model
    ORDER BY
      attributed_revenue_usd DESC,
      touchpoint_channel_group
  ) AS channel_revenue_rank_within_model

FROM
  enriched_comparison;


-- ============================================================
-- Input contracts
-- ============================================================

ASSERT (
  SELECT COUNT(*)
  FROM
    `measurement-360-portfolio.measurement_360_mart.fct_attribution_credits`
) = 43017
AS 'The validated attribution-credit fact must contain 43,017 rows.';


ASSERT (
  SELECT COUNT(DISTINCT attribution_model)
  FROM
    `measurement-360-portfolio.measurement_360_mart.fct_attribution_credits`
) = expected_model_count
AS 'Exactly five attribution models must exist.';


ASSERT (
  SELECT COUNT(DISTINCT touchpoint_channel_group)
  FROM
    `measurement-360-portfolio.measurement_360_mart.fct_attribution_credits`
) = expected_channel_count
AS 'Exactly seven normalized channel groups must exist.';


-- ============================================================
-- Mart contracts
-- ============================================================

ASSERT (
  SELECT COUNT(*)
  FROM channel_comparison_build
) = expected_output_rows
AS 'The comparison mart must contain 70 rows.';


ASSERT (
  SELECT COUNT(*)
  FROM (
    SELECT
      analysis_population,
      attribution_model,
      touchpoint_channel_group
    FROM
      channel_comparison_build
    GROUP BY
      analysis_population,
      attribution_model,
      touchpoint_channel_group
    HAVING COUNT(*) > 1
  )
) = 0
AS 'Population-model-channel combinations must be unique.';


ASSERT (
  SELECT COUNTIF(
    analysis_population IS NULL
    OR attribution_model IS NULL
    OR touchpoint_channel_group IS NULL
    OR attributed_conversion_credit IS NULL
    OR attributed_revenue_usd IS NULL
  )
  FROM
    channel_comparison_build
) = 0
AS 'Required comparison fields must not be null.';


ASSERT (
  SELECT COUNTIF(
    attributed_conversion_credit < 0
    OR attributed_revenue_usd < 0
  )
  FROM
    channel_comparison_build
) = 0
AS 'Attributed conversions and revenue must not be negative.';


ASSERT (
  SELECT COUNT(*)
  FROM (
    SELECT
      analysis_population,
      attribution_model,

      SUM(attributed_conversion_credit)
        AS total_conversions,

      SUM(attributed_revenue_usd)
        AS total_revenue

    FROM
      channel_comparison_build

    GROUP BY
      analysis_population,
      attribution_model

    HAVING
      (
        analysis_population = 'all_observed'
        AND (
          ABS(total_conversions - expected_full_conversions)
            > 0.000000001
          OR ABS(total_revenue - expected_full_revenue)
            > 0.01
        )
      )
      OR
      (
        analysis_population = 'complete_window'
        AND (
          ABS(total_conversions - expected_complete_conversions)
            > 0.000000001
          OR ABS(total_revenue - expected_complete_revenue)
            > 0.01
        )
      )
  )
) = 0
AS 'Every model must reconcile within both analysis populations.';


ASSERT (
  SELECT COUNT(*)
  FROM (
    SELECT
      analysis_population,
      attribution_model,

      SUM(model_conversion_share)
        AS conversion_share_sum,

      SUM(model_revenue_share)
        AS revenue_share_sum

    FROM
      channel_comparison_build

    GROUP BY
      analysis_population,
      attribution_model

    HAVING
      ABS(conversion_share_sum - 1.0) > 0.000000001
      OR ABS(revenue_share_sum - 1.0) > 0.000000001
  )
) = 0
AS 'Channel shares must sum to one for every population and model.';


ASSERT (
  SELECT COUNT(*)
  FROM (
    SELECT
      analysis_population,
      attribution_model,

      SUM(conversion_delta_vs_last_touch)
        AS conversion_delta_sum,

      SUM(revenue_delta_vs_last_touch_usd)
        AS revenue_delta_sum

    FROM
      channel_comparison_build

    GROUP BY
      analysis_population,
      attribution_model

    HAVING
      ABS(conversion_delta_sum) > 0.000000001
      OR ABS(revenue_delta_sum) > 0.01
  )
) = 0
AS 'Model deltas versus last touch must net to zero.';


ASSERT (
  SELECT COUNTIF(
    attribution_model = 'last_touch'
    AND (
      ABS(conversion_delta_vs_last_touch)
        > 0.000000001
      OR ABS(revenue_delta_vs_last_touch_usd)
        > 0.01
    )
  )
  FROM
    channel_comparison_build
) = 0
AS 'Last-touch rows must equal their own baseline.';


ASSERT (
  SELECT COUNTIF(
    attribution_model = 'last_non_direct'
    AND (
      ABS(conversion_delta_vs_last_non_direct)
        > 0.000000001
      OR ABS(revenue_delta_vs_last_non_direct_usd)
        > 0.01
    )
  )
  FROM
    channel_comparison_build
) = 0
AS 'Last-non-direct rows must equal their own baseline.';


-- ============================================================
-- Publish
-- ============================================================

DROP TABLE IF EXISTS
  `measurement-360-portfolio.measurement_360_mart.mart_attribution_channel_comparison`;


CREATE TABLE
  `measurement-360-portfolio.measurement_360_mart.mart_attribution_channel_comparison`

CLUSTER BY
  analysis_population,
  attribution_model,
  touchpoint_channel_group

OPTIONS (
  description = '''
    Channel-level comparison of five heuristic attribution models
    for the full observed transaction population and a complete
    30-day lookback sensitivity population. Includes model shares,
    channel rankings, and conversion and revenue deltas relative
    to last-touch and last-non-direct baselines.
  '''
)

AS
SELECT
  *
FROM
  channel_comparison_build;


-- ============================================================
-- Build summary
-- ============================================================

SELECT
  analysis_population_order,
  analysis_population,
  attribution_model_order,
  attribution_model,

  COUNT(*) AS represented_channels,

  ROUND(
    SUM(attributed_conversion_credit),
    6
  ) AS attributed_conversions,

  ROUND(
    SUM(attributed_revenue_usd),
    2
  ) AS attributed_revenue_usd,

  ROUND(
    SUM(model_conversion_share),
    6
  ) AS conversion_share_sum,

  ROUND(
    SUM(model_revenue_share),
    6
  ) AS revenue_share_sum,

  ROUND(
    SUM(ABS(revenue_delta_vs_last_touch_usd)) / 2,
    2
  ) AS revenue_reallocated_vs_last_touch_usd,

  ROUND(
    MAX(IF(
      touchpoint_channel_group = 'Direct',
      attributed_revenue_usd,
      NULL
    )),
    2
  ) AS direct_attributed_revenue_usd

FROM
  `measurement-360-portfolio.measurement_360_mart.mart_attribution_channel_comparison`

GROUP BY
  analysis_population_order,
  analysis_population,
  attribution_model_order,
  attribution_model

ORDER BY
  analysis_population_order,
  attribution_model_order;
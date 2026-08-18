-- Measurement 360
-- Stage 5C: Reconcile the channel attribution comparison mart

DECLARE expected_table_rows INT64 DEFAULT 70;
DECLARE expected_channel_count INT64 DEFAULT 7;
DECLARE expected_model_population_count INT64 DEFAULT 10;

WITH population_expectations AS (
  SELECT *
  FROM UNNEST([
    STRUCT(
      'all_observed' AS analysis_population,
      1 AS analysis_population_order,
      5375.0 AS expected_conversions,
      340859.0 AS expected_revenue_usd
    ),
    STRUCT(
      'complete_window' AS analysis_population,
      2 AS analysis_population_order,
      3603.0 AS expected_conversions,
      215994.0 AS expected_revenue_usd
    )
  ])
),

model_population_summary AS (
  SELECT
    analysis_population,
    MIN(analysis_population_order)
      AS analysis_population_order,

    attribution_model,
    MIN(attribution_model_order)
      AS attribution_model_order,

    COUNT(*) AS represented_channel_rows,
    COUNT(DISTINCT touchpoint_channel_group)
      AS represented_channels,

    SUM(attributed_conversion_credit)
      AS attributed_conversions,

    SUM(attributed_revenue_usd)
      AS attributed_revenue_usd,

    SUM(model_conversion_share)
      AS conversion_share_sum,

    SUM(model_revenue_share)
      AS revenue_share_sum,

    SUM(conversion_delta_vs_last_touch)
      AS net_conversion_delta_vs_last_touch,

    SUM(revenue_delta_vs_last_touch_usd)
      AS net_revenue_delta_vs_last_touch_usd,

    SUM(ABS(revenue_delta_vs_last_touch_usd)) / 2
      AS revenue_reallocated_vs_last_touch_usd,

    MAX(ABS(
      IF(
        attribution_model = 'last_touch',
        revenue_delta_vs_last_touch_usd,
        0
      )
    )) AS last_touch_baseline_error,

    MAX(ABS(
      IF(
        attribution_model = 'last_non_direct',
        revenue_delta_vs_last_non_direct_usd,
        0
      )
    )) AS last_non_direct_baseline_error,

    COUNTIF(
      attributed_conversion_credit < 0
      OR attributed_revenue_usd < 0
    ) AS negative_metric_rows,

    COUNTIF(
      analysis_population IS NULL
      OR attribution_model IS NULL
      OR touchpoint_channel_group IS NULL
      OR attributed_conversion_credit IS NULL
      OR attributed_revenue_usd IS NULL
    ) AS null_required_field_rows

  FROM
    `measurement-360-portfolio.measurement_360_mart.mart_attribution_channel_comparison`

  GROUP BY
    analysis_population,
    attribution_model
),

overall_quality AS (
  SELECT
    COUNT(*) AS total_table_rows,

    COUNT(DISTINCT CONCAT(
      analysis_population,
      '|',
      attribution_model
    )) AS model_population_combinations,

    COUNT(DISTINCT attribution_model)
      AS represented_models,

    COUNT(DISTINCT analysis_population)
      AS represented_populations

  FROM
    `measurement-360-portfolio.measurement_360_mart.mart_attribution_channel_comparison`
),

duplicate_combinations AS (
  SELECT
    COUNT(*) AS duplicate_population_model_channel_groups
  FROM (
    SELECT
      analysis_population,
      attribution_model,
      touchpoint_channel_group
    FROM
      `measurement-360-portfolio.measurement_360_mart.mart_attribution_channel_comparison`
    GROUP BY
      analysis_population,
      attribution_model,
      touchpoint_channel_group
    HAVING COUNT(*) > 1
  )
)

SELECT
  p.analysis_population_order,
  p.analysis_population,
  m.attribution_model_order,
  m.attribution_model,

  m.represented_channel_rows,
  m.represented_channels,

  p.expected_conversions,
  ROUND(m.attributed_conversions, 6)
    AS attributed_conversions,

  p.expected_revenue_usd,
  ROUND(m.attributed_revenue_usd, 2)
    AS attributed_revenue_usd,

  ROUND(m.conversion_share_sum, 6)
    AS conversion_share_sum,

  ROUND(m.revenue_share_sum, 6)
    AS revenue_share_sum,

  ROUND(m.net_conversion_delta_vs_last_touch, 6)
    AS net_conversion_delta_vs_last_touch,

  ROUND(m.net_revenue_delta_vs_last_touch_usd, 2)
    AS net_revenue_delta_vs_last_touch_usd,

  ROUND(m.revenue_reallocated_vs_last_touch_usd, 2)
    AS revenue_reallocated_vs_last_touch_usd,

  m.last_touch_baseline_error,
  m.last_non_direct_baseline_error,
  m.negative_metric_rows,
  m.null_required_field_rows,

  o.total_table_rows,
  o.model_population_combinations,
  o.represented_models,
  o.represented_populations,
  d.duplicate_population_model_channel_groups,

  CASE
    WHEN m.represented_channel_rows =
        expected_channel_count
      AND m.represented_channels =
        expected_channel_count
      AND ABS(
        m.attributed_conversions
        - p.expected_conversions
      ) < 0.000000001
      AND ABS(
        m.attributed_revenue_usd
        - p.expected_revenue_usd
      ) < 0.01
      AND ABS(
        m.conversion_share_sum - 1.0
      ) < 0.000000001
      AND ABS(
        m.revenue_share_sum - 1.0
      ) < 0.000000001
      AND ABS(
        m.net_conversion_delta_vs_last_touch
      ) < 0.000000001
      AND ABS(
        m.net_revenue_delta_vs_last_touch_usd
      ) < 0.01
      AND m.last_touch_baseline_error < 0.01
      AND m.last_non_direct_baseline_error < 0.01
      AND m.negative_metric_rows = 0
      AND m.null_required_field_rows = 0
      AND o.total_table_rows = expected_table_rows
      AND o.model_population_combinations =
        expected_model_population_count
      AND o.represented_models = 5
      AND o.represented_populations = 2
      AND d.duplicate_population_model_channel_groups = 0
    THEN 'PASS'
    ELSE 'FAIL'
  END AS reconciliation_status

FROM
  model_population_summary AS m

INNER JOIN
  population_expectations AS p
  USING (analysis_population)

CROSS JOIN
  overall_quality AS o

CROSS JOIN
  duplicate_combinations AS d

ORDER BY
  p.analysis_population_order,
  m.attribution_model_order;
-- File: 04_ga4_purchase_quality_profile.sql
-- Purpose:
--   Validate purchase-event completeness, transaction uniqueness,
--   revenue consistency, currency coverage, and item availability.
--
-- Source:
--   Google Analytics 4 obfuscated ecommerce sample dataset.
--
-- Output grain:
--   One summary row for all purchase events in the analysis period.

WITH purchase_events AS (
  SELECT
    event_date,
    event_timestamp,
    user_pseudo_id,

    NULLIF(
      TRIM(ecommerce.transaction_id),
      ''
    ) AS ecommerce_transaction_id,

    ecommerce.purchase_revenue AS ecommerce_purchase_revenue,
    ecommerce.purchase_revenue_in_usd AS purchase_revenue_in_usd,
    ecommerce.total_item_quantity AS total_item_quantity,
    ARRAY_LENGTH(items) AS item_array_length,

    NULLIF(
      TRIM(
        (
          SELECT
            COALESCE(
              parameter.value.string_value,
              CAST(parameter.value.int_value AS STRING),
              CAST(parameter.value.float_value AS STRING),
              CAST(parameter.value.double_value AS STRING)
            )
          FROM
            UNNEST(event_params) AS parameter
          WHERE
            parameter.key = 'transaction_id'
          LIMIT 1
        )
      ),
      ''
    ) AS parameter_transaction_id,

    (
      SELECT
        COALESCE(
          parameter.value.double_value,
          CAST(parameter.value.float_value AS FLOAT64),
          CAST(parameter.value.int_value AS FLOAT64),
          SAFE_CAST(parameter.value.string_value AS FLOAT64)
        )
      FROM
        UNNEST(event_params) AS parameter
      WHERE
        parameter.key = 'value'
      LIMIT 1
    ) AS parameter_value,

    (
      SELECT
        parameter.value.string_value
      FROM
        UNNEST(event_params) AS parameter
      WHERE
        parameter.key = 'currency'
      LIMIT 1
    ) AS currency,

    (
      SELECT
        COALESCE(
          parameter.value.int_value,
          SAFE_CAST(parameter.value.string_value AS INT64)
        )
      FROM
        UNNEST(event_params) AS parameter
      WHERE
        parameter.key = 'ga_session_id'
      LIMIT 1
    ) AS ga_session_id

  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE
    _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    AND event_name = 'purchase'
),

transaction_counts AS (
  SELECT
    ecommerce_transaction_id,
    COUNT(*) AS purchase_event_rows
  FROM
    purchase_events
  WHERE
    ecommerce_transaction_id IS NOT NULL
  GROUP BY
    ecommerce_transaction_id
),

duplicate_summary AS (
  SELECT
    COUNTIF(purchase_event_rows > 1)
      AS duplicated_transaction_ids,

    COALESCE(
      SUM(
        IF(
          purchase_event_rows > 1,
          purchase_event_rows - 1,
          0
        )
      ),
      0
    ) AS excess_purchase_event_rows
  FROM
    transaction_counts
),

purchase_summary AS (
  SELECT
    COUNT(*) AS purchase_event_count,
    COUNT(DISTINCT user_pseudo_id) AS unique_purchase_users,

    COUNTIF(ga_session_id IS NOT NULL)
      AS purchase_events_with_session_id,

    COUNTIF(ecommerce_transaction_id IS NOT NULL)
      AS purchase_events_with_ecommerce_transaction_id,

    COUNT(DISTINCT ecommerce_transaction_id)
      AS distinct_ecommerce_transaction_ids,

    COUNTIF(parameter_transaction_id IS NOT NULL)
      AS purchase_events_with_parameter_transaction_id,

    COUNT(DISTINCT parameter_transaction_id)
      AS distinct_parameter_transaction_ids,

    COUNTIF(
      ecommerce_transaction_id IS NOT NULL
      AND parameter_transaction_id IS NOT NULL
      AND ecommerce_transaction_id = parameter_transaction_id
    ) AS matching_transaction_id_events,

    COUNTIF(
      ecommerce_transaction_id IS NOT NULL
      AND parameter_transaction_id IS NOT NULL
      AND ecommerce_transaction_id != parameter_transaction_id
    ) AS mismatched_transaction_id_events,

    COUNTIF(ecommerce_purchase_revenue IS NOT NULL)
      AS purchase_events_with_ecommerce_revenue,

    ROUND(
      SUM(ecommerce_purchase_revenue),
      2
    ) AS raw_ecommerce_purchase_revenue,

    COUNTIF(purchase_revenue_in_usd IS NOT NULL)
      AS purchase_events_with_usd_revenue,

    ROUND(
      SUM(purchase_revenue_in_usd),
      2
    ) AS raw_purchase_revenue_in_usd,

    COUNTIF(parameter_value IS NOT NULL)
      AS purchase_events_with_parameter_value,

    COUNTIF(
      ecommerce_purchase_revenue IS NOT NULL
      AND parameter_value IS NOT NULL
      AND ABS(ecommerce_purchase_revenue - parameter_value) <= 0.01
    ) AS matching_revenue_value_events,

    COUNTIF(
      ecommerce_purchase_revenue IS NOT NULL
      AND parameter_value IS NOT NULL
      AND ABS(ecommerce_purchase_revenue - parameter_value) > 0.01
    ) AS mismatched_revenue_value_events,

    COUNTIF(currency IS NOT NULL)
      AS purchase_events_with_currency,

    ARRAY_AGG(
      DISTINCT currency
      IGNORE NULLS
      ORDER BY currency
    ) AS currencies_observed,

    COUNTIF(total_item_quantity IS NOT NULL)
      AS purchase_events_with_item_quantity,

    COUNTIF(item_array_length > 0)
      AS purchase_events_with_item_records

  FROM
    purchase_events
)

SELECT
  purchase_summary.*,
  duplicate_summary.duplicated_transaction_ids,
  duplicate_summary.excess_purchase_event_rows
FROM
  purchase_summary
CROSS JOIN
  duplicate_summary;
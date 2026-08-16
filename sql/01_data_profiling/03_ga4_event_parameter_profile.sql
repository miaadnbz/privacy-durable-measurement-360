-- File: 03_ga4_event_parameter_profile.sql
-- Purpose:
--   Build a data dictionary of the nested GA4 event parameters,
--   including usage frequency, participating event types,
--   observed value types, and example values.
--
-- Source:
--   Google Analytics 4 obfuscated ecommerce sample dataset.
--
-- Output grain:
--   One row per event parameter key.

WITH parameter_rows AS (
  SELECT
    events.event_name,
    parameter.key AS parameter_key,
    parameter.value.string_value AS string_value,
    parameter.value.int_value AS int_value,
    parameter.value.float_value AS float_value,
    parameter.value.double_value AS double_value,
    COALESCE(
      parameter.value.string_value,
      CAST(parameter.value.int_value AS STRING),
      CAST(parameter.value.float_value AS STRING),
      CAST(parameter.value.double_value AS STRING)
    ) AS normalized_value
  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
      AS events
  CROSS JOIN
    UNNEST(events.event_params) AS parameter
  WHERE
    _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
),

parameter_profile AS (
  SELECT
    parameter_key,
    COUNT(*) AS parameter_occurrences,
    COUNT(DISTINCT event_name) AS event_types_using_parameter,
    ARRAY_AGG(
      DISTINCT event_name
      ORDER BY event_name
    ) AS event_names,
    COUNTIF(string_value IS NOT NULL) AS string_value_rows,
    COUNTIF(int_value IS NOT NULL) AS int_value_rows,
    COUNTIF(float_value IS NOT NULL) AS float_value_rows,
    COUNTIF(double_value IS NOT NULL) AS double_value_rows,
    COUNTIF(
      string_value IS NULL
      AND int_value IS NULL
      AND float_value IS NULL
      AND double_value IS NULL
    ) AS null_value_rows,
    ARRAY_AGG(
      DISTINCT normalized_value
      IGNORE NULLS
      ORDER BY normalized_value
      LIMIT 3
    ) AS sample_values
  FROM
    parameter_rows
  GROUP BY
    parameter_key
)

SELECT
  parameter_key,
  parameter_occurrences,
  event_types_using_parameter,
  event_names,
  CASE
    WHEN string_value_rows > 0
      AND int_value_rows = 0
      AND float_value_rows = 0
      AND double_value_rows = 0
      THEN 'STRING'

    WHEN string_value_rows = 0
      AND int_value_rows > 0
      AND float_value_rows = 0
      AND double_value_rows = 0
      THEN 'INTEGER'

    WHEN string_value_rows = 0
      AND int_value_rows = 0
      AND float_value_rows > 0
      AND double_value_rows = 0
      THEN 'FLOAT'

    WHEN string_value_rows = 0
      AND int_value_rows = 0
      AND float_value_rows = 0
      AND double_value_rows > 0
      THEN 'DOUBLE'

    WHEN string_value_rows = 0
      AND int_value_rows = 0
      AND float_value_rows = 0
      AND double_value_rows = 0
      THEN 'NULL_ONLY'

    ELSE 'MIXED'
  END AS observed_value_type,
  string_value_rows,
  int_value_rows,
  float_value_rows,
  double_value_rows,
  null_value_rows,
  sample_values
FROM
  parameter_profile
ORDER BY
  parameter_occurrences DESC,
  parameter_key;
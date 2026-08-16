-- File: 02_verify_source_schema.sql
-- Purpose:
--   Confirm that every source field planned for the GA4 staging
--   model is available in the public dataset before creating a view.
--
-- Output grain:
--   One row per required source field.

WITH required_fields AS (
  SELECT
    field_path AS required_field_path
  FROM
    UNNEST([
      -- Core event fields
      'event_date',
      'event_timestamp',
      'event_name',
      'user_pseudo_id',
      'event_bundle_sequence_id',
      'event_server_timestamp_offset',
      'platform',

      -- Event parameter structure
      'event_params.key',
      'event_params.value.string_value',
      'event_params.value.int_value',
      'event_params.value.float_value',
      'event_params.value.double_value',

      -- First-user traffic source
      'traffic_source.name',
      'traffic_source.medium',
      'traffic_source.source',

      -- Ecommerce fields
      'ecommerce.transaction_id',
      'ecommerce.purchase_revenue',
      'ecommerce.purchase_revenue_in_usd',
      'ecommerce.total_item_quantity',

      -- Item fields
      'items.item_id',
      'items.item_name',
      'items.item_brand',
      'items.item_variant',
      'items.item_category',
      'items.price',
      'items.price_in_usd',
      'items.quantity',
      'items.item_revenue',
      'items.item_revenue_in_usd',

      -- Geographic fields
      'geo.country',
      'geo.region',
      'geo.city',

      -- Device fields
      'device.category',
      'device.operating_system',
      'device.web_info.browser',

      -- Privacy fields
      'privacy_info.analytics_storage',
      'privacy_info.ads_storage',
      'privacy_info.uses_transient_token'
    ]) AS field_path
),

available_fields AS (
  SELECT
    field_path,
    ANY_VALUE(data_type) AS data_type
  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.INFORMATION_SCHEMA.COLUMN_FIELD_PATHS`
  WHERE
    table_name BETWEEN 'events_20201101' AND 'events_20210131'
  GROUP BY
    field_path
)

SELECT
  required.required_field_path,
  available.data_type,

  CASE
    WHEN available.field_path IS NULL
      THEN 'MISSING'
    ELSE 'AVAILABLE'
  END AS schema_status

FROM
  required_fields AS required
LEFT JOIN
  available_fields AS available
ON
  required.required_field_path = available.field_path

ORDER BY
  CASE
    WHEN available.field_path IS NULL THEN 1
    ELSE 2
  END,
  required.required_field_path;
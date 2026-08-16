-- Measurement 360
-- Item staging model
--
-- Grain:
-- One row per item record within one GA4 event.
--
-- The item_offset records the item's original position in the
-- repeated GA4 items array.

CREATE OR REPLACE VIEW
  `measurement-360-portfolio.measurement_360_stg.stg_ga4_items`
OPTIONS (
  description = 'One row per GA4 item record with event, session, transaction, acquisition and product attributes.'
)
AS

WITH base_events AS (
  SELECT
    _TABLE_SUFFIX AS source_table_suffix,

    PARSE_DATE('%Y%m%d', src.event_date) AS event_date,
    TIMESTAMP_MICROS(src.event_timestamp) AS event_timestamp_utc,
    src.event_timestamp AS event_timestamp_micros,
    src.event_name,
    src.user_pseudo_id,
    src.event_bundle_sequence_id,
    src.event_server_timestamp_offset,
    src.platform,

    TO_HEX(
      SHA256(
        CONCAT(
          _TABLE_SUFFIX,
          '|',
          COALESCE(src.user_pseudo_id, 'NULL'),
          '|',
          CAST(src.event_timestamp AS STRING),
          '|',
          COALESCE(src.event_name, 'NULL'),
          '|',
          COALESCE(
            CAST(src.event_bundle_sequence_id AS STRING),
            'NULL'
          ),
          '|',
          COALESCE(
            CAST(src.event_server_timestamp_offset AS STRING),
            'NULL'
          )
        )
      )
    ) AS source_event_fingerprint,

    -- Event-level geography and device
    src.geo.country AS geo_country,
    src.geo.region AS geo_region,
    src.geo.city AS geo_city,
    src.device.category AS device_category,
    src.device.operating_system AS device_operating_system,
    src.device.web_info.browser AS device_browser,

    -- First-user acquisition
    src.traffic_source.source AS first_user_source,
    src.traffic_source.medium AS first_user_medium,
    src.traffic_source.name AS first_user_campaign,

    -- Event-level ecommerce
    src.ecommerce.transaction_id AS transaction_id_raw,
    src.ecommerce.purchase_revenue_in_usd
      AS event_purchase_revenue_in_usd,
    src.ecommerce.total_item_quantity
      AS event_total_item_quantity,

    -- Privacy information
    src.privacy_info.analytics_storage,
    src.privacy_info.ads_storage,
    src.privacy_info.uses_transient_token,

    -- Keep the repeated array for the following item expansion.
    src.items,

    (
      SELECT AS STRUCT
        MAX(
          IF(
            param.key = 'ga_session_id',
            COALESCE(
              param.value.int_value,
              SAFE_CAST(param.value.string_value AS INT64)
            ),
            NULL
          )
        ) AS ga_session_id,

        MAX(
          IF(
            param.key = 'ga_session_number',
            COALESCE(
              param.value.int_value,
              SAFE_CAST(param.value.string_value AS INT64)
            ),
            NULL
          )
        ) AS ga_session_number,

        MAX(
          IF(param.key = 'source', param.value.string_value, NULL)
        ) AS event_source,

        MAX(
          IF(param.key = 'medium', param.value.string_value, NULL)
        ) AS event_medium,

        MAX(
          IF(param.key = 'campaign', param.value.string_value, NULL)
        ) AS event_campaign,

        MAX(
          IF(param.key = 'currency', param.value.string_value, NULL)
        ) AS currency

      FROM UNNEST(src.event_params) AS param
    ) AS params

  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
      AS src

  WHERE
    _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
),

expanded_items AS (
  SELECT
    base.* EXCEPT (items),

    item_offset,

    item.item_id,
    item.item_name,
    item.item_brand,
    item.item_variant,
    item.item_category,
    item.price AS item_price,
    item.price_in_usd AS item_price_in_usd,
    item.quantity AS item_quantity,
    item.item_revenue,
    item.item_revenue_in_usd

  FROM base_events AS base
  CROSS JOIN UNNEST(base.items) AS item
    WITH OFFSET AS item_offset
)

SELECT
  -- Item-level audit fingerprint
  TO_HEX(
    SHA256(
      CONCAT(
        source_event_fingerprint,
        '|',
        CAST(item_offset AS STRING)
      )
    )
  ) AS item_record_fingerprint,

  source_event_fingerprint,
  item_offset,
  source_table_suffix,

  -- Event
  event_date,
  event_timestamp_utc,
  event_timestamp_micros,
  event_name,
  event_bundle_sequence_id,
  event_server_timestamp_offset,
  platform,

  -- User and session
  user_pseudo_id,
  params.ga_session_id,
  params.ga_session_number,

  CASE
    WHEN
      NULLIF(TRIM(user_pseudo_id), '') IS NOT NULL
      AND params.ga_session_id IS NOT NULL
    THEN CONCAT(
      TRIM(user_pseudo_id),
      '|',
      CAST(params.ga_session_id AS STRING)
    )
    ELSE NULL
  END AS session_key,

  -- Transaction
  transaction_id_raw,

  CASE
    WHEN transaction_id_raw IS NULL
      OR TRIM(transaction_id_raw) = ''
      THEN NULL
    WHEN LOWER(TRIM(transaction_id_raw))
      IN ('(not set)', 'not set', 'not_set')
      THEN NULL
    ELSE TRIM(transaction_id_raw)
  END AS transaction_id_normalized,

  CASE
    WHEN transaction_id_raw IS NULL
      OR TRIM(transaction_id_raw) = ''
      THEN 'MISSING'
    WHEN LOWER(TRIM(transaction_id_raw))
      IN ('(not set)', 'not set', 'not_set')
      THEN 'NOT_SET'
    ELSE 'VALID'
  END AS transaction_id_status,

  event_name = 'purchase' AS is_purchase_event,
  event_purchase_revenue_in_usd,
  event_total_item_quantity,
  params.currency,

  -- Item identity
  item_id,
  NULLIF(TRIM(item_id), '') AS item_id_normalized,
  item_name,
  NULLIF(TRIM(item_name), '') AS item_name_normalized,

  CASE
    WHEN NULLIF(TRIM(item_id), '') IS NOT NULL
      THEN CONCAT('ID:', TRIM(item_id))
    WHEN NULLIF(TRIM(item_name), '') IS NOT NULL
      THEN CONCAT('NAME:', TRIM(item_name))
    ELSE NULL
  END AS item_identity,

  item_brand,
  item_variant,
  item_category,

  -- Item economics
  item_price,
  item_price_in_usd,
  item_quantity,
  item_revenue,
  item_revenue_in_usd,

  CASE
    WHEN
      item_price_in_usd IS NOT NULL
      AND item_quantity IS NOT NULL
    THEN item_price_in_usd * item_quantity
    ELSE NULL
  END AS calculated_item_value_in_usd,

  -- Acquisition
  params.event_source,
  params.event_medium,
  params.event_campaign,
  first_user_source,
  first_user_medium,
  first_user_campaign,

  -- Geography and device
  geo_country,
  geo_region,
  geo_city,
  device_category,
  device_operating_system,
  device_browser,

  -- Privacy
  analytics_storage,
  ads_storage,
  uses_transient_token,

  -- Quality flags
  NULLIF(TRIM(item_id), '') IS NOT NULL AS has_item_id,
  NULLIF(TRIM(item_name), '') IS NOT NULL AS has_item_name,
  params.ga_session_id IS NOT NULL AS has_session_id

FROM expanded_items;
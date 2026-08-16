-- Measurement 360
-- Staging model: one normalized row per GA4 source event
--
-- Source:
-- bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*
--
-- Data period:
-- 2020-11-01 through 2021-01-31
--
-- Important:
-- This is a logical view. Querying the view reads the underlying public
-- GA4 tables. Use explicit date filters and maximum-bytes-billed controls
-- in downstream analysis.

CREATE OR REPLACE VIEW
  `measurement-360-portfolio.measurement_360_stg.stg_ga4_events`
OPTIONS (
  description = 'One row per GA4 event with normalized session, acquisition, ecommerce, privacy and data-quality fields.'
)
AS

WITH extracted_events AS (
  SELECT
    _TABLE_SUFFIX AS source_table_suffix,

    -- Event identity and time
    PARSE_DATE('%Y%m%d', src.event_date) AS event_date,
    TIMESTAMP_MICROS(src.event_timestamp) AS event_timestamp_utc,
    src.event_timestamp AS event_timestamp_micros,
    src.event_name,
    src.user_pseudo_id,
    src.event_bundle_sequence_id,
    src.event_server_timestamp_offset,
    src.platform,

    -- Geography
    src.geo.country AS geo_country,
    src.geo.region AS geo_region,
    src.geo.city AS geo_city,

    -- Device
    src.device.category AS device_category,
    src.device.operating_system AS device_operating_system,
    src.device.web_info.browser AS device_browser,

    -- First-user acquisition
    src.traffic_source.source AS first_user_source,
    src.traffic_source.medium AS first_user_medium,
    src.traffic_source.name AS first_user_campaign,

    -- Ecommerce fields
    src.ecommerce.transaction_id AS transaction_id_raw,
    src.ecommerce.purchase_revenue AS ecommerce_purchase_revenue,
    src.ecommerce.purchase_revenue_in_usd
      AS ecommerce_purchase_revenue_in_usd,
    src.ecommerce.total_item_quantity AS ecommerce_total_item_quantity,
    COALESCE(ARRAY_LENGTH(src.items), 0) AS item_record_count,
    TO_JSON_STRING(src.items) AS items_json,

    -- Privacy settings
    src.privacy_info.analytics_storage,
    src.privacy_info.ads_storage,
    src.privacy_info.uses_transient_token,

    -- Extract relevant event parameters once per event.
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
          IF(
            param.key = 'session_engaged',
            COALESCE(
              param.value.string_value,
              CAST(param.value.int_value AS STRING),
              CAST(param.value.double_value AS STRING),
              CAST(param.value.float_value AS STRING)
            ),
            NULL
          )
        ) AS session_engaged_raw,

        MAX(
          IF(
            param.key = 'engagement_time_msec',
            COALESCE(
              param.value.double_value,
              param.value.float_value,
              CAST(param.value.int_value AS FLOAT64),
              SAFE_CAST(param.value.string_value AS FLOAT64)
            ),
            NULL
          )
        ) AS engagement_time_msec,

        MAX(
          IF(
            param.key = 'engaged_session_event',
            COALESCE(
              param.value.int_value,
              SAFE_CAST(param.value.string_value AS INT64)
            ),
            NULL
          )
        ) AS engaged_session_event,

        MAX(
          IF(
            param.key = 'debug_mode',
            COALESCE(
              param.value.int_value,
              SAFE_CAST(param.value.string_value AS INT64)
            ),
            NULL
          )
        ) AS debug_mode,

        -- Event-level acquisition
        MAX(
          IF(param.key = 'source', param.value.string_value, NULL)
        ) AS event_source,

        MAX(
          IF(param.key = 'medium', param.value.string_value, NULL)
        ) AS event_medium,

        MAX(
          IF(param.key = 'campaign', param.value.string_value, NULL)
        ) AS event_campaign,

        -- Page information
        MAX(
          IF(param.key = 'page_location', param.value.string_value, NULL)
        ) AS page_location,

        MAX(
          IF(param.key = 'page_title', param.value.string_value, NULL)
        ) AS page_title,

        MAX(
          IF(param.key = 'page_referrer', param.value.string_value, NULL)
        ) AS page_referrer,

        -- Ecommerce parameters
        MAX(
          IF(param.key = 'currency', param.value.string_value, NULL)
        ) AS currency,

        MAX(
          IF(
            param.key = 'value',
            COALESCE(
              param.value.double_value,
              param.value.float_value,
              CAST(param.value.int_value AS FLOAT64),
              SAFE_CAST(param.value.string_value AS FLOAT64)
            ),
            NULL
          )
        ) AS event_value,

        -- Click identifiers are retained even though the public sample
        -- contains only null values for these keys.
        MAX(
          IF(
            param.key = 'gclid',
            COALESCE(
              param.value.string_value,
              CAST(param.value.int_value AS STRING),
              CAST(param.value.double_value AS STRING),
              CAST(param.value.float_value AS STRING)
            ),
            NULL
          )
        ) AS gclid,

        MAX(
          IF(
            param.key = 'gclsrc',
            COALESCE(
              param.value.string_value,
              CAST(param.value.int_value AS STRING),
              CAST(param.value.double_value AS STRING),
              CAST(param.value.float_value AS STRING)
            ),
            NULL
          )
        ) AS gclsrc,

        MAX(
          IF(
            param.key = 'dclid',
            COALESCE(
              param.value.string_value,
              CAST(param.value.int_value AS STRING),
              CAST(param.value.double_value AS STRING),
              CAST(param.value.float_value AS STRING)
            ),
            NULL
          )
        ) AS dclid

      FROM UNNEST(src.event_params) AS param
    ) AS params

  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*` AS src

  WHERE
    _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
)

SELECT
  -- Deterministic event fingerprint for auditing.
  -- This is not presented as a guaranteed primary key.
  TO_HEX(
    SHA256(
      CONCAT(
        source_table_suffix,
        '|',
        COALESCE(user_pseudo_id, 'NULL'),
        '|',
        CAST(event_timestamp_micros AS STRING),
        '|',
        COALESCE(event_name, 'NULL'),
        '|',
        COALESCE(CAST(event_bundle_sequence_id AS STRING), 'NULL'),
        '|',
        COALESCE(CAST(event_server_timestamp_offset AS STRING), 'NULL')
      )
    )
  ) AS source_event_fingerprint,

  source_table_suffix,
  event_date,
  event_timestamp_utc,
  event_timestamp_micros,
  event_name,
  user_pseudo_id,
  event_bundle_sequence_id,
  event_server_timestamp_offset,
  platform,

  -- Session identifiers
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

  CASE
    WHEN LOWER(TRIM(params.session_engaged_raw))
      IN ('1', 'true', 'yes')
      THEN TRUE
    WHEN LOWER(TRIM(params.session_engaged_raw))
      IN ('0', 'false', 'no')
      THEN FALSE
    ELSE NULL
  END AS session_engaged,

  params.engagement_time_msec,
  params.engaged_session_event,
  params.debug_mode,

  -- Acquisition
  params.event_source,
  params.event_medium,
  params.event_campaign,
  first_user_source,
  first_user_medium,
  first_user_campaign,

  -- Page
  params.page_location,
  params.page_title,
  params.page_referrer,

  -- Geography
  geo_country,
  geo_region,
  geo_city,

  -- Device
  device_category,
  device_operating_system,
  device_browser,

  -- Ecommerce
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

  ecommerce_purchase_revenue,
  ecommerce_purchase_revenue_in_usd,
  ecommerce_total_item_quantity,
  params.currency,
  params.event_value,
  item_record_count,
  items_json,

  -- Click identifiers and privacy
  params.gclid,
  params.gclsrc,
  params.dclid,
  analytics_storage,
  ads_storage,
  uses_transient_token,

  -- Convenient analytical and quality flags
  event_name = 'purchase' AS is_purchase_event,

  NULLIF(TRIM(user_pseudo_id), '') IS NOT NULL
    AS has_user_pseudo_id,

  params.ga_session_id IS NOT NULL
    AS has_session_id,

  item_record_count > 0
    AS has_item_records,

  COALESCE(params.gclid, params.gclsrc, params.dclid) IS NOT NULL
    AS has_click_identifier

FROM extracted_events;
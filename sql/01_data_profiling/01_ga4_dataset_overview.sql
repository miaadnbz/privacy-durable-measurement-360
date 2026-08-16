-- File: 01_ga4_dataset_overview.sql
-- Purpose:
--   Establish the overall scope, date coverage, user coverage,
--   event variety, and purchase-event volume of the public
--   Google Analytics 4 ecommerce dataset.
--
-- Source:
--   bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*
--
-- Grain of source:
--   One row per recorded GA4 event.
--
-- Important:
--   The _TABLE_SUFFIX filter limits the wildcard query to the
--   documented public-data period.

SELECT
    COUNT(*) AS event_count,
    COUNT(DISTINCT user_pseudo_id) AS unique_pseudo_users,
    COUNT(DISTINCT event_date) AS active_dates,
    MIN(PARSE_DATE('%Y%m%d', event_date)) AS first_event_date,
    MAX(PARSE_DATE('%Y%m%d', event_date)) AS last_event_date,
    COUNT(DISTINCT event_name) AS distinct_event_names,
    COUNTIF(event_name = 'purchase') AS purchase_event_count
FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE
    _TABLE_SUFFIX BETWEEN '20201101' AND '20210131';
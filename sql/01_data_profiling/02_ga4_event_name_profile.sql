-- File: 02_ga4_event_name_profile.sql
-- Purpose:
--   Profile GA4 event types by volume, unique pseudo-user reach,
--   share of all events, and date coverage.
--
-- Source:
--   Google Analytics 4 obfuscated ecommerce sample dataset.
--
-- Output grain:
--   One row per event_name.

WITH base_events AS (
  SELECT
    event_name,
    event_date,
    user_pseudo_id
  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE
    _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
),

overall_totals AS (
  SELECT
    COUNT(*) AS total_events,
    COUNT(DISTINCT user_pseudo_id) AS total_pseudo_users
  FROM
    base_events
),

event_profile AS (
  SELECT
    event_name,
    COUNT(*) AS event_count,
    COUNT(DISTINCT user_pseudo_id) AS unique_pseudo_users,
    MIN(PARSE_DATE('%Y%m%d', event_date)) AS first_event_date,
    MAX(PARSE_DATE('%Y%m%d', event_date)) AS last_event_date
  FROM
    base_events
  GROUP BY
    event_name
)

SELECT
  profile.event_name,
  profile.event_count,
  profile.unique_pseudo_users,
  ROUND(
    100 * SAFE_DIVIDE(profile.event_count, totals.total_events),
    2
  ) AS event_share_pct,
  ROUND(
    100 * SAFE_DIVIDE(
      profile.unique_pseudo_users,
      totals.total_pseudo_users
    ),
    2
  ) AS user_reach_pct,
  profile.first_event_date,
  profile.last_event_date
FROM
  event_profile AS profile
CROSS JOIN
  overall_totals AS totals
ORDER BY
  profile.event_count DESC;
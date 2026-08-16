-- File: 01_create_datasets.sql
-- Purpose:
--   Create the staging and analytical-mart datasets for the
--   Measurement 360 warehouse.
--
-- Google Cloud project:
--   measurement-360-portfolio
--
-- Processing location:
--   US

CREATE SCHEMA IF NOT EXISTS
  `measurement-360-portfolio.measurement_360_stg`
OPTIONS (
  location = 'US',
  default_table_expiration_days = 60,
  description = 'Standardized staging models derived from public GA4 event exports.',
  labels = [
    ('project', 'measurement_360'),
    ('layer', 'staging')
  ]
);

CREATE SCHEMA IF NOT EXISTS
  `measurement-360-portfolio.measurement_360_mart`
OPTIONS (
  location = 'US',
  default_table_expiration_days = 60,
  description = 'Business-ready analytical facts, dimensions, quality checks, and measurement marts.',
  labels = [
    ('project', 'measurement_360'),
    ('layer', 'analytics_mart')
  ]
);
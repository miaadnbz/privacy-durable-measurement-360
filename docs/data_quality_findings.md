# GA4 Data Quality Findings and Transaction-Key Strategy

## Purpose

This document summarizes the GA4 schema, instrumentation, transaction-quality, and revenue-consistency findings identified during the initial profiling of the Measurement 360 portfolio dataset.

The objective is to define defensible data-cleaning and transaction-key rules before constructing analytical marts, attribution models, experiments, or revenue reporting.

## Data Source

The analysis uses the public Google Analytics 4 ecommerce sample:

`bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`

Analysis period:

- Start date: 2020-11-01
- End date: 2021-01-31
- Active dates: 92

Official references:

- [GA4 BigQuery ecommerce sample dataset](https://developers.google.com/analytics/bigquery/web-ecommerce-demo-dataset)
- [GA4 BigQuery export schema](https://support.google.com/analytics/answer/7029846?hl=en)

Google describes this dataset as obfuscated data that emulates a real-world GA4 implementation. Placeholder values and limited internal consistency are expected, and the data cannot be directly reconciled with the Google Analytics Demo Account.

## Dataset Overview

| Metric | Result |
|---|---:|
| Event rows | 4,295,584 |
| Pseudo-users | 270,154 |
| Active dates | 92 |
| Distinct event names | 17 |
| Purchase-event rows | 5,692 |
| Pseudo-users with purchase events | 4,419 |

Pseudo-users represent browser or device identifiers. They are not necessarily authenticated customers.

## Event Coverage

The five highest-volume events were:

1. `page_view`
2. `user_engagement`
3. `scroll`
4. `view_item`
5. `session_start`

Most events covered the complete analysis period. Two instrumentation exceptions were identified:

- `select_item` first appeared on 2020-11-23.
- `view_item_list` ended on 2021-01-28 and contained only 71 events.

These differences indicate that event availability and implementation consistency must be evaluated before treating every event as a stable funnel stage.

## Event-Parameter Findings

The nested `event_params` structure contained 34 parameter keys.

The following parameters used more than one GA4 value type:

- `session_engaged`
- `tax`
- `transaction_id`
- `value`

These parameters require explicit type standardization before modeling.

The following parameters were present as keys but contained no populated values:

- `all_data`
- `gclid`
- `gclsrc`
- `dclid`

Because the advertising click identifiers are not populated, this sample cannot support deterministic Google Ads click-to-conversion joins or offline-conversion validation.

A clearly labeled synthetic first-party and media layer will be used later for measurement methods that require click IDs, CRM matching, media spend, geographic assignment, or experimental treatment information.

## Session-Key Decision

Both `ga_session_id` and `ga_session_number` were populated for every event row.

The session grain will use the composite key:

`user_pseudo_id + ga_session_id`

The numeric `ga_session_id` will not be used by itself because it is not guaranteed to be globally unique across users.

## Purchase-Quality Findings

Initial purchase-event profiling found:

| Metric | Result |
|---|---:|
| Purchase-event rows | 5,692 |
| Purchase events with an ecommerce transaction ID | 5,669 |
| Distinct raw ecommerce transaction IDs | 4,452 |
| Purchase events with session ID | 5,692 |
| Purchase events with USD revenue | 5,692 |
| Purchase events with currency | 5,692 |
| Purchase events containing item records | 5,690 |
| Raw purchase revenue before deduplication | $362,165 |

All observed purchase-event currencies were USD.

The raw revenue is not treated as a final KPI because duplicate measurement events were present.

## Transaction-ID Findings

The raw ecommerce transaction-ID field contained three major quality problems.

### Sentinel values

The value `(not set)` occurred in 883 purchase rows and spanned nearly the complete analysis period.

This value is treated as missing information rather than a valid transaction ID.

### Missing values

An additional 23 purchase-event rows contained null or empty transaction IDs.

### Identifier conflicts

Fifteen otherwise valid transaction IDs appeared across multiple pseudo-users and also contained conflicting revenue values.

These IDs cannot safely represent one unique business transaction. They are routed to a conservative event-signature fallback instead.

## Event-Parameter Transaction ID

The transaction ID stored in `event_params` was not consistent with `ecommerce.transaction_id`.

Among rows where both were populated:

- Matching records: 1
- Mismatched records: 5,218

The event-parameter transaction ID is therefore excluded from transaction-key construction. It is retained only as a data-quality diagnostic.

## Revenue-Field Decision

The local ecommerce revenue and event-parameter `value` fields were populated for 5,242 purchase events.

Among those records:

- Matching within one cent: 1,832
- Mismatching: 3,410

Because `ecommerce.purchase_revenue_in_usd` was populated for all purchase events and all observed currencies were USD, the canonical revenue field will be:

`ecommerce.purchase_revenue_in_usd`

The event-parameter `value` field will not be used as the canonical transaction-revenue measure.

## Canonical Transaction-Key Strategy

The final transaction key uses the following hierarchy:

| Condition | Key method |
|---|---|
| Valid ID associated with one user and one revenue value | Normalized `ecommerce.transaction_id` |
| Valid ID reused across users or revenue values | SHA-256 fallback event signature |
| Null or empty transaction ID | SHA-256 fallback event signature |
| Transaction ID equals `(not set)` | SHA-256 fallback event signature |

The fallback signature incorporates:

- `user_pseudo_id`
- `ga_session_id`
- `event_timestamp`
- `ecommerce.purchase_revenue_in_usd`
- Serialized item-array content

Including the event timestamp makes the fallback intentionally conservative. Purchases with different observable timestamps remain separate unless they have a reliable common transaction ID.

## Final Candidate-Transaction Results

| Key method | Candidate transactions | Purchase-event rows | Event share |
|---|---:|---:|---:|
| Reliable transaction ID | 4,436 | 4,753 | 83.50% |
| Conflicting-ID fallback | 33 | 33 | 0.58% |
| Missing-ID fallback | 23 | 23 | 0.40% |
| `(not set)` fallback | 883 | 883 | 15.51% |
| **Total** | **5,375** | **5,692** | **99.99%** |

The method identifies 317 likely duplicate measurement rows:

`5,692 raw purchase events − 5,375 candidate transactions = 317 duplicate rows`

The proposed measurement-duplicate rate is:

`317 ÷ 5,692 = 5.57%`

No final candidate key contains cross-user or conflicting-revenue records.

## Warehouse Implementation Rules

The future transaction mart will:

1. Normalize empty and `(not set)` transaction IDs to null.
2. Profile valid transaction IDs for user and revenue conflicts.
3. Generate the final transaction key using the documented hierarchy.
4. Rank events within each final transaction key by event timestamp.
5. Retain the earliest event as the canonical transaction record.
6. Preserve the number of source events as an audit field.
7. Retain key-method and data-quality flags.
8. Use `purchase_revenue_in_usd` as canonical revenue.
9. Keep duplicate source events available for reconciliation rather than deleting them from the raw layer.

Planned audit fields include:

- `transaction_key_method`
- `source_purchase_event_count`
- `is_duplicate_measurement_event`
- `transaction_id_status`
- `had_identity_conflict`
- `had_revenue_conflict`
- `has_item_records`

## Limitations

- The dataset is public and obfuscated.
- Internal field consistency is intentionally limited.
- Pseudo-users are device/browser identifiers, not confirmed customers.
- Advertising click identifiers are not populated.
- The fallback signature cannot establish a true business transaction ID.
- The conservative fallback may retain retransmitted events if their timestamps differ.
- Revenue and transaction results should not be compared directly with the Merchandise Store Demo Account.
- The raw $362,165 revenue will not be presented as final deduplicated revenue until the transaction mart is built.

## Reproducibility

The supporting SQL is available in:

1. [`01_ga4_dataset_overview.sql`](../sql/01_data_profiling/01_ga4_dataset_overview.sql)
2. [`02_ga4_event_name_profile.sql`](../sql/01_data_profiling/02_ga4_event_name_profile.sql)
3. [`03_ga4_event_parameter_profile.sql`](../sql/01_data_profiling/03_ga4_event_parameter_profile.sql)
4. [`04_ga4_purchase_quality_profile.sql`](../sql/01_data_profiling/04_ga4_purchase_quality_profile.sql)
5. [`05_ga4_duplicate_transaction_patterns.sql`](../sql/01_data_profiling/05_ga4_duplicate_transaction_patterns.sql)
6. [`06_ga4_canonical_transaction_key_profile.sql`](../sql/01_data_profiling/06_ga4_canonical_transaction_key_profile.sql)
7. [`07_ga4_final_transaction_key_profile.sql`](../sql/01_data_profiling/07_ga4_final_transaction_key_profile.sql)

## Next Step

The next phase will design and implement the analytical warehouse, including event, session, transaction, acquisition, and measurement-ready marts.
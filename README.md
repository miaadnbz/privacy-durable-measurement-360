# Measurement 360: Privacy-Durable Cross-Channel Measurement and Budget Optimization

> **Project status:** In development

## Business Problem

A fictional high-volume Canadian ecommerce advertiser invests across paid search, Performance Max, YouTube, paid social, display, retargeting, offline media, and owned lifecycle channels.

Leadership needs to determine how the next-quarter marketing budget should be allocated to maximize incremental 90-day customer value rather than relying only on platform-attributed conversions.

The central decision is:

> Which channels should receive more, less, or unchanged investment after considering customer journeys, causal incrementality, media saturation, and long-term customer value?

## Project Objective

This project develops an end-to-end marketing measurement system that combines:

- A privacy-durable first-party data foundation
- GA4 event-level analysis in BigQuery
- Customer-journey and Multi-Touch Attribution analysis
- Geo-holdout incrementality testing
- Statistical significance and confidence intervals
- Bayesian Marketing Mix Modeling using Google Meridian
- Experiment-informed MMM calibration
- Marginal return analysis
- Constrained budget optimization
- Executive dashboards and recommendations

## Planned Measurement Framework

The project will use four complementary measurement perspectives:

1. **Journey analysis and MTA** to examine the touchpoints associated with conversion.
2. **Geo experiments** to estimate the causal incremental effect of selected campaigns.
3. **Marketing Mix Modeling** to estimate aggregate channel contribution, saturation, and marginal return.
4. **Cohort value analysis** to evaluate acquisition quality using 30- and 90-day customer outcomes.

No individual method will be treated as complete ground truth. The final recommendation will triangulate evidence across methods.

## Data Strategy

This project uses a mixed-source data strategy:

| Data source | Purpose |
|---|---|
| Google Analytics Merchandise Store Demo Account | GA4 report and exploration practice |
| Public GA4 ecommerce dataset in BigQuery | Event-level SQL, ecommerce funnels, sessions, journeys, and transactions |
| Transparently generated geo-media dataset | MMM, geo experiments, causal validation, and budget optimization |
| Public Canadian datasets where relevant | Geographic, seasonal, population, and economic controls |

The generated data will be clearly identified as synthetic and will not be presented as the data of a real company.

## Planned Technology

- Google Analytics 4
- Google Tag Manager
- Google BigQuery
- SQL
- Python
- dbt
- Google Meridian
- Looker Studio
- Git and GitHub

## Planned Deliverables

- Measurement architecture and data dictionary
- BigQuery SQL analysis
- [GA4 data-quality findings and transaction-key methodology](docs/data_quality_findings.md)
- Tested dbt transformation models
- Customer-journey attribution analysis
- Geo-holdout experiment analysis
- Bayesian MMM and model diagnostics
- Experiment-calibrated channel estimates
- Budget-allocation scenarios
- Executive Looker Studio dashboard
- Executive recommendation deck
- Joint measurement plan
- Methodology and limitations documentation

## Development Progress

- [x] Environment verification
- [x] Repository initialization and project charter
- [x] Dedicated Google Cloud project
- [x] Initial profiling of the public GA4 ecommerce dataset
- [x] Detailed GA4 event and schema profiling
- [ ] Analytical warehouse design
- [ ] Customer-journey attribution
- [ ] Geo-holdout incrementality analysis
- [ ] Meridian Marketing Mix Modeling
- [ ] Experiment-calibrated budget optimization
- [ ] Looker Studio dashboard
- [ ] Executive recommendation deck
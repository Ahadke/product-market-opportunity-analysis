# Product–Market Opportunity & Revenue Concentration Modeling

## Project Overview

This project implements an end-to-end data science pipeline that analyzes a company's
historical sales opportunities to determine where revenue comes from, how concentrated the
business is, which product-market combinations perform unusually well, what factors explain
deal value, and which combinations represent genuine growth opportunities versus revenue risk.

The system integrates SQL-based data engineering, statistical hypothesis testing, multivariate
regression with interaction effects, unsupervised segmentation, and a transparent, weighted
opportunity-scoring framework — mirroring real-world revenue analytics and growth-strategy
workflows used in B2B sales organizations.

## Key Features

* **SQL-Based ETL Pipeline** – PostgreSQL warehouse layer with automated data-quality checks (duplicates, invalid dates/prices, missing dimensions, unmapped reps, category inconsistencies)
* **Opportunity-Level Data Modeling** – Reconciles line-item grain against opportunity grain (435 raw rows → 145 unique opportunities)
* **Revenue Concentration & Risk Analysis** – Pareto analysis, HHI, Gini coefficient, and entropy across every business dimension and their combinations
* **Statistical Hypothesis Testing** – Welch's t-test, Mann–Whitney U, ANOVA, and Kruskal–Wallis with effect sizes and bootstrap confidence intervals
* **Multivariate Regression with Interactions** – Linear/Ridge/Lasso vs. Random Forest/XGBoost on deal value, with explicit Product×Segment and Product×Geography interaction terms
* **Product-Market Segmentation** – K-Means, Gaussian Mixture Models, and hierarchical clustering, validated with silhouette score and cross-method stability (Adjusted Rand Index)
* **Transparent Opportunity Scoring** – Weighted, normalized, sensitivity-tested scoring framework classifying combinations into Strategic Growth / Core-Mature / Emerging Opportunity / Low Priority-Risk
* **Executive Power BI Dashboard** – Revenue Landscape and Growth Opportunities views with interactive filtering

## Dataset

This project uses a company opportunity-level sales dataset (`company_sales.xlsx`), containing
two tables: **Sales Data** (opportunity/product-family line items) and **People** (sales rep
mapping). Line items were aggregated into opportunity-level records via SQL before modeling.

Data includes:

* Opportunity ID, Product Line, Product Family
* Customer Segment (Enterprise / Corporate) and Geography (AMER / EMEA / APAC)
* Opportunity Type (New Business / Upsell) and Close Date
* Total Price (deal value) and Sales Rep ownership

## Project Structure

```
product_market_analysis/
│
├── data/
│   ├── raw/
│   │   └── company_sales.xlsx
│   └── processed/
│       ├── stg_sales_clean.csv / .parquet
│       ├── opportunities.csv / .parquet
│       └── opportunity_scores.csv / .xlsx
│
├── sql/
│   ├── schema.sql
│   ├── cleaning.sql
│   └── analysis.sql
│
├── src/
│   └── data_cleaning.py
│
├── notebooks/
│   ├── 01_data_understanding.ipynb
│   ├── 02_eda.ipynb
│   ├── 03_statistical_analysis.ipynb
│   ├── 04_modeling.ipynb
│   ├── 05_clustering.ipynb
│   └── 06_opportunity_scoring.ipynb
│
├── dashboard/
│   └── Product-Market-Opportunity-Dashboard.pdf
│
├── requirements.txt
├── .env.example
└── README.md
```

## Methodology

### 1. Data Engineering (SQL/PostgreSQL)

Raw Excel data is landed unmodified into PostgreSQL, then validated and cleaned entirely in
SQL. Eight explicit data-quality checks run before any table is trusted:

* Exact duplicate rows: **52 found and removed**
* Invalid/missing prices, dates, and dimension fields
* Category casing inconsistencies
* Unmapped sales reps: **52 of 61 owner IDs had no name mapping**, labeled `Unknown Rep` rather than silently dropped

**Result:** 435 raw rows → 382 clean line items → 145 unique opportunities.

### 2. Revenue Concentration & Risk

Measured with Pareto analysis, HHI, Gini coefficient, and entropy across every dimension and
their combinations.

**Key finding:** individual dimensions look moderately concentrated (Segment HHI = 0.62,
Opportunity Type HHI = 0.55), but the full Product × Segment × Geography combination level is
actually *unconcentrated* (HHI = 0.07) — no single combination dominates. Top 5% of
opportunities account for 28% of total value; top 20% account for 66%.

### 3. Statistical Testing

```
H0: Enterprise and Corporate opportunities have similar deal-value distributions
H1: They differ
```

Enterprise vs. Corporate: **highly significant** (p < 0.00001, Cohen's d = 1.15 — a large
effect); Enterprise deals average ~4.5x Corporate's. Geography differences were **not**
significant (ANOVA p = 0.56). Upsell vs. New Business was also not significant despite an
apparent gap in raw averages — demonstrating the value of testing before trusting an EDA pattern.

### 4. Multivariate Regression

```
log(Deal Value) ~ Segment + Geography + Opportunity Type + Product×Segment + Product×Geography
```

Segment (Enterprise) emerged as the single strongest driver. The interaction terms revealed
that Product Line's apparent effect on value is substantially **confounded with segment mix**
— a product isn't inherently more valuable, it's valuable because of who it's sold to. Linear
Regression performed comparably to Random Forest/XGBoost (R² ≈ 0.18–0.30); added model
complexity was not justified on this dataset size (n=145).

### 5. Product-Market Segmentation

Unsupervised clustering of 24 Product × Segment × Geography combinations (value, volume, deal
economics, growth, upsell mix, volatility). A stable **2-cluster structure** emerged across
K-Means, GMM, and hierarchical clustering (Adjusted Rand Index up to 1.0) — a set of larger,
higher-volume "core active" combinations versus a set of small, 100%-upsell niche combinations.

### 6. Opportunity Scoring

```
Score = w1·EconomicValue + w2·Growth + w3·DealEconomics + w4·Volume + w5·Consistency
```

Weights justified by prior findings (Value/Growth weighted highest per the regression results),
normalized components, concentration risk tracked separately rather than folded in. 24
combinations classified: **7 Strategic Growth, 5 Core/Mature, 0 Emerging Opportunity, 12 Low
Priority/Risk**. Sensitivity analysis against alternative weightings confirmed the ranking is
robust (Spearman correlation 0.87–0.96, 4/5 top-5 overlap) — not an artifact of arbitrary
scoring choices.

## Technologies

Python · SQL · PostgreSQL · Pandas · NumPy · SciPy · Statsmodels · Scikit-learn · XGBoost ·
Power BI · Matplotlib · Seaborn · Jupyter

## Business Impact

This project demonstrates:

* An end-to-end pipeline from raw transactional data to a governed, validated analytical warehouse
* Distinguishing genuine business patterns from noise via formal hypothesis testing
* Identifying and correcting for confounded variables using interaction modeling
* Data-driven market segmentation validated for stability, not just fit
* A transparent, defensible, sensitivity-tested scoring framework for prioritizing business investment
* Executive-ready visualization translating statistical output into decision-ready categories

The framework mirrors revenue concentration and growth-opportunity analysis used in B2B sales
strategy, portfolio management, and product-market fit evaluation.

## How to Reproduce

```bash
# 1. Set up PostgreSQL
createdb product_market_analysis

# 2. Configure environment
cp .env.example .env   # fill in your DB credentials

# 3. Install dependencies
pip install -r requirements.txt

# 4. Run the ETL pipeline
python src/data_cleaning.py

# 5. Run notebooks 01 through 06 in order
```

Notebooks 03–06 automatically use the pipeline output in `data/processed/` if present, and fall
back to rebuilding from raw Excel otherwise.

## Known Limitations

* Sample size is small (145 opportunities, 24 scored combinations) — clustering and scoring
  results should be read as directional, not statistically definitive
* Growth rates between 2019 and 2020 can appear extreme (700%+) for low-volume combinations —
  a real but fragile signal, not a stable trend
* The "Emerging Opportunity" category was empty in this run, a known consequence of median-split
  classification on a small sample, documented rather than hidden

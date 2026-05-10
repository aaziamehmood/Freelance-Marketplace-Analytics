-- Freelance Marketplace Analytics
-- Dataset: Upwork Job Postings 2024 from Kaggle (~53k rows)
-- Database: freelance_analytics (PostgreSQL)
-- Goal: Find which skills pay well, which are overcrowded, and where the real opportunities are


-- ----------------------------------------------------------------
-- STEP 1: Raw Table
-- Imported everything as TEXT first because the CSV had messy
-- mixed values that kept throwing type errors on import
-- ----------------------------------------------------------------

CREATE TABLE upwork_jobs (
    title TEXT,
    link TEXT,
    description TEXT,
    published_date TEXT,
    is_hourly TEXT,
    hourly_low TEXT,
    hourly_high TEXT,
    budget TEXT,
    country TEXT
);

COPY upwork_jobs (
    title, link, description, published_date,
    is_hourly, hourly_low, hourly_high, budget, country
)
FROM 'C:/Freelance Marketplace Analytics/upwork-jobs.csv'
WITH (
    FORMAT csv,
    HEADER true,
    DELIMITER ',',
    NULL '',
    ENCODING 'UTF8'
);


-- ----------------------------------------------------------------
-- STEP 2: Clean Table
-- The dataset had no separate category or skills columns —
-- both were buried inside the description text. Had to extract
-- them manually using string functions.
-- Also fixed dates, cast numeric columns, and built a single
-- avg_rate column that works for both hourly and fixed jobs.
-- Ended up with 52,546 rows after filtering ~500 incomplete ones
-- ----------------------------------------------------------------

CREATE TABLE upwork_clean AS
SELECT
    title,

    -- category was hidden inside description like:
    -- "...job text... Category: Web Design Skills: ..."
    -- so i extracted the text between Category: and Skills:
    TRIM(
        SUBSTRING(
            description,
            POSITION('Category:' IN description) + 9,
            CASE 
                WHEN POSITION('Skills:' IN description) > POSITION('Category:' IN description)
                THEN POSITION('Skills:' IN description) - POSITION('Category:' IN description) - 9
                ELSE 50
            END
        )
    ) AS category,

    -- skills were also in the description as a comma separated list
    -- they appeared twice so i only grabbed the first occurrence
    -- regexp_replace cleans up the extra spaces between skill names
    TRIM(
        REGEXP_REPLACE(
            CASE
                WHEN POSITION('Skills:        ' IN description) > POSITION('Skills:' IN description)
                THEN SUBSTRING(
                    description,
                    POSITION('Skills:' IN description) + 7,
                    POSITION('Skills:        ' IN description) - POSITION('Skills:' IN description) - 7
                )
                ELSE SUBSTRING(
                    description,
                    POSITION('Skills:' IN description) + 7,
                    POSITION('click to apply' IN description) - POSITION('Skills:' IN description) - 7
                )
            END,
            '\s{2,}', ' ', 'g'
        )
    ) AS skills,

    -- date was stored as text like "2024-02-17 09:09:54+00:00"
    -- just needed the first 10 characters
    CAST(SUBSTRING(published_date, 1, 10) AS DATE) AS job_date,
    EXTRACT(MONTH FROM CAST(SUBSTRING(published_date, 1, 10) AS DATE)) AS job_month,
    EXTRACT(YEAR FROM CAST(SUBSTRING(published_date, 1, 10) AS DATE)) AS job_year,

    -- is_hourly was stored as text "True"/"False" not actual boolean
    CASE 
        WHEN UPPER(is_hourly) = 'TRUE' THEN TRUE 
        ELSE FALSE 
    END AS is_hourly,

    -- these had empty strings instead of nulls so nullif handles that
    NULLIF(hourly_low, '')::NUMERIC AS hourly_low,
    NULLIF(hourly_high, '')::NUMERIC AS hourly_high,
    NULLIF(budget, '')::NUMERIC AS budget,

    -- needed one pay column that works for both job types
    -- hourly jobs: midpoint of the rate range
    -- fixed jobs: just the budget
    CASE
        WHEN UPPER(is_hourly) = 'TRUE' 
            THEN (NULLIF(hourly_low,'')::NUMERIC + NULLIF(hourly_high,'')::NUMERIC) / 2
        WHEN UPPER(is_hourly) = 'FALSE' 
            THEN NULLIF(budget,'')::NUMERIC
        ELSE NULL
    END AS avg_rate,

    -- some rows had empty country so replaced with Unknown
    CASE 
        WHEN country IS NULL OR TRIM(country) = '' 
        THEN 'Unknown' 
        ELSE TRIM(country) 
    END AS country

FROM upwork_jobs
WHERE POSITION('Category:' IN description) > 0
AND POSITION('Skills:' IN description) > 0;


-- ----------------------------------------------------------------
-- STEP 3: Add job_type column
-- Power BI was showing True/False on the chart which looked bad
-- added this column so it shows Hourly / Fixed Price instead
-- ----------------------------------------------------------------

ALTER TABLE upwork_clean 
ADD COLUMN job_type TEXT;

UPDATE upwork_clean 
SET job_type = CASE 
    WHEN is_hourly = TRUE THEN 'Hourly'
    ELSE 'Fixed Price'
END;


-- ----------------------------------------------------------------
-- STEP 4: Analysis Queries
-- Answering the 5 business questions
-- ----------------------------------------------------------------

-- Q1: which skills are most in demand?
-- skills column has comma separated values like "Python, SQL, Excel"
-- unnest splits them into individual rows so i can count each one
SELECT
    TRIM(skill) AS skill_name,
    COUNT(*) AS job_count
FROM upwork_clean,
    UNNEST(STRING_TO_ARRAY(skills, ',')) AS skill
WHERE skills IS NOT NULL
GROUP BY TRIM(skill)
ORDER BY job_count DESC
LIMIT 20;


-- Q2: which categories pay the highest?
-- set minimum of 50 jobs per category so one expensive outlier
-- doesnt make a whole category look like it pays well
SELECT
    category,
    ROUND(AVG(avg_rate), 2) AS avg_pay,
    COUNT(*) AS job_count
FROM upwork_clean
WHERE avg_rate IS NOT NULL
GROUP BY category
HAVING COUNT(*) >= 50
ORDER BY avg_pay DESC
LIMIT 15;


-- Q3: hourly vs fixed price — which pays better?
-- included min and max too because avg alone can be misleading
-- (one $1M fixed price job was pulling the average way up)
SELECT
    is_hourly,
    COUNT(*) AS job_count,
    ROUND(AVG(avg_rate), 2) AS avg_pay,
    ROUND(MIN(avg_rate), 2) AS min_pay,
    ROUND(MAX(avg_rate), 2) AS max_pay
FROM upwork_clean
WHERE avg_rate IS NOT NULL
GROUP BY is_hourly
ORDER BY is_hourly DESC;


-- Q4: which countries post the most jobs?
-- window function here calculates percentage share of total
SELECT
    country,
    COUNT(*) AS job_count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) AS percentage
FROM upwork_clean
WHERE country != 'Unknown'
GROUP BY country
ORDER BY job_count DESC
LIMIT 15;


-- Q5: market gap — high demand but low pay categories
-- the interesting finding: graphic design has the most jobs
-- but pays only $109 on average. full stack pays $710 with
-- almost the same number of jobs. that gap is the whole point.
SELECT
    category,
    COUNT(*) AS job_count,
    ROUND(AVG(avg_rate), 2) AS avg_pay,
    CASE
        WHEN COUNT(*) > 500 AND AVG(avg_rate) < 200 THEN 'Crowded Low Pay'
        WHEN COUNT(*) > 500 AND AVG(avg_rate) >= 200 THEN 'High Demand Good Pay'
        ELSE 'Niche'
    END AS market_label
FROM upwork_clean
WHERE avg_rate IS NOT NULL
GROUP BY category
HAVING COUNT(*) >= 50
ORDER BY job_count DESC
LIMIT 20;


-- ----------------------------------------------------------------
-- STEP 5: Summary Tables for Power BI
-- created these so power bi can load clean pre-aggregated data
-- instead of doing heavy calculations on the full 52k row table
-- ----------------------------------------------------------------

-- top 20 skills
CREATE TABLE skill_demand AS
SELECT
    TRIM(skill) AS skill_name,
    COUNT(*) AS job_count
FROM upwork_clean,
    UNNEST(STRING_TO_ARRAY(skills, ',')) AS skill
WHERE skills IS NOT NULL
GROUP BY TRIM(skill)
ORDER BY job_count DESC
LIMIT 20;


-- top 10 countries
CREATE TABLE country_demand AS
SELECT
    country,
    COUNT(*) AS job_count
FROM upwork_clean
WHERE country != 'Unknown'
AND TRIM(country) != ''
AND country IS NOT NULL
GROUP BY country
ORDER BY job_count DESC
LIMIT 10;


-- top 15 paying categories
CREATE TABLE category_pay AS
SELECT
    category,
    ROUND(AVG(avg_rate)::NUMERIC, 2) AS avg_pay,
    COUNT(*) AS job_count
FROM upwork_clean
WHERE avg_rate IS NOT NULL
GROUP BY category
HAVING COUNT(*) >= 50
ORDER BY avg_pay DESC
LIMIT 15;


-- market gap scatter plot data
CREATE TABLE market_gap AS
SELECT
    category,
    COUNT(*) AS job_count,
    ROUND(AVG(avg_rate)::NUMERIC, 2) AS avg_pay,
    CASE
        WHEN COUNT(*) > 500 AND AVG(avg_rate) < 200 THEN 'Crowded Low Pay'
        WHEN COUNT(*) > 500 AND AVG(avg_rate) >= 200 THEN 'High Demand Good Pay'
        ELSE 'Niche'
    END AS market_label
FROM upwork_clean
WHERE avg_rate IS NOT NULL
GROUP BY category
HAVING COUNT(*) >= 50
ORDER BY job_count DESC;
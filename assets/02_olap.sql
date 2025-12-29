CREATE SCHEMA IF NOT EXISTS analytics;

-- 1. TABLA DIM_EMPLOYEE
CREATE TABLE analytics.dim_employee AS
SELECT 
    employee_id AS employee_key,   
    TRIM(first_name) || ' ' || TRIM(last_name) AS full_name, 
    title AS job_title,
    hire_date AS hire_date, 
    city AS office_city,
    country AS office_country
FROM public.employee;

ALTER TABLE analytics.dim_employee ADD PRIMARY KEY (employee_key);

-- 2. TABLA DIM_CUSTOMER 
DROP TABLE IF EXISTS analytics.dim_customer;

CREATE TABLE analytics.dim_customer AS
SELECT 
    customer_id AS customer_key, 
    TRIM(first_name) || ' ' || TRIM(last_name) AS full_name,
    COALESCE(company, 'Particular') AS company_name,
    CASE 
        WHEN company IS NULL THEN 'B2C' 
        ELSE 'B2B' 
    END AS customer_type,
    city AS city,
    COALESCE(state, 'N/A') AS state_province,
    country AS country,
    LOWER(email) AS email,
    support_rep_id AS support_rep_key 
FROM public.customer;

ALTER TABLE analytics.dim_customer ADD PRIMARY KEY (customer_key);



-- 3. TABLA DIM_TRACK
DROP TABLE IF EXISTS analytics.dim_track;

CREATE TABLE analytics.dim_track AS
SELECT 
    t.track_id AS track_key, 
    t.name AS track_name,
    COALESCE(a.title, 'Unknown Album') AS album_title,
    COALESCE(ar.name, 'Unknown Artist') AS artist_name,
    g.name AS genre_name,
    mt.name AS media_type_name,
    ROUND(t.milliseconds / 60000.0, 2) AS duration_minutes,
    t.bytes AS size_bytes,
    t.unit_price AS unit_price 
FROM public.track t
LEFT JOIN public.album a ON t.album_id = a.album_id         
LEFT JOIN public.artist ar ON a.artist_id = ar.artist_id    
LEFT JOIN public.genre g ON t.genre_id = g.genre_id         
LEFT JOIN public.media_type mt ON t.media_type_id = mt.media_type_id; 

ALTER TABLE analytics.dim_track ADD PRIMARY KEY (track_key);

-- 4. TABLA DIM_DATE
DROP TABLE IF EXISTS analytics.dim_date;

CREATE TABLE analytics.dim_date AS
SELECT DISTINCT
    CAST(TO_CHAR(invoice_date, 'YYYYMMDD') AS INTEGER) AS date_key, -- CAMBIO: invoice_date
    invoice_date AS full_date,
    EXTRACT(YEAR FROM invoice_date) AS year,
    EXTRACT(QUARTER FROM invoice_date) AS quarter,
    EXTRACT(MONTH FROM invoice_date) AS month,
    TO_CHAR(invoice_date, 'Month') AS month_name,
    TO_CHAR(invoice_date, 'Day') AS day_name,
    CASE 
        WHEN EXTRACT(ISODOW FROM invoice_date) IN (6, 7) THEN 'Weekend'
        ELSE 'Weekday'
    END AS is_weekend
FROM public.invoice
ORDER BY full_date;

ALTER TABLE analytics.dim_date ADD PRIMARY KEY (date_key);



-- 5. TABLA FACT_SALES
DROP TABLE IF EXISTS analytics.fact_sales;

CREATE TABLE analytics.fact_sales AS
SELECT 
    il.invoice_line_id AS sales_key, 
    i.customer_id AS customer_key,
    il.track_id AS track_key,
    CAST(TO_CHAR(i.invoice_date, 'YYYYMMDD') AS INTEGER) AS date_key,
    c.support_rep_id AS employee_key,
    i.billing_country AS billing_country, 
    i.invoice_id AS invoice_id,
    il.quantity AS quantity,
    il.unit_price AS unit_price,
    (il.quantity * il.unit_price) AS total_revenue

FROM public.invoice_line il  
JOIN public.invoice i ON il.invoice_id = i.invoice_id
JOIN public.customer c ON i.customer_id = c.customer_id;

ALTER TABLE analytics.fact_sales ADD PRIMARY KEY (sales_key);

-- 6. TABLA CUSTOMER_RFM_SCORE 
DROP TABLE IF EXISTS analytics.customer_rfm_score;

CREATE TABLE analytics.customer_rfm_score AS
WITH max_date_cte AS (
    SELECT MAX(to_date(date_key::text, 'YYYYMMDD')) as max_audit_date
    FROM analytics.fact_sales
),
rfm_metrics AS (
    SELECT 
        f.customer_key,
        (m.max_audit_date - MAX(to_date(f.date_key::text, 'YYYYMMDD'))) as recency_days,
        COUNT(DISTINCT f.invoice_id) as frequency,
        SUM(f.total_revenue) as monetary
    FROM analytics.fact_sales f
    CROSS JOIN max_date_cte m
    GROUP BY f.customer_key, m.max_audit_date
),
rfm_quintiles AS (
    SELECT *,
        NTILE(5) OVER (ORDER BY recency_days DESC) as r_score, 
        NTILE(5) OVER (ORDER BY frequency ASC) as f_score,
        NTILE(5) OVER (ORDER BY monetary ASC) as m_score
    FROM rfm_metrics
)
SELECT 
    customer_key,
    recency_days,
    frequency,
    monetary,
    r_score, f_score, m_score,
    (r_score::text || f_score::text || m_score::text) as rfm_code,
    CASE 
        WHEN (r_score + f_score + m_score) >= 13 THEN 'Campeones (VIP)'
        WHEN (r_score + f_score + m_score) BETWEEN 10 AND 12 THEN 'Leales Potenciales'
        WHEN (r_score + f_score + m_score) BETWEEN 7 AND 9 THEN 'Promedio'
        WHEN r_score <= 2 AND monetary > 40 THEN 'En Riesgo (Gastaban mucho)'
        ELSE 'Perdidos / Bajo Valor'
    END as customer_segment
FROM rfm_quintiles;

ALTER TABLE analytics.customer_rfm_score ADD PRIMARY KEY (customer_key);
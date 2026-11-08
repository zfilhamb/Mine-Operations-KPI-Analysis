-- Create Schema ---------------
CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS clean;

-- Cleaning Table daily_production -----------

-- 1a. Cek duplikat sebelum dedup ---------
WITH ranked_data AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY
                date,
                pit,
                shift,
                material_type,
                plan_tonnage,
                actual_tonnage,
                distance_km,
                fleet_count
        ) AS row_num
    FROM clean.daily_production dp
)
SELECT *
FROM ranked_data
WHERE row_num = 2

-- Bangun tabel clean.daily_production final dengan seluruh perbaikan sekaligus ----
-- 1b. Dedup yang row_num = 1 ------
DROP TABLE IF EXISTS clean.daily_production;
CREATE TABLE clean.daily_production AS
WITH dedup AS (
    SELECT *,
        ROW_NUMBER() OVER(
            PARTITION BY
                date,
                pit,
                shift,
                material_type,
                plan_tonnage,
                actual_tonnage,
                distance_km,
                fleet_count
        ) AS row_num
    FROM raw.daily_production dp
),
parse_data AS (
    SELECT *,
        initcap(material_type) AS clean_material_type 
    FROM dedup
    WHERE row_num = 1
)
SELECT
    CAST(date AS date) AS date,
    CAST(pit AS  varchar(50)) AS pit,
    CAST(shift AS  varchar(50)) AS shift,
    CAST(clean_material_type AS varchar(50)) AS material_type,
    CAST(plan_tonnage AS FLOAT4) AS plan_tonnage,
    CAST(actual_tonnage AS FLOAT4) AS actual_tonnage,
    CAST(distance_km AS FLOAT4) AS distance_km,
    CAST(fleet_count AS  int) AS fleet_count
FROM parse_data

-- Cleaning Table clean.equipment_downtime -----------------
DROP TABLE IF EXISTS clean.equipment_downtime;
CREATE TABLE clean.equipment_downtime AS 
WITH parse_data AS (
    SELECT *,
        TRIM(equipment_id) AS clean_equipment_id
    FROM raw.equipment_downtime
),
median_downtime_by_reason AS (
    SELECT
        downtime_reason,
        PERCENTILE_CONT(0.5)
            WITHIN GROUP (ORDER BY downtime_hours)
            AS median_by_downtime_reason
    FROM parse_data
    WHERE downtime_hours IS NOT NULL
    GROUP BY downtime_reason
)
SELECT
    CAST(pd.date AS DATE) AS date,
    CAST(pd.shift AS VARCHAR(50)) AS shift,
    CAST(pd.pit AS VARCHAR(50)) AS pit,
    CAST(pd.equipment_type AS VARCHAR(50)) AS equipment_type,
    CAST(pd.clean_equipment_id AS VARCHAR(50)) AS equipment_id,
    CAST(pd.downtime_reason AS VARCHAR(50)) AS downtime_reason,
    CAST(
        COALESCE(
            pd.downtime_hours,
            md.median_by_downtime_reason
        ) AS FLOAT4
    ) AS downtime_hours
FROM parse_data AS pd
LEFT JOIN median_downtime_by_reason AS md
    ON pd.downtime_reason
       IS NOT DISTINCT FROM md.downtime_reason;

-- Clean Table clean.cost_production -------------
DROP TABLE IF EXISTS clean.cost_production;
CREATE TABLE clean.cost_production AS
WITH data_clean AS (
    SELECT *
    FROM raw.cost_production cp 
)
SELECT
    CAST(date AS DATE) AS date,
    CAST(cost_category AS VARCHAR(50)) AS cost_category,
    CAST(amount_idr AS FLOAT4) AS amount_idr
FROM data_clean

-- Clean Table clean.equipment_master -------------
DROP TABLE IF EXISTS clean.equipment_master;
CREATE TABLE clean.equipment_master AS
WITH data_clean AS (
    SELECT *
    FROM raw.equipment_master
)
SELECT
    CAST(equipment_id AS VARCHAR(50)) AS equipment_id,
    CAST(equipment_type AS VARCHAR(50)) AS equipment_type,
    CAST(model AS VARCHAR(50)) AS model,
    CAST(year_operational AS INT4) AS year_operational,
    CAST(fuel_capacity_liter AS INT4) AS fuel_capacity_liter
FROM data_clean

-- ============================================================================
-- Mining-Operation-KPI
--
-- Tiap analisis = 1 (atau 2) VIEW datar siap pakai sebagai data source Looker.
-- Prefix view: vw_lk_
--
-- ISI
--   A. Stripping ratio & cost per ton coal (bulanan + per pit)
--   B. Hauling distance vs produktivitas (kuartil jarak)
--   C. Pareto downtime (per penyebab & per unit)
--   D. Reliability alat: MTTR, MTBF proxy, umur alat
--   E. Control chart attainment harian (SPC)

-- CATATAN
--   * Semua hasil = asosiasi/deskriptif, bukan bukti sebab-akibat.
-- ============================================================================

-- ============================================================================
-- A. STRIPPING RATIO & COST PER TON COAL
--    SR (proxy) = ton overburden / ton coal. Bukan BCM/ton, karena data
--    tercatat dalam tonase. Tulis "proxy" di label dashboard.
-- ============================================================================

-- A1. Per pit per bulan (bar / heatmap SR per pit) ----------------------------
CREATE OR REPLACE VIEW vw_lk_sr_pit_bulanan AS
SELECT
    DATE_TRUNC('month', date)::date AS bulan,
    pit,
    SUM(actual_tonnage) FILTER (WHERE material_type = 'Coal') AS ton_coal,
    SUM(actual_tonnage) FILTER (WHERE material_type = 'Overburden') AS ton_overburden,
    ROUND((
        (SUM(actual_tonnage) FILTER (WHERE material_type = 'Overburden'))::numeric
        / NULLIF(
            SUM(actual_tonnage) FILTER (WHERE material_type = 'Coal'),
            0
        )::numeric
    ), 2) AS stripping_ratio
FROM clean.daily_production
WHERE actual_tonnage IS NOT NULL
GROUP BY 1, 2
ORDER BY bulan ASC;

-- A2. Total per bulan + cost per ton coal (combo chart: SR vs cost/ton) -------
CREATE OR REPLACE VIEW vw_lk_sr_cost_bulanan AS
WITH prod AS (
    SELECT DATE_TRUNC('month', date)::date AS bulan,
           SUM(actual_tonnage) FILTER (WHERE material_type = 'Coal')       AS ton_coal,
           SUM(actual_tonnage) FILTER (WHERE material_type = 'Overburden') AS ton_ob,
           SUM(actual_tonnage)                                             AS ton_total
    FROM clean.daily_production
    WHERE actual_tonnage IS NOT NULL
    GROUP BY 1
),
biaya AS (
    SELECT DATE_TRUNC('month', date)::date AS bulan,
           SUM(amount_idr)                 AS total_biaya
    FROM clean.cost_production
    GROUP BY 1
)
SELECT p.bulan,
       p.ton_coal,
       p.ton_ob,
       ROUND(p.ton_ob::numeric / NULLIF(p.ton_coal::numeric , 0), 2)           AS stripping_ratio,
       b.total_biaya,
       ROUND(b.total_biaya::numeric / NULLIF(p.ton_total, 0))        AS cost_per_ton_total,
       ROUND(b.total_biaya::numeric / NULLIF(p.ton_coal, 0))         AS cost_per_ton_coal
FROM prod p
JOIN biaya b USING (bulan)
ORDER BY 1 ASC;


-- ============================================================================
-- B. HAULING DISTANCE vs PRODUKTIVITAS
--    Bucket = kuartil jarak (data-driven), jadi tidak perlu menebak batas.
--    Baris dengan distance NULL dimasukkan sebagai 'Tidak diketahui'.
-- ============================================================================

-- B1. Ringkasan per kuartil jarak (bar chart attainment per bucket) -----------
CREATE OR REPLACE VIEW vw_lk_distance_bucket AS
WITH dasar AS (
    SELECT date, pit, distance_km, plan_tonnage, actual_tonnage,
           CASE WHEN distance_km IS NULL THEN NULL
                ELSE NTILE(4) OVER (ORDER BY distance_km) END AS kuartil
    FROM clean.daily_production
    WHERE actual_tonnage IS NOT NULL
      AND plan_tonnage  IS NOT NULL
)
SELECT COALESCE('Q' || kuartil, 'Tidak diketahui')                  AS bucket_jarak,
       ROUND(MIN(distance_km)::numeric, 2)                          AS jarak_min_km,
       ROUND(MAX(distance_km)::numeric, 2)                          AS jarak_max_km,
       COUNT(*)                                                     AS n_baris,
       ROUND(SUM(actual_tonnage)::numeric
             / NULLIF(SUM(plan_tonnage)::numeric, 0) * 100, 1)               AS attainment_pct,
       ROUND(AVG(actual_tonnage)::numeric, 1)                       AS avg_ton_per_baris
FROM dasar
GROUP BY kuartil
ORDER BY kuartil NULLS LAST;


-- B2. Level pit-hari (scatter jarak vs attainment) ----------------------------
CREATE OR REPLACE VIEW vw_lk_distance_scatter AS
SELECT date::date                                                   AS tanggal,
       pit,
       ROUND(AVG(distance_km)::numeric, 2)                          AS avg_distance_km,
       SUM(actual_tonnage)                                          AS actual_ton,
       ROUND(SUM(actual_tonnage)::numeric
             / NULLIF(SUM(plan_tonnage)::numeric, 0) * 100, 1)               AS attainment_pct
FROM clean.daily_production
WHERE actual_tonnage IS NOT NULL
  AND plan_tonnage  IS NOT NULL
  AND distance_km   IS NOT NULL
GROUP BY 1, 2
ORDER BY tanggal ASC; 

-- ============================================================================
-- C. PARETO DOWNTIME
--    Kolom pct_kumulatif dihitung di SQL supaya Looker cukup memakai
--    combo chart: bar = jam_downtime, line = pct_kumulatif (sumbu kanan).
-- ============================================================================

-- C1. Per penyebab ------------------------------------------------------------
CREATE OR REPLACE VIEW vw_lk_pareto_penyebab AS
WITH agg AS (
    SELECT downtime_reason                       AS penyebab,
           COUNT(*)                              AS n_kejadian,
           SUM(downtime_hours::numeric)          AS jam_downtime
    FROM clean.equipment_downtime
    GROUP BY 1
)
SELECT ROW_NUMBER() OVER (ORDER BY jam_downtime DESC, penyebab)      AS peringkat,
       penyebab,
       n_kejadian,
       ROUND(jam_downtime, 1)                               AS jam_downtime,
       ROUND(jam_downtime / SUM(jam_downtime) OVER () * 100, 1)
                                                                     AS pct_dari_total,
       ROUND(SUM(jam_downtime) OVER (ORDER BY jam_downtime DESC, penyebab)::numeric
             / SUM(jam_downtime) OVER () * 100, 1)                   AS pct_kumulatif
FROM agg;


-- C2. Per unit alat -----------------------------------------------------------
CREATE OR REPLACE VIEW vw_lk_pareto_unit AS
WITH agg AS (
    SELECT equipment_id,
           COUNT(*)              AS n_kejadian,
           SUM(downtime_hours::NUMERIC)   AS jam_downtime
    FROM clean.equipment_downtime
    GROUP BY 1
)
SELECT ROW_NUMBER() OVER (ORDER BY jam_downtime DESC, equipment_id)  AS peringkat,
       equipment_id,
       n_kejadian,
       ROUND(jam_downtime, 1)                               AS jam_downtime,
       ROUND(jam_downtime / SUM(jam_downtime) OVER () * 100, 1)
                                                                     AS pct_dari_total,
       ROUND(SUM(jam_downtime) OVER (ORDER BY jam_downtime DESC, equipment_id)::numeric
             / SUM(jam_downtime) OVER () * 100, 1)                   AS pct_kumulatif
FROM agg;


-- ============================================================================
-- D. RELIABILITY ALAT (PROXY)
--    MTTR proxy      = rata-rata jam downtime per kejadian
--    MTBF proxy      = rata-rata jarak hari antar kejadian (LAG), per unit
--    Frekuensi/bulan = kejadian per 30 hari pengamatan
--    Umur alat       = tahun data terakhir - tahun mulai operasi
--    Unit dengan <2 kejadian tidak punya MTBF (NULL).
-- ============================================================================
CREATE OR REPLACE VIEW vw_lk_reliability_unit AS
WITH kejadian AS (
    SELECT equipment_id,
           date::date AS tgl,
           downtime_hours,
           date::date - LAG(date::date) OVER (PARTITION BY equipment_id ORDER BY date) AS gap_hari
    FROM clean.equipment_downtime
),
rentang AS (
    SELECT (MAX(date) - MIN(date) + 1)::numeric          AS hari_observasi,
           EXTRACT(YEAR FROM MAX(date))::int              AS tahun_data
    FROM clean.equipment_downtime
),
agg AS (
    SELECT equipment_id,
           COUNT(*)                         AS n_kejadian,
           SUM(downtime_hours)              AS total_jam,
           AVG(downtime_hours)              AS mttr_jam,
           AVG(gap_hari)                    AS mtbf_hari
    FROM kejadian
    GROUP BY 1
)
SELECT a.equipment_id,
       m.model,
       m.year_operational,
       (r.tahun_data - m.year_operational)                            AS umur_tahun,
       a.n_kejadian,
       ROUND(a.total_jam::numeric, 1)                                AS total_jam_downtime,
       ROUND(a.mttr_jam::numeric, 2)                                 AS mttr_jam,
       ROUND(a.mtbf_hari::numeric, 1)                                AS mtbf_hari,
       ROUND(a.n_kejadian / r.hari_observasi * 30, 2)                AS kejadian_per_30_hari
FROM agg a
CROSS JOIN rentang r
LEFT JOIN clean.equipment_master m USING (equipment_id)
ORDER BY 3 DESC;

-- ============================================================================
-- E. CONTROL CHART ATTAINMENT HARIAN (SPC, individuals chart)
--    Center line = rata-rata seluruh periode, UCL/LCL = rata-rata +/- 3 sigma.
--    Di Looker: time series dengan 4 metrik (attainment, center, ucl, lcl).
--    Kolom status_kontrol dipakai untuk tabel/filter hari out-of-control.
-- ============================================================================
CREATE OR REPLACE VIEW vw_lk_control_chart AS
WITH harian AS (
    SELECT date::date                                          AS tanggal,
           SUM(actual_tonnage)::numeric
             / NULLIF(SUM(plan_tonnage), 0) * 100              AS attainment_pct,
           SUM(actual_tonnage)                                 AS actual_ton
    FROM clean.daily_production
    WHERE actual_tonnage IS NOT NULL
      AND plan_tonnage  IS NOT NULL
    GROUP BY 1
),
dt AS (
    SELECT date::date AS tanggal, SUM(downtime_hours) AS jam_downtime
    FROM clean.equipment_downtime
    GROUP BY 1
),
stat AS (
    SELECT h.*,
           AVG(attainment_pct::NUMERIC )         OVER () AS center_line,
           STDDEV_SAMP(attainment_pct::NUMERIC ) OVER () AS sigma
    FROM harian h
)
SELECT s.tanggal,
       ROUND(s.attainment_pct::NUMERIC , 1)                                   AS attainment_pct,
       ROUND(s.center_line, 1)                                      AS center_line,
       ROUND(s.center_line + 3 * s.sigma, 1)                        AS ucl,
       ROUND(s.center_line - 3 * s.sigma, 1)                        AS lcl,
       CASE
           WHEN s.attainment_pct > s.center_line + 3 * s.sigma THEN 'Di atas UCL'
           WHEN s.attainment_pct < s.center_line - 3 * s.sigma THEN 'Di bawah LCL'
           ELSE 'Terkendali'
       END                                                          AS status_kontrol,
       s.actual_ton,
       COALESCE(d.jam_downtime, 0)                                  AS jam_downtime
FROM stat s
LEFT JOIN dt d USING (tanggal)
ORDER BY s.tanggal;


-- ============================================================================
-- CEK CEPAT (opsional): pastikan semua view terisi
-- ============================================================================
SELECT 'sr_pit_bulanan'    AS v, COUNT(*) FROM vw_lk_sr_pit_bulanan
UNION ALL SELECT 'sr_cost_bulanan',   COUNT(*) FROM vw_lk_sr_cost_bulanan
UNION ALL SELECT 'distance_bucket',   COUNT(*) FROM vw_lk_distance_bucket
UNION ALL SELECT 'distance_scatter',  COUNT(*) FROM vw_lk_distance_scatter
UNION ALL SELECT 'pareto_penyebab',   COUNT(*) FROM vw_lk_pareto_penyebab
UNION ALL SELECT 'pareto_unit',       COUNT(*) FROM vw_lk_pareto_unit
UNION ALL SELECT 'reliability_unit',  COUNT(*) FROM vw_lk_reliability_unit
UNION ALL SELECT 'control_chart',     COUNT(*) FROM vw_lk_control_chart;
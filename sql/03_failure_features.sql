-- =====================================================================
-- Failure-model features: AmsterdamUMCdb v1.5.0 on BigQuery
-- =====================================================================
-- Replace `OUT` with your dataset (same as before). Run after 01_build_cohorts.sql.
-- Look-back window: 24 h before feature_cutoff_dt (= 30 min before extubation).
-- Project: project-71f189c0-e73d-403e-989. GCS: NICE admission scores excluded (see section 2).
--
-- Output (long format; prepare_failure_data.py turns it into one row per extubation):
--   OUT.failure_feat_base  one row per extubation: label, context, suctioning
--   OUT.failure_feat_num   one row per extubation x numeric variable:
--                          last value, mean last 6 h, min/max/slope over 24 h
--   OUT.failure_feat_cat   one row per extubation x categorical variable: last value
--
-- COST: the measurement table (~1 billion rows) is scanned once. Check the
-- "This script will process X GB" estimate before running.

DECLARE win_h   INT64 DEFAULT 24;  -- look-back window (hours)
DECLARE short_h INT64 DEFAULT 6;   -- short window for the recent mean (hours)

-- ---------------------------------------------------------------------
-- 1. Variables: concept IDs from 00_explore_concepts.sql (0c)
-- ---------------------------------------------------------------------
-- lo/hi = physiologically plausible range; values outside it become missing
-- (removes artifacts like pH 736, FiO2 7.4, compliance 5000, tidal volume 0)
CREATE TEMP TABLE vars AS
SELECT * FROM UNNEST(ARRAY<STRUCT<concept_id INT64, feature STRING, kind STRING, lo FLOAT64, hi FLOAT64>>[
  -- ventilator settings (how much support)
  (3024882,  'fio2_set',    'num', 0.21, 1.0),   -- fraction (% converted below)
  (3025408,  'fio2_meas',   'num', 0.21, 1.0),
  (3022875,  'peep_set',    'num', 0,    30),    -- cmH2O
  (3000461,  'ps_set',      'num', 0,    50),    -- cmH2O
  (3007469,  'rr_set',      'num', 0,    60),    -- /min
  -- ventilator measurements (the patient's own breathing)
  (3007646,  'rr_total',    'num', 1,    80),    -- /min
  (3015016,  'vt_exp',      'num', 50,   2000),  -- mL
  (42527120, 'mv_exp',      'num', 0.5,  40),    -- L/min
  (4108000,  'mv_spont',    'num', 0,    40),    -- L/min (0 = no spontaneous breathing)
  (3016078,  'p_peak',      'num', 1,    80),    -- cmH2O
  (42527086, 'p_mean',      'num', 1,    50),    -- cmH2O
  (21490582, 'compliance',  'num', 1,    500),   -- mL/cmH2O
  (3004921,  'vent_mode',   'cat', NULL, NULL),
  -- blood gas (mmHg in this database)
  (3027315,  'po2',         'num', 20,   700),
  (3013290,  'pco2',        'num', 10,   150),
  (3010421,  'ph',          'num', 6.5,  8.0),
  (3006576,  'hco3',        'num', 2,    60),
  (3012501,  'base_excess', 'num', -40,  40),
  (3047181,  'lactate',     'num', 0.1,  30),
  -- monitoring
  (40762499, 'spo2',        'num', 50,   100),
  (3035357,  'etco2',       'num', 5,    150),   -- mmHg
  -- several concepts can share one feature name; they are combined
  (21490872, 'heart_rate',  'num', 20,   250),   -- heart rate beat-to-beat by EKG
  (3027018,  'heart_rate',  'num', 20,   250),   -- heart rate (other source)
  (21490852, 'map',         'num', 20,   200),   -- invasive mean blood pressure
  (21492241, 'map',         'num', 20,   200),   -- non-invasive mean blood pressure
  (21490586, 'temperature', 'num', 25,   45),    -- blood
  (21490588, 'temperature', 'num', 25,   45),    -- esophageal
  (21490870, 'temperature', 'num', 25,   45),    -- bladder
  (3022060,  'temperature', 'num', 25,   45),    -- rectal
  (3025163,  'temperature', 'num', 25,   45),    -- tympanic
  (3025085,  'temperature', 'num', 25,   45),    -- axillary
  (4189949,  'temperature', 'num', 25,   45),    -- groin
  (3006322,  'temperature', 'num', 25,   45),    -- oral
  -- (skin/extremity temperature left out: peripheral, not core temperature)
  -- neuro / sedation (GCS text -> score via gcs_map below)
  (3016335,  'gcs_eye',     'num', 1,    4),
  (3008223,  'gcs_motor',   'num', 1,    6),
  (3009094,  'gcs_verbal',  'num', 1,    5),     -- "Intubated" = not assessable -> missing
  (36684829, 'rass',        'num', -5,   4),
  (4105091,  'ramsay',      'num', 1,    6),
  -- airway
  (4080582,  'sputum',      'cat', NULL, NULL),
  -- labs (Dutch SI units: mmol/L, umol/L, g/L); blood-gas and serum values combined
  (40762351, 'hemoglobin',  'num', 1.5,  15),    -- mmol/L (normal ~7.5-10)
  (3010813,  'wbc',         'num', 0.1,  200),   -- 10^9/L
  (3020564,  'creatinine',  'num', 10,   2000),  -- umol/L
  (3000285,  'sodium',      'num', 100,  190),   -- mmol/L, blood (gas)
  (3019550,  'sodium',      'num', 100,  190),   -- mmol/L, serum/plasma
  (3005456,  'potassium',   'num', 1.5,  10),    -- mmol/L, blood (gas)
  (3023103,  'potassium',   'num', 1.5,  10),    -- mmol/L, serum/plasma
  (3018572,  'chloride',    'num', 60,   150),   -- mmol/L, blood (gas)
  (3014576,  'chloride',    'num', 60,   150),   -- mmol/L, serum/plasma
  (3024561,  'albumin',     'num', 5,    60),    -- g/L
  (3039000,  'anion_gap',   'num', -10,  50),    -- mmol/L, measured
  -- urine output: summed over 24 h (kind 'sum'), not last/mean
  (3014315,  'urine_output', 'sum', 0,   3000),  -- mL per registration
  (3007123,  'urine_output', 'sum', 0,   3000),  -- post void
  (3016267,  'urine_output', 'sum', 0,   3000),  -- in-and-out catheter
  (21491173, 'urine_output', 'sum', 0,   3000)   -- nephrostomy
  -- removed: rr_spont (3026892) and resistance (21490740), ~98% missing
]);

-- GCS is stored as text (value concept), not as a number: translate to the score
CREATE TEMP TABLE gcs_map AS
SELECT * FROM UNNEST(ARRAY<STRUCT<concept_id INT64, value_name STRING, score FLOAT64>>[
  -- eye opening (E1-E4)
  (3016335, 'Eyes open spontaneously', 4),
  (3016335, 'Opens eyes in response to verbal stimulation', 3),
  (3016335, 'Eye opening to verbal command', 3),
  (3016335, 'Opens eyes in response to painful stimulation', 2),
  (3016335, 'Eye opening to pain', 2),
  (3016335, 'No eye opening', 1),
  -- motor response (M1-M6)
  (3008223, 'Obeys commands', 6),
  (3008223, 'Localizing pain', 5),
  (3008223, 'Withdrawal from pain', 4),
  (3008223, 'Flexion to pain', 3),
  (3008223, 'Extension to pain', 2),
  (3008223, 'No motor response', 1),
  -- verbal response (V1-V5); 'Intubated' is deliberately not mapped
  (3009094, 'Oriented', 5),
  (3009094, 'Confused', 4),
  (3009094, 'Inappropriate words', 3),
  (3009094, 'Incomprehensible sounds', 2),
  (3009094, 'No verbal response (>2 yrs); no vocal response (<=2 yrs)', 1)
]);

-- ---------------------------------------------------------------------
-- 2. All measurements of these variables in the 24 h before the cutoff
-- ---------------------------------------------------------------------
CREATE TEMP TABLE m AS
SELECT DISTINCT                     -- drops duplicate rows (same time and value)
  episode_id, feature, kind, dt, t_h,
  IF(num BETWEEN lo AND hi, num, NULL) AS num,   -- implausible values -> missing
  txt
FROM (
SELECT episode_id, feature, kind, lo, hi, dt, t_h, txt,
       IF(feature LIKE 'fio2%' AND num > 1, num / 100, num) AS num   -- FiO2 in % -> fraction
FROM (
  SELECT f.episode_id, v.feature, v.kind, v.lo, v.hi,
         CAST(x.measurement_datetime AS DATETIME) AS dt,
         -- hours relative to the cutoff (negative = before)
         DATETIME_DIFF(CAST(x.measurement_datetime AS DATETIME), f.feature_cutoff_dt, MINUTE) / 60 AS t_h,
         -- numeric value; for scores stored as text (e.g. "4 Spontaan") take the leading number
         COALESCE(x.value_as_number,
                  g.score,                                  -- GCS text -> score
                  SAFE_CAST(REGEXP_EXTRACT(x.value_source_value, r'^\s*(-?\d+(?:\.\d+)?)') AS FLOAT64)) AS num,
         COALESCE(c.concept_name, x.value_source_value) AS txt
  FROM `project-71f189c0-e73d-403e-989.extubation.failure_cohort` f
  JOIN `amsterdamumcdb.version1_5_0.measurement` x
    ON x.person_id = f.person_id
   AND CAST(x.measurement_datetime AS DATETIME) >  DATETIME_SUB(f.feature_cutoff_dt, INTERVAL win_h HOUR)
   AND CAST(x.measurement_datetime AS DATETIME) <= f.feature_cutoff_dt
  JOIN vars v ON v.concept_id = x.measurement_concept_id
  LEFT JOIN `amsterdamumcdb.version1_5_0.concept` c ON c.concept_id = x.value_as_concept_id
  LEFT JOIN gcs_map g ON g.concept_id = x.measurement_concept_id AND g.value_name = c.concept_name
  WHERE x.provider_id >= 0          -- required partition filter
    -- GCS from the NICE registration (E/M/V_EMV_NICE_Opname, _24uur) describes the ADMISSION
    -- state (at admission / worst of the first 24 h), not the state before extubation: excluded.
    -- Only the bedside nursing scores ("Actief openen van de ogen", "Beste motore reactie van de
    -- armen", "Beste verbale reactie") are used.
    AND NOT (v.feature LIKE 'gcs%' AND IFNULL(x.measurement_source_value, '') LIKE '%NICE%')
)
);

-- ---------------------------------------------------------------------
-- 3. Numeric summaries per extubation x variable
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE `project-71f189c0-e73d-403e-989.extubation.failure_feat_num` AS
SELECT episode_id, feature,
       ARRAY_AGG(num ORDER BY dt DESC LIMIT 1)[OFFSET(0)] AS last_val,
       AVG(IF(t_h > -short_h, num, NULL))                 AS mean_6h,
       MIN(num)                                           AS min_24h,
       MAX(num)                                           AS max_24h,
       SAFE_DIVIDE(COVAR_SAMP(t_h, num), VAR_SAMP(t_h))   AS slope_24h,  -- change per hour
       COUNT(num)                                         AS n_24h       -- number of measurements in the 24 h window
FROM m
WHERE kind = 'num' AND num IS NOT NULL
GROUP BY episode_id, feature;

-- ---------------------------------------------------------------------
-- 4. Categorical variables: last value
-- ---------------------------------------------------------------------
-- Airway competence is charted in the OBSERVATION table, selected by source name
-- ("Hoeveelheid Sputum" shares its concept ID with "Kleur Sputum"):
--   secretion_amount  <- "Hoeveelheid Sputum"  (Khamiees 2001: moderate-abundant secretions)
--   cough_reflex      <- "Hoestprikkel"        (Khamiees 2001: weak cough)
CREATE OR REPLACE TABLE `project-71f189c0-e73d-403e-989.extubation.failure_feat_cat` AS
SELECT episode_id, feature,
       ARRAY_AGG(txt ORDER BY dt DESC LIMIT 1)[OFFSET(0)] AS last_val
FROM (
  SELECT episode_id, feature, dt, txt FROM m WHERE kind = 'cat' AND txt IS NOT NULL
  UNION ALL
  SELECT f.episode_id,
         CASE o.observation_source_value WHEN 'Hoeveelheid Sputum' THEN 'secretion_amount'
                                         WHEN 'Hoestprikkel'       THEN 'cough_reflex' END AS feature,
         CAST(o.observation_datetime AS DATETIME) AS dt,
         TRIM(o.value_source_value) AS txt
  FROM `project-71f189c0-e73d-403e-989.extubation.failure_cohort` f
  JOIN `amsterdamumcdb.version1_5_0.observation` o
    ON o.person_id = f.person_id
   AND CAST(o.observation_datetime AS DATETIME) >  DATETIME_SUB(f.feature_cutoff_dt, INTERVAL win_h HOUR)
   AND CAST(o.observation_datetime AS DATETIME) <= f.feature_cutoff_dt
  WHERE o.provider_id >= 0
    AND o.observation_source_value IN ('Hoeveelheid Sputum', 'Hoestprikkel')
    AND o.value_source_value IS NOT NULL
)
GROUP BY episode_id, feature;

-- ---------------------------------------------------------------------
-- 5. Label + context + suctioning (one row per extubation)
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE `project-71f189c0-e73d-403e-989.extubation.failure_feat_base` AS
WITH airway AS (
  SELECT f.episode_id,
         -- tracheobronchial suctioning / aspiration of trachea ("Aantal Bronchiaaltoilet", "Uitzuigen")
         SUM(IF(p.procedure_concept_id IN (4239191, 4043669), COALESCE(p.quantity, 1), 0)) AS suction_24h,
         -- saline instillation ("Druppelen NaCl"): a sign of thick secretions
         COUNTIF(p.procedure_concept_id = 4337734) AS saline_instill_24h
  FROM `project-71f189c0-e73d-403e-989.extubation.failure_cohort` f
  JOIN `amsterdamumcdb.version1_5_0.procedure_occurrence` p
    ON p.person_id = f.person_id
   AND CAST(p.procedure_datetime AS DATETIME) >  DATETIME_SUB(f.feature_cutoff_dt, INTERVAL win_h HOUR)
   AND CAST(p.procedure_datetime AS DATETIME) <= f.feature_cutoff_dt
  WHERE p.provider_id >= 0
    AND p.procedure_concept_id IN (4239191, 4043669, 4337734)
  GROUP BY f.episode_id
),
-- body weight is recorded at admission (usually >24 h before extubation), so it is
-- taken from the whole admission instead of the 24 h window: last value before the cutoff
wt AS (
  -- weight is an admission-level value: it may have only a date (no time) and an
  -- empty provider_id, so both are handled. Prefer a value from before the cutoff,
  -- then the one closest to the start of the admission.
  SELECT episode_id, weight_kg FROM (
    SELECT f.episode_id, x.value_as_number AS weight_kg,
           ROW_NUMBER() OVER (
             PARTITION BY f.episode_id
             ORDER BY IF(dt <= f.feature_cutoff_dt, 0, 1),
                      ABS(DATETIME_DIFF(dt, f.visit_start_datetime, MINUTE))
           ) AS rn
    FROM `project-71f189c0-e73d-403e-989.extubation.failure_cohort` f
    JOIN (
      SELECT person_id, value_as_number,
             COALESCE(CAST(measurement_datetime AS DATETIME), CAST(measurement_date AS DATETIME)) AS dt
      FROM `amsterdamumcdb.version1_5_0.measurement`
      WHERE (provider_id IS NULL OR provider_id >= 0)
        AND measurement_concept_id IN (3023166, 3026600, 3025315, 3013762)  -- body weight stated/estimated/-/measured
        AND value_as_number BETWEEN 30 AND 250                               -- plausible kg
    ) x
      ON x.person_id = f.person_id
     AND x.dt BETWEEN DATETIME_SUB(f.visit_start_datetime, INTERVAL 7 DAY)
                  AND COALESCE(f.visit_end_datetime, f.feature_cutoff_dt)
  )
  WHERE rn = 1
),
ht AS (
  -- height: same approach as weight; also an admission-level value (often a class midpoint)
  -- weight is an admission-level value: it may have only a date (no time) and an
  -- empty provider_id, so both are handled. Prefer a value from before the cutoff,
  -- then the one closest to the start of the admission.
  SELECT episode_id, height_cm FROM (
    SELECT f.episode_id, x.value_as_number AS height_cm,
           ROW_NUMBER() OVER (
             PARTITION BY f.episode_id
             ORDER BY IF(dt <= f.feature_cutoff_dt, 0, 1),
                      ABS(DATETIME_DIFF(dt, f.visit_start_datetime, MINUTE))
           ) AS rn
    FROM `project-71f189c0-e73d-403e-989.extubation.failure_cohort` f
    JOIN (
      SELECT person_id, value_as_number,
             COALESCE(CAST(measurement_datetime AS DATETIME), CAST(measurement_date AS DATETIME)) AS dt
      FROM `amsterdamumcdb.version1_5_0.measurement`
      WHERE (provider_id IS NULL OR provider_id >= 0)
        AND measurement_concept_id IN (3019171, 3035463, 3036277, 3023540)  -- body height (source name 'height')
        AND value_as_number BETWEEN 120 AND 220                              -- plausible cm
    ) x
      ON x.person_id = f.person_id
     AND x.dt BETWEEN DATETIME_SUB(f.visit_start_datetime, INTERVAL 7 DAY)
                  AND COALESCE(f.visit_end_datetime, f.feature_cutoff_dt)
  )
  WHERE rn = 1
)
SELECT f.person_id, f.episode_id, f.failure, f.died_without_reintubation,
       f.duration_h AS hours_on_vent,
       DATETIME_DIFF(f.feature_cutoff_dt, CAST(v.visit_start_datetime AS DATETIME), MINUTE) / 60 AS hours_since_admission,
       EXTRACT(YEAR FROM CAST(v.visit_start_datetime AS DATETIME)) - pe.year_of_birth AS age,  -- check: dates are shifted
       pe.gender_concept_id = 8507 AS is_male,
       IFNULL(a.suction_24h, 0)        AS suction_24h,
       IFNULL(a.saline_instill_24h, 0) AS saline_instill_24h,
       w.weight_kg,                              -- kg (admission weight, often a weight class midpoint)
       h.height_cm,                              -- cm (admission height, often a class midpoint)
       w.weight_kg / POW(h.height_cm / 100, 2) AS bmi,
       u.urine_output_24h,                       -- mL in the 24 h before the cutoff, NULL = nothing registered
       u.urine_output_24h / NULLIF(u.urine_hours, 0) AS urine_output_ml_h   -- mean mL/h over the registered period
FROM `project-71f189c0-e73d-403e-989.extubation.failure_cohort` f
JOIN `amsterdamumcdb.version1_5_0.visit_occurrence` v ON v.visit_occurrence_id = f.visit_occurrence_id
JOIN `amsterdamumcdb.version1_5_0.person` pe ON pe.person_id = f.person_id
LEFT JOIN airway a ON a.episode_id = f.episode_id
LEFT JOIN wt w ON w.episode_id = f.episode_id
LEFT JOIN ht h ON h.episode_id = f.episode_id
LEFT JOIN (
  SELECT episode_id, SUM(num) AS urine_output_24h,
         -- hours from the first registration in the window to the cutoff (at least 1)
         GREATEST(-MIN(t_h), 1) AS urine_hours
  FROM m WHERE kind = 'sum' AND num IS NOT NULL
  GROUP BY episode_id
) u ON u.episode_id = f.episode_id;
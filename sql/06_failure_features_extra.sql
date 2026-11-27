-- =====================================================================
-- Extra risk-factor features for the failure model (one row per extubation)
-- Run after 03_failure_features_filled.sql. prepare_failure_data.py merges it.
-- Project: project-71f189c0-e73d-403e-989. Timestamps cast to DATETIME to match failure_cohort.
-- =====================================================================

DECLARE win_h   INT64 DEFAULT 24;  -- look-back window (hours)
DECLARE short_h INT64 DEFAULT 6;   -- "currently running" window for drugs (hours)

CREATE TEMP TABLE coh AS
SELECT f.person_id, f.episode_id,
       f.feature_cutoff_dt AS cutoff,
       f.intubation_dt,
       CAST(v.visit_start_datetime AS DATETIME) AS adm_start,
       v.admitted_from_source_value
FROM `project-71f189c0-e73d-403e-989.extubation.failure_cohort` f
JOIN `amsterdamumcdb.version1_5_0.visit_occurrence` v ON v.visit_occurrence_id = f.visit_occurrence_id;

-- ---------------------------------------------------------------------
-- 1. Admission diagnoses (APACHE-style, recorded at admission; concept IDs from E1/E2)
-- ---------------------------------------------------------------------
CREATE TEMP TABLE dx AS
SELECT c.episode_id,
  LOGICAL_OR(co.condition_concept_id IN (257004, 317009, 257581, 45769438, 4110048, 4050961)) AS dx_copd_asthma,
  LOGICAL_OR(co.condition_concept_id IN (319835, 4023479, 321319))          AS dx_heart_failure,  -- incl. cardiomyopathy
  LOGICAL_OR(co.condition_concept_id IN (44812002, 76685, 4164770))         AS dx_neuromuscular,  -- incl. myasthenia, Guillain-Barre
  LOGICAL_OR(co.condition_concept_id IN (44783658, 4120088))                AS dx_cardiac_arrest,
  LOGICAL_OR(co.condition_concept_id = 132797)                              AS dx_sepsis,
  LOGICAL_OR(co.condition_concept_id IN (255848, 257315, 4170143, 4112341)) AS dx_pneumonia,      -- incl. respiratory infection
  LOGICAL_OR(co.condition_concept_id = 4256228)                             AS dx_resp_failure,
  LOGICAL_OR(co.condition_concept_id IN (4132546, 381316))                  AS dx_brain_injury_stroke,
  -- admission type from the diagnosis prefix
  LOGICAL_OR(REGEXP_CONTAINS(co.condition_source_value, r'^(Post-operative|Post-operatief|Operatief)')) AS surgical,
  LOGICAL_OR(REGEXP_CONTAINS(co.condition_source_value, r'^(Non-operative|Non-operatief)'))            AS nonsurgical
FROM coh c
JOIN `amsterdamumcdb.version1_5_0.condition_occurrence` co
  ON co.person_id = c.person_id
 AND CAST(co.condition_start_datetime AS DATETIME) BETWEEN DATETIME_SUB(c.adm_start, INTERVAL 1 DAY) AND c.cutoff
GROUP BY c.episode_id;

-- ---------------------------------------------------------------------
-- 2. Bedside observations stored as conditions, last 24 h before the cutoff
-- ---------------------------------------------------------------------
CREATE TEMP TABLE obs AS
SELECT c.episode_id,
  LOGICAL_OR(co.condition_concept_id = 4102774) AS productive_cough_24h,   -- "Productief"
  LOGICAL_OR(co.condition_concept_id = 373995)  AS delirium_pos_24h,       -- delirium screen "POSITIEF"
  LOGICAL_OR(co.condition_concept_id = 313217)  AS atrial_fib_24h,
  -- muscle strength on the MRC scale (0-5), weakest recorded value = ICU-acquired weakness
  MIN(CASE co.condition_concept_id
        WHEN 4093685 THEN 5   -- movement against resistance ("Normale kracht")
        WHEN 4179292 THEN 4   -- against resistance, incomplete ("Lichte parese")
        WHEN 4092731 THEN 3   -- against gravity ("Zware parese")
        WHEN 4097166 THEN 2   -- with gravity eliminated
        WHEN 4093683 THEN 1   -- visible contraction only
        WHEN 4092729 THEN 0   -- no contraction
      END) AS muscle_strength_min_24h
FROM coh c
JOIN `amsterdamumcdb.version1_5_0.condition_occurrence` co
  ON co.person_id = c.person_id
 AND CAST(co.condition_start_datetime AS DATETIME) >  DATETIME_SUB(c.cutoff, INTERVAL win_h HOUR)
 AND CAST(co.condition_start_datetime AS DATETIME) <= c.cutoff
WHERE co.condition_concept_id IN (4102774, 373995, 313217,
                                  4093685, 4179292, 4092731, 4097166, 4093683, 4092729)
GROUP BY c.episode_id;

-- ---------------------------------------------------------------------
-- 3. Medication overlapping the 24 h before the cutoff (ingredient IDs from E5)
-- ---------------------------------------------------------------------
CREATE TEMP TABLE ingr AS
SELECT * FROM UNNEST(ARRAY<STRUCT<ingredient_id INT64, grp STRING>>[
  (1321341,  'norepinephrine'),
  (1337720,  'inotrope'), (1337860, 'inotrope'), (1343916, 'inotrope'),  -- dobutamine, dopamine, epinephrine
  (753626,   'propofol'),
  (708298,   'midazolam'),
  (791967,   'lorazepam'),
  (1154029,  'opioid'), (1110410, 'opioid'), (19016749, 'opioid'),       -- fentanyl, morphine, remifentanil
  (1398937,  'clonidine'),
  (766529,   'haloperidol'),
  (956874,   'furosemide'),
  (1518254,  'dexamethasone'),                                           -- often given to prevent laryngeal edema
  (975125,   'other_steroid'), (1550557, 'other_steroid'), (1506270, 'other_steroid')
]);

CREATE TEMP TABLE rx AS
SELECT DISTINCT c.episode_id, c.cutoff, i.grp,
       COALESCE(CAST(d.drug_exposure_end_datetime AS DATETIME), CAST(d.drug_exposure_start_datetime AS DATETIME)) AS e
FROM coh c
JOIN `amsterdamumcdb.version1_5_0.drug_exposure` d
  ON d.person_id = c.person_id
 AND CAST(d.drug_exposure_start_datetime AS DATETIME) <= c.cutoff
 AND COALESCE(CAST(d.drug_exposure_end_datetime AS DATETIME), CAST(d.drug_exposure_start_datetime AS DATETIME))
       > DATETIME_SUB(c.cutoff, INTERVAL win_h HOUR)
JOIN `amsterdamumcdb.version1_5_0.concept_ancestor` ca ON ca.descendant_concept_id = d.drug_concept_id
JOIN ingr i ON i.ingredient_id = ca.ancestor_concept_id;

CREATE TEMP TABLE meds AS
SELECT episode_id,
  -- "running in the last 6 h"
  LOGICAL_OR(grp = 'norepinephrine' AND e > DATETIME_SUB(cutoff, INTERVAL short_h HOUR)) AS norepi_6h,
  LOGICAL_OR(grp = 'inotrope'       AND e > DATETIME_SUB(cutoff, INTERVAL short_h HOUR)) AS inotrope_6h,
  LOGICAL_OR(grp = 'propofol'       AND e > DATETIME_SUB(cutoff, INTERVAL short_h HOUR)) AS propofol_6h,
  LOGICAL_OR(grp = 'midazolam'      AND e > DATETIME_SUB(cutoff, INTERVAL short_h HOUR)) AS midazolam_6h,
  LOGICAL_OR(grp = 'opioid'         AND e > DATETIME_SUB(cutoff, INTERVAL short_h HOUR)) AS opioid_6h,
  -- "given in the last 24 h"
  LOGICAL_OR(grp = 'lorazepam')     AS lorazepam_24h,
  LOGICAL_OR(grp = 'clonidine')     AS clonidine_24h,
  LOGICAL_OR(grp = 'haloperidol')   AS haloperidol_24h,
  LOGICAL_OR(grp = 'furosemide')    AS furosemide_24h,
  LOGICAL_OR(grp = 'dexamethasone') AS dexamethasone_24h,
  LOGICAL_OR(grp = 'other_steroid') AS other_steroid_24h,
  -- hours since propofol/midazolam was last running (0 = still running at the cutoff)
  MIN(IF(grp IN ('propofol', 'midazolam'),
         GREATEST(DATETIME_DIFF(cutoff, e, MINUTE) / 60, 0), NULL)) AS hours_since_sedation
FROM rx
GROUP BY episode_id;

-- ---------------------------------------------------------------------
-- 3b. Sedation days: calendar days between intubation and cutoff with propofol or
--     midazolam running (each exposure is clipped to that window)
-- ---------------------------------------------------------------------
CREATE TEMP TABLE sed AS
SELECT episode_id, COUNT(DISTINCT day) AS sedation_days
FROM (
  SELECT c.episode_id, day
  FROM coh c
  JOIN `amsterdamumcdb.version1_5_0.drug_exposure` d
    ON d.person_id = c.person_id
   AND CAST(d.drug_exposure_start_datetime AS DATETIME) <= c.cutoff
   AND COALESCE(CAST(d.drug_exposure_end_datetime AS DATETIME), CAST(d.drug_exposure_start_datetime AS DATETIME)) >= c.intubation_dt
  JOIN `amsterdamumcdb.version1_5_0.concept_ancestor` ca ON ca.descendant_concept_id = d.drug_concept_id
  JOIN ingr i ON i.ingredient_id = ca.ancestor_concept_id AND i.grp IN ('propofol', 'midazolam'),
  UNNEST(GENERATE_DATE_ARRAY(
    DATE(GREATEST(CAST(d.drug_exposure_start_datetime AS DATETIME), c.intubation_dt)),
    DATE(LEAST(COALESCE(CAST(d.drug_exposure_end_datetime AS DATETIME), CAST(d.drug_exposure_start_datetime AS DATETIME)), c.cutoff)))) AS day
)
GROUP BY episode_id;

-- ---------------------------------------------------------------------
-- 3c. APACHE (charted at admission, observation table):
--     APACHE II score, APACHE II main group (operative / non-operative) and APACHE IV group
-- ---------------------------------------------------------------------
CREATE TEMP TABLE apache AS
SELECT c.episode_id,
  -- first score of the admission; three source names are used for the APACHE II score
  ARRAY_AGG(IF(o.observation_source_value IN ('A_Apache_Score', 'NICE Apache II Score', 'MCA_Apache_Score')
               AND o.value_as_number BETWEEN 0 AND 71, o.value_as_number, NULL)
            IGNORE NULLS ORDER BY o.observation_datetime LIMIT 1)[SAFE_OFFSET(0)] AS apache_ii_score,
  ARRAY_AGG(IF(o.observation_source_value = 'Apache II Hoofdgroep', o.value_source_value, NULL)
            IGNORE NULLS ORDER BY o.observation_datetime LIMIT 1)[SAFE_OFFSET(0)] AS apache_ii_group,
  ARRAY_AGG(IF(o.observation_source_value = 'APACHE IV Groepen', o.value_source_value, NULL)
            IGNORE NULLS ORDER BY o.observation_datetime LIMIT 1)[SAFE_OFFSET(0)] AS apache_iv_group
FROM coh c
JOIN `amsterdamumcdb.version1_5_0.observation` o
  ON o.person_id = c.person_id
 AND CAST(o.observation_datetime AS DATETIME) BETWEEN DATETIME_SUB(c.adm_start, INTERVAL 1 DAY) AND c.cutoff
WHERE o.provider_id >= 0
  AND o.observation_source_value IN ('A_Apache_Score', 'NICE Apache II Score', 'MCA_Apache_Score',
                                     'Apache II Hoofdgroep', 'APACHE IV Groepen')
GROUP BY c.episode_id;

-- ---------------------------------------------------------------------
-- 4. One row per extubation
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE `project-71f189c0-e73d-403e-989.extubation.failure_feat_extra` AS
SELECT c.episode_id,
  CASE
    WHEN c.admitted_from_source_value IS NULL                                     THEN 'unknown'
    WHEN REGEXP_CONTAINS(c.admitted_from_source_value, r'ander ziekenhuis')         THEN 'other_hospital'
    WHEN REGEXP_CONTAINS(c.admitted_from_source_value, r'^Eerste Hulp')             THEN 'emergency'
    WHEN REGEXP_CONTAINS(c.admitted_from_source_value, r'^(Verpleegafdeling|Andere locatie)') THEN 'ward'
    WHEN REGEXP_CONTAINS(c.admitted_from_source_value, r'^(CCU/IC|Special/Medium|Recovery)')  THEN 'icu_ccu_recovery'
    ELSE 'other'
  END AS admitted_from,
  -- surgical admission: APACHE II main group ("Operatief ..." / "Non-Operatief ..."),
  -- otherwise the diagnosis prefix; NULL = unknown
  CASE WHEN STARTS_WITH(ap.apache_ii_group, 'Operatief') THEN 1
       WHEN STARTS_WITH(ap.apache_ii_group, 'Non-Operatief') THEN 0
       WHEN dx.surgical THEN 1 WHEN dx.nonsurgical THEN 0 END AS adm_surgical,
  ap.apache_ii_score,                                  -- NULL = not charted
  ap.apache_iv_group AS admission_reason,              -- e.g. "Non-operative respiratory" (proxy for reason for intubation)
  IFNULL(sd.sedation_days, 0) AS sedation_days,        -- days with propofol/midazolam since intubation
  -- diagnosis and observation flags: no record = FALSE
  IFNULL(dx.dx_copd_asthma, FALSE)         AS dx_copd_asthma,
  IFNULL(dx.dx_heart_failure, FALSE)       AS dx_heart_failure,
  IFNULL(dx.dx_neuromuscular, FALSE)       AS dx_neuromuscular,
  IFNULL(dx.dx_cardiac_arrest, FALSE)      AS dx_cardiac_arrest,
  IFNULL(dx.dx_sepsis, FALSE)              AS dx_sepsis,
  IFNULL(dx.dx_pneumonia, FALSE)           AS dx_pneumonia,
  IFNULL(dx.dx_resp_failure, FALSE)        AS dx_resp_failure,
  IFNULL(dx.dx_brain_injury_stroke, FALSE) AS dx_brain_injury_stroke,
  IFNULL(o.productive_cough_24h, FALSE)    AS productive_cough_24h,
  IFNULL(o.delirium_pos_24h, FALSE)        AS delirium_pos_24h,
  IFNULL(o.atrial_fib_24h, FALSE)          AS atrial_fib_24h,
  o.muscle_strength_min_24h,                                                  -- NULL = not assessed
  -- medication flags: no record = FALSE
  IFNULL(m.norepi_6h, FALSE)         AS norepi_6h,
  IFNULL(m.inotrope_6h, FALSE)       AS inotrope_6h,
  IFNULL(m.propofol_6h, FALSE)       AS propofol_6h,
  IFNULL(m.midazolam_6h, FALSE)      AS midazolam_6h,
  IFNULL(m.opioid_6h, FALSE)         AS opioid_6h,
  IFNULL(m.lorazepam_24h, FALSE)     AS lorazepam_24h,
  IFNULL(m.clonidine_24h, FALSE)     AS clonidine_24h,
  IFNULL(m.haloperidol_24h, FALSE)   AS haloperidol_24h,
  IFNULL(m.furosemide_24h, FALSE)    AS furosemide_24h,
  IFNULL(m.dexamethasone_24h, FALSE) AS dexamethasone_24h,
  IFNULL(m.other_steroid_24h, FALSE) AS other_steroid_24h,
  IFNULL(m.hours_since_sedation, win_h) AS hours_since_sedation               -- capped at 24 h
FROM coh c
LEFT JOIN dx  ON dx.episode_id = c.episode_id
LEFT JOIN obs o ON o.episode_id = c.episode_id
LEFT JOIN meds m ON m.episode_id = c.episode_id
LEFT JOIN apache ap ON ap.episode_id = c.episode_id
LEFT JOIN sed sd ON sd.episode_id = c.episode_id;

-- Quick check: how often is each flag TRUE? (sent to the results panel)
SELECT
  COUNT(*) AS n,
  COUNTIF(adm_surgical = 1) AS n_surgical, COUNTIF(adm_surgical = 0) AS n_nonsurgical,
  COUNTIF(dx_copd_asthma) AS copd_asthma, COUNTIF(dx_heart_failure) AS heart_failure,
  COUNTIF(dx_cardiac_arrest) AS cardiac_arrest, COUNTIF(dx_sepsis) AS sepsis,
  COUNTIF(productive_cough_24h) AS productive_cough, COUNTIF(delirium_pos_24h) AS delirium,
  COUNTIF(muscle_strength_min_24h IS NOT NULL) AS muscle_assessed,
  COUNTIF(norepi_6h) AS norepi, COUNTIF(propofol_6h) AS propofol, COUNTIF(midazolam_6h) AS midazolam,
  COUNTIF(dexamethasone_24h) AS dexamethasone,
  ROUND(AVG(hours_since_sedation), 1) AS mean_hours_since_sedation,
  COUNTIF(adm_surgical IS NULL) AS surgical_unknown,
  COUNTIF(apache_ii_score IS NOT NULL) AS apache_ii_available,
  COUNTIF(admission_reason IS NOT NULL) AS admission_reason_available,
  ROUND(AVG(sedation_days), 1) AS mean_sedation_days
FROM `project-71f189c0-e73d-403e-989.extubation.failure_feat_extra`;

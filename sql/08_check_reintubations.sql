-- =====================================================================
-- Label check: what happens around the reintubations (failure = TRUE)?
-- Looks for label noise: reintubation for surgery/procedures, tube exchanges,
-- reintubation after leaving the ICU, and unplanned (self-)extubations.
-- Read-only (only a TEMP table). Run the whole script once, then click
-- "View results" on each of the 4 SELECT statements at the bottom (A, B, C, D).
-- Adapted from the ExpertRuleFit pipeline to 01_build_cohorts.sql v2:
-- tube records by concept ID (same as 01), failure is TRUE/FALSE, project ID filled in.
-- =====================================================================

DECLARE ett_device_ids ARRAY<INT64> DEFAULT [4097216];   -- same as 01_build_cohorts.sql

-- first tube record that starts after the extubation, within 48 h (= the reintubation)
CREATE TEMP TABLE reint AS
SELECT f.person_id, f.episode_id, f.visit_occurrence_id AS extub_visit,
       f.extubation_dt, f.visit_end_datetime,
       r.start_dt AS reint_dt, r.visit_occurrence_id AS reint_visit, r.source_name,
       DATETIME_DIFF(r.start_dt, f.extubation_dt, MINUTE) / 60 AS hours_to_reint
FROM `project-71f189c0-e73d-403e-989.extubation.failure_cohort` f
JOIN (
  SELECT d.person_id, d.visit_occurrence_id,
         CAST(d.device_exposure_start_datetime AS DATETIME) AS start_dt,
         d.device_source_value AS source_name
  FROM `amsterdamumcdb.version1_5_0.device_exposure` d
  WHERE d.device_concept_id IN UNNEST(ett_device_ids)
) r
  ON r.person_id = f.person_id
 AND r.start_dt > f.extubation_dt
 AND r.start_dt <= DATETIME_ADD(f.extubation_dt, INTERVAL 48 HOUR)
WHERE f.failure
QUALIFY ROW_NUMBER() OVER (PARTITION BY f.episode_id ORDER BY r.start_dt) = 1;

-- A. Timing and setting of the reintubations
--    n_failures_found should equal the number of failures in the flowchart (row 16)
SELECT
  COUNT(*)                                                   AS n_failures_found,
  COUNTIF(hours_to_reint < 1)                                AS within_1h,   -- only across admissions: gaps < 60 min are merged in 01
  COUNTIF(hours_to_reint >= 1  AND hours_to_reint < 6)       AS h1_6,
  COUNTIF(hours_to_reint >= 6  AND hours_to_reint < 24)      AS h6_24,
  COUNTIF(hours_to_reint >= 24)                              AS h24_48,
  COUNTIF(reint_visit != extub_visit)                        AS reintubated_in_other_admission,
  COUNTIF(visit_end_datetime IS NOT NULL AND reint_dt > visit_end_datetime) AS reintubated_after_leaving_icu,
  APPROX_QUANTILES(hours_to_reint, 4)                        AS hours_quartiles
FROM reint;

-- B. Most frequent procedures in the 12 h before until 1 h after the reintubation
--    (surgery / OR / bronchoscopy / imaging point to a procedural reintubation)
SELECT p.procedure_source_value, c.concept_name,
       COUNT(DISTINCT r.episode_id) AS n_failures_with_this
FROM reint r
JOIN `amsterdamumcdb.version1_5_0.procedure_occurrence` p
  ON p.person_id = r.person_id
 AND CAST(p.procedure_datetime AS DATETIME) BETWEEN DATETIME_SUB(r.reint_dt, INTERVAL 12 HOUR)
                                                AND DATETIME_ADD(r.reint_dt, INTERVAL 1 HOUR)
LEFT JOIN `amsterdamumcdb.version1_5_0.concept` c ON c.concept_id = p.procedure_concept_id
WHERE p.provider_id >= 0
GROUP BY 1, 2
ORDER BY n_failures_with_this DESC
LIMIT 40;

-- C. Which tube records mark the reintubation (check that they are real ETT intubations)
SELECT source_name, COUNT(*) AS n
FROM reint
GROUP BY 1
ORDER BY n DESC
LIMIT 20;

-- D. Registrations that may mark an UNPLANNED extubation, around the extubation (-2 h to +2 h),
--    for the extubations in the main analysis
SELECT 'observation' AS source_table, o.observation_source_value AS item, o.value_source_value AS value,
       COUNT(DISTINCT f.episode_id) AS n_extubations,
       COUNT(DISTINCT IF(f.failure, f.episode_id, NULL)) AS n_failures
FROM `project-71f189c0-e73d-403e-989.extubation.failure_cohort` f
JOIN `amsterdamumcdb.version1_5_0.observation` o
  ON o.person_id = f.person_id
 AND CAST(o.observation_datetime AS DATETIME) BETWEEN DATETIME_SUB(f.extubation_dt, INTERVAL 2 HOUR)
                                                  AND DATETIME_ADD(f.extubation_dt, INTERVAL 2 HOUR)
WHERE o.provider_id >= 0
  AND NOT f.died_without_reintubation
  AND REGEXP_CONTAINS(LOWER(CONCAT(IFNULL(o.observation_source_value, ''), ' ', IFNULL(o.value_source_value, ''))),
                      r'extub|detub|zelf|accident|onbedoeld|ongepland')
GROUP BY 1, 2, 3
UNION ALL
SELECT 'procedure', p.procedure_source_value, CAST(NULL AS STRING),
       COUNT(DISTINCT f.episode_id), COUNT(DISTINCT IF(f.failure, f.episode_id, NULL))
FROM `project-71f189c0-e73d-403e-989.extubation.failure_cohort` f
JOIN `amsterdamumcdb.version1_5_0.procedure_occurrence` p
  ON p.person_id = f.person_id
 AND CAST(p.procedure_datetime AS DATETIME) BETWEEN DATETIME_SUB(f.extubation_dt, INTERVAL 2 HOUR)
                                                AND DATETIME_ADD(f.extubation_dt, INTERVAL 2 HOUR)
WHERE p.provider_id >= 0
  AND NOT f.died_without_reintubation
  AND REGEXP_CONTAINS(LOWER(p.procedure_source_value), r'extub|detub|zelf|accident|onbedoeld|ongepland')
GROUP BY 1, 2, 3
ORDER BY n_extubations DESC
LIMIT 30;

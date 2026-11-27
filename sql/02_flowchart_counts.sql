-- =====================================================================
-- Cohort flowchart + key numbers for the slide
-- =====================================================================
-- Project ID already filled in. Run after 01_build_cohorts.sql (v2).
-- Hard-coded values: 24 h landmark.

-- ---------------------------------------------------------------------
-- Query 1: flowchart (exclusions are counted in order, so the numbers add up)
-- ---------------------------------------------------------------------
WITH e AS (
  SELECT * FROM `project-71f189c0-e73d-403e-989.extubation.episodes` WHERE ep_in_visit = 1   -- first episode per admission
),
f AS (SELECT * FROM `project-71f189c0-e73d-403e-989.extubation.failure_cohort`)
SELECT * FROM (
  SELECT 1 AS nr, 'All ICU/MC admissions' AS step,
         COUNT(*) AS n FROM `amsterdamumcdb.version1_5_0.visit_occurrence`
  UNION ALL
  SELECT 2, 'Invasive ventilation (ETT) episodes, all', COUNT(*) FROM `project-71f189c0-e73d-403e-989.extubation.episodes`
  UNION ALL
  SELECT 3, '  excluded: not first episode of admission', COUNTIF(ep_in_visit > 1) FROM `project-71f189c0-e73d-403e-989.extubation.episodes`
  UNION ALL
  SELECT 4, 'First episodes (= admissions with ventilation)', COUNT(*) FROM e
  UNION ALL
  SELECT 5, '  excluded: first episode < 24 h', COUNTIF(duration_h < 24) FROM e
  UNION ALL
  SELECT 6, '  excluded: tracheostomy before episode', COUNTIF(duration_h >= 24 AND trach_before) FROM e
  UNION ALL
  SELECT 7, '  excluded: not first eligible admission of patient',
         (SELECT COUNTIF(duration_h >= 24 AND NOT trach_before) FROM e)
         - (SELECT COUNT(*) FROM `project-71f189c0-e73d-403e-989.extubation.base_cohort`)
  UNION ALL
  SELECT 8, 'BASE COHORT (= clinician cohort episodes)', COUNT(*) FROM `project-71f189c0-e73d-403e-989.extubation.base_cohort`
  UNION ALL
  SELECT 9, '  ended in: extubation', COUNTIF(end_type = 'extubation') FROM `project-71f189c0-e73d-403e-989.extubation.base_cohort`
  UNION ALL
  SELECT 10, '  ended in: tracheostomy', COUNTIF(end_type = 'tracheostomy') FROM `project-71f189c0-e73d-403e-989.extubation.base_cohort`
  UNION ALL
  SELECT 11, '  ended in: death on ventilator', COUNTIF(end_type = 'death_on_vent') FROM `project-71f189c0-e73d-403e-989.extubation.base_cohort`
  UNION ALL
  SELECT 12, '  ended in: left ICU intubated', COUNTIF(end_type = 'left_icu_intubated') FROM `project-71f189c0-e73d-403e-989.extubation.base_cohort`
  UNION ALL
  SELECT 13, '  ended in: self-extubation',
         COUNTIF(end_type = 'unplanned_extubation') FROM `project-71f189c0-e73d-403e-989.extubation.base_cohort`
  UNION ALL
  SELECT 14, '  excluded from failure cohort: died < 48 h without reintubation',
         COUNTIF(died_without_reintubation) FROM f
  UNION ALL
  SELECT 15, 'FAILURE COHORT (planned extubations)', COUNTIF(NOT died_without_reintubation) FROM f
  UNION ALL
  SELECT 16, '  failures (reintubation < 48 h)', COUNTIF(failure AND NOT died_without_reintubation) FROM f
)
ORDER BY nr;

-- ---------------------------------------------------------------------
-- Query 2: key numbers per cohort
-- ---------------------------------------------------------------------
-- Failure cohort: size, failure rate, ventilation duration (median + IQR)
SELECT
  COUNT(*)                                        AS n_extubations,
  COUNTIF(failure)                                AS n_failures,
  ROUND(100 * AVG(CAST(failure AS INT64)), 1)     AS failure_pct,
  ROUND(ANY_VALUE(q1), 1)  AS vent_h_q1,
  ROUND(ANY_VALUE(med), 1) AS vent_h_median,
  ROUND(ANY_VALUE(q3), 1)  AS vent_h_q3
FROM (
  SELECT *,
         PERCENTILE_CONT(duration_h, 0.25) OVER () AS q1,
         PERCENTILE_CONT(duration_h, 0.50) OVER () AS med,
         PERCENTILE_CONT(duration_h, 0.75) OVER () AS q3
  FROM `project-71f189c0-e73d-403e-989.extubation.failure_cohort`
  WHERE NOT died_without_reintubation
);

-- Clinician cohort: rows, episodes, share of positive 4-h blocks
SELECT
  COUNT(*)                                                 AS n_rows,
  COUNT(DISTINCT episode_id)                               AS n_episodes,
  COUNTIF(extubated_next_block)                            AS n_positive_rows,
  ROUND(100 * AVG(CAST(extubated_next_block AS INT64)), 1) AS positive_pct
FROM `project-71f189c0-e73d-403e-989.extubation.clinician_cohort`;

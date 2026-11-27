-- =====================================================================
-- Extubation cohorts: AmsterdamUMCdb v1.5.0 (OMOP CDM 5.4) on BigQuery
-- =====================================================================
-- Project ID already filled in: paste the whole script in BigQuery and run it.
-- v2 (shared version for both models):
--   - extubations with a bedside registration of self-extubation ("Autodetubatie")
--     within 2 h are excluded (not a planned extubation), and a
--     registration of a tracheostomy within 2 h counts as 'tracheostomy'
--     (idea from the ExpertRuleFit pipeline, STEP 4)
--   - failure_cohort also has visit_start_datetime / visit_end_datetime
--     (needed by 03_failure_features.sql for weight and height)
--
-- Output tables:
--   extubation.vent_episodes     one row per invasive ventilation (ETT) episode
--   extubation.episodes          + end type, reintubation, death
--   extubation.base_cohort       first episode per admission, >= 24 h, 1 per patient
--   extubation.failure_cohort    one row per planned extubation  (failure model)
--   extubation.clinician_cohort  one row per 4-h block while intubated (clinician model)

-- ---------------------------------------------------------------------
-- STEP 1: parameters
-- ---------------------------------------------------------------------
-- From 00_explore_concepts.sql results:
DECLARE ett_device_ids   ARRAY<INT64> DEFAULT [4097216];            -- Endotracheal tube ("Tube" + older "Niet meer gebruiken ... Tube" items)
DECLARE trach_device_ids ARRAY<INT64> DEFAULT [4044008, 45772284];  -- Tracheostomy tube; tracheostomy speech valve (only exists with a trach)
DECLARE trach_proc_ids   ARRAY<INT64> DEFAULT [4134745, 44783799, 4262010, 3655949];
                         -- percutaneous tracheostomy; exteriorization of trachea; trach care; speaking valve placement

DECLARE trach_window_h INT64 DEFAULT 24; -- trach within 24 h after the tube ends = tube was replaced by a trach
DECLARE merge_gap_min INT64 DEFAULT 60;  -- tube records less than 60 min apart = same episode
DECLARE min_vent_h    INT64 DEFAULT 24;  -- landmark: still ventilated at 24 h
DECLARE outcome_h     INT64 DEFAULT 48;  -- reintubation window
DECLARE block_h       INT64 DEFAULT 4;   -- clinician model: one row per 4 h, label = extubated within 4 h
-- bedside registrations (observation_source_value, lower case) around the tube end
-- self-extubation form ("Autodetubatie - ..."). Not "Accidentele verwijdering": that item is about
-- accidental removal of ANY device (in this cohort only an arterial line), not the tube
DECLARE unplanned_pattern  STRING DEFAULT r'autodetubatie';
DECLARE trach_obs_pattern  STRING DEFAULT r'tracheoto|tracheosto';                    -- tube removed for a tracheostomy
DECLARE unplanned_window_h INT64  DEFAULT 2;                                          -- +/- 2 h around the tube end

ASSERT ARRAY_LENGTH(ett_device_ids) > 0 AS 'Fill in ett_device_ids first (see 00_explore_concepts.sql)';

-- ---------------------------------------------------------------------
-- STEP 2: tube records -> ventilation episodes
-- Overlapping or nearly adjacent tube records (e.g. a tube exchange or a
-- documentation artifact) are merged into one episode ("gaps and islands").
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE `project-71f189c0-e73d-403e-989.extubation.vent_episodes` AS
WITH ett AS (
  -- DISTINCT: identical duplicate tube records (same start AND end) would make the
  -- ordering below ambiguous and create spurious episodes numbered 0
  -- source times are TIMESTAMP: cast to DATETIME here, so every cohort table (and the
  -- feature scripts 03/06, which cast to DATETIME as well) uses one type
  SELECT DISTINCT d.person_id, d.visit_occurrence_id,
         CAST(d.device_exposure_start_datetime AS DATETIME) AS s,
         -- missing end time: tube still in at the end of the admission
         CAST(COALESCE(d.device_exposure_end_datetime, v.visit_end_datetime) AS DATETIME) AS e
  FROM `amsterdamumcdb.version1_5_0.device_exposure` d
  JOIN `amsterdamumcdb.version1_5_0.visit_occurrence` v ON v.visit_occurrence_id = d.visit_occurrence_id
  WHERE d.device_concept_id IN UNNEST(ett_device_ids)
),
flagged AS (
  SELECT *,
         MAX(e) OVER (PARTITION BY visit_occurrence_id ORDER BY s, e
                      ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prev_end
  FROM ett
  WHERE e > s
),
islands AS (
  SELECT *,
         SUM(IF(prev_end IS NULL OR DATETIME_DIFF(s, prev_end, MINUTE) > merge_gap_min, 1, 0))
           OVER (PARTITION BY visit_occurrence_id ORDER BY s, e
                 ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS ep_in_visit
  FROM flagged
)
SELECT person_id, visit_occurrence_id, ep_in_visit,
       CONCAT(CAST(visit_occurrence_id AS STRING), '-', CAST(ep_in_visit AS STRING)) AS episode_id,
       MIN(s) AS start_dt,
       MAX(e) AS end_dt
FROM islands
GROUP BY person_id, visit_occurrence_id, ep_in_visit;

-- ---------------------------------------------------------------------
-- STEP 3: how did each episode end?
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE `project-71f189c0-e73d-403e-989.extubation.episodes` AS
WITH trach AS (
  SELECT person_id, CAST(device_exposure_start_datetime AS DATETIME) AS t
  FROM `amsterdamumcdb.version1_5_0.device_exposure`
  WHERE device_concept_id IN UNNEST(trach_device_ids)
  UNION ALL
  SELECT person_id, CAST(procedure_datetime AS DATETIME) AS t
  FROM `amsterdamumcdb.version1_5_0.procedure_occurrence`
  WHERE provider_id >= 0                      -- required partition filter
    AND procedure_concept_id IN UNNEST(trach_proc_ids)
),
ep AS (
  SELECT e.*,
         DATETIME_DIFF(e.end_dt, e.start_dt, MINUTE) / 60 AS duration_h,
         -- next tube episode of the same patient, across admissions,
         -- so an ICU readmission with reintubation is also caught
         LEAD(e.start_dt) OVER (PARTITION BY e.person_id ORDER BY e.start_dt) AS next_start,
         CAST(v.visit_start_datetime AS DATETIME) AS visit_start_datetime,
         CAST(v.visit_end_datetime AS DATETIME)   AS visit_end_datetime,
         CAST(d.death_datetime AS DATETIME)       AS death_datetime  -- check with query 0e that times are filled in
  FROM `project-71f189c0-e73d-403e-989.extubation.vent_episodes` e
  JOIN `amsterdamumcdb.version1_5_0.visit_occurrence` v ON v.visit_occurrence_id = e.visit_occurrence_id
  LEFT JOIN `amsterdamumcdb.version1_5_0.death` d ON d.person_id = e.person_id
),
tr AS (
  SELECT ep.episode_id,
         LOGICAL_OR(t.t BETWEEN ep.start_dt AND DATETIME_ADD(ep.end_dt, INTERVAL trach_window_h HOUR)) AS trach_during,
         LOGICAL_OR(t.t >= ep.visit_start_datetime AND t.t < ep.start_dt)               AS trach_before
  FROM ep
  JOIN trach t ON t.person_id = ep.person_id
  GROUP BY ep.episode_id
)
SELECT ep.*,
       IFNULL(tr.trach_during, FALSE) AS trach_during,
       IFNULL(tr.trach_before, FALSE) AS trach_before,
       CASE
         WHEN IFNULL(tr.trach_during, FALSE)                                    THEN 'tracheostomy'
         WHEN ep.death_datetime     <= DATETIME_ADD(ep.end_dt, INTERVAL 1 HOUR) THEN 'death_on_vent'
         WHEN ep.visit_end_datetime <= DATETIME_ADD(ep.end_dt, INTERVAL 1 HOUR) THEN 'left_icu_intubated'
         ELSE 'extubation'
       END AS end_type,
       IFNULL(ep.next_start <= DATETIME_ADD(ep.end_dt, INTERVAL outcome_h HOUR), FALSE)     AS reintubated,
       IFNULL(ep.death_datetime <= DATETIME_ADD(ep.end_dt, INTERVAL outcome_h HOUR), FALSE) AS died_within_window
FROM ep
LEFT JOIN tr USING (episode_id);

-- ---------------------------------------------------------------------
-- STEP 4: base cohort
--   first ventilation episode of the admission, still ventilated at 24 h,
--   no tracheostomy before the episode, first such admission per patient.
--   v2: an 'extubation' with a registration of self-extubation
--   within 2 h of the tube end becomes 'unplanned_extubation';
--   one with a registration of a tracheostomy becomes 'tracheostomy'.
--   Both are then left out of the failure cohort and censored in the
--   clinician cohort (STEP 5a/5b need no change: they use end_type).
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE `project-71f189c0-e73d-403e-989.extubation.base_cohort` AS
WITH b AS (
  SELECT * EXCEPT (rn)
  FROM (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY person_id ORDER BY start_dt) AS rn
    FROM `project-71f189c0-e73d-403e-989.extubation.episodes`
    WHERE ep_in_visit = 1
      AND duration_h >= min_vent_h
      AND NOT trach_before
  )
  WHERE rn = 1
),
not_planned AS (
  SELECT b.episode_id,
         LOGICAL_OR(REGEXP_CONTAINS(LOWER(o.observation_source_value), unplanned_pattern)) AS unplanned,
         LOGICAL_OR(REGEXP_CONTAINS(LOWER(o.observation_source_value), trach_obs_pattern)) AS trach_obs
  FROM b
  JOIN `amsterdamumcdb.version1_5_0.observation` o
    ON o.person_id = b.person_id
   AND CAST(o.observation_datetime AS DATETIME)
       BETWEEN DATETIME_SUB(b.end_dt, INTERVAL unplanned_window_h HOUR)
           AND DATETIME_ADD(b.end_dt, INTERVAL unplanned_window_h HOUR)
  WHERE o.provider_id >= 0                      -- required partition filter
    AND REGEXP_CONTAINS(LOWER(o.observation_source_value), CONCAT(unplanned_pattern, '|', trach_obs_pattern))
  GROUP BY b.episode_id
)
SELECT b.* REPLACE (
         CASE
           WHEN b.end_type = 'extubation' AND IFNULL(n.unplanned, FALSE) THEN 'unplanned_extubation'
           WHEN b.end_type = 'extubation' AND IFNULL(n.trach_obs, FALSE) THEN 'tracheostomy'
           ELSE b.end_type
         END AS end_type)
FROM b
LEFT JOIN not_planned n ON n.episode_id = b.episode_id;

-- ---------------------------------------------------------------------
-- STEP 5a: failure cohort (one row per planned extubation)
--   failure = reintubation within 48 h (also via ICU readmission)
--   Death within 48 h WITHOUT reintubation is likely a terminal / comfort-care
--   extubation: flagged, excluded in the main analysis, counted as failure
--   in a sensitivity analysis.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE `project-71f189c0-e73d-403e-989.extubation.failure_cohort` AS
SELECT person_id, visit_occurrence_id, episode_id,
       start_dt AS intubation_dt,
       end_dt   AS extubation_dt,
       DATETIME_SUB(end_dt, INTERVAL 30 MINUTE) AS feature_cutoff_dt,  -- use only data before this
       duration_h,
       reintubated AS failure,
       (died_within_window AND NOT reintubated) AS died_without_reintubation,
       visit_start_datetime,                                          -- used by 03 (weight, height)
       visit_end_datetime
FROM `project-71f189c0-e73d-403e-989.extubation.base_cohort`
WHERE end_type = 'extubation';

-- ---------------------------------------------------------------------
-- STEP 5b: clinician cohort (one row per 4-h block from hour 24 onwards)
--   label = planned extubation within the next 4 h
--   Censored episodes (death, tracheostomy, left ICU intubated, unplanned
--   extubation, presumed terminal extubation): only blocks whose full window
--   lies before the end are kept, all with label 0.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE `project-71f189c0-e73d-403e-989.extubation.clinician_cohort` AS
WITH b AS (
  SELECT *,
         (end_type = 'extubation' AND NOT (died_within_window AND NOT reintubated)) AS planned_extubation
  FROM `project-71f189c0-e73d-403e-989.extubation.base_cohort`
),
blocks AS (
  SELECT b.person_id, b.visit_occurrence_id, b.episode_id,
         b.start_dt, b.end_dt, b.planned_extubation,
         DATETIME_ADD(b.start_dt, INTERVAL (min_vent_h + block_h * k) HOUR) AS pred_dt
  FROM b,
       UNNEST(GENERATE_ARRAY(0, CAST(FLOOR((b.duration_h - min_vent_h) / block_h) AS INT64))) AS k
)
SELECT person_id, visit_occurrence_id, episode_id,
       pred_dt,                                            -- features: only data before this
       DATETIME_DIFF(pred_dt, start_dt, MINUTE) / 60 AS hours_on_vent,
       (planned_extubation
        AND end_dt <= DATETIME_ADD(pred_dt, INTERVAL block_h HOUR)) AS extubated_next_block
FROM blocks
WHERE pred_dt < end_dt
  AND (planned_extubation
       OR DATETIME_ADD(pred_dt, INTERVAL block_h HOUR) <= end_dt);

-- ---------------------------------------------------------------------
-- STEP 6: checks (run after the tables exist)
-- ---------------------------------------------------------------------
-- Flowchart counts for the report
SELECT 'all admissions' AS step, COUNT(*) AS n FROM `amsterdamumcdb.version1_5_0.visit_occurrence`
UNION ALL
SELECT 'admissions with an ETT episode', COUNT(DISTINCT visit_occurrence_id) FROM `project-71f189c0-e73d-403e-989.extubation.episodes`
UNION ALL
SELECT 'first episode >= 24 h, no prior trach', COUNT(*) FROM `project-71f189c0-e73d-403e-989.extubation.episodes`
  WHERE ep_in_visit = 1 AND duration_h >= min_vent_h AND NOT trach_before
UNION ALL
SELECT 'base cohort (1 per patient)', COUNT(*) FROM `project-71f189c0-e73d-403e-989.extubation.base_cohort`
UNION ALL
SELECT 'failure cohort (main analysis)', COUNTIF(NOT died_without_reintubation) FROM `project-71f189c0-e73d-403e-989.extubation.failure_cohort`;

-- How episodes end
SELECT end_type, COUNT(*) AS n
FROM `project-71f189c0-e73d-403e-989.extubation.base_cohort`
GROUP BY end_type
ORDER BY n DESC;

-- v2: which registrations marked an extubation as unplanned / tracheostomy?
-- (check that the item names make sense)
SELECT o.observation_source_value, COUNT(DISTINCT b.episode_id) AS n_episodes
FROM `project-71f189c0-e73d-403e-989.extubation.base_cohort` b
JOIN `amsterdamumcdb.version1_5_0.observation` o
  ON o.person_id = b.person_id
 AND CAST(o.observation_datetime AS DATETIME)
     BETWEEN DATETIME_SUB(b.end_dt, INTERVAL unplanned_window_h HOUR)
         AND DATETIME_ADD(b.end_dt, INTERVAL unplanned_window_h HOUR)
WHERE o.provider_id >= 0
  AND REGEXP_CONTAINS(LOWER(o.observation_source_value), CONCAT(unplanned_pattern, '|', trach_obs_pattern))
GROUP BY 1
ORDER BY 2 DESC;

-- Failure rate: expect roughly 10-20%; far outside that = suspect the episode logic
SELECT COUNT(*) AS n, COUNTIF(failure) AS n_failure, ROUND(AVG(CAST(failure AS INT64)), 3) AS failure_rate
FROM `project-71f189c0-e73d-403e-989.extubation.failure_cohort`
WHERE NOT died_without_reintubation;

-- Clinician cohort size and share of positive blocks
SELECT COUNT(*) AS n_rows,
       COUNT(DISTINCT episode_id) AS n_episodes,
       ROUND(AVG(CAST(extubated_next_block AS INT64)), 3) AS positive_rate
FROM `project-71f189c0-e73d-403e-989.extubation.clinician_cohort`;

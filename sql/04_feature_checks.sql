-- =====================================================================
-- Checks for the missing / unreadable variables in feature_summary.csv
-- Run each query separately and send the results.
-- =====================================================================

-- A. Right concept IDs for heart rate, blood pressure (MAP) and temperature.
--    Only the concept_id column of measurement is scanned (cheap).
WITH cnt AS (
  SELECT measurement_concept_id AS concept_id, COUNT(*) AS n
  FROM `amsterdamumcdb.version1_5_0.measurement`
  WHERE provider_id >= 0
  GROUP BY 1
)
SELECT cnt.concept_id, c.concept_name, c.vocabulary_id, cnt.n
FROM cnt
JOIN `amsterdamumcdb.version1_5_0.concept` c USING (concept_id)
WHERE REGEXP_CONTAINS(LOWER(c.concept_name),
        r'heart rate|pulse rate|arterial pressure|blood pressure|temperature')
ORDER BY cnt.n DESC
LIMIT 50;

-- B. How are GCS values stored? (they produced no numbers at all)
SELECT x.measurement_concept_id,
       x.value_as_number,
       c.concept_name AS value_concept,
       x.value_source_value,
       COUNT(*) AS n
FROM `amsterdamumcdb.version1_5_0.measurement` x
LEFT JOIN `amsterdamumcdb.version1_5_0.concept` c ON c.concept_id = x.value_as_concept_id
WHERE x.provider_id >= 0
  AND x.measurement_concept_id IN (3016335, 3008223, 3009094)   -- GCS eye, motor, verbal
GROUP BY 1, 2, 3, 4
ORDER BY 1, n DESC;

-- C. Values of the categorical features (cheap: small table)
SELECT feature, last_val, COUNT(*) AS n
FROM `project-71f189c0-e73d-403e-989.extubation.failure_feat_cat`
GROUP BY 1, 2
ORDER BY 1, n DESC;

-- D. Extubations that seem to happen before the ICU admission started
SELECT COUNTIF(hours_since_admission < 0) AS n_negative,
       MIN(hours_since_admission) AS most_negative
FROM `project-71f189c0-e73d-403e-989.extubation.failure_feat_base`;

-- =====================================================================
-- Where are the extra risk factors stored? Run each query separately.
-- If a query complains about a missing filter on 'provider_id', add
-- "AND <alias>.provider_id >= 0" to its WHERE clause.
-- =====================================================================

-- E1. Comorbidities among the failure-cohort patients
SELECT co.condition_concept_id, c.concept_name, co.condition_source_value,
       COUNT(DISTINCT co.person_id) AS n_patients
FROM `amsterdamumcdb.version1_5_0.condition_occurrence` co
JOIN `project-71f189c0-e73d-403e-989.extubation.failure_cohort` f ON f.person_id = co.person_id
LEFT JOIN `amsterdamumcdb.version1_5_0.concept` c ON c.concept_id = co.condition_concept_id
WHERE REGEXP_CONTAINS(
        LOWER(CONCAT(IFNULL(c.concept_name, ''), ' ', IFNULL(co.condition_source_value, ''))),
        r'copd|chronic obstructive|emphysema|asthma|heart failure|cardiac failure|cardiomyopathy|hartfalen|neuromuscul|myasthen|guillain|obes|diabetes|renal failure|kidney failure|nierinsuf|cirrhos|immuno|dement|stroke|cva')
GROUP BY 1, 2, 3
ORDER BY n_patients DESC
LIMIT 100;

-- E2. Most common conditions overall in the cohort (shows how admission diagnoses are stored)
SELECT co.condition_concept_id, c.concept_name, co.condition_source_value,
       COUNT(DISTINCT co.person_id) AS n_patients
FROM `amsterdamumcdb.version1_5_0.condition_occurrence` co
JOIN `project-71f189c0-e73d-403e-989.extubation.failure_cohort` f ON f.person_id = co.person_id
LEFT JOIN `amsterdamumcdb.version1_5_0.concept` c ON c.concept_id = co.condition_concept_id
GROUP BY 1, 2, 3
ORDER BY n_patients DESC
LIMIT 60;

-- E3. Admission information in visit_occurrence
SELECT vc.concept_name AS visit_type, v.visit_source_value,
       af.concept_name AS admitted_from, v.admitted_from_source_value,
       COUNT(*) AS n
FROM `project-71f189c0-e73d-403e-989.extubation.failure_cohort` f
JOIN `amsterdamumcdb.version1_5_0.visit_occurrence` v ON v.visit_occurrence_id = f.visit_occurrence_id
LEFT JOIN `amsterdamumcdb.version1_5_0.concept` vc ON vc.concept_id = v.visit_concept_id
LEFT JOIN `amsterdamumcdb.version1_5_0.concept` af ON af.concept_id = v.admitted_from_concept_id
GROUP BY 1, 2, 3, 4
ORDER BY n DESC
LIMIT 50;

-- E4. Weight, height, BMI (only the concept_id column of measurement is scanned: cheap)
WITH cnt AS (
  SELECT measurement_concept_id AS concept_id, COUNT(*) AS n
  FROM `amsterdamumcdb.version1_5_0.measurement`
  WHERE provider_id >= 0
  GROUP BY 1
)
SELECT cnt.concept_id, c.concept_name, cnt.n
FROM cnt
JOIN `amsterdamumcdb.version1_5_0.concept` c USING (concept_id)
WHERE REGEXP_CONTAINS(LOWER(c.concept_name), r'body weight|body height|body mass|weight|height')
ORDER BY cnt.n DESC
LIMIT 30;

-- E5. Medication by active ingredient (concept_ancestor links products to ingredients)
WITH ingr AS (
  SELECT concept_id AS ingredient_id, LOWER(concept_name) AS ingredient
  FROM `amsterdamumcdb.version1_5_0.concept`
  WHERE vocabulary_id = 'RxNorm' AND concept_class_id = 'Ingredient' AND standard_concept = 'S'
    AND LOWER(concept_name) IN (
      'norepinephrine', 'epinephrine', 'dopamine', 'dobutamine', 'vasopressin',      -- vasoactive
      'propofol', 'midazolam', 'lorazepam', 'dexmedetomidine', 'clonidine',          -- sedatives
      'morphine', 'fentanyl', 'sufentanil', 'remifentanil',                         -- opioids
      'haloperidol', 'furosemide',                                                  -- delirium, diuretic
      'dexamethasone', 'methylprednisolone', 'hydrocortisone', 'prednisolone')      -- steroids
)
SELECT i.ingredient, i.ingredient_id,
       COUNT(*) AS n_records,
       COUNT(DISTINCT d.person_id) AS n_patients
FROM `amsterdamumcdb.version1_5_0.drug_exposure` d
JOIN `project-71f189c0-e73d-403e-989.extubation.failure_cohort` f ON f.person_id = d.person_id
JOIN `amsterdamumcdb.version1_5_0.concept_ancestor` ca ON ca.descendant_concept_id = d.drug_concept_id
JOIN ingr i ON i.ingredient_id = ca.ancestor_concept_id
GROUP BY 1, 2
ORDER BY n_patients DESC;

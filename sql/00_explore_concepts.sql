-- =====================================================================
-- STEP 0: find the concept IDs you need (AmsterdamUMCdb v1.5.0, OMOP CDM 5.4)
-- =====================================================================
-- Write down the concept_ids you need for
-- 01_build_cohorts.sql.

-- 0a. All devices. device_exposure is small enough to list completely.
--     Look for the endotracheal tube (Dutch: "tube", "endotracheale tube")
--     and the tracheostomy cannula ("tracheacanule", "tracheostoma").
SELECT d.device_concept_id, c.concept_name, d.device_source_value,
       COUNT(*) AS n,
       COUNTIF(d.device_exposure_end_datetime IS NULL) AS n_without_end
FROM `amsterdamumcdb.version1_5_0.device_exposure` d
LEFT JOIN `amsterdamumcdb.version1_5_0.concept` c ON c.concept_id = d.device_concept_id
GROUP BY 1, 2, 3
ORDER BY n DESC;

-- 0b. Airway / ventilation procedures (e.g. tracheostomy, intubation).
SELECT p.procedure_concept_id, c.concept_name, p.procedure_source_value, COUNT(*) AS n
FROM `amsterdamumcdb.version1_5_0.procedure_occurrence` p
LEFT JOIN `amsterdamumcdb.version1_5_0.concept` c ON c.concept_id = p.procedure_concept_id
WHERE p.provider_id >= 0          -- partition filter (required)
  AND REGEXP_CONTAINS(
        LOWER(CONCAT(IFNULL(c.concept_name, ''), ' ', IFNULL(p.procedure_source_value, ''))),
        r'trache|intubat|extubat|ventilat|beadem|tube')
GROUP BY 1, 2, 3
ORDER BY n DESC;

-- 0c. Ventilator-related measurements. Only the concept_id column is scanned,
--     so this stays cheap despite the table having ~1 billion rows.
WITH terms AS (
  SELECT * FROM UNNEST(ARRAY<STRUCT<term STRING, category STRING>>[
    ('inspired oxygen', '1 FiO2/PEEP'), ('fio2', '1 FiO2/PEEP'),
    ('oxygen concentration', '1 FiO2/PEEP'),
    ('end expiratory pressure', '1 FiO2/PEEP'), ('peep', '1 FiO2/PEEP'),
    ('pressure support', '2 support'), ('above peep', '2 support'),
    ('inspiratory pressure', '2 support'), ('pressure control', '2 support'),
    ('tidal volume', '3 volume/rate'), ('minute volume', '3 volume/rate'),
    ('minute ventilation', '3 volume/rate'), ('respiratory rate', '3 volume/rate'),
    ('breath', '3 volume/rate'),
    ('shallow breathing', '4 weaning index'), ('work of breathing', '4 weaning index'),
    ('ventilat', '5 mode'), ('mode', '5 mode'), ('cpap', '5 mode'),
    ('partial pressure', '6 blood gas'), ('ph of', '6 blood gas'),
    ('bicarbonate', '6 blood gas'), ('base excess', '6 blood gas'),
    ('lactate', '6 blood gas'), ('oxygen saturation', '6 blood gas'),
    ('end tidal', '6 blood gas'),
    ('peak', '7 mechanics'), ('plateau', '7 mechanics'),
    ('mean airway', '7 mechanics'), ('airway pressure', '7 mechanics'),
    ('compliance', '7 mechanics'), ('resistance', '7 mechanics'),
    ('occlusion pressure', '7 mechanics'), ('inspiratory force', '7 mechanics'),
    ('cuff', '8 airway'), ('endotracheal', '8 airway'), ('suction', '8 airway'),
    ('sputum', '8 airway'), ('secretion', '8 airway'), ('cough', '8 airway'),
    ('richmond', '9 sedation/neuro'), ('sedation', '9 sedation/neuro'),
    ('glasgow', '9 sedation/neuro')
  ])
),
cnt AS (
  SELECT measurement_concept_id AS concept_id, COUNT(*) AS n
  FROM `amsterdamumcdb.version1_5_0.measurement`
  WHERE provider_id >= 0   -- partition filter, if this table requires one
  GROUP BY 1
)
SELECT cnt.concept_id, c.concept_name, c.vocabulary_id, cnt.n,
       STRING_AGG(DISTINCT t.category, ', ') AS matched
FROM cnt
JOIN `amsterdamumcdb.version1_5_0.concept` c USING (concept_id)
JOIN terms t ON STRPOS(LOWER(c.concept_name), t.term) > 0
GROUP BY 1, 2, 3, 4
ORDER BY matched, n DESC;

-- 0d. Same for observation. Device data that could not be mapped to a
--     standard concept (e.g. the Shallow Breathing Index = RSBI) ends up here,
--     so source values are included as well.
WITH cnt AS (
  SELECT observation_concept_id AS concept_id,
         observation_source_value AS source_value,
         COUNT(*) AS n
  FROM `amsterdamumcdb.version1_5_0.observation`
  WHERE provider_id >= 0          -- partition filter (required)
  GROUP BY 1, 2
)
SELECT cnt.concept_id, c.concept_name, cnt.source_value, cnt.n
FROM cnt
LEFT JOIN `amsterdamumcdb.version1_5_0.concept` c USING (concept_id)
WHERE REGEXP_CONTAINS(
        LOWER(CONCAT(IFNULL(c.concept_name, ''), ' ', IFNULL(cnt.source_value, ''))),
        r'ventilat|beadem|peep|fio2|druk|support|mode|breathing index|work of breathing|extubat|intubat|tube')
ORDER BY cnt.n DESC;

-- 0e. Are death times available (not just dates)? Step 3 needs them.
SELECT COUNT(*) AS n_deaths,
       COUNTIF(death_datetime IS NULL) AS n_without_time
FROM `amsterdamumcdb.version1_5_0.death`;

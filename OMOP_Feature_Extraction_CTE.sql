/*
===============================================================================
DATA 715 Group Breakout
OMOP Cohort Feature Engineering with Recursive CTE
===============================================================================

Purpose:
    Each group analyzes one research arm or control group.

Workflow:
    1. Select assigned cohort
    2. Determine each patient's index date
    3. Calculate drug exposure feature
    4. Recursively traverse condition hierarchy
    5. Calculate condition hierarchy feature
    6. Determine 30 day mortality outcome
    7. Build one row per patient feature matrix
    8. Validate results
    9. Export final results to CSV
    10. Optional SQL gradient calculation

Requirements:
    MySQL 8.0+

Assumptions:
    research_cohort contains:
        person_id
        study_arm

    OMOP tables:
        DRUG_EXPOSURE
        CONDITION_OCCURRENCE
        CONCEPT_RELATIONSHIP
        CONCEPT
        DEATH

===============================================================================
*/


/*=============================================================================
  GROUP SETTINGS

  EACH GROUP CHANGES ONLY THIS VALUE
=============================================================================*/

SET @study_arm = 0;

SET @max_hierarchy_depth = 3;


/*=============================================================================
  CLEAN UP FROM PREVIOUS RUN
=============================================================================*/

DROP TEMPORARY TABLE IF EXISTS tmp_final_features;


/*=============================================================================
  BUILD FINAL PATIENT LEVEL FEATURE TABLE
=============================================================================*/

CREATE TEMPORARY TABLE tmp_final_features AS

WITH RECURSIVE


/*-----------------------------------------------------------------------------
  1. COHORT

  Restrict the analysis to the group's assigned research arm.
-----------------------------------------------------------------------------*/

cohort AS (

    SELECT DISTINCT
        subject_id as person_id,
        cohort_definition_id as study_arm

    FROM omop.COHORT

    WHERE study_arm = @study_arm

),


/*-----------------------------------------------------------------------------
  2. INDEX DATE

  Define each patient's index date as their most recent drug exposure.

  Patients without a drug exposure will not enter the analytical population.
-----------------------------------------------------------------------------*/

latest_drug AS (

    SELECT
        c.person_id,
        c.study_arm,

        MAX(
            de.drug_exposure_start_date
        ) AS last_drug_date

    FROM cohort c

    INNER JOIN omop.DRUG_EXPOSURE de
        ON c.person_id = de.person_id

    GROUP BY
        c.person_id,
        c.study_arm

),


/*-----------------------------------------------------------------------------
  3. FEATURE 1

  f1 = number of drug exposure records during the 365 days ending on the
       patient's most recent drug exposure date.
-----------------------------------------------------------------------------*/

drug_features AS (

    SELECT
        ld.person_id,

        COUNT(
            de.drug_exposure_id
        ) AS f1

    FROM latest_drug ld

    LEFT JOIN omop.DRUG_EXPOSURE de

        ON de.person_id = ld.person_id

        AND de.drug_exposure_start_date >=
            DATE_SUB(
                ld.last_drug_date,
                INTERVAL 365 DAY
            )

        AND de.drug_exposure_start_date <=
            ld.last_drug_date

    GROUP BY
        ld.person_id

),


/*-----------------------------------------------------------------------------
  4. RECURSIVE CONDITION HIERARCHY

  Anchor:
      Start with condition concepts actually recorded for the patient.

  Recursive step:
      Follow "Is a" relationships upward through the OMOP vocabulary.

  depth:
      0 = recorded condition
      1 = parent
      2 = parent of parent
      3 = next level

  concept_path:
      Used to prevent a concept from being revisited in the same recursive
      path.

  Important:
      Conditions occurring after the index date are excluded to avoid
      information leakage.
-----------------------------------------------------------------------------*/

condition_tree AS (

    /*-------------------------------------------------------------------------
      ANCHOR MEMBER
    -------------------------------------------------------------------------*/

    SELECT DISTINCT

        ld.person_id,

        co.condition_concept_id
            AS source_concept_id,

        co.condition_concept_id
            AS concept_id,

        0 AS depth,

        CAST(
            CONCAT(
                ',',
                co.condition_concept_id,
                ','
            )
            AS CHAR(4000)
        ) AS concept_path

    FROM latest_drug ld

    INNER JOIN omop.CONDITION_OCCURRENCE co
        ON co.person_id = ld.person_id

    WHERE
        co.condition_concept_id IS NOT NULL

        AND co.condition_concept_id <> 0

        AND co.condition_start_date IS NOT NULL

        AND co.condition_start_date <=
            ld.last_drug_date


    UNION ALL


    /*-------------------------------------------------------------------------
      RECURSIVE MEMBER
    -------------------------------------------------------------------------*/

    SELECT

        ct.person_id,

        ct.source_concept_id,

        cr.concept_id_2
            AS concept_id,

        ct.depth + 1
            AS depth,

        CONCAT(
            ct.concept_path,
            cr.concept_id_2,
            ','
        ) AS concept_path

    FROM condition_tree ct

    INNER JOIN omop.CONCEPT_RELATIONSHIP cr

        ON cr.concept_id_1 = ct.concept_id

        AND cr.relationship_id = 'Is a'

        AND cr.invalid_reason IS NULL

    WHERE

        ct.depth < @max_hierarchy_depth

        /* Prevent cycles */

        AND LOCATE(
            CONCAT(
                ',',
                cr.concept_id_2,
                ','
            ),
            ct.concept_path
        ) = 0

),


/*-----------------------------------------------------------------------------
  5. FEATURE 2

  f2 = number of distinct concepts represented after expanding the patient's
       recorded conditions through the hierarchy.

  This includes:
      depth 0 recorded concepts
      depth 1 parents
      depth 2 grandparents
      depth 3 higher level concepts
-----------------------------------------------------------------------------*/

condition_features AS (

    SELECT

        person_id,

        COUNT(
            DISTINCT concept_id
        ) AS f2,

        COUNT(
            DISTINCT source_concept_id
        ) AS raw_condition_concepts,

        MAX(depth)
            AS max_depth_reached

    FROM condition_tree

    GROUP BY
        person_id

),


/*-----------------------------------------------------------------------------
  6. OUTCOME

  y = 1 if death occurs from the index date through 30 days afterward
  y = 0 otherwise

  OMOP DEATH normally has one row per person, but MAX() makes the logic
  resistant to duplicate records.
-----------------------------------------------------------------------------*/

outcomes AS (

    SELECT

        ld.person_id,

        MAX(

            CASE

                WHEN d.person_id IS NOT NULL

                    AND d.death_date >=
                        ld.last_drug_date

                    AND d.death_date <=
                        DATE_ADD(
                            ld.last_drug_date,
                            INTERVAL 30 DAY
                        )

                THEN 1

                ELSE 0

            END

        ) AS y

    FROM latest_drug ld

    LEFT JOIN omop.DEATH d
        ON d.person_id = ld.person_id

    GROUP BY
        ld.person_id

),


/*-----------------------------------------------------------------------------
  7. FINAL FEATURE MATRIX

  One row should represent one patient.
-----------------------------------------------------------------------------*/

final_features AS (

    SELECT

        ld.person_id,

        ld.study_arm,

        ld.last_drug_date,

        COALESCE(
            df.f1,
            0
        ) AS f1,

        COALESCE(
            cf.f2,
            0
        ) AS f2,

        COALESCE(
            cf.raw_condition_concepts,
            0
        ) AS raw_condition_concepts,

        COALESCE(
            cf.max_depth_reached,
            0
        ) AS max_depth_reached,

        COALESCE(
            o.y,
            0
        ) AS y

    FROM latest_drug ld

    LEFT JOIN drug_features df
        ON df.person_id = ld.person_id

    LEFT JOIN condition_features cf
        ON cf.person_id = ld.person_id

    LEFT JOIN outcomes o
        ON o.person_id = ld.person_id

)


SELECT
    person_id,
    study_arm,
    last_drug_date,
    f1,
    f2,
    raw_condition_concepts,
    max_depth_reached,
    y

FROM final_features
;


/*=============================================================================
  VALIDATION 1
  BASIC COHORT CHARACTERIZATION
=============================================================================*/

SELECT

    study_arm,

    COUNT(*) AS row_count,

    COUNT(
        DISTINCT person_id
    ) AS patient_count,

    MIN(last_drug_date)
        AS earliest_index_date,

    MAX(last_drug_date)
        AS latest_index_date

FROM tmp_final_features

GROUP BY
    study_arm
;


/*=============================================================================
  VALIDATION 2
  CONFIRM ONE ROW PER PATIENT
=============================================================================*/

SELECT

    COUNT(*) AS rows,

    COUNT(
        DISTINCT person_id
    ) AS distinct_patients,

    CASE

        WHEN COUNT(*) =
             COUNT(DISTINCT person_id)

        THEN 'PASS: one row per patient'

        ELSE 'FAIL: duplicate patients exist'

    END AS validation_result

FROM tmp_final_features
;


/*=============================================================================
  VALIDATION 3
  FEATURE CHARACTERIZATION
=============================================================================*/

SELECT

    study_arm,

    COUNT(*) AS patients,


    /* Drug exposure feature */

    MIN(f1)
        AS min_f1,

    AVG(f1)
        AS mean_f1,

    MAX(f1)
        AS max_f1,


    /* Hierarchy feature */

    MIN(f2)
        AS min_f2,

    AVG(f2)
        AS mean_f2,

    MAX(f2)
        AS max_f2,


    /* Raw condition concepts */

    AVG(raw_condition_concepts)
        AS mean_raw_condition_concepts,


    /* Hierarchy depth */

    AVG(max_depth_reached)
        AS mean_hierarchy_depth,


    /* Outcome */

    SUM(y)
        AS deaths,

    AVG(y)
        AS mortality_rate

FROM tmp_final_features

GROUP BY
    study_arm
;


/*=============================================================================
  VALIDATION 4
  OUTCOME DISTRIBUTION
=============================================================================*/

SELECT

    study_arm,

    y,

    COUNT(*) AS patients,

    ROUND(
        100.0 * COUNT(*) /
        SUM(COUNT(*)) OVER (
            PARTITION BY study_arm
        ),
        2
    ) AS percent_of_arm

FROM tmp_final_features

GROUP BY
    study_arm,
    y

ORDER BY
    study_arm,
    y
;


/*=============================================================================
  VALIDATION 5
  SAMPLE PATIENTS
=============================================================================*/

SELECT *

FROM tmp_final_features

ORDER BY
    person_id

LIMIT 20
;


/*=============================================================================
  EXPORT DATASET

  Export the result of this query using DBeaver, Aqua Data Studio, MySQL
  Workbench, or another client.

  Suggested filename:

      CONTROL_features.csv
      INTERVENTION_A_features.csv
      INTERVENTION_B_features.csv

=============================================================================*/

SELECT

    person_id,
    study_arm,
    last_drug_date,
    f1,
    f2,
    y

FROM tmp_final_features

ORDER BY
    person_id
;


/*=============================================================================
  OPTIONAL ADVANCED SECTION
  ONE GRADIENT UPDATE IN SQL

  The exported dataset uses:

      y = 0 or 1

  The original gradient example uses:

      y = -1 or 1

  Therefore y_math converts:

      0 -> -1
      1 ->  1
=============================================================================*/

WITH

model_features AS (

    SELECT

        person_id,

        CAST(f1 AS DECIMAL(20,6))
            AS f1,

        CAST(f2 AS DECIMAL(20,6))
            AS f2,

        CASE

            WHEN y = 1
                THEN 1

            ELSE -1

        END AS y_math

    FROM tmp_final_features

),


/*-----------------------------------------------------------------------------
  Initial model weights
-----------------------------------------------------------------------------*/

w AS (

    SELECT

        0.01 AS w1,

        0.01 AS w2,

        0.01 AS intercept

),


/*-----------------------------------------------------------------------------
  Calculate exponential component
-----------------------------------------------------------------------------*/

cse AS (

    SELECT

        mf.person_id,

        mf.f1,

        mf.f2,

        mf.y_math,

        EXP(

            (
                mf.f1 * w.w1
                +
                mf.f2 * w.w2
                +
                w.intercept
            )

            * -mf.y_math

        ) AS val

    FROM model_features mf

    CROSS JOIN w

),


/*-----------------------------------------------------------------------------
  Observation level contribution
-----------------------------------------------------------------------------*/

v AS (

    SELECT

        person_id,

        f1,

        f2,

        y_math,

        val * y_math /
        (
            1.0 + val
        ) AS val

    FROM cse

),


/*-----------------------------------------------------------------------------
  Aggregate gradient components
-----------------------------------------------------------------------------*/

u AS (

    SELECT

        COUNT(*) AS n,

        2 * SUM(
            f1 * val
        ) AS s1,

        2 * SUM(
            f2 * val
        ) AS s2,

        2 * SUM(
            val
        ) AS s3

    FROM v

),


/*-----------------------------------------------------------------------------
  Learning rate
-----------------------------------------------------------------------------*/

params AS (

    SELECT
        0.000001 AS eta

),


/*-----------------------------------------------------------------------------
  Update parameters
-----------------------------------------------------------------------------*/

g AS (

    SELECT

        w.w1
        -
        (
            params.eta *
            (
                u.s1 / u.n
            )
        ) AS w1_new,


        w.w2
        -
        (
            params.eta *
            (
                u.s2 / u.n
            )
        ) AS w2_new,


        w.intercept
        -
        (
            params.eta *
            (
                u.s3 / u.n
            )
        ) AS intercept_new

    FROM w

    CROSS JOIN u

    CROSS JOIN params

)

SELECT *

FROM g
;
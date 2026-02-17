USE <your_database>;
SELECT distinct
    fw.person_id,
    lw.weight - fw.weight AS weight_change,
    lw.measurement_date - fw.measurement_date AS days_between
FROM 
    (SELECT person_id, value_as_number AS weight, measurement_date
     FROM DM_MEASUREMENTS
     WHERE lower(concept_name) = 'body weight'
     AND (person_id, measurement_date) IN 
         (SELECT person_id, MIN(measurement_date)
          FROM DM_MEASUREMENTS
		  WHERE upper(concept_name) = 'BODY WEIGHT'
          GROUP BY person_id)
    ) AS fw
LEFT JOIN 
    (SELECT person_id, value_as_number AS weight, measurement_date
     FROM omop.MEASUREMENT,omop.CONCEPT
     WHERE concept_name like '%Body weight%' and measurement_concept_id = concept_id
    ) AS lw 
ON fw.person_id+0 = lw.person_id+0 and lw.weight <>0
WHERE (lw.weight - fw.weight) != 0
group by     fw.person_id,
    lw.weight - fw.weight,
    lw.measurement_date - fw.measurement_date 
	having sum(abs(lw.weight - fw.weight)) > 0;

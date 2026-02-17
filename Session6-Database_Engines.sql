USE <your_database>;
DROP TABLE IF EXISTS orders_innodb;
DROP TABLE IF EXISTS orders_myisam;
DROP TABLE IF EXISTS orders_memory;

CREATE TABLE orders_innodb (
  order_id BIGINT NOT NULL,
  customer_id INT NOT NULL,
  order_date DATE NOT NULL,
  amount_cents INT NOT NULL,
  status VARCHAR(12) NOT NULL,
  notes VARCHAR(100) NULL,
  PRIMARY KEY (order_id),
  KEY idx_customer_date (customer_id, order_date),
  KEY idx_status (status)
) ENGINE=InnoDB;

CREATE TABLE orders_myisam LIKE orders_innodb;
ALTER TABLE orders_myisam ENGINE=MyISAM;

CREATE TABLE orders_memory LIKE orders_innodb;
ALTER TABLE orders_memory ENGINE=MEMORY;
/*
Part 2: Auto generate scalable synthetic data
This generator uses a digits cross join so you can scale to 10k, 100k, or 1M rows without recursion limits.
*/
-- Step A: Create a reusable numbers view (0 to 999999)

DROP VIEW IF EXISTS v_nums_1m;

CREATE VIEW v_nums_1m AS
SELECT
  (d5.d*100000 + d4.d*10000 + d3.d*1000 + d2.d*100 + d1.d*10 + d0.d) AS n
FROM
  (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
   UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d0
CROSS JOIN
  (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
   UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d1
CROSS JOIN
  (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
   UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d2
CROSS JOIN
  (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
   UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d3
CROSS JOIN
  (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
   UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d4
CROSS JOIN
  (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
   UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d5;
/*
Step B: Pick a scale
Start with 100000 rows. Advanced students can go to 1000000 if their environment is strong.
*/
-- Set a variable and load data into each table. The data is deterministic enough for testing and random enough for distribution.

SET @N = 100000;

TRUNCATE TABLE orders_innodb;
TRUNCATE TABLE orders_myisam;
TRUNCATE TABLE orders_memory;

INSERT INTO orders_innodb (order_id, customer_id, order_date, amount_cents, status, notes)
SELECT
  n + 1 AS order_id,
  (n % 5000) + 1 AS customer_id,
  DATE_ADD('2024-01-01', INTERVAL (n % 365) DAY) AS order_date,
  (n * 37) % 50000 + 100 AS amount_cents,
  ELT((n % 4) + 1, 'new', 'paid', 'shipped', 'closed') AS status,
  CONCAT('row ', n) AS notes
FROM v_nums_1m
WHERE n < @N;

INSERT INTO orders_myisam SELECT * FROM orders_innodb;
INSERT INTO orders_memory SELECT * FROM orders_innodb;
Part 3: Observe persistence and volatility
Task A: Confirm row counts

SELECT 'innodb' engine, COUNT(*) cnt FROM orders_innodb
UNION ALL
SELECT 'myisam', COUNT(*) FROM orders_myisam
UNION ALL
SELECT 'memory', COUNT(*) FROM orders_memory;
/*
Task B: Explain what will happen on server restart for each table, then test if your environment allows restarting MySQL.
If they cannot restart, still require them to answer based on documentation and observed behavior in class discussion.

Part 4: Measure insert and query performance
You can do lightweight timing using timestamp variables so it works in plain SQL.
*/
-- Task A: Bulk insert timing
-- Students should rerun loads for each engine and record elapsed seconds.

SET @N = 200000;

TRUNCATE TABLE orders_innodb;
SET @t0 = NOW(6);
INSERT INTO orders_innodb (order_id, customer_id, order_date, amount_cents, status, notes)
SELECT
  n + 1, (n % 5000) + 1,
  DATE_ADD('2024-01-01', INTERVAL (n % 365) DAY),
  (n * 37) % 50000 + 100,
  ELT((n % 4) + 1, 'new', 'paid', 'shipped', 'closed'),
  CONCAT('row ', n)
FROM v_nums_1m
WHERE n < @N;
SET @t1 = NOW(6);
SELECT 'innodb_insert_seconds' label, TIMESTAMPDIFF(MICROSECOND, @t0, @t1)/1000000.0 seconds;

TRUNCATE TABLE orders_myisam;
SET @t0 = NOW(6);
INSERT INTO orders_myisam (order_id, customer_id, order_date, amount_cents, status, notes)
SELECT
  n + 1, (n % 5000) + 1,
  DATE_ADD('2024-01-01', INTERVAL (n % 365) DAY),
  (n * 37) % 50000 + 100,
  ELT((n % 4) + 1, 'new', 'paid', 'shipped', 'closed'),
  CONCAT('row ', n)
FROM v_nums_1m
WHERE n < @N;
SET @t1 = NOW(6);
SELECT 'myisam_insert_seconds' label, TIMESTAMPDIFF(MICROSECOND, @t0, @t1)/1000000.0 seconds;

TRUNCATE TABLE orders_memory;
SET @t0 = NOW(6);
INSERT INTO orders_memory (order_id, customer_id, order_date, amount_cents, status, notes)
SELECT
  n + 1, (n % 5000) + 1,
  DATE_ADD('2024-01-01', INTERVAL (n % 365) DAY),
  (n * 37) % 50000 + 100,
  ELT((n % 4) + 1, 'new', 'paid', 'shipped', 'closed'),
  CONCAT('row ', n)
FROM v_nums_1m
WHERE n < @N;
SET @t1 = NOW(6);
SELECT 'memory_insert_seconds' label, TIMESTAMPDIFF(MICROSECOND, @t0, @t1)/1000000.0 seconds;
/*
Task B: Read query timing and EXPLAIN
Students run the same queries against each engine and compare timing and plans.
*/
-- Query 1: Point lookup by primary key

SET @t0 = NOW(6);
SELECT * FROM orders_innodb WHERE order_id = 12345;
SET @t1 = NOW(6);
SELECT 'innodb_pk_lookup_seconds' label, TIMESTAMPDIFF(MICROSECOND, @t0, @t1)/1000000.0 seconds;

EXPLAIN SELECT * FROM orders_innodb WHERE order_id = 12345;
-- Repeat for orders_myisam and orders_memory.

-- Query 2: Range filter with composite index

EXPLAIN
SELECT customer_id, COUNT(*) cnt, SUM(amount_cents) sum_amount
FROM orders_innodb
WHERE customer_id = 42
  AND order_date BETWEEN '2024-03-01' AND '2024-06-30'
GROUP BY customer_id;
-- Repeat for the other engines and compare key usage, rows examined, and elapsed time.

/*
Part 5: Feature behavior experiments
These are the conceptual payoff.
*/
/*
Experiment A: Transactions
Students to predict results, then run and explain.
*/
START TRANSACTION;
UPDATE orders_innodb SET status = 'closed' WHERE order_id = 10;
ROLLBACK;
SELECT status FROM orders_innodb WHERE order_id = 10;
-- Now try the same on MyISAM. They will discover no transactional rollback behavior.

START TRANSACTION;
UPDATE orders_myisam SET status = 'closed' WHERE order_id = 10;
ROLLBACK;
SELECT status FROM orders_myisam WHERE order_id = 10;

/*
Experiment B: Locking and concurrency
This works best if students open two SQL sessions.
*/
-- Session 1:
-- Review Data
SELECT order_id,amount_cents from orders_innodb WHERE order_id BETWEEN 1 AND 50000;
START TRANSACTION;
UPDATE orders_innodb SET amount_cents = amount_cents + 1 WHERE order_id BETWEEN 1 AND 50000;
-- do not commit yet
-- Session 2: While session 1 is open, run
SELECT order_id,amount_cents from orders_innodb WHERE order_id BETWEEN 1 AND 50000;

-- Then repeat with MyISAM. Students should observe that table level locking can block more broadly depending on operation and isolation.
-- Session 1:
-- Review Data
SELECT order_id,amount_cents from orders_myisam WHERE order_id BETWEEN 1 AND 50000;
START TRANSACTION;
UPDATE orders_myisam SET amount_cents = amount_cents + 1 ;
-- do not commit yet
-- Session 2: While session 1 is open, run
SELECT order_id,amount_cents from orders_myisam WHERE order_id BETWEEN 1 AND 50000;
/*
Experiment C: Storage footprint
Have them compare table size on disk using information_schema.
*/
ANALYZE TABLE orders_innodb;
ANALYZE TABLE orders_myisam;
ANALYZE TABLE orders_memory;

SELECT
  table_name,
  engine,
  table_rows,
  data_length,
  index_length,
  (data_length + index_length) AS total_bytes
FROM information_schema.tables
WHERE table_schema = DATABASE()
  AND table_name IN ('orders_innodb','orders_myisam','orders_memory');

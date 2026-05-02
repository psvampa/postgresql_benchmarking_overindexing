-- Deterministic seed so successive loads produce the same dataset
-- (note: this guarantees reproducibility for a given PostgreSQL major version;
--  the underlying PRNG implementation may change between versions).
SELECT setseed(0.42);

-- Insert 20,000,000 products
-- sku and sku_number will be auto-generated using global_sku_seq
INSERT INTO products (name, description, price)
SELECT
    'Product ' || i,
    'Description for product ' || i,
    ROUND((random() * 1000 + 10)::NUMERIC, 2)
FROM generate_series(1, 20000000) AS i;

-- Insert 2,500 warehouses
INSERT INTO warehouses (name, location, max_capacity)
SELECT
    'Warehouse ' || i,
    'City ' || (i % 100 + 1),
    (random() * 5000 + 1000)::INT
FROM generate_series(1, 2500) AS i;

-- Insert ~50 million stock records spread across the 20M products / 2,500 warehouses space.
-- Each (product_id, warehouse_id) pair is drawn independently at random and the UNIQUE
-- constraint on (product_id, warehouse_id) deduplicates collisions via ON CONFLICT DO NOTHING.
--
-- Cardinality check:
--   - Possible pairs : 20,000,000 * 2,500 = 5e10
--   - Draws          : 5e7
--   - Expected unique: M * (1 - exp(-N/M)) ~= 49,975,000
--     i.e. ~25,000 (~0.05%) collisions.
--
-- Resulting distribution of warehouses per product follows Poisson(lambda = 2.5):
--   ~8% of products end up with no stock, ~20% with 1, ~26% with 2, ~21% with 3, ~22% with 4+.
-- This long-tail distribution is intentional: it gives the planner realistic statistics
-- and ensures secondary indexes are exercised over a non-trivial value distribution.
INSERT INTO stock (
    product_id,
    warehouse_id,
    quantity,
    min_quantity,
    max_quantity,
    reorder_point,
    last_restock_date,
    is_active,
    location_code,
    batch_number,
    expiration_date,
    last_updated
)
SELECT
    floor(random() * 20000000)::INT + 1 AS product_id,
    floor(random() * 2500)::INT + 1     AS warehouse_id,
    (random() * 500 + 1)::INT           AS quantity,
    (random() * 10 + 1)::INT            AS min_quantity,
    (random() * 100 + 50)::INT          AS max_quantity,
    (random() * 20 + 5)::INT            AS reorder_point,
    NOW() - (random() * INTERVAL '180 days') AS last_restock_date,
    TRUE,
    'LOC-'   || floor(random() * 10000)::INT  AS location_code,
    'BATCH-' || floor(random() * 100000)::INT AS batch_number,
    CURRENT_DATE + (random() * 365)::INT      AS expiration_date,
    NOW() AS last_updated
FROM generate_series(1, 50000000) AS s
ON CONFLICT (product_id, warehouse_id) DO NOTHING;

-- Insert 1,000,000 stock movements.
-- stock_movements has FKs to products(id) and warehouses(id) only (not to the stock pair),
-- so independent uniform sampling is sufficient and keeps the load fast.
INSERT INTO stock_movements (
    product_id,
    warehouse_id,
    quantity,
    movement_type,
    movement_date,
    reason_code,
    reference_document,
    operator_name,
    approved_by,
    movement_status,
    created_at,
    updated_at
)
SELECT
    floor(random() * 20000000)::INT + 1 AS product_id,
    floor(random() * 2500)::INT + 1     AS warehouse_id,
    (random() * 500 + 1)::INT           AS quantity,
    CASE
        WHEN random() < 0.6 THEN 'inbound'
        WHEN random() < 0.9 THEN 'outbound'
        ELSE 'adjustment'
    END AS movement_type,
    NOW() - (random() * INTERVAL '365 days')   AS movement_date,
    'RC-'  || floor(random() * 100)::INT       AS reason_code,
    'DOC-' || floor(random() * 100000)::INT    AS reference_document,
    'Operator '   || floor(random() * 500)::INT AS operator_name,
    'Supervisor ' || floor(random() * 100)::INT AS approved_by,
    CASE
        WHEN random() < 0.8 THEN 'completed'
        ELSE 'pending'
    END AS movement_status,
    NOW(),
    NOW()
FROM generate_series(1, 1000000) AS s;

-- Refresh planner statistics so the first pgbench run is not penalised by stale stats.
-- ANALYZE on its own is enough; VACUUM is included to also build the visibility map for
-- index-only scans (cheap right after a fresh load).
VACUUM (ANALYZE);

-- =====================================================================
-- NovaMarket S1 — M2 : import réception -> rejets -> métier
-- Rejouable : vide tout puis recharge. Une seule transaction :
-- en cas d'erreur, rien n'est à moitié chargé (faire ROLLBACK si besoin).
-- Exécution : docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U atelier -d novamarket < sql/02_import.sql
-- Chemins : ceux du conteneur (/s1 = ./s1 monté en lecture seule).
-- =====================================================================
\set ON_ERROR_STOP 1
BEGIN;

TRUNCATE metier.payments, metier.order_items, metier.orders, metier.customers;
TRUNCATE reception.customers, reception.orders, reception.order_items,
         reception.payments, reception.rejets RESTART IDENTITY;

-- ---------------------------------------------------------------------
-- 1. Réception : copie brute des fichiers
-- ---------------------------------------------------------------------
\copy reception.customers   (customer_id, customer_name, city)                                FROM '/s1/donnees/customers.csv'   WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy reception.orders      (order_id, customer_id, ordered_on, status)                        FROM '/s1/donnees/orders.csv'      WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy reception.order_items (order_item_id, order_id, product_id, quantity, unit_price_cents)  FROM '/s1/donnees/order_items.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
-- NDJSON : chaque ligne lue comme un seul champ (délimiteur/quote improbables)
\copy reception.payments    (document)                                                         FROM '/s1/donnees/payments.ndjson' WITH (FORMAT csv, QUOTE E'\x01', DELIMITER E'\x02')

-- ---------------------------------------------------------------------
-- 2. Rejets. Ordre d'import = ordre des dépendances :
--    customers -> orders -> order_items / payments.
--    Une ligne reçoit au plus un motif (le premier qui s'applique).
-- ---------------------------------------------------------------------

-- 2a. customers
INSERT INTO reception.rejets (source, ligne_id, cle_source, motif, contenu)
SELECT 'customers.csv', ligne_id, customer_id, motif, to_jsonb(r) - 'ligne_id' - 'motif'
FROM (
    SELECT r.*,
           CASE
             WHEN NOT pg_input_is_valid(customer_id, 'integer')         THEN 'customer_id absent ou non entier'
             WHEN coalesce(trim(customer_name), '') = ''                 THEN 'customer_name vide'
             WHEN coalesce(trim(city), '') = ''                          THEN 'city vide'
             WHEN row_number() OVER (PARTITION BY customer_id ORDER BY ligne_id) > 1
                                                                         THEN 'doublon de customer_id (1re occurrence conservée)'
           END AS motif
    FROM reception.customers r
) r
WHERE motif IS NOT NULL;

INSERT INTO metier.customers (customer_id, customer_name, city)
SELECT customer_id::integer, trim(customer_name), trim(city)
FROM reception.customers r
WHERE NOT EXISTS (SELECT 1 FROM reception.rejets j WHERE j.source = 'customers.csv' AND j.ligne_id = r.ligne_id);

-- 2b. orders
INSERT INTO reception.rejets (source, ligne_id, cle_source, motif, contenu)
SELECT 'orders.csv', ligne_id, order_id, motif, to_jsonb(r) - 'ligne_id' - 'motif'
FROM (
    SELECT r.*,
           CASE
             WHEN NOT pg_input_is_valid(order_id, 'integer')             THEN 'order_id absent ou non entier'
             WHEN NOT pg_input_is_valid(customer_id, 'integer')          THEN 'customer_id absent ou non entier'
             WHEN ordered_on !~ '^\d{4}-\d{2}-\d{2}$'
               OR NOT pg_input_is_valid(ordered_on, 'date')              THEN 'ordered_on non ISO AAAA-MM-JJ'
             WHEN status IS NULL OR status NOT IN ('completed', 'pending', 'cancelled')
                                                                         THEN 'status inconnu (sensible à la casse)'
             WHEN NOT EXISTS (SELECT 1 FROM metier.customers c WHERE c.customer_id = r.customer_id::integer)
                                                                         THEN 'client inexistant (référence orpheline)'
             WHEN row_number() OVER (PARTITION BY order_id ORDER BY ligne_id) > 1
                                                                         THEN 'doublon de order_id (1re occurrence conservée)'
           END AS motif
    FROM reception.orders r
) r
WHERE motif IS NOT NULL;

INSERT INTO metier.orders (order_id, customer_id, ordered_on, status)
SELECT order_id::integer, customer_id::integer, ordered_on::date, status
FROM reception.orders r
WHERE NOT EXISTS (SELECT 1 FROM reception.rejets j WHERE j.source = 'orders.csv' AND j.ligne_id = r.ligne_id);

-- 2c. order_items
INSERT INTO reception.rejets (source, ligne_id, cle_source, motif, contenu)
SELECT 'order_items.csv', ligne_id, order_item_id, motif, to_jsonb(r) - 'ligne_id' - 'motif' - 'nb_occ'
FROM (
    SELECT r.*,
           CASE
             WHEN NOT pg_input_is_valid(order_item_id, 'integer')        THEN 'order_item_id absent ou non entier'
             WHEN NOT pg_input_is_valid(order_id, 'integer')             THEN 'order_id absent ou non entier'
             WHEN NOT pg_input_is_valid(product_id, 'integer')           THEN 'product_id absent ou non entier'
             WHEN NOT pg_input_is_valid(quantity, 'integer')
               OR quantity::integer <= 0                                 THEN 'quantity non entière ou <= 0'
             WHEN NOT pg_input_is_valid(unit_price_cents, 'integer')
               OR unit_price_cents::integer <= 0                         THEN 'unit_price_cents non entier ou <= 0'
             WHEN NOT EXISTS (SELECT 1 FROM metier.orders o WHERE o.order_id = r.order_id::integer)
                                                                         THEN 'commande inexistante (référence orpheline)'
             WHEN nb_occ > 1                                             THEN 'doublon de order_item_id (1re occurrence conservée)'
           END AS motif
    FROM (
        SELECT r.*,
               row_number() OVER (PARTITION BY order_item_id ORDER BY ligne_id) AS nb_occ
        FROM reception.order_items r
    ) r
) r
WHERE motif IS NOT NULL;

INSERT INTO metier.order_items (order_item_id, order_id, product_id, quantity, unit_price_cents)
SELECT order_item_id::integer, order_id::integer, product_id::integer, quantity::integer, unit_price_cents::integer
FROM reception.order_items r
WHERE NOT EXISTS (SELECT 1 FROM reception.rejets j WHERE j.source = 'order_items.csv' AND j.ligne_id = r.ligne_id);

-- 2d. payments (NDJSON)
INSERT INTO reception.rejets (source, ligne_id, cle_source, motif, contenu)
SELECT 'payments.ndjson', ligne_id, document ->> 'payment_id', motif, document
FROM (
    SELECT r.*,
           CASE
             WHEN NOT pg_input_is_valid(document ->> 'payment_id', 'integer')   THEN 'payment_id absent ou non entier'
             WHEN NOT pg_input_is_valid(document ->> 'order_id', 'integer')     THEN 'order_id absent ou non entier'
             WHEN (document ->> 'paid_on') !~ '^\d{4}-\d{2}-\d{2}$'
               OR NOT pg_input_is_valid(document ->> 'paid_on', 'date')         THEN 'paid_on non ISO AAAA-MM-JJ'
             WHEN NOT pg_input_is_valid(document ->> 'amount_cents', 'integer')
               OR (document ->> 'amount_cents')::integer <= 0                   THEN 'amount_cents non entier ou <= 0'
             WHEN (document ->> 'status') IS NULL
               OR (document ->> 'status') NOT IN ('captured', 'pending')         THEN 'status inconnu (sensible à la casse)'
             WHEN NOT EXISTS (SELECT 1 FROM metier.orders o WHERE o.order_id = (r.document ->> 'order_id')::integer)
                                                                                THEN 'commande inexistante (référence orpheline)'
             WHEN row_number() OVER (PARTITION BY document ->> 'payment_id' ORDER BY ligne_id) > 1
                                                                                THEN 'doublon de payment_id (1re occurrence conservée)'
           END AS motif
    FROM reception.payments r
) r
WHERE motif IS NOT NULL;

INSERT INTO metier.payments (payment_id, order_id, paid_on, amount_cents, status)
SELECT p.payment_id, p.order_id, p.paid_on, p.amount_cents, p.status
FROM reception.payments r
CROSS JOIN LATERAL jsonb_to_record(r.document)
     AS p(payment_id integer, order_id integer, paid_on date, amount_cents integer, status text)
WHERE NOT EXISTS (SELECT 1 FROM reception.rejets j WHERE j.source = 'payments.ndjson' AND j.ligne_id = r.ligne_id);

COMMIT;

\echo 'Import terminé. Lancer sql/03_controles.sql pour le bilan des volumes.'

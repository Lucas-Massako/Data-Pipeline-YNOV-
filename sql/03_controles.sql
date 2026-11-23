-- =====================================================================
-- NovaMarket S1 — M2/M5 : contrôles après import (lecture seule)
-- Exécution : docker compose exec -T postgres psql -X -U atelier -d novamarket < sql/03_controles.sql
-- Règle attendue : reçus = intégrés + rejetés pour chaque source.
-- =====================================================================

\echo '=== 1. Volumes reçus / intégrés / rejetés ==='
WITH v AS (
    SELECT 'customers.csv'   AS source, (SELECT count(*) FROM reception.customers)   AS recus, (SELECT count(*) FROM metier.customers)   AS integres
    UNION ALL SELECT 'orders.csv',      (SELECT count(*) FROM reception.orders),      (SELECT count(*) FROM metier.orders)
    UNION ALL SELECT 'order_items.csv', (SELECT count(*) FROM reception.order_items), (SELECT count(*) FROM metier.order_items)
    UNION ALL SELECT 'payments.ndjson', (SELECT count(*) FROM reception.payments),    (SELECT count(*) FROM metier.payments)
)
SELECT v.source, v.recus, v.integres,
       (SELECT count(*) FROM reception.rejets r WHERE r.source = v.source) AS rejetes,
       CASE WHEN v.recus = v.integres + (SELECT count(*) FROM reception.rejets r WHERE r.source = v.source)
            THEN 'OK' ELSE 'ÉCART' END AS bilan
FROM v
ORDER BY v.source;

\echo '=== 2. Journal des rejets ==='
SELECT source, ligne_id, cle_source, motif, contenu
FROM reception.rejets
ORDER BY source, ligne_id;

\echo '=== 3. Contrôles de cohérence (chaque ligne doit afficher 0) ==='
SELECT 'commandes sans ligne d''article'           AS controle, count(*) AS nb
FROM metier.orders o WHERE NOT EXISTS (SELECT 1 FROM metier.order_items i WHERE i.order_id = o.order_id)
UNION ALL
SELECT 'commandes sans paiement', count(*)
FROM metier.orders o WHERE NOT EXISTS (SELECT 1 FROM metier.payments p WHERE p.order_id = o.order_id)
UNION ALL
SELECT 'paiements antérieurs à la commande', count(*)
FROM metier.payments p JOIN metier.orders o USING (order_id) WHERE p.paid_on < o.ordered_on
UNION ALL
SELECT 'commandes où total articles <> total paiements (tous statuts)', count(*)
FROM (
    SELECT o.order_id,
           (SELECT sum(quantity * unit_price_cents) FROM metier.order_items i WHERE i.order_id = o.order_id) AS articles,
           (SELECT sum(amount_cents)               FROM metier.payments    p WHERE p.order_id = o.order_id) AS paiements
    FROM metier.orders o
) t
WHERE articles IS DISTINCT FROM paiements;

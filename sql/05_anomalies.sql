-- =====================================================================
-- NovaMarket S1 — M4 : investigation des anomalies (lecture seule)
-- Exécution : docker compose exec -T postgres psql -X -U atelier -d novamarket < sql/05_anomalies.sql
-- Les requêtes A1/A2 portent sur la RÉCEPTION (avant nettoyage),
-- A3/A4 sur le MÉTIER.
-- =====================================================================

\echo '=== A1. Doublons de lignes d''articles (réception) ==='
SELECT order_item_id, order_id, product_id, quantity, unit_price_cents,
       count(*) AS occurrences, array_agg(ligne_id ORDER BY ligne_id) AS lignes_reception
FROM reception.order_items
GROUP BY order_item_id, order_id, product_id, quantity, unit_price_cents
HAVING count(*) > 1;

\echo '--- A1 bis. Paiements identiques sur une même commande : vrais doublons ? ---'
-- 80 commandes ont 2 paiements ; pour certaines, les 2 ont même montant et même date.
-- payment_id distincts et somme = total articles -> paiements fractionnés légitimes,
-- PAS des doublons : on les conserve.
WITH paires AS (
    SELECT order_id, paid_on, amount_cents, status, count(*) AS n
    FROM metier.payments
    GROUP BY order_id, paid_on, amount_cents, status
    HAVING count(*) > 1
)
SELECT count(*) AS commandes_concernees,
       count(*) FILTER (WHERE p.amount_cents * p.n =
              (SELECT sum(quantity * unit_price_cents) FROM metier.order_items i WHERE i.order_id = p.order_id))
              AS dont_somme_egale_total_articles
FROM paires p;

\echo '=== A2. Références orphelines (réception) ==='
SELECT 'order_items -> orders' AS lien, i.ligne_id, i.order_item_id AS cle, i.order_id AS reference
FROM reception.order_items i
WHERE NOT EXISTS (SELECT 1 FROM reception.orders o WHERE o.order_id = i.order_id)
UNION ALL
SELECT 'payments -> orders', p.ligne_id, p.document ->> 'payment_id', p.document ->> 'order_id'
FROM reception.payments p
WHERE NOT EXISTS (SELECT 1 FROM reception.orders o WHERE o.order_id = p.document ->> 'order_id')
UNION ALL
SELECT 'orders -> customers', o.ligne_id, o.order_id, o.customer_id
FROM reception.orders o
WHERE NOT EXISTS (SELECT 1 FROM reception.customers c WHERE c.customer_id = o.customer_id);

\echo '=== A3. Multiplication des montants : jointure directe articles x paiements ==='
-- FAUX : une commande à 2 articles et 2 paiements produit 2 x 2 = 4 lignes ;
-- chaque article est compté 2 fois, chaque paiement aussi.
SELECT 'jointure directe (FAUX)'               AS methode,
       round(sum(i.quantity * i.unit_price_cents) / 100.0, 2) AS ca_articles_euros,
       round(sum(p.amount_cents) / 100.0, 2) AS paiements_euros,
       count(*)                                     AS lignes_produites
FROM metier.orders o
JOIN metier.order_items i USING (order_id)
JOIN metier.payments    p USING (order_id)
WHERE o.status = 'completed' AND p.status = 'captured'
UNION ALL
-- JUSTE : agrégation de chaque côté au grain commande avant la jointure.
SELECT 'pré-agrégation par commande (JUSTE)',
       round(sum(a.t) / 100.0, 2), round(sum(b.t) / 100.0, 2), count(*)
FROM metier.orders o
JOIN (SELECT order_id, sum(quantity * unit_price_cents) AS t FROM metier.order_items GROUP BY order_id) a USING (order_id)
JOIN (SELECT order_id, sum(amount_cents) AS t FROM metier.payments WHERE status = 'captured' GROUP BY order_id) b USING (order_id)
WHERE o.status = 'completed';

\echo '--- A3 bis. Exemple concret : commandes completed avec 2 paiements ---'
SELECT o.order_id,
       (SELECT count(*) FROM metier.order_items i WHERE i.order_id = o.order_id) AS nb_articles,
       (SELECT count(*) FROM metier.payments    p WHERE p.order_id = o.order_id) AS nb_paiements,
       (SELECT sum(quantity * unit_price_cents) FROM metier.order_items i WHERE i.order_id = o.order_id) AS vrai_total_cents,
       (SELECT sum(i.quantity * i.unit_price_cents)
          FROM metier.order_items i JOIN metier.payments p USING (order_id)
         WHERE i.order_id = o.order_id) AS total_apres_jointure_cents
FROM metier.orders o
WHERE o.status = 'completed'
  AND (SELECT count(*) FROM metier.payments p WHERE p.order_id = o.order_id) > 1
ORDER BY o.order_id
LIMIT 5;

\echo '=== A4. Impact du statut de commande sur le CA (lignes d''articles) ==='
WITH ca AS (
    SELECT o.status, sum(i.quantity * i.unit_price_cents) AS cents
    FROM metier.orders o JOIN metier.order_items i USING (order_id)
    GROUP BY o.status
)
SELECT 'completed uniquement (retenu)'        AS perimetre, round(sum(cents) FILTER (WHERE status = 'completed') / 100.0, 2) AS ca_euros FROM ca
UNION ALL SELECT 'completed + pending',        round(sum(cents) FILTER (WHERE status IN ('completed', 'pending')) / 100.0, 2) FROM ca
UNION ALL SELECT 'tous statuts (y c. cancelled)', round(sum(cents) / 100.0, 2) FROM ca;

\echo '--- A4 bis. Argent encaissé sur des commandes annulées ---'
SELECT count(DISTINCT p.order_id) AS commandes_annulees_encaissees,
       round(sum(p.amount_cents) / 100.0, 2) AS encaisse_euros
FROM metier.payments p JOIN metier.orders o USING (order_id)
WHERE o.status = 'cancelled' AND p.status = 'captured';

\echo '=== A5. Impact du doublon de ligne s''il n''avait pas été rejeté (commande 4) ==='
SELECT (SELECT sum(quantity::int * unit_price_cents::int) FROM reception.order_items WHERE order_id = '4') AS total_brut_cents,
       (SELECT sum(quantity * unit_price_cents)           FROM metier.order_items    WHERE order_id = 4)   AS total_nettoye_cents,
       (SELECT sum(amount_cents)                          FROM metier.payments       WHERE order_id = 4)   AS paye_cents;

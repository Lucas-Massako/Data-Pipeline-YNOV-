-- =====================================================================
-- NovaMarket S1 — M3 : indicateurs commerciaux (lecture seule)
-- Exécution : docker compose exec -T postgres psql -X -U atelier -d novamarket < sql/04_indicateurs.sql
-- Montants sources en centimes ; affichés aussi en euros (numeric, /100).
-- Principe : on agrège CHAQUE table à son propre grain AVANT de joindre.
-- =====================================================================

\echo '=== I1. Commandes par statut ==='
SELECT status, count(*) AS nb_commandes,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM metier.orders
GROUP BY status
ORDER BY nb_commandes DESC;

\echo '=== I2. Clients sans aucune commande ==='
SELECT count(*) AS clients_sans_commande,
       (SELECT count(*) FROM metier.customers) AS clients_total
FROM metier.customers c
WHERE NOT EXISTS (SELECT 1 FROM metier.orders o WHERE o.customer_id = c.customer_id);

\echo '=== I3. CA des lignes des commandes terminées (completed) et panier moyen ==='
-- Grain : ligne d'article. Montant ligne = quantity * unit_price_cents.
-- Dénominateur du panier moyen : nombre de commandes 'completed' (ayant au moins une ligne).
WITH lignes_completed AS (
    SELECT i.order_id, i.quantity * i.unit_price_cents AS montant_cents
    FROM metier.order_items i
    JOIN metier.orders o USING (order_id)
    WHERE o.status = 'completed'
)
SELECT sum(montant_cents)                               AS ca_cents,
       round(sum(montant_cents) / 100.0, 2)            AS ca_euros,
       count(DISTINCT order_id)                         AS nb_commandes_denominateur,
       round(sum(montant_cents) / 100.0 / count(DISTINCT order_id), 2) AS panier_moyen_euros
FROM lignes_completed;

\echo '=== I4. Rapprochement articles / paiements, par commande puis par statut ==='
-- Chaque côté est d'abord ramené au grain COMMANDE, puis comparé.
WITH articles AS (
    SELECT order_id, sum(quantity * unit_price_cents) AS articles_cents
    FROM metier.order_items GROUP BY order_id
), paiements AS (
    SELECT order_id,
           sum(amount_cents) FILTER (WHERE status = 'captured') AS captured_cents,
           sum(amount_cents) FILTER (WHERE status = 'pending')  AS pending_cents,
           count(*)                                             AS nb_paiements
    FROM metier.payments GROUP BY order_id
)
SELECT o.status                              AS statut_commande,
       count(*)                              AS nb_commandes,
       round(sum(a.articles_cents) / 100.0, 2) AS articles_euros,
       round(coalesce(sum(p.captured_cents), 0) / 100.0, 2) AS encaisse_euros,
       round(coalesce(sum(p.pending_cents), 0) / 100.0, 2) AS en_attente_euros,
       count(*) FILTER (WHERE a.articles_cents = coalesce(p.captured_cents, 0) + coalesce(p.pending_cents, 0))
                                             AS commandes_equilibrees,
       sum(p.nb_paiements)                   AS nb_paiements
FROM metier.orders o
LEFT JOIN articles  a USING (order_id)
LEFT JOIN paiements p USING (order_id)
GROUP BY o.status
ORDER BY o.status;

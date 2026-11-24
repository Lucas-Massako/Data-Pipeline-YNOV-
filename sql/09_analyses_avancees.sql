-- =====================================================================
-- NovaMarket S2 — M2 à M5 : analyses avancées (lecture seule)
-- Périmètre de vente (décision S1 D1) : commandes 'completed' uniquement.
-- Montant d'une ligne = quantity * unit_price_cents (centimes).
-- Toutes les agrégations partent de la vue de travail ci-dessous.
-- =====================================================================

-- Vue de travail : 1 ligne = 1 ligne d'article d'une commande completed.
-- (vue temporaire : disparaît à la fin de la session)
CREATE TEMP VIEW ventes AS
SELECT i.order_item_id, i.order_id, o.customer_id, o.ordered_on,
       i.product_id, p.category_id,
       i.quantity, i.quantity * i.unit_price_cents AS montant_cents
FROM metier.order_items i
JOIN metier.orders   o USING (order_id)
JOIN metier.products p USING (product_id)
WHERE o.status = 'completed';

\echo '=== Contrôle : la vue ventes conserve le grain ligne d''article ==='
SELECT count(*) AS lignes, count(DISTINCT order_item_id) AS order_item_id_distincts,
       round(sum(montant_cents) / 100.0, 2) AS ca_euros     -- doit redonner 26 210,00 (S1)
FROM ventes;

-- =====================================================================
-- M2 — CLASSEMENTS
-- =====================================================================
\echo '=== M2a. Classement des produits par CA (global et dans leur catégorie) ==='
-- Grain de sortie : 1 ligne = 1 produit.
-- RANK : les ex æquo partagent le rang et le rang suivant est sauté (15, 15, 17).
-- DENSE_RANK et ROW_NUMBER sont affichés pour comparaison ; ROW_NUMBER
-- départage arbitrairement par product_id.
WITH ca_produit AS (
    SELECT product_id, category_id, sum(montant_cents) AS ca_cents, sum(quantity) AS unites
    FROM ventes GROUP BY product_id, category_id
)
SELECT c.category_name, p.product_id, pr.sku,
       round(ca_cents / 100.0, 2) AS ca_euros, unites,
       rank()       OVER (ORDER BY ca_cents DESC)                          AS rang_global,
       dense_rank() OVER (ORDER BY ca_cents DESC)                          AS rang_dense,
       row_number() OVER (ORDER BY ca_cents DESC, p.product_id)            AS rang_unique,
       rank()       OVER (PARTITION BY p.category_id ORDER BY ca_cents DESC) AS rang_dans_categorie
FROM ca_produit p
JOIN metier.products   pr USING (product_id)
JOIN metier.categories c  ON c.category_id = p.category_id
ORDER BY rang_global, p.product_id;

\echo '--- M2a bis. Ex æquo détectés dans le classement produits ---'
WITH ca_produit AS (SELECT product_id, sum(montant_cents) AS ca_cents FROM ventes GROUP BY product_id)
SELECT round(ca_cents / 100.0, 2) AS ca_euros, array_agg(product_id ORDER BY product_id) AS produits_ex_aequo
FROM ca_produit GROUP BY ca_cents HAVING count(*) > 1;

\echo '=== M2b. Top 10 clients par CA (RANK, ex æquo inclus) ==='
-- Grain : 1 ligne = 1 client ayant au moins une commande completed.
-- Le filtre rang <= 10 garde TOUS les clients ex æquo au 10e rang,
-- d'où potentiellement plus de 10 lignes.
WITH ca_client AS (
    SELECT customer_id, sum(montant_cents) AS ca_cents, count(DISTINCT order_id) AS commandes
    FROM ventes GROUP BY customer_id
), classe AS (
    SELECT *, rank() OVER (ORDER BY ca_cents DESC) AS rang FROM ca_client
)
SELECT rang, customer_id, round(ca_cents / 100.0, 2) AS ca_euros, commandes
FROM classe WHERE rang <= 10 ORDER BY rang, customer_id;

\echo '=== M2c. Effet d''une duplication sur le classement produits ==='
-- Si on joignait les ventes au catalogue BRUT (réception, produit 3 en double),
-- chaque vente du produit 3 serait comptée deux fois.
WITH brut AS (
    SELECT i.product_id, sum(i.quantity * i.unit_price_cents) AS ca_cents
    FROM metier.order_items i
    JOIN metier.orders o USING (order_id)
    JOIN reception.products rp ON rp.product_id = i.product_id::text     -- jointure sur le brut
    WHERE o.status = 'completed'
    GROUP BY i.product_id
), propre AS (
    SELECT product_id, sum(montant_cents) AS ca_cents FROM ventes GROUP BY product_id
), comparaison AS (
    SELECT p.product_id,
           round(p.ca_cents / 100.0, 2) AS ca_propre_euros,
           round(b.ca_cents / 100.0, 2) AS ca_brut_euros,
           rank() OVER (ORDER BY p.ca_cents DESC) AS rang_propre,
           rank() OVER (ORDER BY b.ca_cents DESC) AS rang_brut
    FROM propre p JOIN brut b USING (product_id)
)
SELECT * FROM comparaison WHERE rang_propre <> rang_brut OR ca_propre_euros <> ca_brut_euros
ORDER BY rang_brut;

-- =====================================================================
-- M3 — ÉVOLUTION PAR PÉRIODE (LAG / LEAD)
-- =====================================================================
\echo '=== M3a. CA mensuel, évolution vs mois précédent, couverture des jours ==='
-- Grain : 1 ligne = 1 mois. La série des mois est générée pour qu'un mois
-- sans vente apparaisse à 0 au lieu de disparaître (sinon LAG comparerait
-- deux mois non consécutifs).
-- Couverture : jours ayant au moins une commande (tous statuts) / jours du mois.
WITH bornes AS (
    SELECT min(ordered_on) AS debut, max(ordered_on) AS fin FROM metier.orders
), mois AS (
    SELECT generate_series(date_trunc('month', debut), date_trunc('month', fin), interval '1 month')::date AS mois
    FROM bornes
), ca_mois AS (
    SELECT date_trunc('month', ordered_on)::date AS mois, sum(montant_cents) AS ca_cents, count(DISTINCT order_id) AS commandes
    FROM ventes GROUP BY 1
), jours_obs AS (
    SELECT date_trunc('month', ordered_on)::date AS mois, count(DISTINCT ordered_on) AS jours_observes
    FROM metier.orders GROUP BY 1
), serie AS (
    SELECT m.mois,
           coalesce(c.ca_cents, 0) AS ca_cents,
           coalesce(c.commandes, 0) AS commandes,
           coalesce(j.jours_observes, 0) AS jours_observes,
           extract(day FROM (m.mois + interval '1 month - 1 day'))::int AS jours_du_mois
    FROM mois m LEFT JOIN ca_mois c USING (mois) LEFT JOIN jours_obs j USING (mois)
)
SELECT to_char(mois, 'YYYY-MM') AS mois, commandes,
       round(ca_cents / 100.0, 2) AS ca_euros,
       round(lag(ca_cents)  OVER w / 100.0, 2) AS ca_mois_precedent,
       round(lead(ca_cents) OVER w / 100.0, 2) AS ca_mois_suivant,
       round(100.0 * (ca_cents - lag(ca_cents) OVER w) / nullif(lag(ca_cents) OVER w, 0), 1) AS evolution_pct,
       jours_observes || '/' || jours_du_mois AS couverture,
       CASE WHEN jours_observes < jours_du_mois THEN 'INCOMPLET' ELSE 'complet' END AS statut_periode
FROM serie
WINDOW w AS (ORDER BY mois)
ORDER BY mois;

\echo '--- M3a bis. Même comparaison en CA moyen par jour observé (neutralise les mois incomplets) ---'
WITH ca_mois AS (
    SELECT date_trunc('month', ordered_on)::date AS mois, sum(montant_cents) AS ca_cents
    FROM ventes GROUP BY 1
), jours AS (
    SELECT date_trunc('month', ordered_on)::date AS mois, count(DISTINCT ordered_on) AS jours
    FROM metier.orders GROUP BY 1
)
SELECT to_char(mois, 'YYYY-MM') AS mois, jours,
       round(ca_cents / 100.0 / jours, 2) AS ca_par_jour_euros,
       round(100.0 * (ca_cents::numeric / jours - lag(ca_cents::numeric / jours) OVER (ORDER BY mois))
             / lag(ca_cents::numeric / jours) OVER (ORDER BY mois), 1) AS evolution_pct
FROM ca_mois JOIN jours USING (mois)
ORDER BY mois;

\echo '=== M3b. CA hebdomadaire (semaines ISO) avec LAG / LEAD ==='
WITH semaines AS (
    SELECT date_trunc('week', ordered_on)::date AS semaine,
           sum(montant_cents) AS ca_cents, count(DISTINCT order_id) AS commandes
    FROM ventes GROUP BY 1
), jours AS (
    SELECT date_trunc('week', ordered_on)::date AS semaine, count(DISTINCT ordered_on) AS jours_observes
    FROM metier.orders GROUP BY 1
)
SELECT semaine, commandes, round(ca_cents / 100.0, 2) AS ca_euros,
       round((ca_cents - lag(ca_cents) OVER w) / 100.0, 2)  AS ecart_vs_prec_euros,
       round((lead(ca_cents) OVER w - ca_cents) / 100.0, 2) AS ecart_vs_suiv_euros,
       jours_observes || '/7' AS couverture,
       CASE WHEN jours_observes < 7 THEN 'INCOMPLÈTE' ELSE 'complète' END AS statut_periode
FROM semaines JOIN jours USING (semaine)
WINDOW w AS (ORDER BY semaine)
ORDER BY semaine;

\echo '=== M3c. Cohérence dates ventes / catalogue (incohérence démontrée, pas évolution inhabituelle) ==='
SELECT v.product_id, p.first_listed_on, v.ordered_on, v.order_id, round(v.montant_cents / 100.0, 2) AS montant_euros
FROM ventes v JOIN metier.products p USING (product_id)
WHERE v.ordered_on < p.first_listed_on
ORDER BY v.ordered_on;

-- =====================================================================
-- M4 — SEGMENTATION (NTILE)
-- =====================================================================
\echo '=== M4a. Quartiles de clients par CA (NTILE(4)) ==='
-- Population : clients ayant au moins une commande completed (120).
--   Les 60 clients sans achat terminé sont exclus : sinon le dernier
--   quartile ne contiendrait que des 0 et ne mesurerait rien.
-- Mesure : CA completed du client. Ordre : CA décroissant, puis customer_id
--   (départage déterministe et reproductible).
WITH ca_client AS (
    SELECT customer_id, sum(montant_cents) AS ca_cents FROM ventes GROUP BY customer_id
), segments AS (
    SELECT customer_id, ca_cents, ntile(4) OVER (ORDER BY ca_cents DESC, customer_id) AS quartile
    FROM ca_client
)
SELECT quartile, count(*) AS clients,
       round(min(ca_cents) / 100.0, 2) AS ca_min_euros, round(max(ca_cents) / 100.0, 2) AS ca_max_euros,
       round(sum(ca_cents) / 100.0, 2) AS ca_total_euros,
       round(100.0 * sum(ca_cents) / sum(sum(ca_cents)) OVER (), 1) AS part_ca_pct
FROM segments GROUP BY quartile ORDER BY quartile;

\echo '--- M4b. Égalités coupées par une frontière de quartile ---'
-- NTILE coupe à effectif égal : deux clients au même CA peuvent tomber
-- dans deux quartiles différents. On les liste pour le documenter.
WITH ca_client AS (
    SELECT customer_id, sum(montant_cents) AS ca_cents FROM ventes GROUP BY customer_id
), segments AS (
    SELECT customer_id, ca_cents, ntile(4) OVER (ORDER BY ca_cents DESC, customer_id) AS quartile FROM ca_client
)
SELECT round(ca_cents / 100.0, 2) AS ca_euros,
       array_agg(customer_id || '→Q' || quartile ORDER BY customer_id) AS clients_et_quartiles
FROM segments GROUP BY ca_cents HAVING count(DISTINCT quartile) > 1
ORDER BY ca_cents DESC;

\echo '--- M4c. Population totale pour mémoire ---'
SELECT (SELECT count(*) FROM metier.customers) AS clients_total,
       (SELECT count(DISTINCT customer_id) FROM ventes) AS clients_segmentes,
       (SELECT count(*) FROM metier.customers c WHERE NOT EXISTS
           (SELECT 1 FROM ventes v WHERE v.customer_id = c.customer_id)) AS clients_hors_population;

-- =====================================================================
-- M5 — CTE RÉCURSIVE : hiérarchie des catégories et CA par branche
-- =====================================================================
\echo '=== M5a. Arbre des catégories (chemin, profondeur, contrôle de cycle) ==='
WITH RECURSIVE arbre AS (
    SELECT category_id, parent_category_id, category_name, 0 AS profondeur,
           ARRAY[category_id] AS chemin_ids, category_name::text AS chemin, false AS cycle
    FROM metier.categories WHERE parent_category_id IS NULL                       -- ancre : racines
    UNION ALL
    SELECT c.category_id, c.parent_category_id, c.category_name, a.profondeur + 1,
           a.chemin_ids || c.category_id, a.chemin || ' > ' || c.category_name,
           c.category_id = ANY (a.chemin_ids)                                     -- cycle détecté ?
    FROM metier.categories c
    JOIN arbre a ON c.parent_category_id = a.category_id
    WHERE NOT a.cycle AND a.profondeur < 20                                       -- condition d'arrêt
)
SELECT category_id, profondeur, chemin, cycle FROM arbre ORDER BY chemin;

\echo '=== M5b. CA consolidé par branche (chaque catégorie + toutes ses descendantes) ==='
-- Grain de sortie : 1 ligne = 1 catégorie. ancetres associe chaque
-- catégorie à elle-même et à tous ses ancêtres : une vente remonte ainsi
-- une seule fois à chaque niveau.
WITH RECURSIVE ancetres AS (
    SELECT category_id AS descendant_id, category_id AS ancetre_id, 0 AS distance
    FROM metier.categories
    UNION ALL
    SELECT a.descendant_id, c.parent_category_id, a.distance + 1
    FROM ancetres a JOIN metier.categories c ON c.category_id = a.ancetre_id
    WHERE c.parent_category_id IS NOT NULL AND a.distance < 20
), ca_categorie AS (
    SELECT category_id, sum(montant_cents) AS ca_cents FROM ventes GROUP BY category_id
)
SELECT c.category_id, c.category_name, c.parent_category_id,
       round(coalesce(sum(cc.ca_cents), 0) / 100.0, 2)                        AS ca_branche_euros,
       round(coalesce(max(cc.ca_cents) FILTER (WHERE a.distance = 0), 0) / 100.0, 2) AS ca_propre_euros,
       count(*) - 1                                                           AS nb_descendants
FROM metier.categories c
JOIN ancetres a ON a.ancetre_id = c.category_id
LEFT JOIN ca_categorie cc ON cc.category_id = a.descendant_id
GROUP BY c.category_id, c.category_name, c.parent_category_id
ORDER BY c.parent_category_id NULLS FIRST, ca_branche_euros DESC;

\echo '--- M5c. Contrôle anti double comptage : somme des racines = CA total ---'
WITH RECURSIVE ancetres AS (
    SELECT category_id AS descendant_id, category_id AS ancetre_id FROM metier.categories
    UNION ALL
    SELECT a.descendant_id, c.parent_category_id
    FROM ancetres a JOIN metier.categories c ON c.category_id = a.ancetre_id
    WHERE c.parent_category_id IS NOT NULL
), ca_categorie AS (
    SELECT category_id, sum(montant_cents) AS ca_cents FROM ventes GROUP BY category_id
)
SELECT round(sum(cc.ca_cents) / 100.0, 2)                    AS somme_branches_racines_euros,
       (SELECT round(sum(montant_cents) / 100.0, 2) FROM ventes) AS ca_total_euros,
       round(sum(cc.ca_cents) / 100.0, 2) = (SELECT round(sum(montant_cents) / 100.0, 2) FROM ventes) AS coherent
FROM ancetres a
JOIN metier.categories r ON r.category_id = a.ancetre_id AND r.parent_category_id IS NULL
JOIN ca_categorie cc ON cc.category_id = a.descendant_id;

-- =====================================================================
-- NovaMarket S2 — M1 : contrôles du catalogue (lecture seule)
-- =====================================================================

\echo '=== C1. Volumes reçus / intégrés / rejetés (catalogue) ==='
WITH v AS (
    SELECT 'categories.csv' AS source, (SELECT count(*) FROM reception.categories) AS recus, (SELECT count(*) FROM metier.categories) AS integres
    UNION ALL SELECT 'products.csv', (SELECT count(*) FROM reception.products), (SELECT count(*) FROM metier.products)
)
SELECT v.source, v.recus, v.integres,
       (SELECT count(*) FROM reception.rejets r WHERE r.source = v.source) AS rejetes,
       CASE WHEN v.recus = v.integres + (SELECT count(*) FROM reception.rejets r WHERE r.source = v.source)
            THEN 'OK' ELSE 'ÉCART' END AS bilan
FROM v;

\echo '=== C2. Rejets du catalogue ==='
SELECT source, ligne_id, cle_source, motif, contenu
FROM reception.rejets WHERE source IN ('categories.csv', 'products.csv')
ORDER BY source, ligne_id;

\echo '=== C3. Multiplicités à la réception : fiches produit en double ==='
-- Le doublon est-il exact (toutes colonnes identiques) ou contradictoire ?
SELECT product_id, count(*) AS occurrences,
       count(DISTINCT (sku, product_name, category_id, first_listed_on)) AS versions_differentes,
       array_agg(ligne_id ORDER BY ligne_id) AS lignes_reception
FROM reception.products
GROUP BY product_id
HAVING count(*) > 1;

\echo '=== C4. Couverture des codes produit vendus en S1 ==='
SELECT (SELECT count(DISTINCT product_id) FROM metier.order_items)                                   AS produits_vendus,
       (SELECT count(*) FROM metier.products)                                                        AS produits_catalogue,
       (SELECT count(DISTINCT i.product_id) FROM metier.order_items i
         WHERE NOT EXISTS (SELECT 1 FROM metier.products p WHERE p.product_id = i.product_id))       AS vendus_hors_catalogue,
       (SELECT count(*) FROM metier.products p
         WHERE NOT EXISTS (SELECT 1 FROM metier.order_items i WHERE i.product_id = p.product_id))    AS catalogue_jamais_vendu;

\echo '=== C5. Cohérence des dates : ventes avant la première mise en vente déclarée ==='
SELECT p.product_id, p.sku, p.first_listed_on,
       count(*)                                         AS lignes_concernees,
       min(o.ordered_on)                                AS premiere_vente,
       string_agg(DISTINCT o.status, ', ')              AS statuts,
       round(sum(i.quantity * i.unit_price_cents) / 100.0, 2) AS montant_euros
FROM metier.order_items i
JOIN metier.orders   o USING (order_id)
JOIN metier.products p USING (product_id)
WHERE o.ordered_on < p.first_listed_on
GROUP BY p.product_id, p.sku, p.first_listed_on;

\echo '=== C6. Hiérarchie : racines, profondeur, cycles, rattachement des produits ==='
WITH RECURSIVE arbre AS (
    SELECT category_id, parent_category_id, 0 AS profondeur, ARRAY[category_id] AS chemin, false AS cycle
    FROM metier.categories WHERE parent_category_id IS NULL
    UNION ALL
    SELECT c.category_id, c.parent_category_id, a.profondeur + 1, a.chemin || c.category_id,
           c.category_id = ANY (a.chemin)
    FROM metier.categories c JOIN arbre a ON c.parent_category_id = a.category_id
    WHERE NOT a.cycle
)
SELECT (SELECT count(*) FROM metier.categories WHERE parent_category_id IS NULL)              AS racines,
       (SELECT count(*) FROM arbre)                                                          AS categories_atteintes,
       (SELECT count(*) FROM metier.categories)                                              AS categories_total,
       (SELECT max(profondeur) FROM arbre)                                                   AS profondeur_max,
       (SELECT count(*) FROM arbre WHERE cycle)                                              AS cycles,
       (SELECT count(*) FROM metier.products p
         WHERE EXISTS (SELECT 1 FROM metier.categories c WHERE c.parent_category_id = p.category_id)) AS produits_sur_categorie_non_feuille;

\echo '=== C7. Contraintes ajoutées à la base S1 ==='
SELECT conrelid::regclass AS table_, conname, pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE conrelid IN ('metier.categories'::regclass, 'metier.products'::regclass, 'metier.order_items'::regclass)
  AND contype IN ('f', 'u', 'c')
ORDER BY 1, 2;

-- =====================================================================
-- NovaMarket S2 — M1 : intégration du catalogue (catégories, produits)
-- Prérequis : S1 chargé (01_schema + 02_import) et fichiers copiés dans
-- le conteneur (fait par run_s2.sh) :
--   docker compose exec -T postgres mkdir -p /tmp/novamarket-s2
--   docker compose cp s2/donnees/. postgres:/tmp/novamarket-s2/
-- Rejouable : ne touche qu'aux tables du catalogue ; les données S1 et
-- leurs rejets sont conservés.
-- =====================================================================
\set ON_ERROR_STOP 1
BEGIN;

-- 0. Remise à zéro du seul périmètre catalogue
ALTER TABLE metier.order_items DROP CONSTRAINT IF EXISTS order_items_product_fk;
DROP TABLE IF EXISTS metier.products, metier.categories;
DROP TABLE IF EXISTS reception.products, reception.categories;
DELETE FROM reception.rejets WHERE source IN ('categories.csv', 'products.csv');

-- ---------------------------------------------------------------------
-- 1. Réception brute (texte, sans contrainte, ligne_id = ordre de lecture)
-- ---------------------------------------------------------------------
CREATE TABLE reception.categories (
    ligne_id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    category_id        text,
    category_name      text,
    parent_category_id text
);
CREATE TABLE reception.products (
    ligne_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id      text,
    sku             text,
    product_name    text,
    category_id     text,
    first_listed_on text
);

\copy reception.categories (category_id, category_name, parent_category_id)          FROM '/tmp/novamarket-s2/categories.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy reception.products   (product_id, sku, product_name, category_id, first_listed_on) FROM '/tmp/novamarket-s2/products.csv'   WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

-- ---------------------------------------------------------------------
-- 2. Tables métier
--    categories : hiérarchie auto-référencée (parent NULL = racine)
--    products   : 1 fiche par product_id, sku unique
-- ---------------------------------------------------------------------
CREATE TABLE metier.categories (
    category_id        integer PRIMARY KEY,
    category_name      text    NOT NULL,
    parent_category_id integer REFERENCES metier.categories (category_id),
    CHECK (parent_category_id IS DISTINCT FROM category_id)   -- pas d'auto-boucle
);

CREATE TABLE metier.products (
    product_id      integer PRIMARY KEY,
    sku             text    NOT NULL UNIQUE,
    product_name    text    NOT NULL,
    category_id     integer NOT NULL REFERENCES metier.categories (category_id),
    first_listed_on date    NOT NULL
);
CREATE INDEX ON metier.products (category_id);

-- ---------------------------------------------------------------------
-- 3. Rejets puis intégration : catégories (parents avant enfants)
-- ---------------------------------------------------------------------
INSERT INTO reception.rejets (source, ligne_id, cle_source, motif, contenu)
SELECT 'categories.csv', ligne_id, category_id, motif, to_jsonb(r) - 'ligne_id' - 'motif'
FROM (
    SELECT r.*,
           CASE
             WHEN NOT pg_input_is_valid(category_id, 'integer')          THEN 'category_id absent ou non entier'
             WHEN coalesce(trim(category_name), '') = ''                  THEN 'category_name vide'
             WHEN parent_category_id IS NOT NULL
              AND NOT pg_input_is_valid(parent_category_id, 'integer')    THEN 'parent_category_id non entier'
             WHEN parent_category_id IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM reception.categories p WHERE p.category_id = r.parent_category_id)
                                                                          THEN 'parent inexistant (référence orpheline)'
             WHEN row_number() OVER (PARTITION BY category_id ORDER BY ligne_id) > 1
                                                                          THEN 'doublon de category_id (1re occurrence conservée)'
           END AS motif
    FROM reception.categories r
) r
WHERE motif IS NOT NULL;

-- Insertion dans l'ordre de la hiérarchie (racines d'abord) grâce à une CTE récursive
WITH RECURSIVE valides AS (
    SELECT category_id::integer AS category_id, trim(category_name) AS category_name,
           parent_category_id::integer AS parent_category_id
    FROM reception.categories r
    WHERE NOT EXISTS (SELECT 1 FROM reception.rejets j WHERE j.source = 'categories.csv' AND j.ligne_id = r.ligne_id)
), niveaux AS (
    SELECT v.*, 0 AS niveau FROM valides v WHERE parent_category_id IS NULL
    UNION ALL
    SELECT v.*, n.niveau + 1 FROM valides v JOIN niveaux n ON v.parent_category_id = n.category_id
    WHERE n.niveau < 20                                                -- garde-fou contre un cycle
)
INSERT INTO metier.categories (category_id, category_name, parent_category_id)
SELECT category_id, category_name, parent_category_id FROM niveaux ORDER BY niveau, category_id;

-- Catégories valides non atteignables depuis une racine = cycle -> rejet
INSERT INTO reception.rejets (source, ligne_id, cle_source, motif, contenu)
SELECT 'categories.csv', r.ligne_id, r.category_id, 'catégorie hors arbre (cycle ou parent rejeté)', to_jsonb(r) - 'ligne_id'
FROM reception.categories r
WHERE NOT EXISTS (SELECT 1 FROM reception.rejets j WHERE j.source = 'categories.csv' AND j.ligne_id = r.ligne_id)
  AND NOT EXISTS (SELECT 1 FROM metier.categories c WHERE c.category_id = r.category_id::integer);

-- ---------------------------------------------------------------------
-- 4. Rejets puis intégration : produits
-- ---------------------------------------------------------------------
INSERT INTO reception.rejets (source, ligne_id, cle_source, motif, contenu)
SELECT 'products.csv', ligne_id, product_id, motif, to_jsonb(r) - 'ligne_id' - 'motif' - 'occ_id' - 'occ_sku'
FROM (
    SELECT r.*,
           CASE
             WHEN NOT pg_input_is_valid(product_id, 'integer')            THEN 'product_id absent ou non entier'
             WHEN coalesce(trim(sku), '') = ''                             THEN 'sku vide'
             WHEN coalesce(trim(product_name), '') = ''                    THEN 'product_name vide'
             WHEN NOT pg_input_is_valid(category_id, 'integer')            THEN 'category_id absent ou non entier'
             WHEN first_listed_on !~ '^\d{4}-\d{2}-\d{2}$'
               OR NOT pg_input_is_valid(first_listed_on, 'date')           THEN 'first_listed_on non ISO AAAA-MM-JJ'
             WHEN NOT EXISTS (SELECT 1 FROM metier.categories c WHERE c.category_id = r.category_id::integer)
                                                                           THEN 'catégorie inexistante (référence orpheline)'
             WHEN occ_id > 1                                               THEN 'doublon de fiche produit (même product_id ; 1re occurrence conservée)'
             WHEN occ_sku > 1                                              THEN 'sku déjà utilisé par un autre produit'
           END AS motif
    FROM (
        SELECT r.*,
               row_number() OVER (PARTITION BY product_id ORDER BY ligne_id) AS occ_id,
               row_number() OVER (PARTITION BY sku        ORDER BY ligne_id) AS occ_sku
        FROM reception.products r
    ) r
) r
WHERE motif IS NOT NULL;

INSERT INTO metier.products (product_id, sku, product_name, category_id, first_listed_on)
SELECT product_id::integer, trim(sku), trim(product_name), category_id::integer, first_listed_on::date
FROM reception.products r
WHERE NOT EXISTS (SELECT 1 FROM reception.rejets j WHERE j.source = 'products.csv' AND j.ligne_id = r.ligne_id);

-- ---------------------------------------------------------------------
-- 5. Intégrité avec S1 : chaque ligne vendue doit pointer vers un produit.
--    La contrainte n'est ajoutée qu'après contrôle de couverture ; si un
--    code vendu manquait au catalogue, l'ALTER échouerait et la
--    transaction serait annulée (les données S1 restent intactes).
-- ---------------------------------------------------------------------
ALTER TABLE metier.order_items
    ADD CONSTRAINT order_items_product_fk FOREIGN KEY (product_id) REFERENCES metier.products (product_id);
CREATE INDEX IF NOT EXISTS order_items_product_id_idx ON metier.order_items (product_id);

COMMIT;
\echo 'Catalogue intégré. Lancer sql/08_controles_catalogue.sql pour le bilan.'

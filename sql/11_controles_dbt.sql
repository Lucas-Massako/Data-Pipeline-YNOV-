-- =====================================================================
-- NovaMarket S4 — M1/M5 : contrôles du chargement et de la chaîne dbt (lecture seule)
-- Exécution : docker compose exec -T postgres psql -X -U atelier -d novamarket < sql/11_controles_dbt.sql
-- =====================================================================

\echo '=== 1. Journal des chargements (M1) ==='
SELECT chargement_id, fichier, lignes_lues, inserees, mises_a_jour, inchangees, rejetees,
       to_char(debut, 'YYYY-MM-DD HH24:MI:SS') AS debut
FROM fournisseur.chargements ORDER BY chargement_id;

\echo '=== 2. Volumes source -> staging -> mart (M5) ==='
SELECT 'source fournisseur.offres_observations' AS niveau, count(*) AS lignes, 'offre x jour' AS grain
FROM fournisseur.offres_observations
UNION ALL SELECT 'staging stg_fournisseur__offres', count(*), 'offre x jour'
FROM dbt_dev_staging.stg_fournisseur__offres
UNION ALL SELECT 'mart mart_offres_par_produit (lignes)', count(*), 'produit x jour'
FROM dbt_dev_marts.mart_offres_par_produit
UNION ALL SELECT 'mart mart_offres_par_produit (somme nb_offres)', sum(nb_offres), 'doit = staging'
FROM dbt_dev_marts.mart_offres_par_produit;

\echo '=== 3. Multiplication évitée : jointure offres x lignes vendues SANS pré-agrégation ==='
SELECT 'offres' AS calcul, count(*) AS lignes FROM dbt_dev_staging.stg_fournisseur__offres
UNION ALL
SELECT 'offres JOIN lignes vendues (FAUX)', count(*)
FROM dbt_dev_staging.stg_fournisseur__offres o
JOIN dbt_dev_staging.stg_metier__lignes_vendues v USING (produit_id)
UNION ALL
SELECT 'offres JOIN ventes agrégées par produit (JUSTE)', count(*)
FROM dbt_dev_staging.stg_fournisseur__offres o
LEFT JOIN (SELECT produit_id FROM dbt_dev_staging.stg_metier__lignes_vendues GROUP BY produit_id) v USING (produit_id);

\echo '=== 4. Quelques lignes du mart ==='
SELECT produit_id, date_observation, sku, categorie_nom, nb_offres, meilleur_fournisseur_id,
       meilleur_prix_cents, prix_vente_moyen_cents, marge_unitaire_cents, unites_disponibles
FROM dbt_dev_marts.mart_offres_par_produit
ORDER BY marge_unitaire_cents DESC NULLS LAST
LIMIT 8;

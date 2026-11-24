-- =====================================================================
-- NovaMarket S3 — benchmark : mesures avant / après index
-- Prérequis : s3/generer.sql exécuté (schéma benchmark, 10 000 000 lignes).
-- Exécution : docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U atelier -d novamarket < sql/10_benchmark_mesures.sql
-- Rejouable : supprime l'index étudié au début pour repartir d'une
-- référence SANS index ; les mesures sont stockées dans le schéma perf
-- (distinct de benchmark, qui ne contient que les données simulées).
-- Les ventes simulées ne participent jamais au CA NovaMarket.
-- =====================================================================
\set ON_ERROR_STOP 1
\pset pager off

-- ---------------------------------------------------------------------
-- 0. Contexte de mesure (à recopier dans le compte rendu)
-- ---------------------------------------------------------------------
\echo '=== 0. Contexte ==='
SELECT version();
SELECT name, setting, unit FROM pg_settings
WHERE name IN ('shared_buffers', 'work_mem', 'effective_cache_size', 'random_page_cost',
               'max_parallel_workers_per_gather', 'jit')
ORDER BY name;

\echo '--- Volume et taille de la table ---'
SELECT count(*) AS lignes,
       pg_size_pretty(pg_relation_size('benchmark.benchmark_sales'))       AS taille_table,
       pg_size_pretty(pg_total_relation_size('benchmark.benchmark_sales')) AS taille_totale
FROM benchmark.benchmark_sales;

\echo '--- Sélectivité des deux filtres étudiés ---'
SELECT store_id, count(*) AS lignes,
       round(100.0 * count(*) / 10000000, 4) AS pct_table
FROM benchmark.benchmark_sales
WHERE store_id IN (1, 42)
GROUP BY store_id ORDER BY store_id;

-- ---------------------------------------------------------------------
-- 1. Outillage de mesure
--    perf.mesurer exécute n+1 fois EXPLAIN (ANALYZE, BUFFERS) :
--    essai 0 = premier passage (cache froid / JIT), essais 1..n = répétitions.
-- ---------------------------------------------------------------------
DROP INDEX IF EXISTS benchmark.benchmark_sales_store_id_idx;
DROP SCHEMA IF EXISTS perf CASCADE;
CREATE SCHEMA perf;

CREATE TABLE perf.mesures (
    mesure_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    requete       text    NOT NULL,
    phase         text    NOT NULL,
    essai         integer NOT NULL,
    execution_ms  numeric NOT NULL,
    planning_ms   numeric NOT NULL,
    noeuds        text    NOT NULL,     -- types de nœuds du plan, du haut vers le bas
    shared_hit    bigint,
    shared_read   bigint,
    temp_read     bigint
);

CREATE TABLE perf.index_construction (
    index_nom    text PRIMARY KEY,
    definition   text,
    duree_ms     numeric,
    taille       text,
    taille_octets bigint
);

CREATE FUNCTION perf.mesurer(p_requete text, p_libelle text, p_phase text, p_repetitions integer DEFAULT 3)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    plan jsonb;
BEGIN
    FOR i IN 0 .. p_repetitions LOOP
        EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || p_requete INTO plan;
        INSERT INTO perf.mesures (requete, phase, essai, execution_ms, planning_ms, noeuds,
                                  shared_hit, shared_read, temp_read)
        VALUES (p_libelle, p_phase, i,
                (plan -> 0 ->> 'Execution Time')::numeric,
                (plan -> 0 ->> 'Planning Time')::numeric,
                (SELECT string_agg(n #>> '{}', ' > ')
                   FROM jsonb_path_query(plan, 'strict $.**."Node Type"') AS n),
                (plan -> 0 -> 'Plan' ->> 'Shared Hit Blocks')::bigint,
                (plan -> 0 -> 'Plan' ->> 'Shared Read Blocks')::bigint,
                (plan -> 0 -> 'Plan' ->> 'Temp Read Blocks')::bigint);
    END LOOP;
END $$;

-- Requêtes étudiées (même texte avant et après) :
--   QA filtre très sélectif : magasin 42 =        100 lignes (0,001 %)
--   QB filtre très large    : magasin 1  =  9 500 000 lignes (95 %)
\set qa 'SELECT count(*), sum(amount_cents) FROM benchmark.benchmark_sales WHERE store_id = 42'
\set qb 'SELECT count(*), sum(amount_cents) FROM benchmark.benchmark_sales WHERE store_id = 1'

-- ---------------------------------------------------------------------
-- 2. RÉFÉRENCE SANS INDEX
-- ---------------------------------------------------------------------
\echo '=== 2. Référence SANS index : plans estimés puis plans complets ==='
\echo '--- QA (store_id = 42) : EXPLAIN ---'
EXPLAIN :qa;
\echo '--- QA : EXPLAIN (ANALYZE, BUFFERS) ---'
EXPLAIN (ANALYZE, BUFFERS) :qa;
\echo '--- QB (store_id = 1) : EXPLAIN (ANALYZE, BUFFERS) ---'
EXPLAIN (ANALYZE, BUFFERS) :qb;

SELECT perf.mesurer(:'qa', 'QA store 42 (0,001 %)', '1 sans index');
SELECT perf.mesurer(:'qb', 'QB store 1 (95 %)',     '1 sans index');

-- ---------------------------------------------------------------------
-- 3. CRÉATION DE L'INDEX (coût et taille mesurés à part)
-- ---------------------------------------------------------------------
\echo '=== 3. Construction de l''index sur store_id ==='
DO $$
DECLARE t0 timestamptz := clock_timestamp();
BEGIN
    CREATE INDEX benchmark_sales_store_id_idx ON benchmark.benchmark_sales (store_id);
    INSERT INTO perf.index_construction
    SELECT 'benchmark_sales_store_id_idx',
           pg_get_indexdef('benchmark.benchmark_sales_store_id_idx'::regclass),
           round(extract(epoch FROM clock_timestamp() - t0) * 1000, 1),
           pg_size_pretty(pg_relation_size('benchmark.benchmark_sales_store_id_idx')),
           pg_relation_size('benchmark.benchmark_sales_store_id_idx');
END $$;
ANALYZE benchmark.benchmark_sales;
SELECT index_nom, definition, duree_ms, taille,
       round(100.0 * taille_octets / pg_relation_size('benchmark.benchmark_sales'), 1) AS pct_taille_table
FROM perf.index_construction;

-- ---------------------------------------------------------------------
-- 4. APRÈS INDEX : mêmes requêtes, même méthode
-- ---------------------------------------------------------------------
\echo '=== 4. APRÈS index ==='
\echo '--- QA (store_id = 42) : EXPLAIN (ANALYZE, BUFFERS) ---'
EXPLAIN (ANALYZE, BUFFERS) :qa;
\echo '--- QB (store_id = 1) : EXPLAIN (ANALYZE, BUFFERS) — le planificateur ignore-t-il l''index ? ---'
EXPLAIN (ANALYZE, BUFFERS) :qb;

SELECT perf.mesurer(:'qa', 'QA store 42 (0,001 %)', '2 avec index');
SELECT perf.mesurer(:'qb', 'QB store 1 (95 %)',     '2 avec index');

\echo '=== 5. Cas d''index inefficace : on FORCE l''index sur QB (enable_seqscan = off) ==='
BEGIN;
SET LOCAL enable_seqscan = off;
EXPLAIN (ANALYZE, BUFFERS) :qb;
SELECT perf.mesurer(:'qb', 'QB store 1 (95 %)', '3 index forcé');
COMMIT;

-- ---------------------------------------------------------------------
-- 6. Tableau de synthèse : premier passage et médiane des répétitions
-- ---------------------------------------------------------------------
\echo '=== 6. Synthèse des mesures (médiane des essais 1..3, premier passage à part) ==='
SELECT requete, phase,
       max(execution_ms) FILTER (WHERE essai = 0)                                         AS premier_passage_ms,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY execution_ms) FILTER (WHERE essai > 0)::numeric, 3) AS mediane_ms,
       round(min(execution_ms) FILTER (WHERE essai > 0), 3)                                 AS min_ms,
       round(max(execution_ms) FILTER (WHERE essai > 0), 3)                                 AS max_ms,
       max(shared_hit)  FILTER (WHERE essai = 3)                                           AS shared_hit,
       max(shared_read) FILTER (WHERE essai = 3)                                           AS shared_read,
       max(noeuds)      FILTER (WHERE essai = 3)                                           AS plan
FROM perf.mesures
GROUP BY requete, phase
ORDER BY requete, phase;

\echo '--- Détail de chaque essai ---'
SELECT requete, phase, essai, execution_ms, planning_ms, shared_hit, shared_read
FROM perf.mesures ORDER BY requete, phase, essai;

-- ---------------------------------------------------------------------
-- 7. Analyse critique
-- ---------------------------------------------------------------------
\echo '=== 7a. Jointure qui multiplie les lignes : ventes x campagnes (magasin 42 dans 2 campagnes) ==='
SELECT 'ventes du magasin 42 (grain vente)'         AS calcul, count(*) AS lignes, sum(amount_cents) AS montant_cents
FROM benchmark.benchmark_sales WHERE store_id = 42
UNION ALL
SELECT 'JOIN campaign_assignments (FAUX : x2)', count(*), sum(s.amount_cents)
FROM benchmark.benchmark_sales s JOIN benchmark.campaign_assignments c USING (store_id)
WHERE s.store_id = 42
UNION ALL
SELECT 'EXISTS (JUSTE : magasin en campagne)', count(*), sum(s.amount_cents)
FROM benchmark.benchmark_sales s
WHERE s.store_id = 42 AND EXISTS (SELECT 1 FROM benchmark.campaign_assignments c WHERE c.store_id = s.store_id);

\echo '--- Plan de la jointure : lignes en entrée / sortie ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.campaign_id, count(*), sum(s.amount_cents)
FROM benchmark.benchmark_sales s JOIN benchmark.campaign_assignments c USING (store_id)
WHERE s.store_id = 42
GROUP BY c.campaign_id;

\echo '=== 7b. Écart estimé / réel : zone_id et channel_id parfaitement corrélés ==='
-- Le planificateur suppose les colonnes indépendantes : 10 % x 10 % = 1 %
-- (~100 000 lignes estimées) alors que zone_id = channel_id sur chaque ligne
-- (1 000 000 lignes réelles).
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM benchmark.benchmark_sales WHERE zone_id = 3 AND channel_id = 3;

\echo '--- 7c. Correction : statistiques étendues de dépendance ---'
CREATE STATISTICS IF NOT EXISTS benchmark.sales_zone_channel_dep (dependencies) ON zone_id, channel_id
    FROM benchmark.benchmark_sales;
ANALYZE benchmark.benchmark_sales;
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM benchmark.benchmark_sales WHERE zone_id = 3 AND channel_id = 3;
DROP STATISTICS benchmark.sales_zone_channel_dep;
ANALYZE benchmark.benchmark_sales;

\echo 'Fin des mesures. L''index benchmark_sales_store_id_idx est conservé (supprimé au prochain lancement).'

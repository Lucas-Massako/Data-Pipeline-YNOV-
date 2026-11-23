-- =====================================================================
-- NovaMarket S1 — A1 (approfondissement) : anomalies d'une table redondante
-- Fichier : /s1/exemple/planning_a_normaliser.csv
-- Tout est dans des tables temporaires + ROLLBACK : rien n'est conservé.
-- Exécution : docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U atelier -d novamarket < sql/06_normalisation_A1.sql
-- =====================================================================
\set ON_ERROR_STOP 1
BEGIN;

CREATE TEMP TABLE planning (
    reservation_id integer PRIMARY KEY,
    salle_id       integer NOT NULL,
    salle_nom      text    NOT NULL,
    responsable    text    NOT NULL
);
\copy planning FROM '/s1/exemple/planning_a_normaliser.csv' WITH (FORMAT csv, HEADER true)

\echo '--- État initial (nom et responsable répétés à chaque réservation) ---'
SELECT * FROM planning ORDER BY reservation_id;

\echo '--- Anomalie de MISE À JOUR : on change le responsable sur une seule ligne ---'
UPDATE planning SET responsable = 'Bilal' WHERE reservation_id = 1;
SELECT salle_id, salle_nom, array_agg(DISTINCT responsable) AS responsables
FROM planning GROUP BY salle_id, salle_nom;   -- salle 1 a maintenant 2 responsables : incohérence

\echo '--- Anomalie d''INSERTION : impossible de créer une salle sans réservation ---'
SAVEPOINT avant_insert;
\set ON_ERROR_STOP 0
INSERT INTO planning (reservation_id, salle_id, salle_nom, responsable)
VALUES (NULL, 3, 'Atelier Photo', 'Inès');      -- échoue : reservation_id obligatoire
\set ON_ERROR_STOP 1
ROLLBACK TO SAVEPOINT avant_insert;

\echo '--- Anomalie de SUPPRESSION : supprimer la dernière réservation fait disparaître la salle ---'
DELETE FROM planning WHERE salle_id = 2;
SELECT DISTINCT salle_id, salle_nom FROM planning;  -- l'Atelier Textile et Sam n'existent plus nulle part

\echo '--- Correction : schéma normalisé (3FN) ---'
CREATE TEMP TABLE salles_n (
    salle_id    integer PRIMARY KEY,
    nom         text NOT NULL,
    responsable text NOT NULL
);
CREATE TEMP TABLE reservations_n (
    reservation_id integer PRIMARY KEY,
    salle_id       integer NOT NULL REFERENCES salles_n (salle_id)
);
INSERT INTO salles_n VALUES (1, 'Atelier Céramique', 'Ariane'), (2, 'Atelier Textile', 'Sam'), (3, 'Atelier Photo', 'Inès');
INSERT INTO reservations_n VALUES (1, 1), (2, 1), (3, 2);
UPDATE salles_n SET responsable = 'Bilal' WHERE salle_id = 1;   -- 1 seule ligne à modifier
DELETE FROM reservations_n WHERE salle_id = 2;                  -- la salle 2 reste connue
SELECT s.salle_id, s.nom, s.responsable, count(r.reservation_id) AS reservations
FROM salles_n s LEFT JOIN reservations_n r USING (salle_id)
GROUP BY s.salle_id, s.nom, s.responsable ORDER BY s.salle_id;

ROLLBACK;

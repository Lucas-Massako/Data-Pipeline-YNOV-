#!/usr/bin/env bash
# NovaMarket S2 — catalogue + analyses avancées, avec preuves.
# Prérequis : base S1 chargée (bash run_s1.sh). Usage : bash run_s2.sh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p preuves

docker compose up -d --wait postgres

# Fichiers S2 copiés dans le conteneur (s2/ n'est pas monté par compose.yaml)
docker compose exec -T postgres mkdir -p /tmp/novamarket-s2
docker compose cp s2/donnees/. postgres:/tmp/novamarket-s2/

PSQL=(docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U atelier -d novamarket)

echo ">> 07_catalogue"
"${PSQL[@]}" < sql/07_catalogue.sql > /dev/null

for f in 08_controles_catalogue 09_analyses_avancees; do
  echo ">> $f  ->  preuves/$f.txt"
  "${PSQL[@]}" < "sql/$f.sql" > "preuves/$f.txt" 2>&1
done

echo "Terminé. Résultats dans preuves/ ."

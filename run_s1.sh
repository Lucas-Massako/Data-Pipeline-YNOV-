#!/usr/bin/env bash
# NovaMarket S1 — rejoue toute la chaîne et enregistre les preuves.
# Usage (depuis novamarket/) :  bash run_s1.sh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p preuves

docker compose up -d --wait postgres

PSQL=(docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U atelier -d novamarket)

for f in 01_schema 02_import; do
  echo ">> $f"
  "${PSQL[@]}" < "sql/$f.sql" > /dev/null
done

for f in 03_controles 04_indicateurs 05_anomalies 06_normalisation_A1; do
  echo ">> $f  ->  preuves/$f.txt"
  "${PSQL[@]}" < "sql/$f.sql" > "preuves/$f.txt" 2>&1
done

echo "Terminé. Résultats dans preuves/ ."

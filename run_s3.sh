#!/usr/bin/env bash
# NovaMarket S3 — génération du benchmark (si absent) puis mesures.
# Usage : bash run_s3.sh   (compter quelques minutes)
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p preuves

docker compose up -d --wait postgres
PSQL=(docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U atelier -d novamarket)

existe=$("${PSQL[@]}" -tAc "SELECT to_regclass('benchmark.benchmark_sales') IS NOT NULL")
if [ "$existe" = "t" ]; then
  echo ">> schéma benchmark déjà présent : génération ignorée"
else
  echo ">> génération des 10 000 000 lignes (s3/generer.sql)  ->  preuves/10_generation.txt"
  "${PSQL[@]}" < s3/generer.sql > preuves/10_generation.txt 2>&1
fi

echo ">> 10_benchmark_mesures  ->  preuves/10_benchmark_mesures.txt"
"${PSQL[@]}" < sql/10_benchmark_mesures.sql > preuves/10_benchmark_mesures.txt 2>&1

echo "Terminé. Synthèse : section 6 de preuves/10_benchmark_mesures.txt"

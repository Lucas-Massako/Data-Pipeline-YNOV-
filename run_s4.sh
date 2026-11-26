#!/usr/bin/env bash
# NovaMarket S4 — chargement PostgreSQL + chaîne dbt, avec preuves.
# Prérequis : S1/S2 chargés (metier.products existe), venv S3 activé (psycopg installé).
# Usage (depuis novamarket/) : bash run_s4.sh
# Le mot de passe PostgreSQL est demandé une fois et n'est écrit nulle part.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p preuves

export NOVAMARKET_DSN="${NOVAMARKET_DSN:-host=127.0.0.1 port=${NOVAMARKET_PG_PORT:-15432} dbname=novamarket user=atelier}"
if [ -z "${DBT_ENV_SECRET_PASSWORD:-}" ]; then
  read -rsp "Mot de passe PostgreSQL (atelier) : " DBT_ENV_SECRET_PASSWORD; echo
fi
export DBT_ENV_SECRET_PASSWORD PGPASSWORD="$DBT_ENV_SECRET_PASSWORD" DBT_DATABASE=novamarket

docker compose up -d --wait postgres

echo ">> M1 chargement (exemple, 1er passage, rejeu, échec simulé)  ->  preuves/12_chargement.txt"
{
  echo "### exemple transactionnel (cuves)";      python transformation/exemple.py
  echo "### 1er passage";                         python transformation/chargement_postgres.py
  echo "### 2e passage, même lot (rejeu)";        python transformation/chargement_postgres.py
  echo "### échec simulé avant COMMIT";           python transformation/chargement_postgres.py --simuler-echec || true
} > preuves/12_chargement.txt 2>&1

echo ">> dbt (debug, compile, run, build)  ->  preuves/13_dbt.txt"
docker compose --profile transfo build dbt
mkdir -p s4/travail/profil
[ -f s4/travail/profil/profiles.yml ] || cp transformation/dbt/profiles.exemple.yml s4/travail/profil/profiles.yml
DBT=(docker compose --profile transfo run --rm --no-deps --user "$(id -u):$(id -g)" -w /projet
     -e DBT_ENV_SECRET_PASSWORD -e DBT_DATABASE dbt)
: > preuves/13_dbt.txt
for c in debug compile run build; do
  echo "### dbt $c" >> preuves/13_dbt.txt
  "${DBT[@]}" dbt "$c" --profiles-dir /work/profil --no-use-colors >> preuves/13_dbt.txt 2>&1
done
cp transformation/dbt/target/compiled/novamarket_dbt/models/marts/mart_offres_par_produit.sql preuves/14_mart_compile.sql

echo ">> M5 contrôles des volumes  ->  preuves/15_controles_dbt.txt"
docker compose exec -T postgres psql -X -U atelier -d novamarket < sql/11_controles_dbt.sql > preuves/15_controles_dbt.txt 2>&1

echo "Terminé. Preuves : preuves/12 à 15."

#!/usr/bin/env bash
# NovaMarket S3 — ingestion asynchrone : rejoue les 4 collectes et écrit le bilan.
# Prérequis : venv Python 3.12 activé et requirements-v3.txt installé
#   python3.12 -m venv .venv && source .venv/bin/activate && python -m pip install -r requirements-v3.txt
# Usage (depuis novamarket/) : bash run_ingestion.sh
set -uo pipefail
cd "$(dirname "$0")"
mkdir -p preuves

docker compose up -d --build --wait fournisseur
python ingestion/tests/disponibilite.py || exit 1

suffixe=$(date +%Y%m%d%H%M%S)     # run neuf à chaque lancement : les erreurs injectées sont rejouées
sortie=preuves/11_ingestion.txt
: > "$sortie"

collecte () {   # $1 = scénario, $2 = nom du run, $3 = concurrence
  echo ">> $1 (run $2, concurrence $3)"
  python ingestion/src/collecteur.py --scenario "$1" --run "$2" --concurrence "$3" >> "$sortie" 2>&1
  echo "   code retour : $?" | tee -a "$sortie"
}

collecte clean   "clean-$suffixe"   3
collecte clean   "seq-$suffixe"     1      # comparaison séquentielle
collecte panne   "panne-$suffixe"   3      # échec attendu : aucune publication
collecte atelier "atelier-$suffixe" 3      # dernier lot publié = lot atelier, utilisé en S4

echo "Terminé. Journal : $sortie ; bilans : ingestion/data/journaux/*-$suffixe/bilan.json"

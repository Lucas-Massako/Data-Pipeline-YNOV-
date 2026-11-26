#!/usr/bin/env bash
# NovaMarket S5 — Hugging Face streaming, contrôle, PySpark, préparation Hub. Preuves : preuves/16_s5.txt
# Prérequis : venv S3 activé, Java 21 installé.
#   python -m pip install -r requirements-v3.txt -r volumetrie/requirements.txt
# Usage (depuis novamarket/) : bash run_s5.sh [limite]      (défaut : 20000 lignes parcourues)
# La publication Hub (hf auth login / upload) reste manuelle : voir README, section S5 M5.
set -uo pipefail
cd "$(dirname "$0")"
mkdir -p preuves volumetrie/sorties
limite="${1:-20000}"
export JAVA_HOME="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")}"
export SPARK_LOCAL_IP=127.0.0.1
export PYSPARK_PYTHON="$(command -v python)"
export PYSPARK_SUBMIT_ARGS="--driver-memory 1g pyspark-shell"
export HF_HUB_DISABLE_XET=1
horo=$(date +%Y%m%d%H%M%S)
journal=preuves/16_s5.txt
: > "$journal"
etape () { echo ">> $1" | tee -a "$journal"; }

etape "environnement"
{ python --version; java -version 2>&1 | head -1; python volumetrie/spark/verifier.py 2>&1 | grep -i "spark local"; } >> "$journal" 2>&1

etape "M1 métadonnées de la source"
python volumetrie/hf_datasets/acces.py --infos >> "$journal" 2>&1

etape "M2 streaming distant borné ($limite lignes)"
entree_spark=""
if python volumetrie/hf_datasets/acces.py >> "$journal" 2>&1 \
   && python volumetrie/streaming/extraire.py --limite "$limite" >> "$journal" 2>&1; then
  extraction=$(ls -t volumetrie/sorties/extraction_*[0-9].jsonl | head -1)
  etape "M3 contrôle qualité de $extraction"
  python volumetrie/streaming/controler.py "$extraction" >> "$journal" 2>&1 && entree_spark="${extraction%.jsonl}.spark.jsonl"
else
  echo "   streaming distant en échec : M2/M3 à refaire avec le réseau ; Spark lancé sur le secours" | tee -a "$journal"
fi

etape "M4 pipeline Spark"
if [ -n "$entree_spark" ]; then
  python volumetrie/spark/pipeline.py "$entree_spark" "volumetrie/sorties/agregat_$horo" >> "$journal" 2>&1
fi
python volumetrie/spark/pipeline.py volumetrie/secours/trajets_fictifs.jsonl "volumetrie/sorties/agregat_secours_$horo" >> "$journal" 2>&1

etape "M5 préparation publication/ (version 1)"
python volumetrie/publication/preparer.py --version 1 >> "$journal" 2>&1

echo "Terminé. Journal : $journal ; sorties : volumetrie/sorties/ ; dossier à publier : publication/"

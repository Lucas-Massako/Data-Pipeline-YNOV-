# Fiche source S5 — NYC TaxiData (M1)

| Élément | Valeur |
|---|---|
| Identifiant | `DinoPonjevic/NYC_TaxiData` (Hugging Face, type dataset) |
| Révision épinglée | `5941adbf8c0b9930e47002dc3103de3f9291360d` (`hf_datasets/source.json`) |
| Taille du dépôt | 371 fichiers Parquet, 39 350 805 895 octets (≈ 39,35 Go) |
| Partition étudiée | `2024/yellow/yellow_tripdata_2024-01.parquet` (taxis jaunes, janvier 2024) ; taille exacte : `taille_partition` dans `preuves/16_s5.txt` |
| Colonnes lues | `Start_Zone` (code zone TLC, 1 à 265), `Trip_Distance` (miles), `Trip_Duration` (secondes) |
| Table de référence | `secours/zones.csv` : 265 zones TLC (`LocationID`, `Borough`, `Zone`, `service_zone`) |
| Origine | données publiques NYC TLC, republiées et normalisées par le miroir |
| Restrictions | licence du miroir « unknown » : lecture et analyse seulement ; **aucune republication de lignes brutes**. Publication Hub limitée au jeu synthétique `secours/` |

## Pourquoi ne pas tout charger en RAM

Le dépôt fait 39,35 Go : il ne tient pas dans la mémoire d'un poste de TP, et Docker est limité à 2 Go. Même une seule partition mensuelle se compte en millions de trajets. Le TP n'a besoin que de 3 colonnes et d'un échantillon borné : le streaming lit les lignes au fur et à mesure, sans télécharger le dépôt.

| Outil | Modèle d'exécution | Adapté quand |
|---|---|---|
| Pandas | tout le tableau en mémoire, un seul processus | le jeu tient largement en RAM (quelques centaines de Mo) |
| Hugging Face Datasets (`streaming=True`) | itérateur ligne à ligne sur des fichiers distants, révision épinglée | explorer ou extraire un sous-ensemble d'une source volumineuse sans la télécharger |
| Spark (PySpark) | plan d'exécution distribué en partitions, évaluation paresseuse | transformations, jointures et agrégations sur des volumes qui dépassent la mémoire d'une machine |

## Mesures à ne pas confondre

Taille du dépôt (39,35 Go) ≠ taille de la partition ≠ octets transférés ≠ lignes parcourues par le script (bornées par `--limite`). Les compteurs réels sont dans `volumetrie/sorties/extraction_*.bilan.json`.

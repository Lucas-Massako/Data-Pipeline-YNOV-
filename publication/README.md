---
pretty_name: NovaMarket S5 — agrégat de trajets fictifs par arrondissement
license: other
tags:
  - education
  - synthetic
size_categories:
  - n<1K
---

# NovaMarket S5 — agrégat de trajets fictifs

Jeu d'exercice du cours « Ingénierie des données et pipelines SQL » (YNOV, M1 Data IA).
Il est **synthétique et agrégé** : il est calculé à partir du fichier de secours
`volumetrie/secours/trajets_fictifs.jsonl` fourni par le formateur, et de la table de zones TLC
`volumetrie/secours/zones.csv`. Aucune ligne du miroir `DinoPonjevic/NYC_TaxiData`
(révision `5941adbf8c0b9930e47002dc3103de3f9291360d`, licence indiquée « unknown ») n'est republiée.

Usage : pédagogique uniquement. Ne pas utiliser pour une analyse réelle du trafic new-yorkais.

## Colonnes et unités

Grain : **un arrondissement** (Borough). Fichier : `agregat_arrondissements.parquet`, 3 lignes.

| Colonne | Type | Description |
|---|---|---|
| `arrondissement` | texte | arrondissement TLC (`Borough` de zones.csv) |
| `nb_trajets` | entier | nombre de trajets fictifs retenus |
| `distance_moyenne_miles` | réel | distance moyenne, en miles |

Pas de valeur manquante. Pas de dimension temporelle (les trajets fictifs ne sont pas datés).

## Extraction et qualité

- Lignes parcourues : 6 ; rejetées (distance ou durée ≤ 0) : 1 ;
  sans zone connue (non appariées à zones.csv) : 1 ; retenues : 4.
- Clé de jointure `Start_Zone` = `LocationID`, unique dans zones.csv (265 zones).
- Limite : 6 trajets fictifs seulement ; les moyennes n'ont aucune valeur statistique.
- Reproduction, depuis `novamarket/` : `python volumetrie/publication/preparer.py --version 1`.

## Révisions

- **v1** : agrégat initial (nb_trajets, distance moyenne) par arrondissement.

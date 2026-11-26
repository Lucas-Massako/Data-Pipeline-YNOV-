"""S5 — M4 : pipeline PySpark trajets × zones → agrégat par arrondissement (Parquet).

Usage, depuis novamarket/ (venv actif, variables JAVA_HOME / SPARK_LOCAL_IP exportées) :
    python volumetrie/spark/pipeline.py volumetrie/sorties/extraction_<horodatage>.spark.jsonl \
           volumetrie/sorties/agregat_<horodatage>
    # secours hors ligne :
    python volumetrie/spark/pipeline.py volumetrie/secours/trajets_fictifs.jsonl volumetrie/sorties/agregat_secours_01

Étapes : lecture JSONL + zones.csv, schémas, typage, filtre, colonne calculée (vitesse_mph),
contrôle d'unicité de la clé LocationID, non-appariements (anti-jointure), jointure,
comparaison des effectifs avant/après, agrégation par Borough, partitions, explain(),
écriture Parquet dans un dossier NEUF (errorifexists) puis relecture et vérification.
"""
import argparse
import json
from pathlib import Path

from pyspark.sql import SparkSession, functions as F

ZONES = Path(__file__).resolve().parents[1] / "secours" / "zones.csv"


def titre(texte: str) -> None:
    print(f"\n=== {texte} ===", flush=True)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("entree", type=Path, help="JSONL de trajets (sortie de controler.py ou secours)")
    p.add_argument("sortie", type=Path, help="dossier Parquet à créer (ne doit pas exister)")
    p.add_argument("--zones", type=Path, default=ZONES)
    args = p.parse_args()
    if args.sortie.exists():
        raise SystemExit(f"{args.sortie} existe déjà : choisir un nouveau dossier de sortie")

    spark = (SparkSession.builder.master("local[2]").appName("novamarket-s5")
             .config("spark.sql.shuffle.partitions", "2").getOrCreate())
    spark.sparkContext.setLogLevel("WARN")
    bilan = {}
    try:
        titre("1. Lecture et schémas bruts")
        brut = spark.read.json(str(args.entree))
        zones_brut = spark.read.option("header", True).csv(str(args.zones))
        brut.printSchema()
        zones_brut.printSchema()
        bilan["trajets_lus"] = brut.count()
        bilan["zones_lues"] = zones_brut.count()

        titre("2. Typage explicite")
        trajets = brut.select(
            F.col("Start_Zone").cast("int").alias("zone_id"),
            F.col("Trip_Distance").cast("double").alias("distance_miles"),
            F.col("Trip_Duration").cast("double").alias("duree_s"),
        )
        zones = zones_brut.select(
            F.col("LocationID").cast("int").alias("zone_id"),
            F.col("Borough").alias("arrondissement"),
            F.col("Zone").alias("zone_nom"),
        )
        trajets.printSchema()

        titre("3. Filtre et colonne calculée")
        valides = (trajets
                   .where(F.col("zone_id").isNotNull()
                          & (F.col("distance_miles") > 0) & (F.col("duree_s") > 0))
                   .withColumn("vitesse_mph", F.round(F.col("distance_miles") / (F.col("duree_s") / 3600), 2)))
        bilan["trajets_apres_filtre"] = valides.count()
        bilan["trajets_filtres"] = bilan["trajets_lus"] - bilan["trajets_apres_filtre"]

        titre("4. Contrôle de la clé de jointure (zones.LocationID)")
        bilan["zones_distinctes"] = zones.select("zone_id").distinct().count()
        bilan["cle_zones_unique"] = bilan["zones_distinctes"] == bilan["zones_lues"]
        if not bilan["cle_zones_unique"]:
            raise SystemExit("clé zone_id non unique dans zones.csv : la jointure multiplierait les trajets")

        titre("5. Non-appariements (trajets sans zone connue)")
        orphelins = valides.join(zones, "zone_id", "left_anti")
        bilan["trajets_sans_zone"] = orphelins.count()
        orphelins.groupBy("zone_id").count().orderBy("zone_id").show(truncate=False)

        titre("6. Jointure et effectifs avant / après")
        jointes = valides.join(zones, "zone_id", "inner")
        bilan["trajets_apres_jointure"] = jointes.count()
        bilan["jointure_sans_multiplication"] = (
            bilan["trajets_apres_jointure"] + bilan["trajets_sans_zone"] == bilan["trajets_apres_filtre"])

        titre("7. Agrégation par arrondissement")
        agregat = (jointes.groupBy("arrondissement")
                   .agg(F.count("*").alias("nb_trajets"),
                        F.round(F.avg("distance_miles"), 3).alias("distance_moyenne_miles"),
                        F.round(F.avg("duree_s") / 60, 2).alias("duree_moyenne_min"),
                        F.round(F.expr("percentile_approx(vitesse_mph, 0.5)"), 2).alias("vitesse_mediane_mph"))
                   .orderBy(F.desc("nb_trajets")))
        agregat.show(truncate=False)

        titre("8. Partitionnement et plan d'exécution")
        bilan["partitions_entree"] = brut.rdd.getNumPartitions()
        bilan["partitions_agregat"] = agregat.rdd.getNumPartitions()
        print("partitions entrée :", bilan["partitions_entree"], "| partitions agrégat :", bilan["partitions_agregat"])
        agregat.explain(mode="formatted")

        titre("9. Écriture Parquet puis relecture")
        agregat.write.mode("errorifexists").parquet(str(args.sortie))
        relu = spark.read.parquet(str(args.sortie))
        relu.printSchema()
        relu.orderBy(F.desc("nb_trajets")).show(truncate=False)
        bilan["lignes_parquet"] = relu.count()
        bilan["somme_nb_trajets_parquet"] = relu.agg(F.sum("nb_trajets")).first()[0]
        bilan["parquet_coherent"] = bilan["somme_nb_trajets_parquet"] == bilan["trajets_apres_jointure"]
    finally:
        spark.stop()

    titre("Bilan")
    print(json.dumps(bilan, ensure_ascii=False, indent=2))
    (args.sortie.parent / f"{args.sortie.name}.bilan.json").write_text(
        json.dumps(bilan, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 0 if bilan.get("parquet_coherent") else 1


if __name__ == "__main__":
    raise SystemExit(main())

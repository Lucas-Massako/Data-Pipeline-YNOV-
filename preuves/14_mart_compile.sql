-- Grain : un produit × une date d'observation.
-- Matérialisé en table : résultat analytique lu par les tableaux de bord (S6).
with  __dbt__cte__int_offres_enrichies as (
-- Réutilisable : chaque observation d'offre + son produit + le prix de vente moyen NovaMarket.
-- Grain inchangé : une offre observée un jour.
-- Les ventes sont d'abord agrégées par produit (1 ligne par produit) AVANT la jointure,
-- sinon chaque offre serait répétée autant de fois que le produit a de lignes vendues.
with ventes_par_produit as (
    select
        produit_id,
        sum(quantite)                                        as unites_vendues,
        round(sum(montant_cents)::numeric / sum(quantite))   as prix_vente_moyen_cents
    from "novamarket"."dbt_dev_staging"."stg_metier__lignes_vendues"
    group by produit_id
)

select
    o.offre_id,
    o.date_observation,
    o.fournisseur_id,
    o.produit_id,
    p.sku,
    p.produit_nom,
    p.categorie_nom,
    o.prix_cents,
    o.unites_disponibles,
    v.unites_vendues,
    v.prix_vente_moyen_cents,
    v.prix_vente_moyen_cents - o.prix_cents as marge_unitaire_cents
from "novamarket"."dbt_dev_staging"."stg_fournisseur__offres" as o
join "novamarket"."dbt_dev_staging"."stg_metier__produits"    as p on p.produit_id = o.produit_id
left join ventes_par_produit              as v on v.produit_id = o.produit_id
), offres as (
    select * from __dbt__cte__int_offres_enrichies
),

classees as (
    select
        *,
        row_number() over (
            partition by produit_id, date_observation
            order by prix_cents, fournisseur_id      -- départage déterministe
        ) as rang_prix
    from offres
)

select
    produit_id,
    date_observation,
    min(sku)                                                   as sku,
    min(produit_nom)                                           as produit_nom,
    min(categorie_nom)                                         as categorie_nom,
    count(*)                                                   as nb_offres,
    count(distinct fournisseur_id)                             as nb_fournisseurs,
    sum(unites_disponibles)                                    as unites_disponibles,
    min(prix_cents)                                            as meilleur_prix_cents,
    max(fournisseur_id) filter (where rang_prix = 1)           as meilleur_fournisseur_id,
    max(prix_vente_moyen_cents)                                as prix_vente_moyen_cents,
    max(prix_vente_moyen_cents) - min(prix_cents)              as marge_unitaire_cents,
    max(unites_vendues)                                        as unites_vendues_s1
from classees
group by produit_id, date_observation
-- Grain : un produit × une date d'observation.
-- Matérialisé en table : résultat analytique lu par les tableaux de bord (S6).
with offres as (
    select * from {{ ref('int_offres_enrichies') }}
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

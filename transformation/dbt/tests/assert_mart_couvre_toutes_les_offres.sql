-- Le mart ne perd ni ne multiplie aucune offre : somme des nb_offres = lignes du staging.
-- Le test échoue s'il renvoie une ligne.
select s.nb_staging, m.nb_mart
from (select count(*) as nb_staging from {{ ref('stg_fournisseur__offres') }}) as s
cross join (select sum(nb_offres) as nb_mart from {{ ref('mart_offres_par_produit') }}) as m
where s.nb_staging <> m.nb_mart

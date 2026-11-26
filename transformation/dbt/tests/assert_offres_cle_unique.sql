-- La clé métier (offre_id, date_observation) est unique dans le staging.
select offre_id, date_observation, count(*) as n
from {{ ref('stg_fournisseur__offres') }}
group by offre_id, date_observation
having count(*) > 1

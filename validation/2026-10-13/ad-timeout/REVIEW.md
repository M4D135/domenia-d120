# Recherche interrompue et état AD — RC1.17.5

## Observation reçue

La photo du journal montre `GlobalSearch`, `Timeout apres 45s : Recherche dans l annuaire`, puis `Recherche incomplète`. La photo précédente montre le bandeau « AD injoignable » et un compteur de 746 lignes visibles sur 746 chargées. Ces informations établissent un dépassement de délai ; elles ne prouvent ni une panne générale AD, ni une lecture exhaustive de l’OU.

Les photos originales et les noms réels de l’annuaire ne sont pas intégrés au dépôt.

## Corrections

- Un délai de requête produit un avertissement distinct : « Dernière requête AD : délai dépassé ». Il n’active plus à lui seul le mode hors ligne.
- Une erreur réseau conserve le mode hors ligne et son repère d’invalidation des anciennes fiches. Un délai ultérieur ne retire pas cette protection. Une lecture AD réussie efface les deux avertissements.
- Annulations, démonstrations, anciens comptes/sessions et sondes WMI ne changent pas l’état de la connexion AD.
- Le compteur des résultats commence par « Liste partielle » après une recherche incomplète, y compris après filtrage local. Il distingue également « Chargement… » et « Limite atteinte ».
- Les règles d’écriture incertaine, de fraîcheur de la fiche et de relecture préalable restent appliquées.

## Revue du moteur

`GlobalSearch` est également l’identifiant des lectures limitées à une OU ; ce nom dans le journal ne signifie pas une recherche sur tout le domaine. Le périmètre sélectionné et la profondeur sont transmis au worker. Le chronomètre démarre au lancement effectif du worker, sans compter la file d’attente.

La cause de la durée de 45 secondes n’est pas établie par les photos. Aucun changement de budget, de pagination, de filtre LDAP ou de code worker n’est effectué. Le dashboard a un périmètre indépendant : ces vues tronquées ne permettent pas d’expliquer sa population précise par rapport aux résultats partiels.

## Validation et portée

Les contrôles ciblés exécutent les fonctions et expressions réelles sous PowerShell 7 avec des ports inertes. Ils ne qualifient pas Windows PowerShell 5.1, WPF, SQLite natif ni l’annuaire de l’utilisateur. Les tests Windows restent à effectuer par l’utilisateur, conformément à sa décision. Aucun nouvel accès au laboratoire ni nouvelle capture n’est revendiqué.

## Retour utile

Sur une petite OU, relever la version, les états du bandeau et du compteur après lecture complète et après un éventuel délai. Après une lecture AD réussie, le bandeau doit revenir à « Connecté ». Une liste restée partielle doit conserver sa mention même si une autre lecture AD a réussi. En cas de nouveau délai, transmettre le journal de l’opération depuis son lancement et son périmètre, sans identifiants secrets.

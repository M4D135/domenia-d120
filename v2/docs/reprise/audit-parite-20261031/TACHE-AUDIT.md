# Tâche : audit de parité Domenia 2 (lecture seule)

Dossier de travail : `/home/m4d135/domenia/audit-parite-20261030`. Dépôt en lecture : `repo/` (master 7b128f32, Domenia 2 dans `repo/v2/`).
Entrée : `open-items.json` — 293 fonctions du catalogue `repo/v2/docs/features.json` encore `a-faire` (224, toutes TRV-*) ou `partiel` (69).
Pour une `partiel`, le champ `reste` cite la note « Reste à faire » de `repo/v2/docs/FEATURES.md`.

## But
Ces notes datent souvent de plusieurs lots : beaucoup de fonctions ont pu être faites depuis (2.0.5 à 2.0.8 ont ajouté moteur, cache, atelier de requêtes, campagnes, connexion…).
Pour chaque fonction, établir dans le code actuel ce qui existe vraiment et ce qui manque.

## Méthode, fonction par fonction (dans l'ordre du fichier)
1. Lire titre, description, garde-fous (`safeguards`), `reste`.
2. Chercher l'implémentation : `rg`/`grep` dans `repo/v2/src`, `repo/v2/web`, `repo/v2/tests` (noms d'opérations, textes d'interface français, termes de la description). Lire seulement les passages utiles.
3. Écrire `AUDIT/<ID>.json` (UTF-8) :
   `{"id","verdict","preuves":["chemin:ligne — ce que montre le code"],"manque":"ce qui manque réellement, précis et vérifiable","effort":"S|M|L","depend":["ID ou sujet"],"risque":"lecture|ecriture-locale|ecriture-AD|reseau"}`
   - `verdict` : `fait` (tout est là, garde-fous compris, avec test), `fait-sans-test`, `partiel` (manque précis), `a-faire` (rien), `incertain` (expliquer).
   - Une preuve = un chemin et une ligne réellement lus. Ne jamais inventer de chemin. Sans preuve, pas de `fait`.
4. Si `AUDIT/<ID>.json` existe déjà, passer à la suivante (reprise sans refaire).

## Fin
Quand les 293 fichiers existent, écrire `AUDIT/SYNTHESE.md` en français : comptes par verdict, puis proposition de lots de correction (cohérents, ≤ 15 fonctions, ordonnés par valeur et dépendances, en signalant ceux qui touchent des écritures AD ou le réseau).

## Interdits
- Aucune modification de `repo/` ni de `open-items.json` ; écrire uniquement dans `AUDIT/`.
- Aucune compilation, aucun test, aucun réseau, aucun sous-agent, aucun service. Commandes autorisées : lecture seule (rg, grep, sed -n, cat, ls, wc, find, jq, python3 en lecture).
- Aucun secret ni mot de passe recopié.
- Ne pas conclure `fait` par analogie avec une autre fonction.

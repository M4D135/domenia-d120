# Interface automatisable locale et dossier de diagnostic hors ligne (points 139 et 140)

État au 15 octobre 2026. Règles pures, interface en ligne de commande, raccordement de l’Atelier et suite Windows écrits ;
aucune exécution Windows PowerShell 5.1 n’a eu lieu.

## Principe

`wad\Domenia-Automate.ps1` est l’interface automatisable de Domenia, contrat **`Domenia.Automation/1`** :

- une commande, une réponse datée, puis le processus s’arrête : **aucun port réseau, aucun service, aucune tâche planifiée** ;
- lecture seule de la base SQLite locale (ouverture `SQLITE_OPEN_READONLY`) : ni écriture dans la base, ni liaison à
  l’annuaire, ni contact avec un poste, ni compte ou mot de passe demandé ;
- avant toute lecture, les empreintes de `Domenia-Core.ps1`, `Domenia-Common.Model.ps1` et `Domenia-Automation.Model.ps1`
  sont comparées au manifeste du paquet ; le lecteur SQLite est celui du cœur vérifié (extrait par l’arbre syntaxique).

Code : `wad/modules/Domenia-Automation.Model.ps1` (règles pures), `wad/Domenia-Automate.ps1` (lecture et écriture),
`wad/modules/Domenia-Automation.UI.ps1` et `Domenia-Automation.Worker.ps1` (Atelier, opération `OfflineDossier`).

## Commandes (version 1)

| Commande | Nature | Périmètre | Formats | Contenu |
|---|---|---|---|---|
| `version` | lecture | — | JSON | contrat, version, commandes, codes de sortie |
| `etat` | lecture | — | JSON | base (chemin, taille, date), schéma, magasin et révision, synchronisations, volumes par type, famille et source |
| `postes` | lecture | requis | JSON, CSV | postes de l’index local, système, dates ; jamais les champs LAPS |
| `observations` | lecture | requis | JSON | dernières observations par famille (`Presence`, `Console`, `Inventory`, `Probe:<sonde>`), statut, dates, erreur, données sans champ secret |
| `associations` | lecture | requis | JSON, CSV | associations utilisateur ↔ poste mémorisées, avec source et lot d’import |
| `requetes` | lecture | — | JSON | requêtes enregistrées non archivées, définition et empreinte |
| `dossier` | export | requis | dossier | dossier de diagnostic hors ligne (ci-dessous) |

Périmètre : `-OrganizationalUnit "OU=…,DC=…"`, `-Computers PC-01,PC-02` ou `-Guids …` (500 postes au plus), un seul à la fois.
L’OU couvre ses sous-OU ; elle est comparée sans tenir compte de la casse, lettres accentuées comprises (`OU=Écoles` et
`ou=écoles` désignent la même OU, jamais `OU=Ecoles`). La base et la destination doivent être locales : chemin UNC et
lecteur réseau sont refusés.
Aucune commande ne parcourt tout le domaine implicitement ; la racine du domaine doit être demandée explicitement.
Autres paramètres : `-Family`, `-Limit` (1 000 par défaut, 5 000 au plus, limite atteinte signalée par `Truncated`),
`-Format Json|Csv`, `-OutputPath` (fichier `.json`/`.csv` écrit atomiquement, ou dossier parent pour `dossier`).

Chaque réponse JSON porte `Contract`, `Command`, `GeneratedUtc`, `Source` (base, magasin, domaine, révision, lecture seule),
`Perimeter`, `Limit`, `Count`, `Truncated`, `ExcludedFields`, `Notes`, `Items` et `Meaning` : les données sont celles de la
base locale, **datées et non revérifiées** dans Active Directory ni sur les postes. Le CSV suit l’export de Domenia
(point-virgule, UTF-8 avec BOM, cellules de formule neutralisées).

Codes de sortie : `0` succès, `2` commande ou paramètre invalide, `3` base absente, illisible ou occupée,
`4` refus (périmètre absent, intégrité du paquet), `5` écriture du résultat impossible. Un refus est aussi écrit en JSON
sur la sortie standard. La sortie standard suit la page de codes de la console : `-OutputPath` garde les accents.

```powershell
powershell -NoProfile -File wad\Domenia-Automate.ps1 etat -DatabasePath "D:\Domenia\Domains\corp\Domenia.db" -OutputPath D:\Exports\etat.json
powershell -NoProfile -File wad\Domenia-Automate.ps1 postes -DatabasePath "…\Domenia.db" -OrganizationalUnit "OU=Postes,DC=corp,DC=example" -Format Csv -OutputPath D:\Exports\postes.csv
powershell -NoProfile -File wad\Domenia-Automate.ps1 dossier -DatabasePath "…\Domenia.db" -Computers PC-01 -OutputPath D:\Diagnostics
```

## Dossier de diagnostic hors ligne (`Domenia.OfflineDossier/1`)

Produit par `dossier` ou depuis l’Atelier › **Dossier hors ligne** (poste sélectionné, postes des résultats affichés,
500 au plus, ou OU sélectionnée ; jamais la racine du domaine). L’Atelier passe par l’opération `OfflineDossier`, qui
appelle la même interface dans un worker et écrit dans le dossier **Exports** de la base locale ; la bannière propose
« Ouvrir le dossier ».

Contenu d’un nouveau dossier `Domenia-Diagnostic-<sujet>-AAAAMMJJ-HHmm` (jamais réutilisé, écrit à côté puis renommé) :
`etat.json`, `postes.json`, `observations.json`, `associations.json`, `requetes.json` (sections choisies),
`LISEZMOI.txt`, `manifeste.json` (sections, éléments, limites atteintes, empreintes, exclusions) et `SHA256SUMS.txt`.

Exclus : mots de passe et tout champ nommé comme un secret (`password`, `pwd` sauf `pwdLastSet`, `secret`, `token`,
`credential`, `laps`, clés de récupération BitLocker, `msFVE`, clés privées…), à toute profondeur des données ; la table
`secret_state` ; les colonnes LAPS ; les détails d’annuaire bruts (`domenia_details`) ; les journaux bruts ; les comptes de
connexion. Les champs retirés sont listés dans `ExcludedFields`. Le dossier contient des noms de postes et de comptes et
des chemins internes : il se conserve sur un support protégé et ne part jamais automatiquement.

## Limites explicites

| Limite | Valeur |
|---|---|
| Lignes par commande | 1 000 par défaut, 5 000 au plus |
| Postes nommés ou GUID | 500 |
| Données d’une observation | 262 144 caractères (au-delà : non reprises, signalé) |
| Texte d’un dossier | 64 Mio |

## Tests

- Règles : `wad/tests/rules/Automation.Tests.ps1` (`AUT-001` à `AUT-008`).
- Suite Windows : `wad/tests/Test-DomeniaAutomation.ps1` (paquet minimal recopié avec manifeste, base fictive, processus
  Windows PowerShell 5.1 enfant, intégrité, dossier, raccordement de l’Atelier et du worker `OfflineDossier`).
- Aucun de ces tests n’a été exécuté sous Windows PowerShell 5.1 à cette date. L’opération `OfflineDossier` doit être
  épinglée (`update_worker_contracts.py --add OfflineDossier Get-DomeniaOfflineDossierWorkerCode`) par l’intégrateur.

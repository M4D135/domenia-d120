# Reprises de lectures 108 — reprise directe GitHub

Base examinée : `9b1c0333c34020ad88c1448874b91eff884d5406`, branche dédiée `codex/v2-finalisation-20261025`.

Le lot 123 resté sur Spark/Mac n’a pas été récupéré. Les changements ci-dessous sont développés depuis les fichiers réellement présents sur GitHub.

## Écart prouvé

`TRV-108` décrit une classification avant reprise, trois essais au plus et des attentes de 30 puis 120 secondes. La branche de référence contient les budgets adaptatifs et les limites physiques, mais aucun consommateur de cette politique de reprise. L’inventaire léger d’`AdDirectorySource`, la console des relevés Rechercher et leurs inventaires exécutent une seule tentative.

## Raccordements

- Classification native fermée dans `CimSession` : délai transitoire, protocole inaccessible, classe absente, droit refusé, identifiants rejetés, arrêt et incident non qualifié. Aucun classement à partir d’un texte d’erreur.
- Le retour d’une attente expirée n’est pas une preuve de fin physique. Les lecteurs n’ajoutent cette preuve qu’après la fin effective de leur tâche et la libération de ses ressources.
- Politique commune : trois essais au total, attentes de 30 puis 120 secondes, réservation du budget de la tentative suivante dans une fenêtre de cinq minutes, file de reprises bornée à 32 attentes. Aucune reprise d’écriture, de refus, de classe absente, de protocole inaccessible ou sans preuve récente de présence.
- Inventaire léger Accueil : contexte et identité requalifiés, observations qualifiées enregistrées avant attente, place logique de campagne rendue pendant l’attente. Chaque tentative conserve son plafond natif de 15 secondes et passe par les admissions physiques existantes.
- Rechercher : reprise de console uniquement dans le relevé ayant obtenu un ping récent ; les lectures individuelles restent au contrat initial. Les inventaires des relevés utilisent le même classement, conservent le même compte et enregistrent les mesures terminées avant une reprise.
- Changement de compte, de session ou de cible : aucun nouveau contact sous le contexte de remplacement. Les budgets en pause ne sont pas contournés. Aucun second ping ni transport de repli n’est ajouté.
- La classification et la preuve physique sont éphémères : leur sérialisation en cache ne peut pas autoriser une nouvelle lecture.

## Validation

Deux classes critiques ajoutées : `CollectionReadRetryTests` et `CollectionReadRetryNativeTests`. Elles couvrent les refus de reprise, les trois tentatives, la conservation avant attente, l’annulation, le changement de contexte, les budgets, les codes natifs et les vrais lecteurs avec transports injectés.

Tests écrits, **non exécutés**. La première CI Windows verte `c60ebd110091eefb0185c55e7df9030fec28db8e` précède ces changements et ne les valide pas. Les résultats de compilation du présent lot doivent être rattachés à son commit après push.

Recettes AD/UI sur `CNAMTS-DC01` et `DOMENIA-FIRSTRUN-20261020` : **non vérifiées**. Aucune release ni archive finale publiée.

## Relecture croisée et renforcement après le premier push

Le premier raccordement `2b34e9b0371eb4c4817dcf26c3f9e7ce28736b50` a compilé Debug et Release sur Windows GitHub Actions avec zéro erreur et zéro avertissement ([passage 40214071981](https://github.com/M4D135/domenia-d120/actions/runs/40214071981)). Aucune suite n’a été exécutée.

La relecture a ensuite corrigé trois fenêtres réelles : la deadline de cinq minutes couvre désormais aussi l’attente d’admission et les qualifications ; les réglages CIM/registre/WinRM de Recherche sont figés avec le compte ; les sources détaillées entièrement réussies d’un premier essai ne sont plus effacées par l’échec du suivant. `SearchInventoryAttempts` est limité à une séquence de relevé : l’âge des valeurs conservées n’est pas rajeuni, chaque accès conservé reste partiel avec les deux dates et le dernier échec. Une nouvelle réponse vide valide remplace l’ancienne valeur. Aucune ancienne association console n’est restaurée ; les décisions de reprise portent toujours sur le résultat natif brut.

La fin physique après annulation est documentée séparément dans `reprise-github-fin-physique-lectures-20261025.md`. Un test de deadline d’admission et quatre tests de conservation des sources ont été ajoutés, **non exécutés**. La compilation du premier push ne vaut pas compilation de ces renforcements ; leur SHA doit recevoir sa propre preuve Windows.

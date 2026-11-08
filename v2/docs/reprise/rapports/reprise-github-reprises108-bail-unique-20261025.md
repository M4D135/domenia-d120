# Reprise GitHub — reprises108 et bail à usage unique — 25 octobre 2026

## Écarts prouvés

- Recherche inventaire sélectionnait un compte avant la boucle, puis `InventoryAsync → ComputerSessionCoreAsync → ReadConsoleAsync` le sélectionnait de nouveau. Le compte OneShot pouvait être consommé avant le premier envoi.
- Console avec reprise et inventaire léger Accueil réacquéraient aussi un compte dès le premier essai de leur boucle.
- Le retrait différé d’un OneShot local par un affichage passif déplaçait la génération d’une lecture déjà admise.
- Acquérir LDAP avant un OneShot machine partagé invalidait le premier bail LDAP. Inverser aveuglément l’ordre produisait le défaut symétrique pour un OneShot LDAP.
- Le relevé Relations conservait également son bail LDAP avant la première admission machine.

## Correction raccordée

`AdWorkstationReadAccess` détient une sélection LDAP et une sélection machine pour un geste logique. Un aperçu local sans consommation choisit LDAP d’abord si son bail est OneShot, sinon Machine d’abord. Les versions, source, compte et transports de l’aperçu sont vérifiés avant copie. La branche LDAP OneShot exige exactement l’incrément attendu ; elle n’accepte pas librement une nouvelle génération machine après LDAP. Les versions d’un plan confirmé peuvent être transmises jusqu’à cette frontière.

Les trois consommateurs108 empruntent les mêmes accès pendant les reprises. Ils revalident avant chaque envoi la cible, la session, le compte, sa pause, son expiration et les transports configurés. Aucune réacquisition, prolongation de bail ou recherche de compte de repli n’accompagne la reprise. Les budgets existants et l’attente de fin physique restent en place ; l’annulation d’un inventaire Recherche sans identité reçue reste une annulation après fin physique.

Les copies OneShot sont scellées après le retrait de leur slot, local ou partagé. Un affichage passif ne révoque plus cette copie par simple balayage. Un changement explicite de compte, y compris entre copie et synchronisation des magasins, reste refusé.

Poste et Atelier utilisent la même admission via `AdQueryAccess`. Les inventaires et consoles exposent un emprunt de l’accès retenu pour une lecture composée ; son propriétaire conserve la durée de vie jusqu’à la fin physique de toutes ses sources.

## Bornes explicites

- Deux OneShot distincts issus du **magasin partagé AccountAccess**, LDAP et Remote, restent refusés avant contact : aucune remise à zéro de génération ni sélection de repli. Le cas LDAP OneShot avec OneShot machine **local au service** est distinct ; le retrait local ne modifie pas la sélection AccountAccess.
- Relations engage un OneShot machine pour la **première cible du plan avant son ping**. Si elle est muette, le bail reste consommé ; les consoles suivantes sont arrêtées avant toute nouvelle sélection. Le résultat donne ce motif exact, distinct d’un changement de session. Le budget global reste 120 secondes.
- La factory de transport LDAP ajoutée est interne, réservée aux fixtures et absente de la composition de production. Elle conserve tous les contrôles de sélection, contexte, session et identité.

## Vérification

Tests écrits, **non exécutés** :

- `CollectionOneShotAccessTests` : six scénarios de consommateurs réels Recherche/Accueil/console ; comptes local et partagé, reprise avec le même objet credential, affichage passif, pauses, changement de compte/transport, expiration, dates conservées et annulation devant un worker natif encore vivant.
- `AdRelationProbeTests` : scénario ajouté, première cible répondante puis muette ; aucun repli ni console suivante, motif explicite.
- `PostePersonalProbeNativeTests` : quatre scénarios ajoutés par la revue croisée ; LDAP OneShot seul, deux OneShot partagés refusés, changement machine pendant admission LDAP, versions du plan transmises à la frontière. Le scénario OneShot machine/poll UI du lot Poste reste également applicable.

Relecture statique croisée et `git diff --check` effectués. Aucune compilation locale ni exécution de suite dans ce lot. La compilation Windows du commit qui intégrera ce correctif et les validations CRITIQUES dans **deux VM Windows avec recette UI/native** restent à produire. Aucun paquet PROD/DEV v2.0.0 publié sur cette base.

## Compilation constatée après intégration

Lot poussé dans `d8915aea383282c70e9855f05bfe03edab9ee643`. Le premier run a révélé CS1503 dans une assertion de test (`bool?` transmis à `Check.True`) ; le correctif `bd350707f568a8ecc3c9923883a532bdd3304625` exige explicitement `Confirmed == true`.

[Run Windows 40219618795](https://github.com/M4D135/domenia-d120/actions/runs/40219618795), job `121248131252` : journaux lus, Debug et Release réussis avec **0 avertissement et 0 erreur** (18:07:46 et 18:08:40 UTC le 25/10/2026). Les tests sont compilés mais **aucune suite exécutée dans ce run**. Le lot Atelier ultérieur et les recettes critiques UI/native des deux VM ne sont pas validés par cette preuve.

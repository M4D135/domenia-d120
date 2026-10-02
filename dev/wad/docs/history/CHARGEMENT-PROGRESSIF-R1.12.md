# ADCC 1.0 R1.12 : résultats progressifs et utilisateurs en arrière-plan

Build : `2026.09.30-R1.12-PROGRESSIVE`.
Base de travail : le pack complet R1.11 de cette conversation. Cette version contient toute l'application ; elle ne contient pas la base personnelle, les journaux ou les préférences de l'utilisateur.

## Utilisation

Ouvrir **Rechercher**, choisir une OU et lancer une recherche normalement. La liste conserve ses filtres OU, sa profondeur et sa limite habituelle. Le chargement commence sans attendre les diagnostics des postes.

Lorsque le même périmètre a déjà été consulté, une projection connue peut s'afficher avec **Cache · à vérifier**. La lecture LDAP est néanmoins lancée à chaque chargement. Les retours du contrôleur arrivent progressivement dans la même grille, avec **AD vérifié** : cela signifie reçu de cette lecture AD, pas droits effectifs certifiés ni session du poste vérifiée.

La case **Vérifier les utilisateurs des postes**, active par défaut, programme les machines reçues de la lecture AD. Deux sondes automatiques simultanées par défaut. Il s'agit des machines renvoyées dans la limite demandée, même si un filtre local masque ensuite certaines lignes. La machine sélectionnée a priorité sur celles en attente.

Les nouvelles colonnes distinguent le compte console, l'état de sa vérification et la fraîcheur de l'information AD. Survoler le compte pour consulter le dernier utilisateur connu, la date d'observation, la dernière tentative et la source. Le filtre local inclut les comptes et états de vérification.

**Revérifier les postes** recommence la vérification des machines fraîches de la liste, sans modifier le filtre OU. Une sonde déjà en cours est partagée, pas doublée. Décocher la détection arrête sa programmation et demande l'arrêt des sondes automatiques ; la recherche AD continue. La vue **Opérations** garde ses commandes d'arrêt des lectures et ses protections des écritures.

## Chargement en trois circuits indépendants

1. **Résultats LDAP** : liste explicite de propriétés, pages demandées de 40 objets, publication dans une file concurrente au fil de l'énumération. Le client n'attend plus le retour final du worker pour commencer à rendre les lignes. Le délai de la première réponse reste dépendant du contrôleur et du réseau.
2. **Affichage** : une collection observable stable, des lignes notifiantes et un timer WPF de priorité basse. Chaque passage ajoute au maximum 12 lignes, avec un budget coopératif de 6 ms et un intervalle de 80 ms. Ces nombres sont des réglages, pas des temps mesurés ou des garanties temps réel. Si une opération individuelle dépasse le budget, elle doit finir avant le retour au Dispatcher.
3. **Enrichissement et cache** : sondes CIM/DCOM et lectures/écritures SQLite dans des runspaces. Une réponse de session modifie ses cellules, sans réaffecter tout `ItemsSource`. Les écritures locales sont groupées, avec une transaction et un seul job de cache à la fois.

Les pools des trois opérations concernées sont réutilisés pour éviter de recréer un runspace à chaque machine. Les opérations d'écriture AD ne passent pas dans ces nouveaux pools. Des créneaux sont gardés pour les lectures interactives et les actions de l'opérateur.

Un environnement refusant la compilation du petit type notifiant ne déclenche aucun contournement de sécurité : l'application utilise des lignes PowerShell avec un rafraîchissement visuel groupé. Ce repli peut être moins fluide.

## Ce que la détection utilisateur constate exactement

La sonde automatique effectue une lecture **`Win32_ComputerSystem.UserName` via CIM/DCOM**. Elle ne nécessite pas WinRM et ne déploie aucun script sur les postes. Le fournisseur Windows retourne le compte associé à la console, pas un inventaire des sessions Terminal Services/RDP. Une console verrouillée n'implique pas une déconnexion du compte.

| Situation | Affichage et mémorisation |
|---|---|
| Compte console renvoyé | Compte observé et nouvelle date d'observation. |
| Lecture réussie, valeur vide | Aucun compte console ; la dernière observation historique est conservée dans le détail. Cela n'exclut pas des sessions RDP. |
| Refus d'accès, délai, poste inaccessible | Dernier utilisateur connu conservé, présenté en cache, et motif de la tentative non confirmée. La date d'observation n'est pas rajeunie artificiellement. |
| Identifiants distants rejetés | Nouvelles sondes automatiques suspendues, sans essai d'un autre compte. Les jobs déjà envoyés peuvent encore se terminer. |
| Identifiants AD rejetés lors de la résolution du compte | L'observation console reste une observation ; l'association AD n'est pas inventée, et la validation AD est suspendue. |

La sonde utilise le compte poste configuré selon le mécanisme existant. Le compte AD distinct reste celui de la validation de l'identité. Seul un nom qualifié du domaine courant et effectivement retrouvé dans AD est ajouté à l'association user-machine. Un nom local ou non qualifié n'est pas transformé au hasard en utilisateur du domaine.

Aucun PsExec, aucune tâche planifiée, aucune installation de service, aucun parcours des profils et aucune modification du registre ne sont ajoutés à la détection automatique. Le parcours détaillé volontaire déjà présent dans ADCC est conservé ; il ne doit pas être confondu avec cette lecture automatique légère. La politique existante `Remote.UseCim=false` est respectée.

## Mémoire et persistance

Les lignes connues sont immédiatement réutilisables en mémoire pour une requête identique. Une copie persistante est écrite dans la base ADCC du domaine, dans deux nouvelles tables :

- `adcc_live_queries` : projection de la recherche, périmètre, date et lignes reçues ;
- `adcc_live_observations` : cible, GUID, état de tentative, compte console courant/dernier connu, dates et source.

Les clés séparent le domaine, le compte AD et le compte distant. La clé de requête inclut l'OU, la profondeur, le texte, le type et la limite. Le GUID distingue un objet ordinateur recréé d'un ancien objet portant le même DN. Les informations reçues sous un ancien contexte de compte ne repeuplent pas le contexte courant.

La rétention SQLite concerne uniquement ces deux nouvelles tables : 20 projections par contexte, 5 000 observations par contexte, et expiration après 30 jours sans tentative récente. Le cache des projections en mémoire est limité à 20 requêtes. Les observations de la session restent en mémoire jusqu'au changement de contexte ou à la fermeture ; elles ne constituent pas un historique illimité de connexions.

Quand l'utilisateur a été confirmé dans AD, l'association historique existante est actualisée par une écriture ciblée sur la machine. Le parcours automatique **ne réécrit plus toute la table des liens à chaque réponse**. Une association manuelle n'est pas écrasée. Le schéma des anciennes tables métier n'est pas modifié.

Les données sont enregistrées de façon différée : lors d'une fermeture immédiate ou forcée, le dernier lot peut ne pas avoir été validé sur disque. Le dernier cache déjà validé reste disponible. L'application ne bloque pas la fermeture pour attendre un poste distant ou forcer un flush synchrone. Une erreur d'enregistrement est signalée ; des observations en mémoire ne sont pas présentées comme enregistrées à tort.

Le cache ne contient pas de PSCredential, mot de passe ou clé LAPS/BitLocker. Les projections contiennent néanmoins des noms, descriptions, comptes et chemins professionnels : elles ne sont pas anonymisées et le nouveau cache n'ajoute pas de chiffrement. Les droits de protection de la base restent ceux du stockage existant.

## Garde-fous du parcours

- Changer d'OU, de texte, de profondeur ou de génération invalide l'affichage des anciens retours.
- Une réponse vide mais complète retire les anciennes lignes du périmètre. Une réponse partielle ou une erreur ne remplace pas le cache par une prétendue liste complète.
- Les nouvelles lignes AD ne sont pas rejetées parce qu'une ancienne projection remplit déjà la limite : les anciennes lignes non confirmées libèrent leur place.
- Une lecture native annulée reste comptée tant qu'elle n'est pas réellement terminée. Le délai du worker est une demande d'arrêt, pas une interruption garantie du système distant.
- Une écriture AD active ou dont l'état reste inconnu suspend l'application des mises à jour de liste et l'enrichissement. Aucun résultat différé n'enlève les protections de l'interface.
- Les nouveaux boutons suivent le verrouillage de la grille. Une consultation, une revalidation et un clic sur une ligne ne déclenchent aucune écriture AD nouvelle.

Les délais proposés sont de 4 secondes par appel CIM, 14 secondes pour le worker de sonde et 300 ms d'attente du verrou SQLite dans le worker. Des API natives, la résolution réseau et le système peuvent dépasser ces attentes ; la consommation physique reste alors bornée et la ligne n'est pas annoncée comme vérifiée.

## Installation

Fermer ADCC après la fin des opérations d'écriture. Extraire ce pack dans un dossier distinct. Depuis le nouveau dossier `ADCC` :

```powershell
# Adapter la destination à l'installation actuelle.
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\ADCC' -WhatIf
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\ADCC'
```

Ne pas supprimer l'ancien dossier. L'installateur garde `wad\data` et les configurations existantes, vérifie le manifeste et les tests natifs isolés, puis sauvegarde le code remplacé. Ne pas copier uniquement le cœur : `ADCC-Live.Model.ps1`, `ADCC-Live.UI.ps1` et `ADCC-Live.Types.cs` sont nécessaires avec les modules précédents.

Pour une nouvelle installation, extraire tout le dossier, conserver `wad` à côté des lanceurs et ouvrir `LANCER-ADCC.cmd`. L'EXE et les DLL sont ceux de R1.11. Les politiques de sécurité de l'organisation restent applicables.

Le retour arrière du code reste disponible via `INSTALLER-MISE-A-JOUR.ps1 -RestoreBackup 'CHEMIN_AFFICHE_PAR_L_INSTALLATEUR'`. Les nouvelles tables peuvent rester dans la base ; un retour de code ne détruit ni ne remplace les données personnelles. Ne pas faire de retour arrière pendant une opération active.

## Essais et vérifications

### Réalisé dans cet environnement

`python wad/tests/audit_streaming.py` réalise les contrôles de source, les comparaisons d'empreintes, les vérifications XML et des essais SQLite réels au moyen de Python. Les contrôles de source couvrent le registre fermé des 47 opérations, les ressources conservées, les frontières des workers, les gardes de génération et le maintien des protections. Les essais SQL couvrent les apostrophes, la transaction/rollback, la mise à jour ciblée, la conservation des liens manuels et la rétention.

Le rapport `wad/docs/AUDIT-PROGRESSIF-R1.12.json` précise les résultats. Il ne représente pas une exécution des scripts PowerShell. Les contrôles lexicaux approximatifs ne sont pas le parseur natif de PowerShell.

### Fourni pour Windows, non exécuté ici

**`TESTER-PROGRESSIF.cmd`** contient 60 scénarios natifs isolés : syntaxe réelle, collection WPF, arrivée par lots, cache complet/partiel, changement de génération, absence de mélange d'identités, observations, annulations, partage de sondes et SQLite dans un dossier temporaire. Les accès CIM et LDAP y sont remplacés par des doubles explicites, y compris le ping. Cela ne teste pas les droits ou les délais du parc réel.

**`APERCU-PROGRESSIF.cmd`** ouvre le vrai XAML de cette version avec 40 machines fictives et quelques autres objets. Un producteur local alimente les vraies files d'affichage et les callbacks d'observation. Changer d'OU, refaire une recherche, filtrer les lignes, masquer les panneaux et désactiver/réactiver la détection sont examinables. Aucun cache réel, aucun LDAP, aucun CIM, aucune authentification et aucune écriture AD ne sont effectués par cet aperçu. Les délais simulés ne mesurent pas les performances du domaine.

Les aperçus et suites de tests précédents restent disponibles. L'installateur ajoute la suite progressive avant le remplacement du code. Un échec de test doit être examiné à partir du rapport affiché, pas contourné en supprimant le contrôle.

### Recette réelle à faire

Sur une petite OU autorisée, vérifier une liste connue et son export. Observer les premières lignes puis les comptes console. Relancer exactement la même requête et contrôler les mentions de cache avant revalidation. Changer d'OU rapidement et vérifier l'absence de mélange. Tester un poste arrêté et un refus d'accès : l'utilisateur connu doit rester historique, pas fraîchement confirmé. Vérifier la fermeture/réouverture après la fin de l'enregistrement et les comptes AD/poste distincts. Enfin, tester les protections habituelles d'écriture sur un environnement de recette.

Les logs ajoutent le délai du premier affichage, le nombre de retours AD, la durée jusqu'à finalisation et le caractère complet ou partiel. Le premier affichage peut provenir du cache : ce compteur n'est pas un temps du premier résultat LDAP. Ces mesures sont disponibles sur le poste ; aucun benchmark avant/après n'a été exécuté ici.

**Non exécutés ici : Windows PowerShell 5.1, rendu WPF, authentification, LDAP, CIM/DCOM et recette sur le domaine.** Cette version traite les points bloquants identifiés dans le chargement de liste ; elle n'est pas une preuve que tous les autres parcours historiques de l'application ne peuvent jamais ralentir.

## Références de conception

Microsoft Learn : modèle de threading WPF, traitement court du Dispatcher et travail en arrière-plan ; `DirectorySearcher.PageSize`, `CacheResults` et `Asynchronous` ; propriété `Win32_ComputerSystem.UserName` et sa limite console/Terminal Services. Ces références décrivent les API, pas une validation du fonctionnement de ce pack sur votre parc.

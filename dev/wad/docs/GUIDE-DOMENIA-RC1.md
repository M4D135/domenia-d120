# Domenia 1.0 RC1 : guide de livraison et limites

Build : `2026.09.30-DOMENIA-1.0-RC1`.

Cette livraison contient de vraies modifications du projet ADCC R1.13, un lanceur natif recompilé, les modules raccordés et deux distributions cohérentes. **Le plan M01 à M42 n’est pas entièrement clôturé.** Le tableau de suivi est fourni séparément, avec les parties réellement implantées et les compléments nécessaires. Aucune validation Windows n’est inventée.

## 1. Structure

```text
prod/
├── Domenia.exe
└── wad/
    ├── Domenia-Start.ps1
    ├── Domenia-Core.ps1
    ├── Domenia.config.json
    ├── modules/
    ├── package-manifest.json
    └── Support/
        ├── DEBLOQUER_TOUT.cmd
        ├── Debloquer-Paquet.ps1
        └── .lifecycle.lock
```

DEV contient le même runtime, l’installateur, les tests natifs, trois aperçus, les sources du lanceur et les outils de construction. Les composants Microsoft et PsExec de l’archive d’origine restent identiques. L’inventaire des composants est dans `COMPONENTS.json` ; leurs conditions de redistribution doivent être examinées par l’organisation.

PROD ne réclame aucun BAT de démonstration, fichier de test, documentation ou outil de compilation pour démarrer. Le fichier `.lifecycle.lock` est un composant volontairement vide du runtime, pas une trace à nettoyer. Ne pas supprimer les verrous ou les reçus pour forcer un lancement ou une action.

**L’édition PROD désigne le contenu minimal à distribuer. RC1 reste un candidat à valider avant diffusion élargie.**

## 2. Changements utilisables

### Comptes et secrets

Le bouton Tester ou Activer du panneau Comptes utilise désormais une validation asynchrone. Il n’attend plus `WaitOne` sur le thread de la fenêtre. Un résultat tardif, une annulation ou un changement de session ne remplace pas le compte actif. La validation AD n’est pas présentée comme une certification des droits de chaque ressource.

Les refus LAPS et BitLocker restent séparés. Après accord, la connexion alternative vise la ressource concernée ; seule une lecture de secret peut être retentée automatiquement une fois après validation. Les autres actions se relancent volontairement. Aucun mot de passe n’est essayé en cascade. Les comptes alternatifs expirent au bout de trente minutes ; il s’agit d’une durée absolue, pas d’un délai d’inactivité. Les comptes principaux du panneau restent des credentials de session.

Pour une machine sélectionnée, le formulaire alternatif distant accepte un compte ciblé, y compris `POSTE\compte` ou `.\compte`. La validation utilise CIM/DCOM sur la cible, pas obligatoirement le domaine AD courant. Cela ne garantit pas des droits WTS/SMB identiques. Il faut sélectionner la bonne machine et fournir le compte exact.

Les copies de secrets utilisent désormais les formats Windows d’exclusion de l’historique et de synchronisation lorsque ces mécanismes sont respectés. L’effacement différé ne supprime pas les copies faites hors de l’application et n’intervient pas sur un nouveau contenu que l’utilisateur aurait copié. Les secrets ne sont pas ajoutés aux caches ou aux reçus.

### Transports distants

Les mots de passe ne sont plus placés dans les options de processus `-p`, `/p` ou `/rp` des transports corrigés. Le Planificateur est utilisé par son API COM. PsExec conserve uniquement le contexte Windows intégré : **un compte explicite n’est pas silencieusement converti en arguments PsExec**. Une fonctionnalité autrefois dépendante de ce comportement peut maintenant refuser cette méthode.

Un dépôt de script, une création de service ou une tâche demande une autorisation temporaire dans **Outils > Fiabilité**. Elle est liée au poste choisi et à la session, pendant cinq minutes ; ce n’est pas une élévation ni une désactivation de contrôle Windows. Les scripts sont placés dans un sous-dossier privé du vrai répertoire Windows, avec ACL ciblées, fichiers bornés et nettoyage tracé. Les sondes automatiques légères restent sans dépôt.

### Réactivité et données

Le flux LDAP progressif, le cache identifié comme historique, le filtre OU et la détection console en arrière-plan sont conservés. Les écritures courantes de l’index, des liens et des métadonnées rejoignent une file locale bornée, avec transaction, traitement par lot et temporisation en cas d’échec. Après trois échecs de stockage, la reprise se demande dans Fiabilité. Un affichage en mémoire n’est pas annoncé comme sauvegardé.

La file est coordonnée avec les travaux LiveCache et IndexBuild. Ce n’est pas encore la conversion de **toutes** les anciennes fonctions de stockage en un écrivain unique : certaines initialisations et fonctions de maintenance restent synchrones. Aucun temps de réponse sur ton domaine n’a été mesuré.

Les liens manuels sont enregistrés par différence et contrôle de version du contenu, au lieu d’effacer toute la table. Un conflit laisse la version disque intacte et avertit l’opérateur. Les lots de changement manuel sont limités à 64 : un import plus grand doit être subdivisé ; aucune sauvegarde exhaustive n’est prétendue réussie à tort.

La nouvelle réconciliation réinterroge le dernier périmètre choisi, par défaut après trois minutes, seulement dans son contexte valide. Elle se limite à 500 lignes et se suspend quand la fenêtre n’est pas active ou qu’une écriture doit être protégée. Elle peut être désactivée. Une absence dans un retour n’est pas transformée en preuve de suppression. Quand le plafond est atteint, actualiser ou affiner reste nécessaire.

### Exactitude AD et saisies

Un `lockoutTime` non nul n’est plus assimilé seul à un verrouillage actuel. La valeur calculée du contrôleur est utilisée quand elle existe, sinon le statut reste indéterminé. Les états désactivé et verrouillé sont distincts. La casse des champs texte peut désormais être corrigée sans que la modification soit écartée.

Le test d’appartenance directe interroge le serveur sur le membre exact. La lecture des attributs multivalués `member`/`memberOf` gère les plages. L’affichage d’un très grand groupe est limité à 2000 lignes avec avertissement ; il ne devient pas une preuve de complétude.

Une fiche fraîche reçue pendant la saisie ne remplace plus le brouillon. **Fiabilité > Comparer les saisies** expose la version lue, la saisie et le retour disponible, sans afficher les mots de passe. La fusion champ par champ reste manuelle. Un changement de fiche ou un rechargement demande confirmation avant abandon.

### Écritures à vérifier

Les écritures AD du canal contrôlé `IsWrite` enregistrent un reçu local avant la commande, puis le stade `Sent` avant l’envoi. Une coupure ou un résultat incertain conserve un état à vérifier au prochain lancement. Le rechargement de la fiche ne suffit plus à effacer cet état. Aucune commande n’est rejouée automatiquement.

**Outils > Fiabilité** permet de consulter les reçus. La vérification automatique de reprise couvre actuellement les écritures d’attributs avec GUID et empreinte des valeurs attendues. Pour les autres opérations, il faut vérifier le résultat avec un outil autorisé, puis consigner explicitement une revue externe : le reçu devient `Reviewed`, pas un succès inventé. Un changement de mot de passe n’est pas vérifié en lisant sa valeur.

Limites importantes : les opérations distantes GPUpdate/redémarrage/exécution ne sont pas toutes couvertes par ce reçu AD ; le reçu est local au compte Windows qui exécute l’application ; un administrateur local peut modifier un fichier local ; ce n’est ni un audit signé ni un verrou distribué du domaine. Les précontrôles et l’écriture AD restent séparés : aucune assertion LDAP atomique universelle n’a été ajoutée.

Le dossier de reçus est `%LOCALAPPDATA%\Domenia\Receipts`, protégé pour son utilisateur, SYSTEM et les administrateurs. Les reçus non résolus ne sont jamais purgés automatiquement. Au-delà de 384 reçus, les reçus terminés les plus anciens passent dans le sous-dossier `archive` sous le verrou d'écriture, jusqu'à n'en garder que 256 ; les reçus non résolus ne bougent jamais. Au-delà de 512 reçus non résolus, l'écriture est refusée jusqu'à leur vérification. Rien n'est supprimé.

### Fonctions complémentaires

- **Sessions** : lecture WTS volontaire du poste, utilisateur, domaine, protocole et état. Aucun bouton de déconnexion. Une lecture incomplète ou refusée ne signifie pas « personne connecté ».
- **Favoris** : jusqu’à 50 recherches avec nom, domaine/OU, profondeur, texte, type et limite. Aucun credential ou résultat n’est mémorisé dans le favori.
- **Captures A/B** : sauvegarde et chargement explicites de captures historiques filtrées, jusqu’à 1 Mo, avec comparaison existante et référence ticket. Une capture importée ne devient jamais AD fraîche.
- **Fiabilité** : motifs d’indisponibilité, backlog de sauvegardes, retards locaux du Dispatcher p50/p95 sur une fenêtre bornée. Ce ne sont pas des mesures de disponibilité du domaine.
- **Dossier support minimal** : aperçu de compteurs techniques avant export local ; pas de compte, cible, journal brut, mot de passe ou clé ajouté à ce nouveau dossier.
- **Pesto / FilPro** : lancement uniquement après configuration d’un chemin EXE absolu et de son SHA-256, puis confirmation. Aucun argument ni credential transmis, faute de contrat CLI inter-outils confirmé.

## 3. Données et migration

`Storage.Mode` accepte `Compatible` (défaut), `UserLocal` et `Portable`.

En mode Compatible, un ancien dossier `wad/data` contenant des données est conservé. Pour une installation neuve, les données vont dans `%LOCALAPPDATA%\Domenia\Data`. UserLocal impose ce stockage local ; Portable utilise `wad/data`. Les données actives sur UNC/lecteur réseau/redirection sont refusées plutôt que converties en cache partagé WAL. Les exports choisis peuvent aller dans un emplacement autorisé, sans en faire une base active.

La base ADCC existante est réutilisée selon le contexte du domaine. Elle n’est ni effacée ni renommée arbitrairement. Les noms de tables historiques et la version de schéma legacy 11 sont conservés ; une version de schéma Domenia 1 est ajoutée. Une sauvegarde SQLite cohérente précède la première migration. Une version future ou inconnue est refusée. Les ACL d’un vieux cache portable ne sont pas modifiées automatiquement.

Les nouvelles préférences Domenia ont priorité. Les réglages ADCC servent de reprise si celles-ci sont absentes. Colonnes, branche OU, thème et disposition sont repris selon leur ancien contexte valide. Aucune réparation de données illisibles ni fusion de domaines n’est exécutée automatiquement.

Un reçu n’existant pas avant cette livraison ne peut pas reconstruire une opération ADCC ancienne. **Terminer et vérifier les opérations en cours avant la migration.**

## 4. Installation et retour arrière

Fermer toutes les anciennes instances. Conserver une copie de l’installation et de ses sauvegardes. Extraire DEV dans un dossier distinct. Exemple depuis DEV :

```powershell
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\ADCC' -WhatIf
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\ADCC'
```

L’installateur ne copie que le runtime, conserve `wad/data` et les configurations, lance une suite native sans domaine avant copie, sauvegarde le code et coordonne l’opération avec le nouveau lanceur. En cas d’arrêt brutal, `wad/Support/.update.pending` bloque le lancement et indique la sauvegarde. Ne pas effacer ce marqueur pour poursuivre.

```powershell
.\INSTALLER-MISE-A-JOUR.ps1 -RestoreBackup 'CHEMIN_EXACT_DE_LA_SAUVEGARDE'
```

Le retour arrière est celui du code, pas de la base et des opérations métier. Ne pas changer de version pendant une mutation. Les fichiers ADCC anciens ne sont pas supprimés par l’installateur ; retirer leur raccourci et utiliser Domenia.exe. Le lanceur ADCC ancien ne connaît pas le nouveau verrou, d’où la fermeture manuelle obligatoire à la première migration.

## 5. Vérifications livrées

**Exécutées dans l’environnement Linux de préparation :** compilation croisée réelle du lanceur Windows x64, seconde compilation identique, 18 004 assertions du code C portable de ses helpers, contrôles Python de structure/raccordements/empreintes/XML et SQLite réel sur le schéma extrait. Les archives finales sont rouvertes et comparées à leur manifeste ; le runtime est identique dans DEV et PROD.

**Non exécutées ici :** exécutable Windows, Windows PowerShell 5.1, code C# natif sous Windows, rendu WPF, authentification, AD, CIM/DCOM, WTS, clipboard réel, ACL réelles, installation/migration/rollback Windows. Les contrôles lexicaux ne remplacent pas le parseur PowerShell natif.

DEV fournit `TESTER-DOMENIA.cmd` et un workflow Windows optionnel. La suite n’ouvre pas de domaine et n’exécute aucune mutation réelle. `APERCU-INTERFACE.cmd`, `APERCU-CONNEXION.cmd` et `APERCU-PROGRESSIF.cmd` restent des aperçus réels du XAML sur des données fictives, pas une preuve de connexion ou une capture produite ici. Les rapports anciens sont archivés et ne certifient pas cette RC.

### Recette Windows minimale avant distribution

1. Exécuter les deux contrôles DEV, puis `prod\Domenia.exe --check` avec PROD seul.
2. Examiner login, clair/sombre, menus repliés, arbre OU, tableaux et dialogues sur 100/125/150/200 %.
3. Sur une OU de test autorisée, vérifier liste connue/vide/plafonnée, changement rapide de filtre et retour tardif.
4. Tester le compte AD lecteur, le compte poste, un refus LAPS et un compte BitLocker distinct. Refuser puis accepter un autre compte, sans cascades de tentatives.
5. Saisir pendant une relecture retardée, changer de fiche, comparer et abandonner explicitement.
6. Tester sur objets de recette les écritures et coupures après envoi, reçus Unknown, absence de rejeu et revue explicite. Faire les modifications réelles uniquement dans cet environnement de test.
7. Verrouiller la base de test, simuler disque plein/échec d’écriture, vérifier que l’interface conserve les observations en mémoire et indique la non-persistance.
8. Tester les sessions WTS et transports autorisés ; contrôler avec un secret factice qu’aucun argument ou journal de test ne le contient.
9. Tester migration d’une copie ADCC, démarrage simultané avec mise à jour, interruption, retour arrière et conservation des données.

## 6. Signature et statut

Domenia.exe et les scripts livrés ne sont pas signés avec un certificat de l’organisation. Les hashes détectent un mélange de versions ou une altération relative au manifeste, mais ne prouvent pas seuls la provenance. La signature et l’autorisation WDAC/AppLocker doivent suivre la procédure interne. L’outil `Signer-Distribution.ps1` n’exporte aucune clé et n’invente aucun éditeur de confiance.

La priorité suivante de clôture reste : vraie recette Windows, vérification de reprise propre à toutes les mutations, compléments de cache/index historique et réduction des dernières attentes synchrones. La matrice M01–M42 conserve ces écarts visibles.

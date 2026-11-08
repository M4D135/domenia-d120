# AD⚡CC 1.0 R1.5 : Atelier support

**Build : `2026.09.21-R1.5-ATELIER`**  
Base de travail : paquet R1.4 fourni dans cette conversation. Date : 21 septembre 2026.

## Ce qui est livré

Un nouvel onglet **Atelier**, intégré à la fenêtre ADCC. Il ne s'agit ni d'une maquette, ni d'un programme externe, ni d'une connexion à une IA. Ses règles sont explicites et locales. La version publique reste **1.0**.

| Espace | Fonction disponible | Limite volontaire |
|---|---|---|
| Comprendre | Synthèse de la fiche déjà chargée : constat, élément observé, vérification proposée et limite d'interprétation. Source AD/cache/non confirmée et horodatage visibles. | Pas de nouvelle interrogation AD ni de validation automatique de la santé du poste. |
| Comparer A / B | Deux captures indépendantes en mémoire, même objet avant/après ou deux objets de référence du même type et du même périmètre de session. Différences scalaires et différences d'appartenances directes. | Une valeur absente, tronquée ou partiellement lue reste indéterminée. Ce n'est pas un historique exhaustif des modifications AD. |
| Incidents expliqués | Derniers avertissements/erreurs reçus par le journal UI après le montage de l'Atelier ; pistes contextuelles, filtre littéral, détail local et plafond de 200 incidents. | Toutes les cibles de la session sont réunies. Aucune attribution automatique à l'objet actuellement affiché. Ce n'est pas l'importation des anciens fichiers de logs. |
| Repères de session | Jusqu'à 24 fiches épinglées, ouverture par le moteur habituel, dédoublonnage de la même identité. | Les repères ne sont pas conservés au redémarrage. Leur DN mémorisé peut devenir obsolète si l'objet est déplacé ou renommé. |
| Dossier / ticket | Aperçu, copie texte et export HTML autonome de la fiche, de la comparaison éventuelle et d'un incident explicitement sélectionné. | Partage manuel, aucun envoi automatique à GLPI, par courriel ou vers un service externe. |

Le menu **Ctrl+K** propose aussi l'ouverture de la synthèse et du comparateur. La palette d'actions reprend maintenant les ressources du thème de la fenêtre principale ; son filtrage ne traite plus les caractères saisis comme des jokers.

## Installation sur ton dossier existant

**Ne supprime pas ton installation actuelle. Le nouveau paquet ne contient pas ta base personnelle.**

Fermer ADCC après la fin des opérations, extraire le ZIP dans un dossier distinct, puis lancer depuis ce nouveau dossier :

```powershell
# Adapter le chemin à l'installation actuelle. Dossiers non imbriqués.
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\ADCC' -WhatIf
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\ADCC'
```

Le plan `-WhatIf` n'effectue aucune copie et ne lance pas les suites fonctionnelles. L'installation réelle vérifie le manifeste et analyse nativement les fichiers PowerShell. Elle lance les suites isolées distant/détection/comptes/Atelier avant la première sauvegarde ou copie de code. Une exception arrête la mise à jour. Les rapports de ces tests sont placés dans le répertoire temporaire Windows, pas dans ta base.

Les réglages existants marqués à conserver dans le manifeste et `wad\data` ne sont pas remplacés. Le code remplacé est sauvegardé dans `wad\maintenance\backups`. L'installateur permet un retour au code précédent avec `-RestoreBackup`, selon la procédure générale du `LIRE-MOI.md`.

**Ne copie pas uniquement `ADCC-Core.ps1` : les trois nouveaux fichiers `wad\modules\ADCC-Support.*` sont nécessaires.** Les exécutables, DLL, icône et lanceurs existants sont conservés à l'identique. Aucun Python, NuGet, service, API ou modèle IA n'est requis pour utiliser l'Atelier.

## Prise en main

### Lire une fiche avec ses limites

Ouvrir normalement une fiche utilisateur ou machine, puis **Atelier → Comprendre**. Cliquer sur un constat pour consulter son élément justificatif et la vérification proposée. **Recalculer la synthèse** utilise uniquement les propriétés déjà en mémoire. Pour relire réellement l'annuaire, actualiser la fiche depuis les commandes habituelles de l'application.

Une capture fraîche d'une fiche issue du cache ne la transforme pas en lecture AD fraîche. Le seuil de 15 minutes est un indicateur local pour inviter à actualiser, pas une règle de l'annuaire.

### Comparer avant/après une intervention

Depuis la fiche de départ, cliquer **Fiche actuelle → A**. Réaliser l'intervention autorisée avec les outils habituels, actualiser réellement la fiche, puis cliquer **Fiche actuelle → B**. Le comparateur lui-même n'effectue aucune écriture et n'applique aucune différence.

Pour comparer deux comptes de référence, capturer le premier en A, ouvrir le second puis capturer B. Le bandeau indique alors explicitement **Objets différents**. Un GUID valide permet de reconnaître le même objet malgré un changement de DN ; sans GUID exploitable, l'identité de secours est le DN. La comparaison refuse deux types ou périmètres de session différents.

**Identique** signifie identique sur les valeurs fournies et comparables. **Différent** indique un écart de valeur. **Indéterminé** indique que la lecture ne permet pas de conclure. Sélectionner la ligne `memberOf` pour voir les groupes fournis seulement en A ou seulement en B. Le comparateur ignore l'ordre et la casse de ces noms de groupes.

`memberOf` ne représente pas à lui seul les droits effectifs, les groupes imbriqués ou le groupe principal. La comparaison est limitée à 128 valeurs par attribut et à 1 024 caractères par valeur. Tout dépassement marque l'attribut comme partiel, sans annoncer une suppression certaine.

### Comprendre un incident

Les règles distinguent annulation/remplacement, refus d'authentification, refus d'accès, indisponibilité RPC, délai dépassé, nom/chemin réseau introuvable, conflit de sessions SMB, moteur occupé et sortie PsExec à examiner. Plusieurs pistes peuvent coexister. Sans correspondance, l'incident reste **Message non classé**.

Un refus LDAP, WMI ou SMB n'est pas transformé en verdict universel sur le mot de passe. Une interruption de lecture n'est pas transformée en « utilisateur absent ». Un code PsExec 1 seul ne prouve pas que la licence explique l'échec. Ces textes guident la vérification ; ils ne prouvent pas une cause racine.

Le journal de l'Atelier est limité aux messages collectés sur le thread UI après son initialisation. Les avertissements historiques, les messages non relayés au journal UI et les données supprimées par le plafond ne sont pas reconstruits.

### Préparer un dossier

Dans **Dossier / ticket**, générer l'aperçu puis copier le texte ou exporter le HTML. L'incident n'est ajouté que si sa case est cochée et qu'une ligne a été sélectionnée dans les incidents. Les comptes comparés peuvent être différents de la fiche courante ; leurs noms et sources sont indiqués séparément.

Le dossier ne contient pas les champs dédiés aux mots de passe LAPS, clés BitLocker, credentials ni les détails bruts des incidents. La sélection repose sur une liste positive de 29 attributs, sans les descriptions/notes libres. Des masquages supplémentaires détectent certaines formes de secrets saisis accidentellement dans un champ autorisé.

**Ce n'est pas une anonymisation et aucun filtre ne garantit de reconnaître tout secret librement saisi dans un attribut.** Les noms, DN, adresses et appartenances peuvent rester des informations internes ou personnelles. Relire avant partage. L'export HTML demande confirmation, encode le contenu comme texte et n'embarque ni script, ni image distante, ni ressource externe. La copie et l'export régénèrent le dossier, plutôt que de réutiliser silencieusement un ancien aperçu.

Les captures, repères et incidents de l'Atelier restent en mémoire jusqu'à fermeture, relogin ou effacement explicite. Les journaux et le cache habituels d'ADCC continuent de suivre leur politique existante. « En mémoire » ne garantit pas l'absence de traces dans la pagination ou les dumps du système.

## Architecture et non-régression

Trois fichiers additionnels :

- `wad\modules\ADCC-Support.Model.ps1` : 15 fonctions sans dépendance WPF, réseau ou écriture disque ; règles, captures, différences, incidents et rendu du rapport.
- `wad\modules\ADCC-Support.UI.ps1` : 17 fonctions d'adaptation à la fenêtre, aux données en mémoire et aux commandes existantes.
- `wad\modules\ADCC-Support.xaml` : contrôles nommés dans leur propre namescope, ressources dynamiques héritées du thème, tableaux en lecture seule avec virtualisation et recyclage activés.

Les 562 fonctions identifiées du cœur R1.4 sont conservées. Cinq sont modifiées pour l'intégration : `Add-AdccUiLog`, `Show-AdccCommandPalette`, `Start-AdccAccountRelogin`, `Show-AdObjectResult`, `Initialize-Window`. Les 557 autres conservent leur corps source. Deux déclarations de build et le chargement des modules sont également modifiés hors de ces fonctions.

Le moteur du login, la validation des comptes, le contexte des workers, le code commun distant et les opérations distantes ne sont pas réécrits. Cela préserve leur implémentation R1.4 ; cela **ne vaut pas validation de leurs accès sur ton domaine**.

Aucun nouveau schéma SQLite, scan automatique, redémarrage, modification AD ou élargissement des permissions n'est ajouté. L'ouverture volontaire d'un repère utilise la lecture de fiche existante et peut déclencher les lectures habituelles de cette fiche.

Le rafraîchissement de l'Atelier est local, à cadence d'une seconde, et ne recalcule les vues que lorsque nécessaire ou lors d'une demande manuelle. La liste n'est pas recalculée quand son onglet principal est caché. En cas de défaut du rafraîchissement optionnel, son timer est suspendu ; la synthèse manuelle peut le réactiver. Un échec de montage du nouvel écran est journalisé sans empêcher le reste de la console de s'initialiser.

## Vérifications : bien séparer ce qui a été exécuté

Les six audits disponibles dans `wad\tests\audit_*.py` ont été exécutés dans l'environnement de construction Linux. Ils couvrent les empreintes de fonctions et workers, les points d'intégration, le lexique approximatif, les noms et ressources XML, les garde-fous, des motifs regex exécutés en Python, les contrastes calculés et les tests SQLite préexistants sur données synthétiques. Le détail et le type de chaque contrôle sont dans `wad\docs\audit-*-R1.5.json`.

**Ni Windows PowerShell 5.1, ni WPF, ni Active Directory n'ont été exécutés dans cet environnement.** Une analyse XML n'est pas un chargement WPF. Le scanner lexical n'est pas le parseur PowerShell. Les regex Python ne remplacent pas le moteur .NET. Les résultats ne constituent donc pas une homologation de production.

La nouvelle suite `Test-ADCCSupport.ps1` fournit **52 tests fonctionnels natifs isolés** et **un scénario WPF optionnel**. Ils sont écrits, inclus et contrôlés statiquement, mais ne sont pas présentés comme réussis sous Windows ici.

```powershell
# Sans WPF ni connexion au domaine : mêmes tests que ceux de l'installateur.
powershell.exe -NoProfile -File .\wad\tests\Test-ADCCSupport.ps1

# Avec chargement WPF réel des XAML, sans démarrage du programme ni connexion AD.
powershell.exe -NoProfile -STA -File .\wad\tests\Test-ADCCSupport.ps1 -Wpf
```

Le fichier **`TESTER-ATELIER.cmd`** lance la deuxième commande. Les rapports manuels sont placés dans `wad\data\TestReports`. Une suite arrêtée avant la création du rapport peut laisser seulement le message visible dans la console.

## Recette Windows avant utilisation courante

Sur un poste de test Windows, lancer `TESTER-ATELIER.cmd`, puis les suites existantes. Vérifier le nouveau build au démarrage. Effectuer ensuite une recette en lecture seule : fiche utilisateur et machine, clair/sombre puis relance, captures A/B d'une même fiche, comparaison de deux comptes, valeur non fournie, effacement de l'Atelier, changement de compte et vérification de la disparition des captures/repères/incidents.

Vérifier également le comportement pendant une lecture distante lente : les captures doivent refuser une ancienne fiche lorsqu'une autre cible charge. Tester l'export HTML avec des valeurs contenant `&`, `<` et des accents, et relire le fichier pour vérifier le contenu partagé. Contrôler que les fonctions préexistantes, notamment les comptes et la détection utilisateur, ont le même comportement que sur R1.4.

Les zones de détail ont une hauteur prédéfinie. La lisibilité à tous les facteurs DPI et sur une petite fenêtre n'a pas été validée par un rendu Windows. Les contrôles de contraste portent sur les ressources, pas sur une capture d'écran réelle.

## Références techniques

Références Microsoft consultées pour les règles et les choix d'interface. Les seuils locaux, le bornage et l'organisation de l'Atelier sont des choix du projet, pas des recommandations attribuées à ces pages.

- [userAccountControl et ses indicateurs](https://learn.microsoft.com/en-us/troubleshoot/windows-server/active-directory/useraccountcontrol-manipulate-account-properties).
- [msDS-User-Account-Control-Computed](https://learn.microsoft.com/en-us/windows/win32/adschema/a-msds-user-account-control-computed), pour les indicateurs calculés, utilisés seulement lorsqu'ils sont fournis.
- [lockoutTime, notamment ses remarques](https://learn.microsoft.com/en-us/windows/win32/adschema/a-lockouttime), pour ne pas assimiler une trace à un verrouillage actuel.
- [pwdLastSet](https://learn.microsoft.com/en-us/windows/win32/adschema/a-pwdlastset), pour tenir compte de l'option de non-expiration quand la valeur est zéro.
- [accountExpires](https://learn.microsoft.com/en-us/windows/win32/adschema/a-accountexpires), pour les dates et valeurs sentinelles.
- [memberOf](https://learn.microsoft.com/en-us/windows/win32/adschema/a-memberof), pour limiter l'interprétation des appartenances.
- [Optimisation des contrôles WPF](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/advanced/optimizing-performance-controls), pour la virtualisation et le recyclage.

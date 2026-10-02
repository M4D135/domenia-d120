# Domenia 1.0 RC1.9 : interactions intégrées et identité des relations

Build : `2026.10.01-DOMENIA-1.0-RC1.9-INTEGRATED`.
Base : les archives originales Domenia RC1.8 présentes dans cette conversation.
Statut : version candidate. Les tests Windows sont fournis, pas présentés comme exécutés ici.

## 1. Ce que vous avez signalé

Le sélecteur « Associer un poste » ouvrait un ancien formulaire séparé. Son affichage blanc ne reprenait pas les ressources de la fenêtre principale, et le clic Rechercher exécutait la recherche LDAP directement dans son événement WPF. Une simple adaptation de couleur n'aurait pas supprimé cette rupture de parcours ni l'attente de réseau sur le thread appelant.

L'écran de Relations montrait aussi « Recherche AD non confirmée ». La capture situe un échec mais ne fournit pas l'exception précise. La lecture des sources a trouvé un défaut de représentation du GUID binaire : l'identifiant AD pouvait devenir un tableau d'octets déroulé par le pipeline, puis une chaîne de nombres, au lieu d'un GUID. La recherche inverse le comparait au GUID texte de la sélection et pouvait alors refuser le même utilisateur comme prétendument recréé. Cette cause est corrigée dans le code ; elle n'a pas été reproduite sur votre domaine dans cet environnement.

## 2. Plus de fenêtre séparée pour les interactions métier

Un hôte commun est ajouté dans le XAML principal. Les formulaires sont présentés dans un **volet intégré à droite**, au-dessus de la page, avec un fond d'attente derrière. Le volet ne prend aucune ligne supplémentaire dans la disposition : recherche, arbre OU, activité et journal conservent leur géométrie extérieure.

Les parcours raccordés sont :

| Interaction | Présentation |
|---|---|
| Associer un poste ou un utilisateur | Recherche, résultats, sélection et validation dans le volet intégré. |
| Choisir un utilisateur depuis Relations | Nouveau bouton explicite ; recherche sur tout le domaine, choix volontaire. |
| Choisir l'OU d'un déplacement | Même sélecteur intégré ; sa validation ne déclenche pas le déplacement. |
| Confirmations, avertissements et formulaires de saisie | Carte intégrée avec les mêmes ressources de thème. Les confirmations existantes sont conservées. |
| Compte alternatif après refus | Formulaire intégré, moteur d'authentification existant, sans partage de mots de passe nouveau. |
| Reconnexion volontaire du compte AD principal | Formulaire de connexion existant hébergé dans le volet ; le login initial reste distinct. |
| Palette de commandes | Contenu intégré ; les commandes ne sont pas élargies. |
| Paramètres d'exécution distante existants | Formulaire intégré ; mêmes protections et confirmation métier. |
| Ouvrir/enregistrer un CSV, une capture ou un rapport | Sélecteur de chemin intégré, sans fenêtre OpenFileDialog/SaveFileDialog supplémentaire. |

Il s'agit d'une modification de présentation, pas d'un système de décision automatique. Une confirmation est toujours requise là où elle l'était. Le volet est une décision modale **dans la fenêtre principale** : la page située derrière est volontairement désactivée pendant le choix. Le Dispatcher continue de traiter les événements ; une attente de réponse de l'utilisateur n'est pas transformée en appel Sleep ou WaitOne. Les traitements déjà envoyés peuvent continuer, mais certains callbacks métier attendent toujours la fin d'une décision selon le moteur existant. Ce n'est pas une garantie de mise à jour de toutes les vues pendant chaque confirmation.

Les anciens objets Window utilisés pour construire certains formulaires ne sont plus affichés comme fenêtres lorsqu'un hôte principal est ouvert : leur contenu et les handlers existants sont hébergés dans ce volet. Cela limite les changements de contrats d'appel des opérations sensibles. Les tests WPF fournis contrôlent que ces propriétaires non affichés n'obtiennent pas de HWND.

### Thèmes, fermeture et clavier

Les champs, listes et boutons utilisent les ressources de Domenia en clair ou sombre. Les noms et aides sont statiques, pas générés depuis les valeurs saisies. Le focus est contenu dans le volet. Les raccourcis de la page arrière sont suspendus, puis restaurés ; Fermer ou Échap annule le choix. La sélection et la saisie de la page ne sont pas effacées par le volet.

Une seconde demande ne s'empile pas sur la première. Les messages apparaissent dans le panneau actif. Une confirmation refusée faute de contexte n'autorise pas l'action. La proposition de compte alternatif attend la fermeture du volet courant au lieu de consommer silencieusement son tour. Un changement de session ou une fermeture de l'application invalide le choix non terminé.

Les champs de mot de passe intégrés sont vidés à la fermeture. Les credentials réellement validés conservent les règles existantes de durée de vie et de périmètre ; aucune nouvelle persistance de secret n'est ajoutée.

### Limite explicite

Le **login initial**, le chargement initial et une erreur fatale avant que le GUI puisse exister restent des écrans de démarrage. Les dialogues de sécurité Windows, dont UAC, ne sont pas remplacés ou contournés. Une application externe ouverte volontairement (éditeur de journal, console Windows, Bureau à distance) reste une application externe. Les listes déroulantes et les infobulles normales restent disponibles. La règle porte sur les interactions métier internes, pas sur la falsification d'une demande de sécurité du système.

## 3. Associer un poste depuis l'utilisateur

1. Sélectionner un utilisateur dans la recherche, ou cliquer **Choisir un utilisateur** dans Relations.
2. Examiner ses associations mémorisées ; le contexte ne devient pas Toutes les associations par défaut.
3. Cliquer **Associer un poste**.
4. Saisir au moins deux caractères, puis Rechercher. Le domaine connecté est utilisé, pas le filtre OU de la page arrière.
5. Sélectionner le poste. Aucune première ligne n'est choisie automatiquement.
6. Cliquer Choisir. Le poste est relu dans AD avec son DN et son GUID exacts.
7. La confirmation de l'association apparaît elle aussi dans le GUI. Elle indique les deux objets et précise qu'il s'agit d'une déclaration locale, pas d'une session détectée ni d'une écriture AD.

La recherche du sélecteur est une opération de lecture en runspace, dans le registre fermé, avec délais demandés et retour borné à 100 objets. Sa fermeture demande l'arrêt ; une API native peut terminer après cette demande. Les retours tardifs ou d'une autre session/requête ne valident pas le choix. Le bouton de validation et la sélection sont immobilisés pendant la relecture du GUID.

Le nouveau sélecteur utilisateur fournit les champs utiles à Relations (type, login, DN, GUID). Il ne déclenche ni ping ni sondage des consoles. La recherche globale de l'en-tête n'est pas modifiée et ne sélectionne pas automatiquement le premier utilisateur correspondant.

## 4. Recherche inverse et GUID

`Get-WPropFirst` préserve les valeurs binaires comme un objet unique. `Convert-WGuid` accepte un GUID déjà typé, un texte GUID valide ou un tableau de 16 octets. Les longueurs et valeurs impossibles sont rejetées. Le worker inverse refuse explicitement un GUID illisible, au lieu de l'assimiler à une preuve de compte recréé.

La première erreur de lecture est ajoutée au résumé visible de Relations, avec sa méthode et son détail. Elle reste dans le tableau de diagnostic. La recherche n'annonce pas qu'aucun poste n'existe lorsque la lecture AD échoue.

Les anciennes fixtures de la suite Relations simulaient les GUID directement sous forme de chaînes, ce qui ne représentait pas le format AD concerné. Elles utilisent maintenant des octets binaires et les véritables helpers communs extraits par AST. La nouvelle suite conserve aussi une reproduction explicite du déroulement de tableau avant correctif.

Cela ne crée pas un inventaire magique des sessions : sans association connue, indice AD ou console effectivement vérifiée, Domenia peut ne pas trouver un poste. Un responsable déclaré, un profil local, une association manuelle et une session console restent des notions distinctes. Le balayage inverse conserve son consentement, son périmètre et ses limites, sans sondage automatique supplémentaire.

## 5. Choix des fichiers intégré

Parcourir et valider les chemins utilisent un worker distinct, sans credential AD transmis. Aucune lecture de dossier n'est lancée à l'ouverture du volet. Le dossier est lu après Parcourir ; son contenu est borné à 500 entrées, sans récursion. Un chemin complet de fichier peut être saisi directement.

L'absence d'un fichier est distinguée d'une erreur d'accès. Un dossier ou un parent absent n'est pas créé automatiquement. Pour enregistrer sur un fichier existant, **Remplacer** demande un second clic explicite et revalide sa signature longueur/date. Une modification ultérieure entre ce contrôle et l'écriture reste possible : cette vérification n'est pas un verrou transactionnel sur les fichiers.

Le format attendu est affiché. La liste montre les fichiers du dossier, pas un filtre d'extension exhaustif. L'extension par défaut est ajoutée en mode Enregistrer seulement lorsqu'aucune extension n'a été saisie. Les lecteurs/écrivains métier existants conservent leurs validations et modes d'écriture ; la navigation de fichiers intégrée ne prétend pas rendre asynchrones tous les anciens exports.

## 6. Périmètre et conservation

Les 577 fonctions principales restent présentes ; 17 corps changent dans la limite du raccordement des interactions, des nouveaux contrats et du build. Les helpers binaires dans le bloc commun aux workers sont également corrigés. Un module de présentation de 20 fonctions est ajouté. Le plan fermé contient **22 modules et 255 fonctions de modules**, vérifiés par nom et fichier d'origine au chargement.

Le registre contient **57 opérations** : les 55 existantes et les deux lectures du sélecteur AD et des chemins. Le worker UserComputerProbe reçoit son contrôle de GUID illisible ; les 54 autres corps d'opérations existantes conservent leur empreinte. Le registre et son empreinte globale sont reconstruits explicitement par l'outil de contrat, pas appris au démarrage.

Les moteurs d'authentification, les règles de droits et non-rejeu, la recherche globale/OU, les pings et utilisateurs uniquement à la sélection, l'Atelier, les données et migrations SQLite ne sont pas remplacés. Les fichiers EXE/DLL ne changent pas. L'exécutable reste non signé ; il n'a pas été recompilé pour cette révision de scripts et de présentation.

## 7. Installer

Les deux archives ont des dossiers clairement nommés `prod` et `dev`. La racine PROD contient uniquement `Domenia.exe` et `wad`. Le déblocage reste dans `wad/Support/DEBLOQUER_TOUT.cmd`. Aucun test, aperçu ou document DEV n'est requis au lancement PROD.

Fermer l'application après la fin des opérations. Extraire DEV dans un dossier distinct, puis depuis ce nouveau dossier :

```powershell
# Adapter au dossier qui contient actuellement Domenia.exe et wad.
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\Domenia' -WhatIf
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\Domenia'
```

Conserver l'installation et ses données. L'installateur garde les configurations et `wad/data`, ne remplace pas `%LOCALAPPDATA%\Domenia\Data` et sauvegarde le code remplacé. Installer le cœur, le nouveau module, le chargeur et les manifestes ensemble, pas un script isolé. Les nouvelles archives ne contiennent pas votre base.

## 8. Vérifications et recette

### Effectivement exécuté dans l'environnement de préparation

Audit Python général : sources, noms, XML, contrats d'opérations et essais SQLite préexistants exécutés par Python. Audit ciblé RC1.9 : routes des interfaces, confinement des volets, absence des anciens constructeurs de sélecteur de fichiers, conservation des fonctions et binaires, helpers GUID et contrats fermés. Construction puis réouverture indépendante des deux ZIP : CRC, chemins Windows uniques, tailles, SHA-256 de tous les fichiers, structure PROD, correspondance du runtime entre PROD et DEV.

Les nombres et les résultats sont dans les rapports JSON. Les délimiteurs lexicaux ne sont pas le parseur PowerShell. Les preuves d'empreintes et XML ne constituent pas un test de placement des pixels.

### Fourni pour Windows, non exécuté ici

**TESTER-INTEGRATION.cmd** contient **72 scénarios Windows PowerShell 5.1 x64 STA**. Il utilise les véritables helpers et workers, avec transports LDAP/CIM doublés, fichiers temporaires de recette et le XAML réel. Il couvre GUID binaires/déroulés, résultats plafonnés, refus, candidats recréés, chemins, relecture avant choix, zéro requête à l'ouverture, retour tardif, annulation, thème, absence de HWND secondaire, focus/état de la page, géométrie et Dispatcher actif pendant la décision. Il exige la totalité des 72 résultats et aucun échec. Les scénarios de signature système/UAC et les droits de votre domaine ne sont pas simulés comme des réussites.

**TESTER-RELATIONS.cmd** conserve ses 65 scénarios avec les fixtures GUID corrigées. Les autres suites natives restent dans l'installateur ; le test du registre attend les 57 opérations actuelles, tout en reproduisant séparément l'ancien refus 55/54 sur une fixture de 55 entrées.

**APERCU-INTEGRE.cmd** exécute la nouvelle suite puis ouvre le volet de choix sur le vrai XAML, avec un poste fictif et une file de résultats simulée. Aucun compte, domaine, poste ou cache personnel n'est interrogé. Les aperçus initialement disponibles sont conservés.

**Non exécutés ici : Windows PowerShell 5.1, WPF, HWND, exécutable Windows, authentification, LDAP ou CIM réels.** Une tentative de récupération d'un parseur Linux n'a pas abouti ; aucun test PowerShell n'est déclaré passé. La recette native doit être faite avant distribution élargie. Un échec de test doit être analysé, pas contourné en supprimant le contrôle.

### Vérifications sur poste de recette

Examiner les deux thèmes. Depuis Relations, choisir un utilisateur, rechercher ses postes, ouvrir le sélecteur et annuler avant/après une recherche lente. Faire une association volontaire sur des données de test et vérifier les deux identités dans la confirmation. Contrôler un refus de lecture et l'accès à un compte alternatif après fermeture du sélecteur. Vérifier un import/export avec annulation et remplacement, puis comparer la présentation de l'arbre, de l'activité et des compteurs. Le login initial reste celui de FILPRO ; une reconnexion dans l'application est intégrée.

Références de conception : documentation Microsoft WPF, modèle de threading, Dispatcher.PushFrame et Window.Closing. Les formes de valeurs AD sont vérifiées à partir du code et des fixtures binaires ; aucune session Windows réelle n'a été testée ici.

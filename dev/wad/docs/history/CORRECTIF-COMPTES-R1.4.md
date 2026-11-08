# ADCC 1.0 R1.4 : validation cohérente des comptes

**Build : `2026.09.21-R1.4-ACCOUNTS`**  
Base : paquet R1.3 fourni dans cette conversation. Version publique : 1.0.

## Incident et diagnostic

La capture fournie montre un échec lors de l'activation du compte « Remote », dans un appel `Bind`, avec un message d'identifiants invalides. L'utilisateur indique que le même compte fonctionne au login principal.

La comparaison du code R1.3 confirme deux chemins différents :

| Chemin | Code avant R1.4 |
|---|---|
| Login explicite | `Invoke-AdccInProcessAuthProbe`, puis `DirectoryEntry` avec identifiant validé et `AuthenticationTypes.Secure`. |
| Boutons Tester et Activer des comptes | `Test-AdccCredentialBind`, utilisant directement `LdapConnection`, `AuthType.Negotiate` et `NetworkCredential(user, password)`. |

Le second chemin ne réutilisait pas la qualification de l'identifiant effectuée par le login. Il construisait également son propre objet `NetworkCredential`, sans renseigner séparément le domaine.

**Ce décalage est vérifié dans le code. La cause native exacte du refus sur le contrôleur de l'utilisateur n'a pas été reproduite ici.** La documentation de .NET distingue les constructeurs et leurs paramètres ; elle ne permet pas d'affirmer que chaque identifiant `DOMAINE\utilisateur` échoue avec `LdapConnection`. Le correctif élimine la divergence au lieu d'imposer un changement de mot de passe ou de politiques AD.

Le message de la capture survient pendant la validation AD. Il ne démontre pas un refus WMI, WinRM ou SMB sur un poste.

## Changements du correctif

### Un seul moteur pour le login et le panneau Comptes

`Test-AdccCredentialBind` lance maintenant le même worker `Invoke-AdccInProcessAuthProbe`, via `Start-AdccLoginAuthRunspace`. Le moteur de login lui-même n'a pas été modifié : son empreinte de texte normalisé est identique à R1.3.

La requête reprend le contrôleur, la base, le domaine et le NetBIOS de la session AD active. Elle limite la liste à un contrôleur. Le login reçu reste inchangé, hors espaces autour du nom ; la qualification d'un nom court est laissée au moteur existant. Il n'y a pas de succession automatique de variantes de comptes, pas de repli de validation vers le compte Windows, et pas de deuxième essai avec le mot de passe après un refus.

Une découverte du contexte avec la session Windows reste présente dans le moteur de login existant. Elle ne remplace pas la validation du compte explicite. Le résultat accepté doit être un succès du mode `Explicit`, de méthode `ADSI.DirectoryEntry+ContextDiscovery`, avec un `BindUser` non vide.

### L'identité testée est l'identité conservée

Après une validation réussie, le compte Remote ou Secrets est créé à partir du nom retourné par le moteur, et non à partir du nom court initialement tapé. L'identifiant et son mot de passe restent associés.

Les boutons Activer lisent maintenant directement `PasswordBox.SecurePassword`. Les nouvelles fonctions utilisent des copies privées de `SecureString`. Le mot de passe n'est ni nettoyé avec `Trim`, ni enregistré dans les préférences, ni journalisé par ces nouvelles fonctions. Le moteur ADSI existant convertit temporairement ce secret pour l'API qui en a besoin ; cette révision ne prétend pas supprimer toutes les représentations temporaires en mémoire.

Le compte précédemment actif est conservé lorsque la validation échoue ou expire. Le champ mot de passe n'est vidé qu'après activation réussie. Seul le nom du compte est envoyé aux préférences.

### Test du compte AD : empêcher un mélange de comptes

Le bouton Tester du bloc Annuaire pouvait prendre le nom actuellement édité et lui associer le mot de passe de la session AD active. Il refuse maintenant ce test si le nom ne correspond pas au compte actif. Le bouton « Utiliser / relogger » reste le parcours pour changer de compte. Une différence de casse ou le nom court du même compte dans le même NetBIOS est acceptée sans réattribuer le mot de passe.

### Compte Secrets transmis aux workers

`Get-WorkerContext` pouvait choisir le mot de passe du compte Secrets tout en conservant le `BindUser` du compte AD principal. Pour LAPS et BitLocker, les workers reçoivent désormais le nom du credential réellement sélectionné. La séparation entre compte AD et compte distant pour la détection du dernier utilisateur est conservée.

### Délais et nettoyage

L'appel natif s'exécute dans un runspace ; l'attente du résultat est bornée à huit secondes par défaut. Le bouton attend encore cette validation de façon synchrone : ce n'est pas une refonte entièrement asynchrone de l'interface. L'initialisation et le nettoyage ne constituent pas une garantie de durée totale exactement égale à huit secondes.

En cas de dépassement, aucun résultat tardif n'est appliqué. Tant que l'appel natif précédent ne s'est pas terminé ou nettoyé, une nouvelle validation est refusée avant d'envoyer un autre essai. Le message distingue ce délai d'un refus d'identifiants. La fermeture du logiciel demande aussi l'arrêt de ce worker.

## Périmètre conservé et limites

Aucune fonction principale n'a été supprimée. Cinq fonctions existantes ont été modifiées, deux ajoutées. La procédure de login existante, les 46 corps de workers épinglés, le thème sombre et le cycle de détection R1.3 sont conservés. Les exécutables, icônes et DLL de la distribution de base sont inchangés.

**Valider une identité AD ne valide pas les autorisations de cette identité sur un poste.** Le journal le dit explicitement. Un refus d'accès CIM, WMI, SMB, LAPS ou BitLocker reste possible après une validation AD réussie ; aucune permission ni stratégie de sécurité n'est contournée.

Ce panneau conserve une validation de comptes d'annuaire. Cette révision n'ajoute pas de validation d'un compte local `POSTE\administrateur` ou `.\administrateur` contre le poste distant.

Un clic sur Tester puis un clic sur Activer constituent deux demandes volontaires distinctes. Pour l'essai de cette correction, un seul clic sur Activer suffit. Si un compte AD explicite est déjà utilisé au login et qu'aucun compte distant dédié ou par-machine n'est configuré, le repli vers ce compte pour les opérations distantes reste celui du code existant.

## Installation sans perdre le cache

Fermer ADCC après la fin des opérations. Extraire le nouveau paquet dans un autre dossier, non imbriqué dans l'installation actuelle. Ouvrir Windows PowerShell 5.1 depuis le dossier contenant l'installateur et adapter le chemin de destination :

```powershell
# Contrôle du paquet et aperçu du plan, sans copie.
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\ADCC' -WhatIf

# Sauvegarde du code puis installation.
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\ADCC'
```

**Ne pas supprimer l'installation actuelle.** Le ZIP distribué ne contient pas la base personnelle. L'installateur préserve `wad\data` et les fichiers de configuration déjà présents ; les fichiers de code remplacés sont sauvegardés dans `wad\maintenance\backups`.

L'installateur vérifie le manifeste et la syntaxe PowerShell native. Avant toute copie du code, il exécute les suites isolées Remote, Detection et Comptes. Leurs appels réseau sont simulés. Un échec interrompt l'installation avant le remplacement du code. Ces tests ne demandent pas de compte ni de mot de passe réels.

Le mécanisme de restauration du code fourni avec les versions précédentes reste présent. En cas de retour arrière, utiliser le fichier `RESTAURER-CODE.ps1` et le chemin de sauvegarde indiqués dans le journal d'installation, selon la procédure générale de `LIRE-MOI.md`.

## Recette ciblée sur le poste

1. Lancer la copie mise à jour avec `LANCER-ADCC.cmd`. Vérifier le build `2026.09.21-R1.4-ACCOUNTS` dans le journal.
2. Se connecter avec le compte habituel. Dans Comptes, saisir le compte distant avec la même forme d'identifiant que celle qui fonctionne au login. Cliquer une fois sur **Activer**.
3. Vérifier les lignes « moteur du login ADSI », « identite AD validee » puis « Compte Remote active ». La mention sur les droits non testés est normale. En cas de refus ou de délai, vérifier que l'ancien compte actif n'a pas changé.
4. Relancer ensuite la détection sur un poste autorisé. Un succès de validation AD et un succès d'accès au poste sont deux résultats différents.

`TESTER-COMPTES.cmd` peut exécuter séparément les tests isolés, sans AD et sans WPF. Son rapport JSON est créé dans le dossier temporaire Windows. Ne jamais communiquer un mot de passe pour reproduire ce problème ; le journal suffit au diagnostic du prochain éventuel refus.

## Vérifications exécutées ici

Environnement : Linux, Python et SQLite. Les comptes, domaines et secrets des nouveaux scénarios de test sont synthétiques.

| Suite | Résultats exécutés | Nature |
|---|---:|---|
| `audit_accounts.py` | 28 réussis, 0 échec | Assertions sur les chemins du code, empreinte du login, tests fournis et ordre d'installation. |
| `audit_theme.py` | 14 réussis, 0 échec | Analyse source, XML et contrastes calculés, pas de rendu WPF. |
| `audit_remote.py` | 29 réussis, 0 échec | Assertions source sur les accès distants et les corps de workers. |
| `audit_lastuser.py` | 26 réussis, 0 échec | Assertions source sur le cycle de détection. |
| `audit_project.py` | 45 réussis, 0 échec | Lexique, XML, intégrité, requêtes SQL synthétiques et API SQLite via Python. |

Ces suites se recouvrent partiellement. Les assertions source ne sont pas des essais comportementaux de l'application. Les fichiers JSON correspondants sont présents dans `wad/docs`.

**Les 25 nouveaux scénarios de `Test-ADCCAccounts.ps1` sont fournis, mais n'ont pas été exécutés dans cet environnement.** Ils extraient les vraies fonctions par l'AST PowerShell et remplacent les frontières d'authentification par des mocks. Ils couvrent les identités, SecureString, refus, délais, résultats tardifs, séparation des comptes et transmission aux workers.

Windows PowerShell 5.1, WPF et l'authentification sur le domaine de l'utilisateur n'ont pas été exécutés ici. La recette de connexion réelle ci-dessus reste nécessaire. Le paquet ne doit pas être présenté comme certifié pour la production sur la seule base de ces contrôles.

## Traçabilité et références

`wad/docs/ADCC-R1.4-ACCOUNTS.patch` contient le diff du cœur depuis R1.3. `CHANGES-ACCOUNTS-R1.4.json` décrit les fonctions modifiées. Les rapports des versions antérieures restent dans le paquet comme historique, pas comme preuve d'une exécution Windows de R1.4.

Références techniques consultées le 21 septembre 2026, distinctes du diagnostic tiré du code fourni :

- Microsoft Learn, `DirectoryEntry` constructors : le constructeur explicite reçoit chemin, nom, mot de passe et type d'authentification. `https://learn.microsoft.com/en-us/dotnet/api/system.directoryservices.directoryentry.-ctor?view=netframework-4.8.1`
- Microsoft Learn, `NetworkCredential` constructors : les surcharges à deux et trois paramètres distinguent le domaine des nom et mot de passe. `https://learn.microsoft.com/en-us/dotnet/api/system.net.networkcredential.-ctor?view=netframework-4.8.1`

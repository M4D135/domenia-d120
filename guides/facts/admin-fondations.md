# Fiche de faits — guide administrateur, fondations (Domenia 1.0)

Relevé du 8 octobre 2026 sur le dépôt `Domenia-D120`, branche `claude/epic-newton-j5ir1w`, commit `225d5a7`
(arbre propre hors `guides/`). Le code fait foi. Aucune exécution sous Windows ni dans la VM pour cette fiche.

Conventions :
- Références : `Core:N` = `dev/wad/Domenia-Core.ps1` ligne N ; `Start:N` = `dev/wad/Domenia-Start.ps1` ;
  `Modules:N` = `dev/wad/Domenia-Modules.ps1` ; `Installer:N` = `dev/INSTALLER-MISE-A-JOUR.ps1` ;
  `launcher.c:N` = `dev/tools/launcher/launcher.c` ; `X.UI:N` = `dev/wad/modules/Domenia-X.UI.ps1` (idem `.Model`, `.Worker`).
- Libellés entre « » : copiés à l'identique du code (sans accents quand le code n'en a pas). Les libellés de la fenêtre
  de connexion contiennent l'apostrophe typographique U+2019 (« l’identifiant ») : la reprendre telle quelle.
- [NV] = non vérifié (non observé à l'écran ou déduit de la lecture du code seulement).
- Ne pas reprendre dans les guides : noms d'hôte, adresses IP, comptes et nom de domaine du labo cités dans
  `CLAUDE.md` et `engineering/d120/lab/*` (données réelles). Cette fiche ne les recopie pas.

## 1. Identité de la livraison

- Contrat unique : `dev/tools/release-contract.json` (seul endroit où la version s'écrit à la main, `tools/release_contract.py:4`).
  Valeurs : `Product` Domenia, `Version` 1.0, `Release` RC1.11.0, `Build` `2026.10.05-DOMENIA-1.0-RC1.11.0-D120`,
  `DisplayName` « Domenia 1.0 RC1.11.0 », `Date` 2026-10-05, `Channel` Candidate,
  `ReleaseStatus` CandidateRequiresWindowsValidation, `DataSchemaVersion` 11, `MinimumPowerShell` 5.1.
- Composants épinglés (SHA-256 dans le contrat) : `Domenia.exe` (lanceur natif, « conserve a l octet », non recompilé,
  non signé), `wad/Microsoft.ActiveDirectory.Management.dll`, `wad/ActiveDirectoryPowerShellResources.dll`,
  `wad/PsExec.exe` (tiers, « revue de licence requise »). Composants système déclarés : Windows PowerShell 5.1 + WPF,
  `winsqlite3.dll` fourni par Windows, CIM/WMI, WTS, LDAP.
- Copie runtime : `dev/wad/Domenia.release.json` (identique au contrat). Sites de version vérifiés par
  `python tools/release_contract.py --check` : `$script:Version = "1.0"` (Core:390, 8074, 19673),
  `$script:MasterBuild` (Core:19675), `$script:DomeniaBuild = "Domenia 1.0 RC1.11.0"` (Core:24462),
  pied du menu « DOMENIA 1.0 · RC1.11.0 » (Core:4176), trace de démarrage (Core:25794, « Demarrage Domenia 1.0 RC1.11.0 (…) »).
- Lanceur `Domenia.exe` : 26 624 octets, SHA-256 `3535a6cb…6be7ac` (recalculé : identique au contrat) ; ressources
  de version FileVersion 1.0.0.1, ProductVersion « 1.0 RC1 », FileDescription « Domenia launcher ».
- Exécuté le 08/10 sur Mac (non qualifiant) : `release_contract.py --check` → PASS, aucun problème.
- Point à signaler : le code a changé les 7 et 8 octobre (widgets, StorageBackup, etc.) mais l'identité est restée
  RC1.11.0 / Build du 05/10. Conséquence lue dans le code : l'installateur refuse d'installer sur un poste déjà en
  RC1.11.0 avec « Cette version est deja active. Utilisez une livraison portant un nouveau Build. » (Installer:191).
  Une nouvelle livraison doit changer le Build dans le contrat puis `release_contract.py --stamp`.

## 2. Paquets PROD et DEV, arborescence

- Construction : `python tools/build_packages.py --output <dossier hors de dev\>` (refuse un dossier de sortie dans
  l'arbre, `build_packages.py:38-42`). Archives : `Domenia_1.0_RC1.11.0_PROD.zip` et `Domenia_1.0_RC1.11.0_DEV.zip`
  (`build_packages.py:202`), dossiers racine `prod/` et `dev/` dans le ZIP.
- PROD : racine exactement `Domenia.exe` + `wad` (contrôle `build_packages.py:214`) ; 82 fichiers runtime
  (`tools/prod-manifest.json`, `Edition` prod). DEV : même runtime à l'octet (contrôle `build_packages.py:216-217`) +
  installateur, sources, outils, tests, suivi ; 435 fichiers dans `wad/package-manifest.json` (`Edition` dev).
- Exclus de DEV : `wad/data/`, dossiers `backups`, `__pycache__`, `.git`, fichiers `.pyc`/`.tmp`, `.DS_Store`,
  `Thumbs.db`, `desktop.ini` (`build_packages.py:20-21,44-56`). Le runtime ne peut contenir ni `tests`, ni `data`,
  ni `history`, ni `backups` (`build_packages.py:181-184`).
- La construction refuse un `wad/Domenia.config.json` qui active `Auth.DemoProvider` (`build_packages.py:58-64`,
  décision D111).
- Liste runtime (`build_packages.py:31-35`) : `Domenia.exe` ; `wad/` : `Domenia-Start.ps1`, `Domenia-Modules.ps1`,
  `Domenia-Core.ps1`, `Domenia.ico`, `Domenia.config.json`, `Domenia.release.json`, `Domenia.login-mode.cfg`,
  `Domenia.theme.cfg`, `Domenia.ui-profile.cfg`, les deux DLL AD, `PsExec.exe` ; `wad/Support/` :
  `DEBLOQUER_TOUT.cmd`, `Debloquer-Paquet.ps1`, `.lifecycle.lock` (fichier vide) ; tous les `.ps1 .json .cs .xaml`
  de `wad/modules/`.
- Fichiers « conservés » (`PreserveExisting` = vrai, empreinte non imposée au démarrage, jamais remplacés par
  l'installateur) : `wad/Domenia.config.json`, `wad/Domenia.login-mode.cfg`, `wad/Domenia.theme.cfg`,
  `wad/Domenia.ui-profile.cfg` (`build_packages.py:36`, Installer:83).
- Contenu livré : `Domenia.config.json` = `Auth.LoginWindowMode` "Standard", `Streaming.VerifyUserOnSelection` true,
  `Streaming.AutoDetectLoggedUser` false (cette dernière clé n'est lue par aucun code : grep vide) ;
  `Domenia.login-mode.cfg` = `Standard` ; `Domenia.theme.cfg` = `Light` ; `Domenia.ui-profile.cfg` = `Tech`.
- Arborescence DEV (racine `dev/`) : `Domenia.exe`, `Domenia.ico`, `Domenia.ps1`, `INSTALLER-MISE-A-JOUR.ps1`,
  `LANCER-Domenia.cmd`, `Lancer-Domenia.vbs`, `VERIFIER-PACK.cmd`, `TESTER-*.cmd` (11), `APERCU-*.cmd` (6), notes
  `CORRECTIF-*.md` / `LIRE-MOI.md` ; `wad/` (runtime + `maintenance/`, `tests/`, `docs/`) ; `tools/` ; `engineering/d120/`.
- Vérifié le 08/10 (Mac) : les 435 empreintes de `wad/package-manifest.json` correspondent aux fichiers du disque
  (0 écart).

## 3. Chaîne de démarrage

1. `Domenia.exe` (source `tools/launcher/launcher.c`, chaînes de l'exécutable identiques à la source) :
   - ouvre `wad\Support\.lifecycle.lock` en lecture partagée ; échec → « Paquet absent, mise a jour en cours ou dossier
     inaccessible. Ne pas supprimer les verrous. Utiliser l installateur DEV. » (code 7, launcher.c:41-42) ;
   - si `wad\Support\.update.pending` existe → « Une installation interrompue doit etre restauree ou terminee avant de
     lancer Domenia. » (code 8, launcher.c:43-44) ;
   - `wad\Domenia-Start.ps1` absent → « wad\Domenia-Start.ps1 est absent. Extraire tout le dossier prod ou dev. » (code 3) ;
   - lance `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoLogo -NoProfile -STA -File wad\Domenia-Start.ps1`
     (launcher.c:47-52) ; PowerShell absent → « Windows PowerShell 5.1 x64 est requis. » (code 4) ;
   - arguments admis : aucun (lancement normal, fenêtre console cachée), `--check` (ajoute `-CheckOnly`) ou
     `--diagnostic` (ajoute `-Diagnostic`) ; avec l'un des deux, une console visible est créée (launcher.c:50-56).
     Autre argument → « Arguments acceptes : --check ou --diagnostic. Le lancement normal ne prend aucun argument. » (code 5) ;
   - n'ajoute PAS `-ExecutionPolicy` : la stratégie d'exécution de la machine s'applique (launcher.c:52) [NV : effet
     selon la stratégie] ;
   - après un arrêt en erreur (lancement normal) : « DOMENIA s'est arrete sur une erreur. Lancer Domenia.exe --diagnostic
     pour la voir. Les journaux restent sous wad\data\Logs ou le dossier utilisateur. » (launcher.c:60). Titre des
     messages : « DOMENIA | Demarrage ».
2. `wad/Domenia-Start.ps1` (Start:1-131) :
   - exige Windows PowerShell 5.1 Desktop x64 STA, sinon « Windows PowerShell 5.1 x64 STA requis. Lancez Domenia.exe. » (Start:7-9) ;
   - refuse un dossier redirigé (jonction/lien) sur la racine ou un ancêtre : « Dossier du logiciel redirige. Utilisez une
     copie locale validee. » (Start:10-12) ;
   - refuse le marqueur `.update.pending` : « Mise a jour incomplete. Restaurez le code avec l installateur DEV avant
     lancement. » (Start:15) ;
   - lit `wad/package-manifest.json` (≤ 2 Mo, `Format` 1), garde les entrées `Runtime` = vrai (entre 10 et 100, sinon
     « Liste du runtime invalide. » — 82 aujourd'hui), refuse chemins absolus, `..`, `:` et `wad/data` ;
   - recalcule le SHA-256 de chaque fichier non conservé à CHAQUE démarrage : « Composant modifie ou versions melangees : <chemin> »,
     « Composant manquant : <chemin> », « Composant redirige : <chemin> » (Start:30-37) ;
   - vérifie une liste de composants obligatoires (Start:43-103 ; `Domenia-Migration.UI.ps1` y figure deux fois, sans effet) :
     « Manifeste incomplet : <chemin> » ;
   - `-CheckOnly` : analyse aussi chaque `.ps1` avec le vrai parseur, importe les modules dans une portée jetable et écrit
     « Runtime <Build> : <n> fichiers verifies ; <m> modules charges et fonctions disponibles. Aucun acces AD. » puis
     sort en 0 (Start:104-117) ;
   - `-Diagnostic` : déclaré mais non utilisé par Start.ps1 (son seul effet est la console visible du lanceur) ;
   - en cas d'erreur : message en rouge, ajout dans `%TEMP%\Domenia-startup-error.log`, boîte « Domenia | Demarrage »
     avec « Diagnostic : <chemin du journal> » (Start:119-130).
3. `wad/Domenia-Core.ps1` (≈ 25 870 lignes, 594 fonctions selon `audit_preload.py`) : point d'entrée Core:25749-25874 :
   dot-source `Domenia-Modules.ps1`, `Load-AppConfig`, `Initialize-DomeniaDemoMode`, `Initialize-DomeniaDataStore`,
   migration des préférences, pré-validation XAML (interface principale, login standard, login debug), fenêtre de
   connexion, `Initialize-Window`, `ShowDialog`. Erreur fatale : « DOMENIA na pas pu terminer son initialisation. »
   + chemins des journaux de démarrage et de connexion (Core:25836-25860). À la fermeture, les identités secondaires et
   mots de passe en mémoire sont effacés (Core:25862-25874).
   Paramètres du cœur (`-Server`, `-SearchBase`, `-DefaultLimit` 100, `-NoAutoConnect`, `-DomeniaSelfTest`, Core:3-10) :
   Start.ps1 appelle le cœur sans argument (Start:118), ils ne sont donc pas accessibles via `Domenia.exe`.

## 4. Chargeur fermé et modules

- `wad/Domenia-Modules.ps1` : « Definition-only bootstrap… The list is closed: extra scripts beside these files are
  never auto-loaded. » (Modules:2-4). Un script ajouté dans `modules/` n'est jamais chargé.
- Plan `Get-DomeniaRuntimeModulePlan` (Modules:6) : 58 modules déclarés (2 en phase `Bootstrap` : Common.Model,
  Engine.Model ; les autres en phase `Modules`), chacun avec la liste exacte de ses fonctions ; Experience.Model et
  Experience.UI sont validés sans être ré-importés (dot-sourcés par `Domenia-UX.UI.ps1`).
  Types C# 5 compilés avant les modules : `Domenia-Live.Types.cs`, `Domenia-Identity.Types.cs` (Modules:1169-1175).
  Chargés à la demande hors plan : `Domenia-Clipboard.Native.cs` (Guard.UI:210), `Domenia-Sessions.Native.cs`
  (Sessions.UI:3). Fichiers de données : `Domenia-Inline.xaml`, `Domenia-Support.xaml`, `Domenia-UX.help.json`,
  `SupportSuite.UI.json`.
- Séquence (Modules:1199-1285) : existence de tous les fichiers, analyse syntaxique de chacun, compilation des types,
  import Bootstrap, contrôle du plan (phases, dépendances, cycles, doublons : `Test-DomeniaStartupPlan`), import dans
  l'ordre, puis contrôle que chaque fonction déclarée existe ET provient du bon fichier (`Assert-DomeniaRuntimeImports`,
  Modules:1177-1197).
- Codes d'erreur : `DOMENIA_MODULE_MISSING` (« … Reinstallez le paquet complet. »), `DOMENIA_MODULE_PARSE`,
  `DOMENIA_MODULE_TYPES`, `DOMENIA_MODULE_IMPORT`, `DOMENIA_MODULE_PLAN`, `DOMENIA_MODULE_EXPORT`,
  `DOMENIA_MODULE_ORIGIN` (Modules:1188-1276).
- Organisation des modules (CLAUDE.md) : `*.Model.ps1` = règles pures (ni WPF, ni réseau, ni disque), `*.UI.ps1` =
  interface, `*.Worker.ps1` = code exécuté en arrière-plan. Interface : composants dans la page, jamais de nouvelle
  fenêtre pour un parcours métier.
- Exécuté le 08/10 (Mac, non qualifiant) : `audit_function_names.py` → « PASS (58 modules, 1650 fonctions, 0
  probleme(s)) » ; `audit_preload.py` → 168 contrôles réussis, 0 échec, 594 fonctions du cœur inchangées, 56 fichiers
  de modules, 1007 exports ; `validate_powershell_static.py` → PASS sur 139 fichiers PowerShell (parseur Windows non exécuté).

## 5. Scripts à la racine DEV (que fait chacun)

Tous lancent `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe` (ou `Sysnative` s'il existe, pour forcer le
64 bits depuis un processus 32 bits) avec `-NoLogo -NoProfile -STA`, puis `pause`, et rendent le code de retour.

| Script | Action exacte |
|---|---|
| `LANCER-Domenia.cmd` | `Domenia.exe --diagnostic` (console visible). |
| `Lancer-Domenia.vbs` | lance `Domenia.exe` sans console ; message « Domenia.exe introuvable » s'il manque. |
| `Domenia.ps1` | `Domenia.exe --diagnostic` (le paramètre `-Console` n'a pas d'effet). |
| `VERIFIER-PACK.cmd` | `wad\maintenance\Verifier-Paquet.ps1` avec `-ExecutionPolicy Bypass` : empreintes et syntaxe de tous les fichiers du manifeste, rapport JSON (`%TEMP%\Domenia-pack-<guid>.json` par défaut) ; fichiers conservés notés « LOCAL » ; option `-StrictConfig` pour imposer aussi leur empreinte ; message final « Un manifeste local verifie la coherence, pas la signature ou la provenance du code. ». Aucun accès AD, aucun démarrage. |
| `TESTER-DOMENIA.cmd` | `wad\tests\Test-DomeniaModules.ps1`, puis si réussite `Test-DomeniaCandidate.ps1 -Wpf`. |
| `TESTER-MODULES.cmd` | `Test-DomeniaModules.ps1`. |
| `TESTER-PRECHARGEMENT.cmd` | `Test-DomeniaPreload.ps1` (la suite exigée par l'installateur). |
| `TESTER-DEMARRAGE-LOGIN.cmd` | `Test-DomeniaStartupLogin.ps1`. |
| `TESTER-INTERFACE-STABLE.cmd` | `Test-DomeniaStableUi.ps1`. |
| `TESTER-ACTIVITE.cmd` | `Test-DomeniaActivityLayout.ps1`. |
| `TESTER-INTEGRATION.cmd` | `Test-DomeniaEmbeddedUi.ps1`. |
| `TESTER-RELATIONS.cmd` | `Test-DomeniaRelationsAlignment.ps1`. |
| `TESTER-SELECTION.cmd` | `Test-DomeniaSelection.ps1`. |
| `TESTER-ACL.cmd` | `Test-DomeniaAcl.ps1`. |
| `TESTER-RECHERCHE-PRESENCE.cmd` | `Test-DomeniaSearchPresence.ps1` (avec `-ExecutionPolicy Bypass`). |
| `APERCU-CONNEXION.cmd` | `wad\maintenance\Preview-DomeniaLogin.ps1` : affiche la vraie fenêtre de connexion sans authentification (fonctions extraites par AST, identité fictive `EXAMPLE\compte.demo`). |
| `APERCU-INTERFACE.cmd` | `wad\maintenance\Preview-DomeniaUi.ps1` : aperçu hors ligne de la vraie fenêtre principale, sans démarrage ni AD (options `-Theme Light/Dark`, `-Verify`, `-CaptureDirectory`, `-CaptureRoutes`). |
| `APERCU-PROGRESSIF.cmd` | `Preview-DomeniaUi.ps1 -Progressive` (charge `Preview-DomeniaProgress.ps1` : 40 postes fictifs `PC-DEMO-01…40`, sans cache disque). |
| `APERCU-ACTIVITE.cmd` / `APERCU-INTEGRE.cmd` / `APERCU-RELATIONS.cmd` | mêmes suites que les TESTER correspondants avec `-Preview` (fenêtre affichée). |

- `wad\Support\DEBLOQUER_TOUT.cmd` (PROD et DEV) : vérifie l'empreinte de `Debloquer-Paquet.ps1` dans le manifeste,
  puis celui-ci vérifie l'empreinte de chaque fichier runtime et retire la marque de téléchargement (`Unblock-File`)
  seulement si tout est conforme ; messages « Runtime debloque. … » et « Aucune politique PowerShell, GPO,
  AppLocker/WDAC ou protection antivirus modifiee. Le manifeste ne vaut pas signature. ». Refus : « Empreinte invalide :
  <chemin>. Aucun deblocage en masse effectue. ».
- `wad\maintenance\Sauvegarder-Cache.ps1 -DatabasePath <fichier .db>` : sauvegarde SQLite cohérente hors application
  (« preferably with DOMENIA closed »), 7 copies maximum dans `Backups`, affiche le chemin et le SHA-256 ; refuse
  PowerShell Core et le 32 bits.
- Règle du dépôt (CLAUDE.md) : tests et aperçus uniquement sur un poste ou une VM de test, jamais en production ni sur
  l'hôte du labo. [NV] : ces `.cmd` datent du 02/10 (RC1.x) ; leur résultat sur l'arbre actuel n'a pas été rejoué.
  L'installateur précise que les suites historiques « superseded UI expectations are not release criteria » (Installer:235-236).

## 6. Installation et mise à jour

Première installation (LIRE-MOI.md) : extraire le ZIP ENTIER dans un dossier local ; si Windows bloque les fichiers,
`wad/Support/DEBLOQUER_TOUT.cmd` ; « Ne pas déplacer le cœur sans les modules et leur manifeste. » ; lancer `Domenia.exe`.
L'installateur ne sert pas à une première installation : il exige une destination contenant déjà
`wad\Domenia-Core.ps1` (ou l'ancien `wad\ADCC-Core.ps1`), sinon « Destination incorrecte : choisir le dossier DOMENIA
contenant wad\Domenia-Core.ps1. » (Installer:181).

Mise à jour : fermer Domenia, extraire le ZIP DEV dans un dossier distinct, puis dans Windows PowerShell 5.1 :

~~~
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Domenia'
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Domenia' -WhatIf
.\INSTALLER-MISE-A-JOUR.ps1 -RestoreBackup 'C:\Domenia\wad\maintenance\backups\DOSSIER'
~~~

Déroulé lu dans le code :
1. Refus si source = destination (« Extrais le nouveau ZIP dans un dossier distinct de ton DOMENIA actuel. ») ou
   dossiers imbriqués (Installer:178-180).
2. `Assert-AppClosed` : refuse si un processus `Domenia`/`ADCC` du dossier cible tourne ou si un `powershell.exe`,
   `powershell_ise.exe` ou `pwsh.exe` exécute son cœur ou son Start : « Fermez Domenia dans le dossier a mettre a jour
   ou restaurer. », « DOMENIA encore lance : PID <n>. Ferme-le sans interrompre une ecriture AD. » (Installer:34-49).
   Une copie ouverte dans un AUTRE dossier n'empêche pas la mise à jour.
3. Source = `tools\prod-manifest.json` du DEV : seuls les 82 fichiers runtime sont installés (le DEV n'est pas copié).
   Contrôle de chaque empreinte source, analyse syntaxique des `.ps1` ; refus de tout chemin `wad/data` ou
   `wad/maintenance/backups` (« Le programme de mise a jour ne doit pas toucher aux donnees ou sauvegardes. »,
   Installer:18) ; refus des jonctions/liens.
4. Version active identique → « Cette version est deja active. … » (Installer:191). Les fichiers déjà identiques ne
   sont pas recopiés ; les préférences existantes sont « Conserve : … » ; un ancien `ADCC.*` de configuration est
   repris « Migration sans suppression : … » si le `Domenia.*` n'existe pas (Installer:206-215).
5. Affiche « Fichiers a installer : N » et la liste ; s'arrête là avec `-WhatIf` (Installer:229-231).
6. Porte DEV : exécute `wad\tests\Test-DomeniaPreload.ps1 -ReportPath … -Quiet` sous PowerShell 5.1 -STA ; exige un
   rapport complet, natif Windows PowerShell, WPF exécuté, 0 échec, 0 ignoré et au moins 40 réussites, sinon
   « Verification native echouee avant copie » / « Rapport de tests incomplet ou en echec » (Installer:232-245).
7. Prépare une copie complète dans `<destination>\wad\maintenance\backups\<aaaaMMjj-HHmmss>-<8 hex>\prepared`,
   vérifie chaque empreinte, applique la règle `Get-DomeniaInstallPlan` (Release.Model), puis lance
   `Domenia-Start.ps1 -CheckOnly` sur la copie préparée : « La version preparee ne peut pas demarrer. Le code actif est
   inchange. » (Installer:248-274).
8. Prend le verrou exclusif `.lifecycle.lock`, refuse si `.update.pending` existe (« Installation precedente incomplete.
   Utilisez -RestoreBackup … »), sauvegarde l'ancien code dans `…\files`, écrit `transaction.json`, copie l'installateur
   en `RESTAURER-CODE.ps1`, écrit le marqueur `wad\Support\.update.pending` (le lancement est alors bloqué), remplace les
   fichiers un à un (copie atomique + vérification), vérifie l'ensemble, retire le marqueur (seul point d'activation).
   Fin : « Mise a jour installee. Ancien code : <sauvegarde> » et « Runtime installe. Lancez Domenia.exe. Les anciens
   fichiers DEV ne sont pas supprimes automatiquement. » (Installer:276-314).
9. Échec après le début des remplacements : restauration automatique (« Installation en echec : ancien code restaure. »)
   ou « Restauration automatique incomplete : … Sauvegarde : … », puis « Mise a jour interrompue : … » (Installer:316-322).
- Restauration `-RestoreBackup` : relit `transaction.json`, refuse si une autre transaction est en attente, vérifie
  d'abord sans écrire, refuse d'écraser un fichier modifié indépendamment (« Fichier modifie depuis la mise a jour,
  restauration refusee : … »), puis « Code precedent restaure. wad\data et les preferences conservees n ont pas ete
  modifies. » (Installer:149-174). Les données ne sont jamais touchées.
- LIRE-MOI déclare l'installateur vérifié sur six scénarios (installation, restauration, interruption, verrouillage,
  corruption, modifications concurrentes) via `wad\tests\Test-DomeniaInstaller.ps1` [NV : non rejoué].
- [NV] Stratégie d'exécution nécessaire pour lancer `INSTALLER-MISE-A-JOUR.ps1` : non documentée dans la livraison.

## 7. Prérequis

- Windows PowerShell 5.1 « Desktop », processus 64 bits, thread STA (Start:7) ; WPF ; `winsqlite3.dll` de Windows
  (base SQLite, `Initialize-DomeniaWinSqliteNative` Core:20216). [NV] Versions de Windows supportées : non écrites
  dans le code ; les campagnes de test ont tourné sur une VM Windows 11.
- Module Active Directory : RSAT du système ou les deux DLL Microsoft livrées dans `wad`, repli LDAP/ADSI
  (en-tête Core:12-20 ; réglages `Modules.*`).
- Dossier d'installation local, non redirigé par un lien ou une jonction (Start:10-12) ; extraire le ZIP complet.
- Base active obligatoirement locale : refus d'un chemin UNC ou d'un lecteur réseau (« Une base active SQLite doit etre
  locale. Choisissez UserLocal ; les sources existantes seront conservees. », Core:19945).
- Droits (d'après les libellés et la règle d'exécution, Core:5164-5244) :
  - annuaire : un compte AD capable de lire l'annuaire ; les écritures exigent en plus les délégations AD
    correspondantes (Domenia estime les droits à l'ouverture d'un objet, `Security.EvaluateRightsOnObjectOpen`) ;
  - postes : « Identifiant ayant les droits administrateur sur les postes. » (Core:5203) pour WMI/CIM, C$, consoles ;
  - secrets : « Identifiant autorise a lire LAPS et BitLocker dans Active Directory. » (Core:5228).
  - Aucun droit d'administrateur local n'est requis pour lancer Domenia en mode UserLocal [NV : déduit, non testé].
- Transports utilisés (`Get-DomeniaTransportPolicy`, Access.Model:418-430) : LDAP 389/TCP (signature et scellement
  Kerberos/NTLM) ; CIM/DCOM 135/TCP + RPC dynamiques ; CIM/WSMan 5985/5986 seulement si déjà en service ; WTS (RPC/445) ;
  partage ADMIN$ 445 (dépôt temporaire, seulement avec consentement) ; Planificateur (COM) ; PsExec 445 (intervention
  ponctuelle, consentement). « Domenia ne modifie aucun reglage Windows : ni certificat, ni WinRM, ni pare-feu, ni
  antivirus, ni strategie. » (Core:5250).

## 8. Connexion, comptes, lecture seule, démonstration

Fenêtre de connexion standard (`Get-DomeniaStandardLoginXaml`, Core:25185-25360) — libellés exacts :
titre de fenêtre « Domenia · Connexion » ; « Connexion à Domenia » ; « Votre compte Active Directory » ;
champ « Compte Windows » (aide : « Saisissez votre compte AD habituel : DOMAINE\identifiant, identifiant@domaine ou le
format déjà utilisé. Seul l’identifiant peut être mémorisé. ») ; « Mot de passe » ; « Afficher » ;
« Verr. Maj activé : le mot de passe distingue les majuscules. » ; case « Mémoriser uniquement l’identifiant » ;
boutons « Se connecter », « Annuler », « Utiliser mon compte Windows », « Ouvrir le journal », « Copier le diagnostic » ;
mention « Le mot de passe n’est jamais enregistré. » ; attente « Vérification du compte… » et « Annuler la connexion ».

- Mode de la fenêtre (`Get-DomeniaLoginWindowMode`, Core:25136-25183), ordre de priorité :
  1. marqueur `wad\Domenia.login.debug` présent → Debug ;
  2. `wad\Domenia.login-mode.cfg` : une ligne `Standard` ou `Debug` (aussi `LoginMode=…` / `LoginWindowMode=…`,
     valeurs debug/diagnostic/diag/verbose/detail/detailed/true/1/on/oui → Debug ; standard/normal/production/prod/
     false/0/off/non → Standard ; autre → Standard avec avertissement dans la trace) ;
  3. `Auth.LoginWindowMode` de `Domenia.config.json` (défaut "Standard").
  Fenêtre Debug : titre « Domenia 1.0  Connexion », bandeau « MODE DEBUG  diagnostic de connexion en direct »,
  zone « TRACE TECHNIQUE ».
- « Utiliser mon compte Windows » : actif seulement si `Auth.AllowWindowsSession` (défaut vrai) et si l'identité
  Windows du processus est connue (Core:24636-24639) ; aide « … n’ajoute aucun droit. ».
- Mémorisation : identifiant seulement, dans le registre `HKCU:\Software\DOMENIA` (valeurs `RememberLogin`,
  `LastLogin`, Core:891, 1026-1033, 1051-1058). Jamais le mot de passe.
- Délais de connexion : `Auth.LoginTimeoutSeconds` 30, `Auth.PerServerTimeoutSeconds` 6, `Auth.MaxServerCandidates` 4 ;
  découverte `Conf.AutoDiscover` vrai ; serveur/base forçables par `Conf.Server`, `Conf.SearchBase`.

Comptes (onglet « Comptes », `TabAccounts`, Core:5159-5250 ; navigation « Comptes ») : « Les mots de passe restent
uniquement en memoire. » Trois scopes indépendants (« Regle d execution », Core:5243) :
« Annuaire : compte AD courant. Postes : compte distant s il existe, sinon compte AD. Secrets : compte secrets s il
existe, sinon compte AD. Les trois scopes sont independants. »
- « ANNUAIRE AD » : « Changer de compte », « Tester la connexion », « Se connecter ».
- « POSTES / WMI / DISTANT » (compte d'administration distante) : « Identifiant », « Mot de passe », « Tester »,
  « Activer », « Effacer » ; état « Repli sur le compte AD courant. », « Aucun mot de passe n est persiste. ».
- « SECRETS AD » (LAPS et BitLocker) : mêmes boutons.
- Compte des opérations poste (Core:5560-5601, zone « Diagnostic du poste » [NV : visibilité à l'écran]) :
  « Compte poste », « Mot de passe », « Utiliser ce compte », « Compte de connexion » ; libellé d'état
  `LblMachineCredential` : « Operations poste : session Windows <identité>. », « Operations poste : compte saisi
  <compte>, en memoire seulement. » ou « Operations poste : compte de connexion Domenia <compte> (CIM, C$, consoles). »
  (Core:17003-17008). Ordre réel pour un worker poste (`Get-WorkerContext`, Core:21766) : compte poste saisi →
  compte POSTES / WMI / DISTANT → compte de connexion → session Windows. « Ouvrir C$ » utilise ce compte (worker
  `ComputerAdminShare`).
- Changement de périmètre AD : les comptes secondaires sont retirés de la mémoire (« Perimetre AD change : comptes
  secondaires retires pour eviter leur envoi dans un autre domaine. », Core:19171-19174).
- Compte temporaire accepté après un refus : limité à sa ressource et à son poste, oublié après
  `Security.AlternateCredentialIdleMinutes` (30) sans usage (Core:5244, Access.UI:37).
- [NV, déduit du code] Les identifiants des comptes POSTES et SECRETS sont écrits dans les préférences
  (`RemoteCredentialUser`, `SecretsCredentialUser`) mais ces clés ne figurent pas dans la liste blanche de
  `Get-DomeniaDefaultSettings` : `Load-DomeniaSettings` ne les relit donc pas au lancement suivant.

Lecture seule et écritures AD :
- Case « Lecture seule » dans le bandeau (`ChkReadOnlyMode`, Core:4339) ; aide : « Coché : les écritures AD et les
  actions distantes classées comme modificatrices sont bloquées. Décocher ne donne pas de droits supplémentaires ; les
  confirmations restent nécessaires. »
- Toujours cochée au démarrage (« Toujours demarrer en lecture seule. », Core:24374-24376) et à chaque changement de
  compte (Core:19164-19166) ; jamais mémorisée dans les préférences (commentaire Core:2878-2882).
- Décocher ouvre la confirmation « Attention : mode ecriture » (« Tu vas activer le mode ecriture Active Directory. … »,
  Core:19610-19632) ; refus → « Mode lecture seule conserve. ». Recocher : « Mode lecture seule actif : ecritures AD,
  GPUpdate et redemarrage distant bloques. ».
- Mode écriture visible : bandeau rouge « MODE ECRITURE AD ACTIF » (Core:4327-4330) et cadre rouge `WriteModeHalo`
  (Core:6341).
- Garde-fous de configuration (`Security.*`, Core:21791-21798) : objets protégés bloqués, écriture d'objets protégés
  interdite, suppression de conteneur interdite, écriture d'attribut brut interdite, attributs sensibles bloqués, objet
  frais exigé (`MaxObjectAgeMinutes` 15), canal d'écriture unique, confirmation saisie pour les actions à haut risque
  (`RequireTypedHighRiskConfirmation`, Core:23603).
- Reçus d'opérations : `%LOCALAPPDATA%\Domenia\Receipts` (Core:21759). Une écriture n'est jamais rejouée
  automatiquement : « Une operation precedente reste a verifier. Consultez les recus, pas une relance automatique. »
  (Access.UI:452).
- Profil d'interface « Essentiel » / « Expert » (`CmbUiProfile`, Core:4340, valeurs `Tech`/`Admin`) : « Ce choix ne
  donne aucun droit supplémentaire. »

Démonstration (pour le seul guide administrateur ; le guide technicien n'en parle pas) :
- Activée seulement si `Auth.DemoProvider` vaut le booléen JSON `true` (`Test-DomeniaDemoProviderEnabled`,
  Demo.Model:4-8) ; décidée une fois par session (Demo.UI:4-17). Une livraison qui l'active est refusée par la
  construction.
- Bandeau « DÉMONSTRATION — aucune connexion AD » (Demo.Model:18), identité `Demo.Identity` (défaut
  `DEMO\demo.operateur`), domaine fictif `demo.invalid`, bouton « Entrer en démonstration », pas de mot de passe ni de
  session Windows, lecture seule verrouillée, mesure/purge du stockage et relevés désactivés (Demo.UI:26-70).

## 9. Workers épinglés par SHA-256

- Registre fermé `Get-DomeniaWorkerOperationHashes` (Core:20880) : 68 opérations, chacune avec l'empreinte SHA-256 de
  son code exact (« Registre ferme : seules ces operations internes, avec leur corps exact, peuvent entrer dans un
  runspace. »). Métadonnées : `dev/tools/operation-contracts.json` (68 entrées : opération, fichier, fonction, index
  de here-string, empreinte ; 45 dans le cœur, les autres dans 14 modules).
- Liste : BatchNetworkDiag, CmdletHelp, CmdletInventory, ComputerAdminShare, ComputerDiagnostics, ComputerGpUpdate,
  ComputerInventory, ComputerLastUser, ComputerPing, ComputerRestart, DemoDirectory, DocumentStore, DomainOverview,
  EmbeddedDirectoryLookup, EmbeddedPathBrowse, EngineSelfTest, GlobalSearch, IndexBuild, IsolatedRead, LegacyMigration,
  LiveCache, LiveConsole, LiveDirectoryCheck, LiveSelectedPing, LocalIndexRead, LocalStore, LogonHarvest, OpenAdObject,
  OpenLinkedObject, ParkSharedSync, ParkSweep, PermissionAnalysis, PresenceScan, PruneLinks, ReadBitLocker,
  ReadBitLockerKey, ReadBitLockerList, ReadLaps, ReceiptStore, RemoteCredentialCheck, RimotteRun, ScopeReconcile,
  SelectedPresence, SelfCheck, SessionsList, SoftwareInventory, StartupWarmCache, StorageBackup, StoragePurge,
  StorageUsage, TreeChildren, UserComputerProbe, WmiClasses, WmiNamespaces, WmiQuery, WriteAccountDisabled,
  WriteAccountOptions, WriteAttributes, WriteCreateOu, WriteDeleteObject, WriteExpiration, WriteExpirePassword,
  WriteGroupMember, WriteMoveObject, WriteObjectGroup, WriteRenameComputer, WriteResetPassword, WriteUnlock.
- Contrôles en trois temps :
  1. au démarrage, chaque fichier runtime est comparé au manifeste (section 3) ;
  2. à l'initialisation du moteur (`Initialize-AsyncEngine`, Core:21110-21121), `Assert-DomeniaWorkerRegistry`
     (Core:20954-20978) recalcule l'empreinte de la table entière (`$expectedFingerprint` =
     `4D8A5DCF…501E6F17`) : opération ajoutée, retirée ou modifiée → « Registre worker non conforme (<n> operation(s),
     empreinte=<…>). Composant manquant, ajoute ou modifie ; reinstallez un paquet coherent. » ;
  3. avant chaque runspace (`New-DomeniaWorkerRunspace` → `Assert-DomeniaWorkerOperationCode`, Core:20980-20993) :
     « Operation worker non autorisee : <op> » ou « Integrite worker refusee pour <op> (attendu=…, obtenu=…). ».
     Empreinte = SHA-256 du code canonisé en UTF-8 sans BOM (`Get-DomeniaWorkerCodeHash`, Core:20869).
- `Start-UiTask` (Core:21198) : seul point d'entrée des tâches de fond. Paramètres : `Name`, `OperationId` (motif
  `^[A-Za-z][A-Za-z0-9]{2,63}$`), `Code`, `Payload`, gestionnaires de succès/erreur, `DisableControls`, `ReplaceKey`,
  `TimeoutSeconds`, `HardTimeoutSeconds`, `StatusText`, `IsWrite`, `NonCancellable`, `TaskClass`
  (Explicit/Selection/Background). Refus si `Async.Enabled` faux (« Moteur multithread desactive dans la
  configuration. ») ou moteur en fermeture. Les écritures passent par `Start-DomeniaWriteTask` (Core:22926).
  Limites : `Async.MaxThreads` 6, `MaxOutstandingWorkers` 12, file `MaxQueued` 32 dont `ReservedForeground` 2,
  attente max 120 s.
- Modification d'un worker (développement seulement, CLAUDE.md) : relire, puis
  `python tools/update_worker_contracts.py --apply` (met à jour le registre du cœur, l'empreinte globale et
  `operation-contracts.json`), puis `python tools/build_packages.py` pour régénérer les manifestes (sinon
  Domenia-Start.ps1 refuse le démarrage), et lister les opérations modifiées dans les notes de version. L'outil précise :
  « The running application NEVER calls this tool. It is not a bypass for a bad downloaded pack. ».
- Exécuté le 08/10 (Mac) : `update_worker_contracts.py` sans `--apply` → `ReviewedChangesRequired: []`, `Count: 68`.

## 10. Réglages

Fichiers et emplacements :
- `wad\Domenia.config.json` : configuration (lue au démarrage par `Load-AppConfig`, Core:1001-1048, depuis
  `$script:RootDir` = dossier `wad`, Core:888-890). Sections connues fusionnées clé par clé avec `New-DefaultConfig`
  (Core:19704-19930) ; une section inconnue est conservée telle quelle (Core:1012-1018). JSON illisible → valeurs par
  défaut sans message (catch vide, Core:1024). Conservé par l'installateur.
- `Get-CfgValue <Section> <Clé> <défaut>` (Core:1060-1070) : rend la valeur de la configuration fusionnée ; si elle est
  absente, nulle ou vide, rend le défaut de l'appel. Donc le défaut effectif d'une clé présente dans `New-DefaultConfig`
  est celui de `New-DefaultConfig`, pas celui de l'appel.
- Particularités : `Browser.DefaultLimit` est toujours remplacé par le paramètre `-DefaultLimit` du cœur (100) car
  celui-ci est toujours > 0 (Core:1037) : la valeur du JSON n'a pas d'effet [déduit du code] ;
  `Browser.FastBoot`/`LoadFirstLevelOnStartup` sont forcés à vrai/faux si `ForceFirstLevelAtStartup` est faux
  (Core:1038-1046) ; `Features.*` se lisent par `Get-DomeniaFeatureFlag` (Common.Model:177-190 : booléen, ou texte
  true/1/oui/yes/on, false/0/non/no/off).
- Préférences utilisateur : `<DataDir>\Preferences\Domenia.settings.json` (+ `.bak`, écriture atomique,
  `Write-DomeniaPreference` Core:2850-2872). Lecture de repli, sans réécriture : `<DataDir>\Domenia.settings.json`,
  `wad\Domenia.settings.json`, anciens noms `ADCC.settings.json` (Core:2811-2847). Écriture différée de 1,5 s
  (Core:2966-2998).
- Liste blanche `Get-DomeniaDefaultSettings` (Core:2884-2927) — seules ces clés survivent au rechargement :
  `SavedSearches`, `GridLayoutsJson`, `OuBookmarksJson`, `UxNavCollapsed`, `UxHelpVisible`, `UxHelpCompactOpen`,
  `UxLogCollapsed`, `UxLogExpandedHeight` (180), `UxLogWrap`, `UxLogFontSize` (11), `UxDensity` ("Confort"),
  `Theme` ("Light"), `UiProfile` ("Tech"), `Workspace` ("TabDashboard"), `PresenceFilter` ("Tous"), `SearchType`
  ("Tous"), `SearchLimit` ("100"), `IndexAutoBuild` ("Ask"), `ParkSweepEnabled` (faux), `ParkHarvestEnabled` (vrai),
  `InventoryScope` ("Toutes"), `SoftwareScope` ("Toutes"), `SoftwarePerUser` (vrai), `SoftwareStore` (faux),
  `SoftwareUpdates` (faux), `WmiLimit` ("25"), `WindowWidth`, `WindowHeight`, `WindowLeft`, `WindowTop`,
  `WindowMaximized`, `TreeWidth`, `LogHeight`, `Dashboard.Computer.Layout`, `Dashboard.Fleet.Layout`,
  `Dashboard.Software.Layout`, `Widgets.Computer`, `Widgets.Fleet` (39 clés). La lecture seule en est volontairement exclue.
- Thème : `Theme` du JSON prime ; `Domenia.theme.cfg` (Preferences, puis DataDir, puis `wad`) n'est lu qu'en l'absence
  de choix JSON valide ; valeurs Light/Dark, sinon Light (`Get-DomeniaStoredTheme`, Core:3167-3188). Le bouton de thème
  de la connexion enregistre immédiatement (`Save-DomeniaTheme`, Core:3364-3373).
- `Domenia.ui-profile.cfg` : ancien fichier, lu seulement si le JSON n'a pas d'`UiProfile` valide (Core:2951-2955).
- `Domenia.login-mode.cfg` et marqueur `Domenia.login.debug` : voir section 8.

Clés de `Domenia.config.json` réellement lues par le code (défaut effectif ; premier site de lecture) :

| Clé | Défaut effectif | Lue en |
|---|---|---|
| Conf.AutoDiscover | true | Core:25065 |
| Conf.DOMAINE / Conf.NETBIOS | "" | Core:1083-1084 |
| Conf.SearchBase / Conf.Server | "" | Core:25068, 25071 |
| Conf.ADM | "" | Core:25427 |
| Auth.RememberLogin | true | Core:25435 |
| Auth.LastLogin | "" | Core:25426 |
| Auth.LoginWindowMode | "Standard" | Core:25174 |
| Auth.AllowWindowsSession | true | Core:24636 |
| Auth.LoginTimeoutSeconds | 30 | Core:25073 |
| Auth.PerServerTimeoutSeconds | 6 | Core:24543 |
| Auth.MaxServerCandidates | 4 | Core:24544 |
| Auth.DemoProvider | false | Demo.UI:7 |
| Features.Scheduler | true | Engine.UI:15 |
| Features.IdlePolicy | true | Engine.UI:411 |
| Features.BitLockerKeySelection | true | Secrets.UI:11 |
| Features.SecretSingleCopy | true | Secrets.UI:11 |
| Features.SearchSyntax | true | Core:9838 |
| Features.SearchRanking | true | Live.UI:178 |
| Features.InlineConfirm | true | Relations.UI:561 |
| Features.IsolatedReads | false | Engine.UI:181 |
| Demo.Identity | "DEMO\demo.operateur" | Demo.UI:21 |
| Demo.LatencyMs | 0 | Demo.UI:12 |
| Streaming.VerifyUserOnSelection | true | Live.UI:39 |
| Streaming.RevalidateListedObjects | true | Continuity.UI:233 |
| Streaming.RevalidateIntervalSeconds | 60 | Continuity.UI:247 |
| Streaming.ReconcileSeconds | 180 | Reconcile.UI:148 |
| Streaming.MaxUserProbes | 2 | Live.UI:700 |
| Browser.FastBoot / LoadFirstLevelOnStartup / ForceFirstLevelAtStartup | false / true / true | Core:6843 |
| Browser.DefaultLimit | 100 (voir particularité) | Core:24372 |
| Browser.GlobalSearchLimit | 100 | Core:9863 |
| Browser.GlobalSearchMinChars | 2 | Core:9826 |
| Browser.MaxPageSize | 300 | Core:1153 |
| Browser.LiveGlobalSearch / AllowLiveGlobalSearch | false / false | Core:16667-16668 |
| Browser.LiveSearchDelayMs | 900 | Core:16681 |
| Browser.SelectionDebounceMs | 180 | Core:10329 |
| Browser.SearchServerTimeLimitSeconds | 8 (défaut d'appel) | Core:10174 |
| Browser.SearchClientTimeoutSeconds | 12 (défaut d'appel) | Core:10175 |
| UI.TreeRenderBatchSize / TreeRenderIntervalMs | 16 / 20 | Core:6783, 6693 |
| Async.Enabled | true | Core:21239 |
| Async.MaxThreads | 6 | Core:20701 |
| Async.MaxOutstandingWorkers | 12 | Core:21294 |
| Async.MaxQueued / ReservedForeground / MaxQueueWaitSeconds | 32 / 2 / 120 | Engine.UI:33-35 |
| Async.PollIntervalMs / UiRefreshIntervalMs | 250 / 500 | Core:21126, 9211 |
| Async.MaxCompletionsPerTick / CallbackWarningMs / CancelGraceSeconds | 2 / 120 / 5 | Core:21470-21491 |
| Async.DefaultTimeoutSeconds | 60 | Core:21311 |
| Async.SearchTimeoutSeconds / ObjectTimeoutSeconds / TreeTimeoutSeconds | 45 / 35 / 30 | Core:10206, 22115, 9576 |
| Async.RemoteTimeoutSeconds | 45 | Core:16086 |
| Async.ComputerTimeoutSeconds | 90 (défaut d'appel) | Core:12785 |
| Async.SelfCheckTimeoutSeconds | 120 | Core:10623 |
| Async.WriteSoftTimeoutSeconds / WriteHardTimeoutSeconds | 90 / 300 | Core:23004, 21312 |
| Cache.Enabled / TtlSeconds / ObjectTtlSeconds / MaxEntries | true / 90 / 45 / 400 | Core:9260-9279, 21997 |
| Cache.RequireReadyBeforeMainWindow | false | Core:24235 |
| Cache.WarmRootTree / WarmRootObjects / WarmRootObjectLimit | true / true / 100 | Core:24245-24247 |
| Cache.WarmupTimeoutSeconds / WarmupRetries / WarmupRetryDelayMs | 45 / 2 / 1200 | Core:24242-24244 |
| Security.EvaluateRightsOnObjectOpen | true | Core:22229 |
| Security.BlockOnAclEstimate / DisableIndeterminateControls | false / false | Core:22440-22441 |
| Security.AutoClearSecretClipboardSeconds | 30 | Core:11029 |
| Security.AlternateCredentialIdleMinutes | 30 | Access.UI:37 |
| Security.SecretMemorySeconds | 300 | Core:323 |
| Security.RequireFreshObject / MaxObjectAgeMinutes | true / 15 | Core:21797, 21937 |
| Security.BlockProtectedObjects / AllowProtectedObjectWrites | true / false | Core:21791-21792 |
| Security.AllowContainerDelete / AllowRawAttributeWrite / BlockSensitiveRawAttributes | false / false / true | Core:21793-21795 |
| Security.RequireTypedHighRiskConfirmation | true | Core:23603 |
| Security.SingleWriteChannel | true | Core:21798 |
| SelfCheck.FullBenchmarkIterations | 3 | Core:10508 |
| Startup.ShowMonitor | true | Core:20056 |
| Remote.PortTimeoutMs / CommandTimeoutSeconds | 1200 / 10 | Core:21770-21771 |
| Remote.UseCim / UseWinRM | true / true | Core:21772-21773 |
| Remote.UsePsExecFallback / UseTaskFallback / TaskFallbackTimeoutSeconds | true / true / 75 | Core:21774-21779 |
| Remote.UseRemoteRegistry / UseProfilesShare / UseSecurityLog / AllowUnboundedFallbacks | true / true / false / false | Core:16631-16634 |
| WAPT.Enabled / WaptGetPath / ServerUrl | false / "" / "" | Core:21788-21790 |
| UserMachineLink.MinimumConfidence | 60 | Core:16254 |
| UserMachineLink.ClassicProbeTimeoutSeconds / TaskFallbackProbeTimeoutSeconds / ProbeMethodTimeoutMs | 8 / 30 / 3000 | Core:16403-16405 |
| UserMachineLink.ObjectRefreshHours | 4 (défaut d'appel) | Core:16383 |
| Modules.AutoLoad / PreferActiveDirectoryModule / UseCredential | true / true / true | Core:1314, 16653, 1339 |
| Index.StartupDeltaMaxAgeMinutes | 5 | Core:14521 |
| Index.MaxObjects / BudgetMs / ComputerFirst | 60000 / 240000 / true | Core:14492-14498 |
| LocalStore.Mode | "Compatible" (défaut d'appel ; Compatible, UserLocal ou Portable) | Core:19935 |
| LocalStore.DatabaseFile | "Domenia.db" (nom seul, motif `^[A-Za-z0-9][A-Za-z0-9._-]*\.db$`) | Core:20174 |
| LocalStore.DatabaseBackupCount | 7 (défaut d'appel, borné 2 à 30) | Core:20423 |
| LocalStore.BackupTimeoutSeconds | 30 (borné 5 à 120) | Core:20406 |
| LocalStore.DatabaseBusyTimeoutMs / MutexTimeoutMilliseconds | 2500 / 350 | Core:20291, 20155 |
| Inventory.PreferWinrm | false (défaut d'appel) | Core:12113 |
| ParkSweep.SharedPath / HarvestMaxEvents / HarvestDays / RefreshDays / RetryDays | "" / 5000 / 7 / 14 / 2 (défauts d'appel) | Core:14725-14981 |

Clés déclarées dans `New-DefaultConfig` mais lues par AUCUN code (grep -w, 08/10) — à ne pas présenter comme réglables :
Conf.UsersBase, Conf.ComputersBase ; Auth.DetailedLoginTrace ; Features.ScopedLocks, ColumnProfiles, WakeOnLan,
LocalAssistant, ReadTrace (WakeOnLan et LocalAssistant ont des règles pures, mais aucun appel ne lit le drapeau) ;
Browser.IncludeContainers, DefaultObjectFilter, DefaultScope, AutoLoadBranchOnSelect, SelectRootWithoutLoading ;
Dashboard.Enabled, RefreshAfterEachAction ; UI.WindowWidth, WindowHeight, TreeWidth, ObjectListHeight, AppleLike,
ReadOnlyDefault, ShowStartupMonitor ; Async.MinThreads ; Cache.StartupGlobalCache ; Security.DisableDeniedControls,
MaskSecretsByDefault, RequireTypedDeleteConfirmation, NeverPersistLaps, NeverPersistBitLockerRecovery,
NeverLogSecretValues, SecretClipboardSeconds ; SelfCheck.AutoQuickAfterLogin ; Startup.AutoLongOperations,
DetailedTrace, KeepMonitorUntilReady, WarnStageSeconds ; Remote.AllowRemoteArtifacts (le consentement se donne dans
l'interface, pas par la configuration), TaskFallbackKeepFailedArtifacts, TaskFallbackPreferSystem ; WAPT.LinkCsv ;
UserMachineLink.AutoProbeOnComputerSelect, AllowAutoProbeOnSelect, ProbeTimeoutSeconds, ProbeOncePerSession,
DoNotOverwriteExisting, VerifyUserInAd, SecurityLogDays, SecurityLogMaxEvents, ScanCandidates, ScanProbes,
ProbeBudgetMs, ScanBudgetMs ; Modules.ActiveDirectoryPath, FallbackToLdap, ShowModuleStatus ;
Index.StartupDeltaEnabled, FullRebuildDays ; LocalStore.AtomicWrites, KeepBackup, KeepLegacyFiles,
TelemetryRetentionDays. Clé livrée `Streaming.AutoDetectLoggedUser` : non lue non plus.
Préférence `IndexAutoBuild` : seulement validée (Ask/Always/Never, Experience.Model:27), aucun comportement trouvé.

## 11. Stockage local et Base autonome

Emplacement (`Initialize-DomeniaDataStore` Core:19932-20005 ; règle `Get-DomeniaStorageLayout` Release.Model:1371) :
- `LocalStore.Mode` : `UserLocal` → `%LOCALAPPDATA%\Domenia\Data` ; `Portable` → `<installation>\wad\data` ;
  `Compatible` (défaut) → Portable si `wad\data` contient déjà des données, sinon UserLocal (la déduction est annoncée
  dans la trace : « Mode Compatible : … »). Valeur invalide → « LocalStore.Mode doit valoir Compatible, UserLocal ou
  Portable. ».
- UserLocal : DACL protégée posée sur le dossier (utilisateur courant, SYSTEM, Administrateurs ;
  SDDL `D:P(A;OICI;FA;;;<SID>)(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)`, Core:19949-19963) ; échec → `DOMENIA_STORE_DACL`.
  Portable : « aucune DACL posee » (« reserve a un support personnel »).
- Refus sans repli silencieux : chemin réseau, dossier redirigé, dossier non inscriptible (« … Aucun repli silencieux.
  Configurez UserLocal. ») ; incohérence → `DOMENIA_STORE_LAYOUT`.
- Sous-dossiers de `<DataDir>` : `Logs`, `Backups`, `Diagnostics`, `Exports`, `Legacy`, `Domains`, plus `Preferences`
  (Core:19977, 19985-19992). Reçus hors DataDir : `%LOCALAPPDATA%\Domenia\Receipts`.
- Base SQLite par domaine (`Get-DomeniaDatabasePath` Core:20172-20213) : `<DataDir>\Domains\<clé>\Domenia.db`, clé =
  32 premiers caractères hexadécimaux du SHA-256 de la base DN en minuscules (`Get-DomeniaScopeKey`, Core:241-248).
  Une ancienne base `<DataDir>\Domenia.db` (ou `ADCC.db`) n'est adoptée que si sa base DN enregistrée correspond ;
  jamais déplacée ni fusionnée. Journal SQLite en mode WAL (fichiers `-wal`, `-shm`).
- Schéma : migration seulement vers l'avant ; une base plus récente, illisible ou ambiguë est refusée intacte ; avant une
  migration, sauvegarde obligatoire dans `Backups\migrations` hors rotation (Core:20446-20470).
- Base illisible : aucun déplacement automatique, message « Le cache SQLite est illisible. Aucune base ni sauvegarde
  n'a ete deplacee ou ecrasee. Ferme DOMENIA, conserve le fichier .db ET ses fichiers -wal/-shm, puis restaure une
  sauvegarde verifiee. … » (`Recover-DomeniaDatabase`, Core:20440-20444). [NV] Aucune procédure de restauration
  outillée trouvée : restauration = remplacer le fichier à la main, Domenia fermé.

Onglet Outils, « Base autonome » (`TabIndex`, Core:6017-6080) — libellés :
« Base autonome DOMENIA » ; « Mettre a jour tout » ; « Mettre a jour les changements » ; « Ouvrir l objet » ;
« Exporter CSV » ; encadré « Emplacement et sauvegarde » avec le chemin (`TxtIndexLocation`), « Ouvrir l emplacement »,
« Sauvegarder maintenant », « Copier une sauvegarde vers... » ; état `LblIndexBackupStatus` composé
« Sauvegardes : <dossier> · derniere le jj/MM/aaaa HH:mm » ou « … · aucune pour l instant » (Storage.UI:597-608) ;
« Releve du parc » : « Releve manuel uniquement », « Lire le journal du controleur », « Oublier les releves » ;
« Rechercher » dans l'index. Sous-onglets visibles d'« Outils » (`ApplicationToolTabs`) : « Verification »,
« Base autonome », « Charge & stats », « Domaine », « Journal » ; masqués (`Visibility="Collapsed"`) : « Fiabilité »,
« Opérations et confort », « Commandes » (Core:5932-6205).
- Mise à jour de la base : jamais automatique à l'ouverture ; si la base est plus vieille que
  `Index.StartupDeltaMaxAgeMinutes`, seule une ligne de journal la recommande (« … mise a jour recommandee, non lancee
  automatiquement. … », `Request-DomeniaIndexAutoRefresh` Core:14511-14524).
- « Sauvegarder maintenant » (`Invoke-DomeniaIndexBackup`, Storage.UI:614-632) : worker `StorageBackup`
  (Storage.Worker:885-927) : copie à chaud par l'API de sauvegarde SQLite, original ouvert en lecture seule, budget
  `LocalStore.BackupTimeoutSeconds`, contrôle `PRAGMA quick_check`, fichier
  `<dossier de la base>\Backups\Domenia-aaaaMMjj-HHmmss-fff-<8 hex>.db`, copie partielle supprimée en cas d'échec,
  rotation : garde les `LocalStore.DatabaseBackupCount` (7) plus récentes `Domenia-*.db`. Message « Sauvegarde de la
  base enregistree : <chemin> ».
- « Copier une sauvegarde vers... » : demande un fichier (titre « Copier une sauvegarde de la base », nom proposé
  `Domenia-aaaaMMjj-HHmm.db`), fait la même sauvegarde puis la copie vers ce fichier (« Sauvegarde de la base copiee :
  <chemin> »).
- Pas de sauvegarde périodique automatique trouvée (`Backup-DomeniaDatabase -IfNeeded` n'est appelé nulle part) ;
  sauvegardes automatiques seulement avant migration de schéma.
- Mesure et purge (`ExpStorageMaintenance` « Stockage local », dans l'onglet « Fiabilité » masqué, Core:5933-5944) :
  « Mesurer » (worker `StorageUsage`, lecture seule) ; « Purge volontaire » avec cases « Toutes les observations et les
  relevés du parc », « Tous les instantanés de recherche », « Tout lʼindex local de lʼannuaire », « Historique de plus de »
  [730] « jours » (1 à 36500) ; « Simuler la purge » puis « Purger… » (confirmation dans la page « Confirmer la purge
  locale », boutons « Purger ces donnees locales » / « Conserver ») ; « Toujours conservés : associations et historique
  protégé, secrets, configuration, préférences, journaux et reçus. » ; « La purge libere de la place reutilisable dans
  la base ; elle ne compacte pas le fichier. » (Storage.UI:457-595). [NV] L'onglet « Fiabilité » n'apparaît que par
  routage interne (Core:9423, Access.UI:394) ; aucun bouton visible pour l'ouvrir n'a été trouvé (`BtnGuardOpen` absent
  du XAML) : la mesure et la purge sont probablement inaccessibles en usage normal.

## 12. Journaux et diagnostic

| Fichier | Contenu | Référence |
|---|---|---|
| `<DataDir>\Logs\Domenia.log` | journal applicatif, une ligne tabulée : date, niveau, `AD=<compte>`, `WIN=<identité>`, texte masqué ; rotation au-delà de 5 Mio vers `Domenia.log.1` (une génération) | `Write-AppLog` Core:17126-17157 |
| `<DataDir>\Logs\Domenia-startup.log` | étapes de démarrage (`Write-StartupTrace`) | Core:20003, 20008 |
| `<DataDir>\Logs\Domenia-login.log` | trace de connexion ; si le stockage est refusé : `%LOCALAPPDATA%\DOMENIA\Logs` puis `%TEMP%\DOMENIA\Logs` | `Get-DomeniaFastLoginLogPath` Core:24469-24500 |
| `%TEMP%\Domenia-startup-error.log` | erreurs de Domenia-Start.ps1 (avant le cœur) | Start:123-124 |
| `%TEMP%\Domenia-pack-<guid>.json` | rapport de `Verifier-Paquet.ps1` | Verifier-Paquet.ps1 |

- Masquage avant écriture (`Protect-DomeniaLogText`, Core:181-200) : mots de passe, jetons, en-têtes Bearer/Basic,
  arguments `-p`/`/p`…, clés de récupération BitLocker ; « Defence in depth, not a promise to recognise every possible
  secret. ».
- Interface : onglet Outils « Journal » (`TxtLog`, « Journal détaillé de l’application. Les noms internes ne sont pas
  anonymisés par la consultation ou la copie. ») ; `Open-DomeniaAuditLog` ouvre `Domenia.log` dans le Bloc-notes
  (Core:17159) ; connexion : « Ouvrir le journal », « Copier le diagnostic ».
- Onglet Outils « Verification » (Core:5983-6009) : « Verification rapide », « Verification complete », « Copier le
  rapport », « Exporter le diagnostic » ; colonnes « Categorie », « Test », « Etat », « Duree ms », « Detail ».
  « Exporter le diagnostic » (`Export-SelfCheckReport`, Core:24083-24118) produit
  `Domenia-Diagnostic-aaaaMMjj-HHmmss.zip` : `runtime.json`, `configuration-sanitized.json` (valeurs sensibles
  remplacées par `<MASQUE>`), `self-check.csv`, `README.txt` (« Journaux bruts exclus. Les identites, noms de machines,
  domaines et chemins ne sont pas anonymises. Relire avant partage. »).
- Démarrage en diagnostic : `Domenia.exe --diagnostic` ou `LANCER-Domenia.cmd` (console visible). Contrôle sans
  démarrage ni AD : `Domenia.exe --check`, ou depuis une console Windows PowerShell 5.1 x64 :

~~~
powershell -NoProfile -STA -File wad\Domenia-Start.ps1 -CheckOnly
~~~

  [NV] Avec `Domenia.exe --check`, la console créée se ferme à la fin du processus : le message de réussite peut ne pas
  rester visible ; `VERIFIER-PACK.cmd` se termine par `pause`.
- Mode Debug de la fenêtre de connexion : voir section 8.

## 13. Tests et contrôles

Suites Windows `dev/wad/tests/Test-*.ps1` (41 fichiers) : chacune accepte `-ReportPath` (rapport JSON) et le plus
souvent `-Quiet` ; certaines `-Wpf`/`-SkipWpf`/`-Preview`. Exemples d'objet : `Test-DomeniaRules.ps1` (règles pures des
modules, 16 fichiers `rules/*.Tests.ps1`, sans WPF ni réseau ; option `-Filter`) ; `Test-DomeniaModules.ps1` (chargeur
fermé) ; `Test-DomeniaPreload.ps1` (porte de l'installateur) ; `Test-DomeniaBoards.ps1` (tableaux de bord en widgets
dans la vraie fenêtre, données fictives `example.invalid`) ; `Test-DomeniaInstaller.ps1` (`-RestoreOnly`) ;
`Test-DomeniaGeometry.ps1` (géométrie de la vraie fenêtre) ; `Test-DomeniaFaults.ps1` (injection de pannes) ;
`Test-DomeniaWiring*.ps1` (preuves de raccordement par lot : Acces, Cache, Ecritures, Inline, Interface, Moteur,
Recherche, Relations, Suites) ; `Test-DomeniaParkDetection.ps1`, `Test-DomeniaSelectionIdentity.ps1`, etc.
Audits Python dans `wad/tests/` : `audit_*.py`.

Commandes du dépôt (CLAUDE.md), depuis `dev\`, sous Windows PowerShell 5.1, dans une VM de test :

~~~
powershell -NoProfile -STA -ExecutionPolicy Bypass -File wad\tests\Test-DomeniaRules.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Test-DomeniaPs51Compat.ps1 -Root .
powershell -NoProfile -ExecutionPolicy Bypass -File engineering\d120\Test-NativeParser.ps1 -SourceRoot . -ReportPath $env:TEMP\parser.json -RequireWindows51
powershell -NoProfile -ExecutionPolicy Bypass -File engineering\d120\lab\Invoke-LabRun.ps1 -DevRoot . -OutDir $env:TEMP\domenia-out
~~~

et hors Windows (contrôles non qualifiants) : `python tools/validate_powershell_static.py`,
`python tools/audit_preload.py`, `python tools/update_worker_contracts.py`, `python tools/release_contract.py --check`,
`python -m unittest -v engineering/d120/test_release_guard.py` (depuis `engineering/d120`),
`python tools/build_packages.py --output <dossier>`. Autres outils : `tools/Test-DomeniaUiBlocking.ps1` (audit statique
des appels bloquants depuis le Dispatcher, D014), `tools/Signer-Distribution.ps1 -Thumbprint <empreinte>` (signature
Authenticode des fichiers runtime avec un certificat « Code Signing » du magasin utilisateur, D116).

- `engineering/d120/lab/Invoke-LabRun.ps1 -DevRoot … -OutDir … [-Filter] [-TimeoutSeconds 600]` : lance chaque
  `wad\tests\Test-*.ps1` dans son propre processus 5.1 -STA, écrit `<suite>.json`, `.stdout.txt`, `.stderr.txt`,
  `.exit` et `_summary.json`.
- `Invoke-D120Campaign.ps1` : campagne d'intégration par étapes `env, compat, parser, startcheck, suites`, sortie hors
  de `dev\`, refusée sur l'hôte du labo ; « The result is an INTEGRATION report … must never be presented as » le
  rapport qualifiant. `lab.sh` / `campaign.sh` : pilotage depuis le Mac vers la VM (sync, ps, file, get) — outils
  internes du labo, ne pas décrire leurs hôtes dans les guides.
- Qualification d'une livraison : seulement avec un rapport Windows PowerShell 5.1 lié au SHA-256 des deux ZIP
  (`release_guard.py --require-windows`, « Publiable uniquement avec … », `build_packages.py:226`).
  Suivi `engineering/d120/Suivi_D001_D120.json` : 120 points, `acceptance_passed` faux pour tous ; statuts
  RACCORDE_A_VALIDER_WINDOWS 52, DEVELOPPE_NON_RACCORDE 44, RACCORDE_NON_EXECUTE 23, NON_CLOTURE 1.
- Derniers résultats DÉCLARÉS (non rejoués pour cette fiche) : ligne de base avant raccordement 1 215 réussis /
  79 échecs (CLAUDE.md) ; campagne du commit `64e6b69` : 2 365 réussis, 0 échec (LIRE-MOI.md, 05/10) ; commit
  `332074b` : règles Boards/BoardFleet/BoardSoftware 495/495 sous 5.1 natif, `Test-DomeniaBoards` 19/19,
  `Test-DomeniaModules` 110/110 ; commit `225d5a7` : `Test-DomeniaGeometry` 42/42 à 960x516, ParkDetection 22 cas.
- Exécuté pour cette fiche (Mac, 08/10, non qualifiant) : `release_contract.py --check` PASS ;
  `update_worker_contracts.py` 68 opérations, aucun écart ; `validate_powershell_static.py` PASS (139 fichiers) ;
  `audit_preload.py` 168/0 ; `audit_function_names.py` PASS ; empreintes du manifeste DEV 435/435.

## 14. Règles de sécurité (avec preuves)

- Aucun secret dans le dépôt, un script, un rapport ou un argument de processus (CLAUDE.md, règle 3). Mots de passe en
  mémoire seulement (« Le mot de passe n’est jamais enregistré. » ; onglet « Comptes ») ; effacés à la fermeture
  (Core:25858-25874) ; identifiant seul mémorisé dans `HKCU:\Software\DOMENIA`.
- Lecture par défaut : démarrage toujours en « Lecture seule » (Core:24374) ; passage en écriture confirmé et signalé
  en rouge (section 8).
- Aucune sonde réseau, aucun scan et aucune écriture AD sans geste explicite (CLAUDE.md, règle 4) : pas de mise à jour
  de la base à l'ouverture (Core:14511) ; pas de détection sur tout le parc : « detection sur tout le parc retiree.
  Filtrez la liste dans Rechercher puis Detecter la liste. » (Park.UI:34, Core:15119) ; pas d'analyse sur le domaine
  entier : « choisissez d abord une OU : aucune analyse sur le domaine entier. » (Dashboard.UI:86) ; chaque relevé passe
  par une confirmation dans la page et interroge au plus quatre postes à la fois (Park.UI:70-76).
- Une écriture n'est jamais rejouée automatiquement (reçus, Access.UI:451-452 ; purge « Aucun rejeu automatique. »).
- Ne pas affaiblir Windows : aucun appel de neutralisation de certificat, WinRM, pare-feu, antivirus ou stratégie
  dans le code (recherche des motifs le 08/10 : seules occurrences = la règle de détection
  `Test-DomeniaTransportCodeSafety`, Access.Model:441-460 environ, utilisée par les tests) ; transports intrusifs (ADMIN$,
  Planificateur, PsExec) jamais utilisés pour une lecture ou une détection et seulement avec autorisation explicite pour
  le poste (`Test-DomeniaTransportFallbackAllowed`, Access.Model:432-439) ; le déblocage du paquet ne modifie aucune
  stratégie.
- Intégrité : manifeste vérifié à chaque démarrage, chargeur fermé, registre des workers épinglé (sections 3, 4, 9).
  Le manifeste « ne vaut pas signature » : le lanceur et le runtime ne sont pas signés (signature possible via
  `Signer-Distribution.ps1`).
- Secrets LAPS/BitLocker : presse-papiers vidé après `Security.AutoClearSecretClipboardSeconds` (30 s) ; « Une valeur a
  la fois, affichee brievement, jamais journalisee ni mise en cache. » (Core:5901).
- Données locales protégées par DACL en mode UserLocal ; base obligatoirement locale ; dossiers redirigés refusés.

## 15. Écarts et points à signaler

1. `LIRE-MOI.md` (05/10) décrit encore « Dans Relations, Détecter sur tout le parc traite tous les postes actifs de
   l'index local » : le code le refuse depuis (Park.UI:34, Core:15119, Core:5281 « Aucune détection sur tout le parc. »).
   L'aide `Domenia-UX.help.json:2229` contient encore une entrée « Detecter sur tout le parc ».
2. Identité de livraison inchangée (RC1.11.0, Build du 05/10) malgré les lots des 07-08/10 : l'installateur refusera une
   mise à jour d'un poste déjà en RC1.11.0 (section 1).
3. `CLAUDE.md` annonce « ~23 800 lignes, 598 fonctions » pour le cœur : relevé actuel ≈ 25 870 lignes et 594 fonctions.
4. 61 clés de `New-DefaultConfig` + `Streaming.AutoDetectLoggedUser` ne sont lues par aucun code (section 10).
5. Les identifiants des comptes POSTES/SECRETS ne survivent probablement pas au redémarrage (hors liste blanche).
6. Mesure et purge du stockage local placées dans l'onglet « Fiabilité » masqué (section 11).
7. Case « Releve manuel uniquement » (`ChkParkSweepEnabled`, Core:6045) : son aide dit l'inverse (« Lance un lot de
   releves en arriere-plan a chaque ouverture. … ») ; comportement réel non vérifié.

## 16. Non vérifié

- Aucun écran observé, aucune exécution Windows/VM pour cette fiche ; toutes les affirmations de comportement viennent
  de la lecture du code (sauf les contrôles Mac listés en 13).
- Effet de la stratégie d'exécution PowerShell sur `Domenia.exe` et sur l'installateur.
- Versions de Windows prises en charge ; droits AD exacts nécessaires pour chaque écriture ; absence de besoin de droits
  d'administrateur local.
- Visibilité réelle des zones « Diagnostic du poste » (compte poste) et de l'onglet « Fiabilité ».
- Persistance des identifiants des comptes secondaires (déduction).
- Résultat actuel des `TESTER-*.cmd` historiques et de `Test-DomeniaInstaller.ps1` sur l'arbre courant.
- Identité binaire exacte entre `tools/launcher/launcher.c` et `Domenia.exe` (seules les chaînes ont été comparées).
- Procédure de restauration d'une base `.db` (aucun outil dédié trouvé).

# R40 — temps de démarrage (21 octobre 2026)

Statut : code et bancs écrits, **rien exécuté sous Windows PowerShell 5.1** (règle du 21 octobre : David teste à la main).
Les gains ci-dessous sont des **estimations** tirées des mesures du 20 octobre, pas des résultats.
Objectif de David : démarrage sous 20 s. Ce lot ne l’atteint pas seul (voir « Reste à mesurer »).

## 1. Où passe le temps (mesures RC1.17.38 du 20/10, VM 1 vCPU / 4 Go)

Source : `validation/2026-10-20/rc38-startup/final/` (chronomètre de l’hôte, `HostTiming*.json`, traces
`measurements/*-startup.log`). Médianes RC38 : connexion **22,5 s**, Accueil initialisé **110,3 s**.
L’horloge murale de la VM dérive (jusqu’à ±30 %) : seules les durées Stopwatch des traces et l’hôte font foi.
Le processus consomme 80 à 84 s de CPU sur 109 à 112 s : le démarrage est limité par le processeur.

| Phase (passages AfterIdle2 / AfterIdle3) | Durée mesurée | Remarque |
|---|---:|---|
| Lancement → fenêtre de connexion | 23,7 / 21,3 s (hôte) | dont intégrité du paquet 2,5 s, prévalidation XAML 0,5–0,7 s, construction du login ≈ 2,2–2,7 s |
| … reste avant la première ligne de trace | ≈ 15–18 s | **non tracé jusqu’ici** : PowerShell, analyse du cœur, chargeur des 130 modules, deux compilations C#, configuration |
| Clic → début « Apres login » | ≈ 4,5–5 s | authentification (banc automatisé) |
| Préférences persistantes | 0,6 / 1,5 s | |
| Chargement interface WPF | 13,0 / 13,0 s | XAML principal 3 450 éléments, aides du catalogue (813 entrées) |
| Moteur multithread | 1,0 / 1,1 s | |
| Branchement des événements | 14,4 / 14,4 s | **non détaillé jusqu’ici** |
| Vues de recherche, comptes, aides | 2,6 / 2,5 s | |
| Base autonome DOMENIA | 4,5 / 4,6 s | schéma SQLite sur le fil de l’interface |
| État initial de sécurité | 16,2 / 21,5 s | droits 3,0–3,6 s ; thème 1,1–1,4 s ; aides et icône 3,2–3,3 s ; accès, continuité, Accueil 2,8–3,7 s |
| Réglages du stockage local | 6,2 / 2,5 s | page Outils > Stockage, absente du premier écran |
| Préparation arbre AD | 1,2 / 1,4 s | arbre de Rechercher, absent du premier écran |
| « Apres login OK » → fenêtre vue par l’hôte | ≈ 17–20 s (déduit) | **non tracé jusqu’ici** : premier affichage, premier rendu |

## 2. Ce que change R40

### Avant la connexion

| Changement | Fichier | Gain estimé |
|---|---|---:|
| Analyse syntaxique unique des modules : le contrôle « tout le plan est valide avant le premier import » passe par l’objet script de PowerShell, dont l’import réutilise l’analyse (cache des scripts par chemin et contenu). Avant : ≈ 5,8 Mo de script analysés deux fois. La politique d’exécution et les contrôles de PowerShell restent ceux de l’import. | `Domenia-Modules.ps1` (`Get-DomeniaRuntimeModuleParseError`) | 2 à 5 s |
| Les deux fichiers C# immédiats (`Domenia-Live.Types.cs`, `Domenia-Identity.Types.cs`) sont compilés par **un** appel `Add-Type` (un seul csc.exe) ; les DLL restent chargées une à une après leur empreinte. | `Domenia-Modules.ps1` | 0,5 à 1,5 s |
| Le XAML de connexion n’est plus vérifié deux fois : un texte déjà accepté dans la session est accepté sans second parcours ; un texte refusé est revérifié à chaque appel. | `Assert-DomeniaXamlPreflight` | 0,5 à 0,7 s |

Connexion attendue : **22,5 s → 15 à 19 s** (estimation).

### Après la connexion

| Changement | Fichier | Gain estimé |
|---|---|---:|
| Les trois gestionnaires d’aide (survol, infobulle, focus clavier) sont convertis une fois et partagés par les 813 contrôles du catalogue, au lieu d’une conversion script → délégué par contrôle (≈ 2 400). Comportement identique, marqueur d’idempotence conservé. | `Domenia-UX.UI.ps1` | 1 à 3 s |
| Le thème n’est plus peint deux fois : même thème et même contraste élevé que la peinture de `Load-XamlWindow` → seul le bouton de thème est remis à jour ; toute différence repeint comme avant. | `Initialize-DomeniaPresentation` | 0,9 à 1,4 s |
| « Réglages du stockage local » et « Préparation arbre AD » s’exécutent **juste après le premier rendu de l’Accueil**, en priorité WPF `Loaded`, donc **avant toute saisie** : aucune page ne peut être atteinte avant d’être prête. Le minuteur de sauvegarde (période 60 s) n’est pas avancé. L’avertissement de maintenance de la base reste immédiat. | `Initialize-Window`, `Register-DomeniaDeferredStartupStep` | Accueil affiché 3,7 à 11,8 s plus tôt ; disponibilité inchangée pour cette part |
| Accueil « dernière vue » : la dernière vue calculée (postes actifs, à traiter, ligne datée des mesures) est gardée dans les préférences (`Fleet.LastView.<64 hex>`, liée à la base et à l’OU) et affichée avec sa date, sans lecture ni calcul. | `Domenia-Dashboard.UI.ps1`, `Domenia-BoardFleet.Model.ps1` | affichage immédiat, coût nul |

Accueil attendu : **110 s → 90 à 100 s affiché** (estimation) ; l’objectif de 20 s demande le lot suivant.

### Différences de comportement (hors temps)

- Un échec de l’une des deux étapes différées n’arrête plus l’ouverture déjà affichée : trace `ERROR`, ligne `ERROR` dans
  `Domenia.log` et incident d’interface habituel. Avant, la session ne s’ouvrait pas.
- Dans le journal de l’interface, « Pret. Connexion validee… » précède désormais les lignes de l’arbre (OU par défaut).
- L’Accueil montre « Dernière vue enregistrée, non recalculée : calcul du JJ/MM/AAAA HH:MM, N postes actifs, dont P à
  traiter » quand une vue de la même base et de la même OU a été calculée. Rien n’est relu ni recalculé.
- **Non fait, décision à prendre** : le recalcul automatique en arrière-plan à l’ouverture. David a retiré tout calcul
  de l’Accueil au démarrage le 19/10 ; R40 garde ce choix. « Recalculer la vue » reste le seul déclencheur.

## 3. Nouvelles lignes de `Domenia-startup.log`

Colonne durée = millisecondes ; pour `Jalon/…` c’est le temps **depuis le démarrage du processus PowerShell**, lu sur le
chronomètre du processus (insensible à la dérive de l’horloge de la VM). Le texte donne aussi « x s apres Clic de connexion ».

| Ligne | Mesure |
|---|---|
| `Detail/Demarrage/Lancement de PowerShell` | lanceur, powershell.exe, analyse de `Domenia-Start.ps1` |
| `Integrite du paquet` (existant) | empreintes du manifeste |
| `Detail/Demarrage/Analyse du coeur`, `Definitions du coeur` | analyse de `Domenia-Core.ps1`, puis ses définitions et assemblages WPF |
| `Detail/Demarrage/Modules` puis `Modules/Fichiers et analyse syntaxique`, `Types C#`, `Socle`, `Import des modules`, `Controle des exports` | chargeur fermé |
| `Detail/Demarrage/Composition des workers`, `Configuration`, `Dossier des donnees`, `Migration des preferences` | reste avant la trace |
| `Jalon/Coeur pret`, `Jalon/Connexion affichee`, `Jalon/Clic de connexion`, `Jalon/Connexion validee` | moments de la connexion |
| `Detail/Ouverture/Moniteur de demarrage` | écran « Initialisation » |
| `Detail/Interface/…` (8 lignes) | lecture, contrôle, construction WPF, aides du catalogue, barre de titre, contrôles nommés, thème, politique |
| `Detail/Evenements/…` (13 lignes) | groupes du branchement des événements |
| `Detail/Base/Schema SQLite`, `Detail/Base/Demande des associations` | base autonome |
| `Detail/Ouverture/Travaux en file pendant le moniteur` | travail en file exécuté par les `DoEvents` du moniteur (déjà compris dans les étapes) |
| `Jalon/Fenetre principale prete` | fin d’initialisation, juste avant l’affichage |
| `Jalon/Fenetre principale chargee` | première mise en page (Loaded) |
| `Jalon/Accueil affiche` | premier rendu de l’Accueil (ContentRendered) |
| `Apres affichage/Réglages du stockage local`, `Apres affichage/Preparation arbre AD` | étapes différées |
| `Jalon/Accueil disponible` | premier moment où le fil de l’interface est libre |

## 4. Mesure par David sous Windows

1. Fermer Domenia. Lancer `Domenia.exe` en déclenchant un chronomètre (t0).
2. Noter t1 à l’apparition de la fenêtre de connexion, cliquer aussitôt (t2), noter t3 quand l’Accueil est affiché,
   t4 quand un clic sur « Rechercher » répond.
3. Ouvrir la trace : bouton « Ouvrir le journal » du moniteur, ou `Logs\Domenia-startup.log` sous le dossier indiqué par
   la ligne `Stockage/Mode` (mode portable : `wad\data\Logs`, mode UserLocal : `%LOCALAPPDATA%\Domenia\Data\Logs`).
4. Extraire la dernière session, dans Windows PowerShell :

```powershell
$log = 'C:\chemin\vers\Logs\Domenia-startup.log'
$lines = @(Get-Content -LiteralPath $log -Encoding UTF8)
$session = (@($lines | Where-Object { $_ -match "`tApplication`tSTART`t" })[-1] -split "`t")[1]
foreach ($line in $lines) {
    $f = $line -split "`t"
    if (($f.Count -ge 7) -and ($f[1] -eq $session) -and (($f[3] -like 'Jalon/*') -or ($f[3] -like 'Detail/*') -or ($f[3] -like 'Apres affichage/*') -or ($f[4] -eq 'OK'))) {
        '{0,-62} {1,8} ms  {2}' -f $f[3], $f[5], $f[6]
    }
}
```

5. Lire d’abord les jalons : `Connexion affichee` (≈ t1), `Accueil affiche` (≈ t3, avec « s apres Clic de connexion »)
   et `Accueil disponible` (≈ t4). Les lignes `Detail/…` désignent la phase qui coûte.
6. Pour comparer deux versions : trois lancements chacune, même profil, VM au repos, médianes des jalons (pas des
   horodatages de la VM).

## 5. Reste à mesurer, puis à faire

- Les ≈ 15–18 s non tracés avant la connexion et les ≈ 17–20 s entre « Apres login OK » et la fenêtre vue par l’hôte :
  les nouvelles lignes les découpent. Rien n’est optimisé à l’aveugle.
- `Branchement des evenements` (14 s) et `Chargement interface WPF` (13 s) : construire à la première ouverture les vues
  hors Accueil (atelier de requêtes, associations, outils), seulement si les lignes `Detail/…` le désignent.
- Le cœur et les modules restent chargés en entier : le chargeur fermé, `audit_preload.py` et les épinglages supposent tout
  le plan importé au démarrage. Un chargement par groupe demanderait de revoir ces garanties ; non fait.

## 6. Pour l’intégrateur

- Workers épinglés modifiés : **aucun** (`check_worker_composition.py` PASS).
- Fonctions critiques de `audit_preload.py` modifiées : **aucune**. Échecs attendus : « Every original core function
  retained » (11 fonctions ajoutées au cœur) et « Unchanged payload: wad/Domenia-Start.ps1 » (horloge partagée).
- Fonctions du cœur modifiées : `Assert-DomeniaXamlPreflight`, `ConvertFrom-DomeniaXaml`, `Load-XamlWindow`, `Wire-Events`,
  `Set-DomeniaStartupStage`, `Initialize-DomeniaPresentation`, `Initialize-Window`, `Write-DomeniaFastLoginLog` ; ajoutées :
  `Get-DomeniaLaunchElapsedMs`, `Format-DomeniaLaunchElapsed`, `Add-DomeniaStartupMark`, `Write-DomeniaStartupMarks`,
  `Get-DomeniaStartupMilestoneGap`, `Write-DomeniaStartupMilestone`, `Write-DomeniaStartupTimings`,
  `Register-DomeniaDeferredStartupStep`, `Invoke-DomeniaNextDeferredStartupStep`, `Start-DomeniaDeferredStartup`,
  `Complete-DomeniaStartupAvailability`.
- Modules : `Domenia-BoardFleet.Model.ps1` (+2 fonctions), `Domenia-Dashboard.UI.ps1` (+4), `Domenia-UX.UI.ps1`,
  `Domenia-Experience.Model.ps1` (clé `Fleet.LastView`) ; listes du plan rafraîchies par `integrate_lots.py --refresh-functions`.
- À régénérer : `preload-baseline.json` (après relecture), manifestes et packs.
- Bancs écrits, non exécutés : `Test-DomeniaStartupWork.ps1` (+12 cas), `Test-DomeniaModules.ps1` (+4),
  `Test-DomeniaBoards.ps1` (+2, attendu 75), `Test-DomeniaStoragePreferences.ps1` (+1), `rules/BoardFleet.Tests.ps1`
  (BF-028, BF-029).

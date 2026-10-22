# Domenia 2 — tests de bout en bout (E2E)

Le harnais `tests/Domenia.E2E` lance le vrai `Domenia.exe`, avec sa vraie fenêtre et son vrai moteur WebView2, et le
pilote comme un opérateur : vrais clics de souris, saisie, touches, attentes, une capture d’écran par étape. Les
scénarios sont des fichiers JSON (`tests/e2e/<écran>/<nom>.json`) ; le rapport sort en JSON et en HTML. Dans la VM du
labo, `tools/vm.sh <lot> e2e` fait tout, dans la session de bureau visible.

Mis en place le 22 octobre 2026. Les suites de tests ne s’exécutent qu’à la toute fin (décision de David du 21/10) : les
deux scénarios de l’Accueil livrés avec le harnais ont servi une fois à **valider l’outil** (§ 10), pas de recette.

## 1. Principe

- `Domenia.E2E.exe` démarre `Domenia.exe` avec `--e2e-port <n>` et `DOMENIA_E2E=1` placé dans l’environnement **du seul
  processus enfant** (jamais dans celui de la machine ou de l’utilisateur), puis se connecte au protocole Chrome DevTools
  de la WebView2 sur `127.0.0.1:<n>`.
- Il agit par ce protocole uniquement :
  - `Runtime.evaluate` pour lire la page, avec des **fonctions constantes** du harnais (`Driver/PageScripts.cs`) ; une
    valeur venue d’un scénario (sélecteur, texte, route) n’est jamais du texte de script : elle passe en **un argument
    JSON** encodé (guillemets, chevrons, `&`, `+`, caractères non ASCII et séparateurs de ligne échappés) ;
  - `Input.dispatchMouseEvent` pour de **vrais clics** au centre de l’élément (déplacement, appui, relâchement), après
    avoir vérifié qu’il est visible, immobile, actif et **réellement sous le pointeur** (`elementFromPoint`) ;
  - `Input.insertText` pour la saisie et `Input.dispatchKeyEvent` pour les touches et raccourcis ;
  - `Page.captureScreenshot` après chaque étape (et à l’état de départ).
- **Un processus Domenia neuf par scénario** : profil WebView2 E2E vidé, préférences du moteur en mémoire. Deux scénarios
  ne se voient donc jamais.
- **Aucune dépendance** : `ClientWebSocket`, `HttpClient` (boucle locale, sans proxy) et `System.Text.Json` du framework.

## 2. Mode E2E de Domenia.App

### 2.1 Activation : l’option ET la variable

| Ligne de commande | `DOMENIA_E2E` | Résultat |
|---|---|---|
| sans `--e2e-port` | quelconque | démarrage normal, rien n’est ouvert |
| `--e2e-port <n>` | `1` (espaces tolérés autour) | **mode E2E** : port de débogage `127.0.0.1:<n>` |
| `--e2e-port <n>` | absente, vide, `0`, `true`… | refus : code 2, aucune fenêtre |

- L’option se reconnaît comme `--simulation` et `--capture` : valeur exacte, casse indifférente, sans forme
  `--e2e-port=<n>` (comptée alors parmi les arguments ignorés), admise une fois. Le port suit l’option : chiffres
  décimaux seulement, de 1 024 à 65 535. L’option et son port sont retirés de la ligne de commande avant le choix du mode.
- Le mode E2E vaut **en simulation comme en mode annuaire**. Il refuse de se combiner avec `--capture`.
- Un refus (port oublié ou invalide, option répétée, variable absente, capture demandée aussi) n’ouvre aucune fenêtre et
  ne touche à aucun profil ni fichier : message en français sur la sortie d’erreur (UTF-8) et dans le journal technique.

| Refus | Message |
|---|---|
| port oublié | Mode E2E refusé : indiquez le port après --e2e-port (nombre de 1024 à 65535). |
| port invalide | Mode E2E refusé : port invalide après --e2e-port (nombre entier de 1024 à 65535). |
| option répétée | Mode E2E refusé : l’option --e2e-port n’est admise qu’une fois. |
| variable absente | Mode E2E refusé : --e2e-port exige aussi la variable d’environnement DOMENIA_E2E=1. |
| avec `--capture` | Mode E2E refusé : --e2e-port ne se combine pas avec --capture. |

### 2.2 Effets du mode E2E

- **Port de débogage** : `CoreWebView2EnvironmentOptions.AdditionalBrowserArguments` reçoit
  `--remote-debugging-port=<n> --remote-debugging-address=127.0.0.1`. Chromium n’écoute que la boucle locale ; le
  harnais le **vérifie avant de se connecter** (tous les sockets d’écoute du port doivent être en boucle locale, sinon il
  arrête Domenia et le scénario échoue).
- **Profil WebView2 dédié et vidé** : `%LOCALAPPDATA%\Domenia\WebView2-E2E` (mode annuaire) ou
  `WebView2-E2E-Simulation`, supprimé au démarrage hors du fil de l’interface (jamais s’il s’agit d’un lien), puis
  `ClearBrowsingDataAsync` pour ce qui n’a pas pu l’être. Les profils de l’opérateur et ceux de la capture ne sont ni lus
  ni modifiés.
- **Préférences du moteur en mémoire** (`MemoryPreferenceStore`, comme en capture) : `preferences.json` et
  `preferences-simulation.json` ne sont ni lus ni écrits ; un scénario qui coupe un widget ne laisse rien derrière lui.
- **Titre** : « Domenia — Simulation — pilotage E2E » (ou « Domenia — pilotage E2E ») : la fenêtre pilotée se signale.
- **Aucune boîte de dialogue** sur une erreur fatale (personne ne la fermerait) : la trace va au journal technique et
  Domenia se termine avec le code 2. Sans le mode E2E, le code de sortie reste 0 comme avant.
- **Journal technique** : « Préférences en mémoire seulement (mode E2E) … » puis « Mode E2E actif : protocole DevTools de
  WebView2 ouvert sur 127.0.0.1:<n> pour le harnais de tests, profil WebView2-E2E-Simulation vidé au démarrage,
  préférences en mémoire seulement. »
- Le reste est inchangé : navigation limitée à `https://domenia.local/`, requêtes externes refusées, pont fermé, gardes de
  la simulation et du mode annuaire, lecture seule.

### 2.3 Variables d’environnement de WebView2 neutralisées

WebView2 lit aussi des arguments dans l’environnement : une variable posée sur le poste pourrait ouvrir le protocole de
débogage à l’insu de l’application. Au démarrage, **avant toute création de WebView2**, Domenia retire de son propre
environnement (donc de celui des processus du navigateur qu’il lance) :

| Variable | Hors mode E2E | En mode E2E |
|---|---|---|
| `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS` | neutralisée si elle contient `remote-debugging` (casse indifférente) ; conservée sinon | toujours neutralisée : seul le port de `--e2e-port` s’applique |
| `WEBVIEW2_PIPE_FOR_SCRIPT_DEBUGGER` | neutralisée en Release, conservée en Debug (débogage local de la page) | idem |

Chaque neutralisation est journalisée (`ATTENTION`) avec le **nom** de la variable, jamais sa valeur.

### 2.4 Limites assumées

- Le protocole DevTools n’a pas d’authentification : pendant une exécution, tout processus **local** du poste peut s’y
  connecter. Le mode E2E est réservé aux postes de test (VM du labo) ; il exige deux gestes explicites et se signale dans
  le titre et le journal.
- Une stratégie de groupe `AdditionalBrowserArguments` de WebView2 (registre, posée par l’administrateur du poste) n’est
  pas couverte par la garde : elle relève de l’administration du poste. Le harnais signale un port qui ne s’ouvre pas.
- En mode annuaire, la fenêtre pilotée lit l’annuaire **avec l’identité de la session** où elle tourne (authentification
  intégrée, aucun mot de passe nulle part) ; les écritures restent soumises aux gardes du pont (plan, confirmation, reçu,
  relecture).

## 3. Fichiers de scénario

- Emplacement : `tests/e2e/<écran>/<nom>.json` (un niveau ; noms en minuscules, chiffres et tirets). Identifiant :
  `<écran>/<nom>` (`accueil/choisir-ou`). Le schéma `tests/e2e/scenario.schema.json` donne la complétion dans un éditeur ;
  le harnais contrôle en plus les champs admis par chaque action.
- JSON en UTF-8 ; commentaires `//` et virgules finales tolérés ; **tout champ inconnu est refusé** (une faute de frappe
  ne passe jamais inaperçue). Un fichier refusé donne le verdict « invalide » avec un message qui nomme l’étape et le champ.
- Les textes cherchés comparent les espaces de façon souple (espaces, espaces insécables U+00A0 et U+202F, retours à la
  ligne valent une espace) ; l’apostrophe typographique et les accents se comparent tels quels.

| Champ | Obligatoire | Rôle |
|---|---|---|
| `name` | oui | titre du scénario, en français (120 caractères au plus) |
| `description` | non | ce que vérifie le scénario |
| `modes` | non | `["simulation"]` par défaut ; `"annuaire"` pour le mode annuaire ; un scénario hors du mode demandé est « ignoré » |
| `start` | non | écran de départ (route du routeur, requête facultative), `accueil` par défaut |
| `theme` | non | `dark`, `light` ou `contrast`, imposé à la page avant son chargement |
| `motion` | non | `full` ou `reduced` (animations), imposé de même ; par défaut, celles de l’application (riches) |
| `allowConsoleErrors` | non | `true` admet les erreurs de la console de la page (refusées par défaut) |
| `timeoutMs` | non | délai par défaut de chaque étape, 10 000 ms (de 100 à 120 000) |
| `steps` | oui | les étapes, dans l’ordre (200 au plus) |

## 4. Étapes

Chaque étape a un champ `do` (l’action), un `title` facultatif (description dans le rapport ; sinon le harnais en écrit
une) et un `timeoutMs` facultatif.

### 4.1 Désigner un élément

| Champ | Sens |
|---|---|
| `selector` | sélecteur CSS |
| `text` | texte visible **exact** de l’élément, ou son `aria-label` ; parmi les éléments dont le texte correspond, le plus profond est retenu (le texte d’un bouton désigne le bouton, pas la carte qui le contient) |
| `within` | sélecteur CSS de la zone où chercher (toutes les zones visibles qui correspondent) |
| `nth` | rang (à partir de 0) quand plusieurs éléments correspondent ; sans `nth`, plusieurs éléments visibles sont une erreur |

Seuls les éléments **visibles** comptent (`checkVisibility` : affichés, sans `visibility: hidden`, taille non nulle).
Comme dans Playwright, l’opacité ne masque pas : une carte qui attend son animation d’entrée sous la ligne de flottaison
(`.reveal`) est présente, et l’atteindre pour un clic fait défiler la page et jouer l’animation (le clic attend qu’elle
soit immobile).
`selector` et `text` se combinent (texte exact parmi les éléments du sélecteur).

### 4.2 Actions

| `do` | Champs | Effet |
|---|---|---|
| `go` | `route` | va à l’écran (`location.hash = '#/<route>'`) et attend `data-ready` = nom de l’écran (`CAPTURE.md` § 5) |
| `click` | élément, `button` (`left`, `right`), `clickCount` (1, 2) | vrai clic au centre de l’élément |
| `hover` | élément | déplace la souris au centre de l’élément |
| `type` | `text` (à saisir), `selector` (champ, cliqué d’abord), `clear` | saisie par `Input.insertText` ; `clear` efface d’abord (Ctrl A, Retour arrière) |
| `press` | `key`, `repeat` | touche ou raccourci : `Enter`, `Escape`, `Tab`, `Space`, `Backspace`, `Delete`, flèches, `Home`, `End`, `PageUp`, `PageDown`, `F1` à `F12`, lettres, chiffres, avec `Control+`, `Shift+`, `Alt+`, `Meta+` (`Control+K`, `Shift+Tab`, `Alt+1`) |
| `expect` | élément ou `contains`, `within`, `count`, `absent`, `property` ou `attribute` + `equals` | vérification, réessayée jusqu’au délai |
| `wait` | `ms`, ou `ready` (écran), ou un élément / `contains` (+ `absent`, `count`) | attente ; une seule forme par étape |
| `shot` | `name`, élément facultatif | capture nommée `<n°>-<name>.png`, limitée à l’élément s’il est indiqué |
| `scroll` | `deltaY`, élément (`.main` par défaut) | molette de souris au centre de l’élément |
| `journal` | `contains` ou `pattern`, `absent` | lignes du journal technique écrites depuis le lancement de ce Domenia |

Conditions de `expect` (et de `wait` sur un élément) :

| Forme | Vraie quand |
|---|---|
| élément | au moins un élément visible correspond |
| élément + `absent: true` | aucun élément visible ne correspond (une zone `within` absente compte comme absente) |
| élément + `count: n` | exactement `n` éléments visibles correspondent |
| `contains` (+ `within`) | le texte visible de la zone (la page entière sans `within`) contient ce texte ; `absent: true` pour l’inverse. Les capitales imposées par le CSS (`text-transform`) ne comptent pas : le texte visible est comparé sans casse, le texte du document avec sa casse exacte |
| élément + `property` + `equals` | la propriété DOM de l’élément unique (ou du `nth`) vaut `equals` (`checked`, `disabled`, `value`, `ariaExpanded`…) |
| élément + `attribute` + `equals` | l’attribut vaut `equals` (`null` : attribut absent) |

`journal` : `contains` (texte exact dans une ligne) ou `pattern` (expression régulière .NET, délai d’une seconde) ; avec
`absent: true`, la vérification est ponctuelle (ce que contient le journal au moment de l’étape) ; sinon elle est
réessayée jusqu’au délai. Exemples : `{ "do": "journal", "contains": "[ERREUR]", "absent": true }`,
`{ "do": "journal", "contains": "Mode E2E actif" }`.

### 4.3 Attente automatique et messages

`click`, `hover`, `type`, `shot` et `scroll` attendent que l’élément soit prêt, toutes les 100 ms jusqu’au délai.
Passé le délai, l’étape échoue avec la raison constatée en dernier :

| Constat | Message |
|---|---|
| zone `within` absente | zone … introuvable ou masquée. |
| aucun élément | aucun élément visible pour « … ». |
| plusieurs éléments | n éléments visibles pour « … » : précisez « within » ou « nth » (premiers éléments décrits). |
| élément qui bouge encore | élément toujours en mouvement : … (position mesurée deux fois à 60 ms d’écart) |
| hors de la fenêtre | élément hors de la fenêtre : … (après `scrollIntoView`) |
| désactivé (`click`, `type`) | élément désactivé : … (`:disabled`, `aria-disabled="true"`, `inert`, y compris sur un parent) |
| recouvert | élément recouvert par … : … (un autre élément reçoit le point central : panneau, voile, notification) |

Après `click`, `hover`, `type`, `press` (300 ms) et `scroll` (600 ms), le harnais laisse l’interface répondre avant la
capture. Pour vérifier un résultat, enchaîner un `expect` : il attend ce qu’il faut, pas plus.

## 5. Déroulement d’un scénario

1. Port libre de la boucle locale, position du journal technique, lancement de Domenia (`--simulation` en simulation ;
   en mode annuaire, `DOMENIA_SIMULATION` retirée de l’environnement de l’enfant pour que la jonction du poste décide).
2. Attente de la page `https://domenia.local/…` sur le point d’accès DevTools (90 s au plus ; un Domenia qui s’arrête
   avant est signalé avec son code), vérification de l’écoute en boucle locale, connexion, activation des domaines
   `Runtime`, `Log`, `Page` et de l’émulation du focus (la fenêtre peut ne pas être au premier plan).
3. **Mode réellement choisi** : la ligne « Démarrage de Domenia … : mode Simulation » (ou `Directory`) du journal doit
   correspondre au mode demandé, sinon le scénario échoue.
4. Préférences de la page (`theme`, `motion`) posées avant tout script, puis **rechargement** sur l’écran de départ : la
   console est suivie dès le premier script ; attente de `data-ready` (30 s), capture `00-depart.png`.
5. Les étapes, chacune suivie de sa capture `<n°>-<action>.png` (`<n°>-<name>.png` pour `shot`). Une étape en échec
   arrête le scénario ; les suivantes sont « non exécutées ». Un Domenia qui se ferme pendant une étape la fait échouer.
6. Fin : fermeture de la fenêtre comme un opérateur (`WM_CLOSE`), 15 s d’attente, sinon arrêt de l’arbre de processus ;
   puis attente de la fermeture du port (processus du navigateur terminé, profil libéré pour le scénario suivant).
7. Verdict : une erreur de la console de la page (`console.error`, exception non interceptée, refus de la politique de
   sécurité, ressource introuvable) fait échouer un scénario réussi, sauf `allowConsoleErrors`. La demande automatique
   de `/favicon.ico` par le navigateur est classée en avertissement. Un code de sortie de Domenia différent de 0 fait
   échouer aussi.

## 6. Rapport

Dans le dossier de sortie, réécrits après chaque scénario (un arrêt en cours de route laisse un rapport lisible) :

| Fichier | Contenu |
|---|---|
| `report.json` | format `domenia.e2e.report`, version 1 : début (UTC), durée, mode, filtre, exécutable, machine, versions de Domenia et du moteur WebView2, bilan (`passed`, `failed`, `skipped`, `invalid`), puis chaque scénario (identifiant, fichier, titre, verdict, durée, durée du démarrage, erreur, code de sortie de Domenia, étapes avec action, titre, verdict, durée, erreur et capture, erreurs et avertissements de la console avec leur étape, lignes du journal technique écrites pendant le scénario, 400 au plus) |
| `report.html`, `report.css` | le même rapport à lire : bandeau du bilan, contexte, sommaire, puis chaque scénario avec ses étapes en vignettes cliquables (verdict, durée, erreur), la console et le journal ; thèmes clair et sombre, contraste élevé, aucun script, aucun style en ligne, aucune ressource externe, tout texte échappé |
| `shots/<écran>/<nom>/<n°>-<action>.png` | une capture par étape |

Verdicts : scénario `passed` (réussi), `failed` (échoué), `skipped` (ignoré : hors du mode demandé), `invalid` (fichier
refusé) ; étape `passed`, `failed`, `notRun`. Avant d’écrire, le harnais supprime de ce dossier son rapport précédent
(`report.*` et `shots/` seulement), et seulement si le dossier est vide ou déjà un dossier de rapport (fichier témoin
`.domenia-e2e`, ou `report.json` de ce format) : un dossier donné par erreur (dossier personnel, racine d’un lecteur) est
refusé sans rien toucher (code 2). `vm.sh` vide de même l’ancien rapport du dossier local `--out` avant la copie.

Codes de sortie de `Domenia.E2E.exe` : **0** tous les scénarios exécutés ont réussi, **1** au moins un échec ou un
fichier invalide, **2** usage ou environnement (exécutable ou dossier introuvable, aucun scénario pour le filtre,
interruption).

## 7. Dans la VM du labo : `tools/vm.sh <lot> e2e`

```bash
tools/vm.sh accueil e2e --out ~/e2e/accueil                          # tous les scénarios, simulation, build Release
tools/vm.sh accueil e2e --scenarios accueil/choisir-ou --out ~/e2e/ou  # un scénario
tools/vm.sh accueil e2e --scenarios 'accueil,comptes/*' --mode annuaire --out ~/e2e/annuaire
tools/vm.sh accueil e2e --pack --out ~/e2e/pack                       # depuis le pack publié (moteur WebView2 embarqué)
```

- Verrou exclusif de la VM, synchronisation du lot, compilation (Release par défaut, `--config Debug` possible, ou
  publication avec `--pack`), exécution de `tools/e2e-vm.ps1`, puis copie de `C:\DomeniaDev\e2e\<lot>` dans `--out`.
- `--scenarios` : motifs séparés par des virgules (`accueil`, `accueil/*`, `*/choisir-*`, `accueil/mesure-active`) ;
  un motif sans `/` désigne un écran ou un nom de fichier. Caractères admis : lettres, chiffres, `* ? _ . / , -`.
- `--mode annuaire` : Domenia démarre sans `--simulation` ; sur la VM jointe à `cnamts.local`, il lit l’annuaire avec
  l’identité de la session de bureau (`CNAMTS\Administrateur`, authentification intégrée). Les écritures réelles du labo
  vont dans `OU=Domenia-Tests` (décision du 21/10). Les captures et le journal du rapport montrent alors des données
  réelles du labo : le rapport reste dans le labo et sur le Mac, jamais dans un guide.
- **Session de bureau** : quand une session de bureau du compte est ouverte sur la VM (console regardée par David), le
  harnais y tourne par une **tâche planifiée ponctuelle interactive** (`tools/desktop-run.ps1`, voir `CAPTURE.md` § 11) :
  les fenêtres de Domenia apparaissent sur ce bureau et se ferment seules ; la session n’est ni fermée ni verrouillée.
  Sans session de bureau, l’exécution passe directement par SSH.
- Variables : `DOMENIA_VM_E2E_TIMEOUT` (durée maximale de l’exécution dans la VM, 3 600 s par défaut ; au-delà la tâche
  et les processus du lot sont arrêtés, code 124), `DOMENIA_VM_SESSION` (`auto`, `direct`, `desktop`).
- Disque de la VM : préférer le build (`--pack` publie environ 780 Mo ; supprimer ensuite `C:\DomeniaDev\out\<lot>`).

## 8. À la main, sur un poste Windows de test

```text
set DOTNET_ROOT=C:\DomeniaDev\dotnet
Domenia.E2E.exe run --exe C:\…\Domenia.exe --scenarios C:\…\v2\tests\e2e --filter accueil --mode simulation --out C:\Temp\e2e
Domenia.E2E.exe self-test
```

Le harnais est une application console dépendante du framework .NET 10 (`DOTNET_ROOT`) ; il n’écrit que dans le dossier
`--out` et lit le journal technique du compte qui le lance.

## 9. Écrire un scénario

- Désigner les éléments comme l’opérateur les voit : `text` + `within` (« Choisir l’OU » dans `.scope-card`), sinon les
  attributs stables de la page (`data-widget`, `data-act`, `data-ou-apply`, rôles ARIA) ; éviter les classes de mise en
  forme et les positions.
- Une vérification par résultat visible : état d’un contrôle (`property: "checked"`), texte d’une carte, notification
  (`contains` dans `.toasts`), absence d’un panneau refermé (`absent: true`).
- Finir par les assertions du journal utiles (`[ERREUR]` absent, ligne attendue présente).
- Aucun script libre : le format n’a pas d’action « évaluer du JavaScript », pour que les scénarios restent des gestes
  d’opérateur.
- En mode annuaire, ne rien écrire hors de `OU=Domenia-Tests` ; une écriture passe toujours par le plan, la
  confirmation, le reçu et la relecture de l’application.

Exemple réel (`tests/e2e/accueil/mesure-active.json`, extrait) :

```json
{ "do": "click", "selector": "[data-toggle]", "within": "[data-widget=\"diskAlerts\"]", "title": "Couper « Mesure active » sur Alertes disque" },
{ "do": "expect", "selector": "[data-toggle]", "within": "[data-widget=\"diskAlerts\"]", "property": "checked", "equals": false },
{ "do": "expect", "contains": "Mesure désactivée : Alertes disque.", "within": ".toasts" },
{ "do": "journal", "contains": "Préférences en mémoire seulement (mode E2E)" }
```

## 10. Validation de l’outil (22 octobre 2026)

Validation de l’outil, pas recette : les deux scénarios de l’Accueil (`tests/e2e/accueil/`) ont été exécutés dans la VM
du labo par `tools/vm.sh infra e2e --out …`, session de bureau `CNAMTS\Administrateur` ouverte sur la console (exécution
dans la session 1 par la tâche ponctuelle, retirée ensuite), build Release (0 avertissement), moteur WebView2 de Windows
155.0.4283.62.

| Scénario | Étapes | Résultat de l’exécution finale |
|---|---|---|
| `accueil/choisir-ou` : ouvrir « Choisir l’OU », déplier Postes au clavier, sélectionner Lyon, appliquer, vérifier la carte, la notification et le journal | 16 (+ départ) | réussi en 25,1 s (démarrage 3,4 s, fermeture 1,0 s), 17 captures |
| `accueil/mesure-active` : couper puis rétablir « Mesure active » d’Alertes disque, vérifier l’interrupteur, les notifications, le widget, le journal | 12 (+ départ) | réussi en 17,3 s (démarrage 3,0 s, fermeture 1,0 s), 13 captures |

Bilan : 2 réussis sur 2 en 42,6 s, code 0, rapport HTML et 30 captures (1 424 × 861 px : la fenêtre est limitée par
l’écran de la VM) rapatriés sur le Mac. Le journal technique de chaque scénario contient « Préférences en mémoire seulement
(mode E2E) » et « Mode E2E actif : … 127.0.0.1:<port> … », aucune ligne `ERREUR` ni `ATTENTION` ; aucune erreur dans la
console de la page, deux avertissements (icône, ci-dessous).

Ce que les exécutions de mise au point ont appris (corrigé dans le harnais) :

- la page n’a pas d’icône : WebView2 demande `/favicon.ico` de lui-même et le journalise en erreur réseau ; le harnais le
  classe en avertissement (« icône demandée par le navigateur ») ; donner une icône à `web/index.html` le fera disparaître ;
- le processus navigateur de WebView2 survit un instant à Domenia et tient le profil : le scénario suivant ne pouvait pas
  le supprimer entièrement (« Profil WebView2 E2E vidé en partie », `ClearBrowsingDataAsync` finissait le travail) ; le
  harnais attend maintenant la fermeture du port de débogage avant le scénario suivant ;
- les cartes de l’Accueil sous la ligne de flottaison attendent leur animation d’entrée avec une opacité nulle
  (`.reveal`) : compter l’opacité comme un masquage les rendait introuvables ; le harnais suit désormais la règle de
  Playwright (§ 4.1).

## 11. Auto-tests (écrits, exécutés à la fin)

`Domenia.E2E.exe self-test` (aucune fenêtre, aucun processus, aucun réseau) : option et variable du mode E2E (absence,
casse, ports refusés, valeur oubliée, option répétée, forme `=`, variable seule), garde des variables WebView2, touches,
scénarios valides et refusés (message qui nomme l’étape et le champ), filtres, encodage des arguments de scripts, cibles
DevTools (page de l’interface seulement, même port, boucle locale), icône demandée par le navigateur, évaluation des
attentes, échappement du rapport HTML. `E2eArguments.cs` est compilé dans le harnais depuis son fichier source : le code
testé est celui qui est livré.

`tests/tools/vm-e2e-test.sh` (même principe que `vm-lock-test.sh`, en essai à blanc : rien n’est envoyé à la VM) vérifie
la commande `e2e` de `tools/vm.sh` (compilation, passage par `desktop-run.ps1`, arguments transmis, rapatriement, `--pack`,
variables), ses refus (motif, mode, options d’une autre commande) et le passage de `capture` par la session de bureau.

Restent à écrire pour la recette finale : refus de `Domenia.exe --e2e-port 9333` sans `DOMENIA_E2E=1` (code 2, aucune
fenêtre, profil E2E intact), `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=9222` neutralisée hors E2E
(aucun écouteur sur 9222, ligne `ATTENTION` au journal), et un scénario par écran porté.

## 12. Code

| Fichier | Rôle |
|---|---|
| `src/Domenia.App/E2e/E2eArguments.cs` | option `--e2e-port`, variable `DOMENIA_E2E`, arguments du navigateur, garde des variables WebView2, textes |
| `src/Domenia.App/Program.cs` | option retirée avant le choix du mode, refus (code 2), neutralisation des variables, pas de boîte de dialogue en E2E |
| `src/Domenia.App/MainForm.cs` | profil E2E vidé, `AdditionalBrowserArguments`, `ClearBrowsingDataAsync`, titre, ligne du journal |
| `src/Domenia.App/AppPaths.cs`, `Composition.cs` | profils `WebView2-E2E(-Simulation)`, préférences en mémoire |
| `tests/Domenia.E2E/Cdp/` | session WebSocket du protocole (`CdpConnection`), découverte et contrôle de la boucle locale (`DevToolsEndpoint`) |
| `tests/Domenia.E2E/Driver/` | scripts constants (`PageScripts`), entrées réelles et captures (`PageDriver`), touches (`Keys`) |
| `tests/Domenia.E2E/Scenarios/` | modèle et validation des fichiers (`Scenario`, `ScenarioLoader`) |
| `tests/Domenia.E2E/Runner/` | lancement et fermeture de Domenia, console, journal (`AppSession`), étapes (`ScenarioRunner`), fichiers et filtres (`ScenarioCatalog`) |
| `tests/Domenia.E2E/Report/` | modèle (`RunReport`), JSON et HTML (`ReportWriter`), feuille de style embarquée (`report.css`) |
| `tests/Domenia.E2E/Program.cs`, `SelfTests.cs` | ligne de commande, codes de sortie, auto-tests |
| `tests/e2e/` | scénarios et schéma JSON |
| `tests/tools/vm-e2e-test.sh` | essais à blanc de `vm.sh <lot> e2e` et du passage de `capture` par la session de bureau |
| `tools/e2e-vm.ps1`, `tools/desktop-run.ps1`, `tools/vm.sh` | exécution dans la VM, session de bureau, verrou et rapatriement |

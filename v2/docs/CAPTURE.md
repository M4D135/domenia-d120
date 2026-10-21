# Domenia 2 — mode capture (`--capture`)

Demande de David (21 octobre 2026) : « faire tourner le soft en simu » et en tirer des images reproductibles, notamment
pour les guides. Avec l’option `--capture <dossier>`, Domenia démarre, rejoue une séquence fixe pilotée par l’hôte,
écrit une image PNG par étape et un journal `capture.log` dans ce dossier, puis se ferme seule avec un code de sortie.

**Sans `--capture`, rien ne change** : même fenêtre, même profil WebView2, mêmes préférences, code de sortie 0.

## 1. Usage

```text
Domenia.exe --simulation --capture C:\Captures\Domenia
Domenia.exe --simulation --capture "D:\Doc Domenia\captures"
```

- L’option se reconnaît comme `--simulation` : valeur exacte, casse indifférente, sans forme `--capture=…`. Le dossier
  est l’argument qui suit ; un chemin qui contient des espaces se met entre guillemets. L’option n’est admise qu’une fois.
- La capture n’est admise **qu’en simulation** : avec `--simulation` (recommandé, et obligatoire pour les guides), avec
  `DOMENIA_SIMULATION=1`, ou sur un poste que la règle habituelle (`SIMULATION.md` § 2) met en simulation (hors domaine,
  jonction illisible). En mode annuaire (poste joint sans `--simulation`, ou `DOMENIA_SIMULATION=0`), elle est refusée
  avant toute écriture dans le dossier (§ 8) : les images montreraient des données réelles (domaine de jonction, compte
  Windows de l’opérateur, puis l’annuaire lui-même) hors du dossier de données de Domenia.
- `--capture` et son dossier sont retirés de la ligne de commande avant le choix du mode : ils ne comptent pas parmi les
  arguments ignorés du journal technique.
- Domenia est une application fenêtrée : pour attendre la fin et lire le code de sortie,

  ```text
  start "" /wait Domenia.exe --simulation --capture C:\Captures\Domenia
  echo %errorlevel%
  ```

  ```powershell
  $p = Start-Process .\Domenia.exe -ArgumentList '--simulation', '--capture', 'C:\Captures\Domenia' -PassThru -Wait
  $p.ExitCode
  ```

## 2. Séquence

Chaque étape part de l’état laissé par la précédente. Ordre et contenu sont fixes (`src/Domenia.App/Capture/CaptureSequence.cs`).

| # | Image | Contenu | Gestes de l’hôte |
|---|---|---|---|
| 1 | `accueil-sombre.png` | Accueil, thème sombre, données chargées | attente de l’écran Accueil prêt (`data-ready`), vérification des animations réduites, thème sombre |
| 2 | `accueil-clair.png` | Accueil, thème clair | clic sur le bouton « Thème clair » de la barre supérieure |
| 3 | `accueil-contraste.png` | Accueil, contraste élevé | clic sur « Contraste élevé » |
| 4 | `accueil-bas.png` | Accueil défilé jusqu’en bas (journal, « Session et vérifications »), thème sombre | thème sombre, défilement de `.main` jusqu’en bas |
| 5 | `palette.png` | Palette de commandes ouverte sur l’Accueil | retour en haut, ouverture par le champ de recherche de la barre supérieure (même effet que Ctrl K, sans risque de refermer) |
| 6 | `page-a-porter.png` | Écran Rechercher « en cours de portage », avec la liste des fonctions de Domenia 1 | fermeture de la palette (Échap), `#/rechercher`, attente de l’écran prêt |
| 7 | `menu-replie.png` | Menu replié (comme Ctrl B), sur l’écran Rechercher | clic sur « Replier le menu » s’il est déplié |

Ajouter ou modifier une étape, c’est modifier `CaptureSequence.cs` **et** ce tableau.

## 3. Fenêtre et images

- Fenêtre placée en haut à gauche, zone cliente de **1 600 × 1 000 pixels à 100 %**. La taille suit l’échelle d’affichage
  de Windows : la page voit toujours 1 600 × 1 000 pixels CSS ; l’image fait 1 600 × 1 000 à 100 %, 2 400 × 1 500 à 150 %.
- Si Windows limite la fenêtre (petit écran, session non interactive), la surface WebView2 garde sa taille : la page et
  les images restent à 1 600 × 1 000. `capture.log` l’indique (« fenêtre limitée par l’écran, surface conservée ») et
  donne la zone d’affichage réellement vue par la page ; un écart est signalé par `ATTENTION`.
- Chaque image vient de `CoreWebView2.CapturePreviewAsync` au format PNG : la surface web seule, sans bordure ni barre de
  titre. L’en-tête est contrôlé (signature PNG, bloc `IHDR`, dimensions non nulles) avant l’écriture, qui passe par
  `<image>.png.tmp` puis un renommage : jamais de fichier tronqué.
- Dès l’ouverture de `capture.log`, avant toute étape, les sept images de la séquence et leurs fichiers `.png.tmp`
  laissés par une capture précédente sont supprimés (ces noms seulement) ; chaque étape supprime encore son image avant
  de la prendre. Même une capture arrêtée tôt (WebView2 qui ne démarre pas, garde-fou, fenêtre fermée) ne laisse donc
  aucune ancienne image à côté du nouveau journal ; une image impossible à supprimer est signalée par `ATTENTION`.

## 4. Préférences et profil WebView2

- La capture a son **propre profil WebView2** : `%LOCALAPPDATA%\Domenia\WebView2-Capture` (mode annuaire) ou
  `WebView2-Capture-Simulation`. Il est vidé à chaque démarrage (`ClearBrowsingDataAsync`). Les profils de l’opérateur
  (`WebView2`, `WebView2-Simulation`) et donc ses préférences (`localStorage`) ne sont ni lus ni modifiés.
- Avant tout script de la page, un script constant écrit dans ce profil les préférences `domenia.prefs.v1` : thème
  sombre, **animations réduites**, menu déplié (mêmes clés que `web/js/boot.js` et `web/js/app.js`). Avec les animations
  réduites, entrées, compteurs et graphiques s’affichent directement dans leur état final (`css/motion.css`) : deux
  captures de la même séquence donnent les mêmes images, aux heures affichées près.
- La première étape vérifie `data-motion="reduced"` ; si la préférence n’a pas pris, elle échoue et **la séquence
  s’arrête là** (ligne `ARRÊT`, code 2) : aucune image n’est prise en cours d’animation. Il en va de même pour tout échec
  de la première étape (écran Accueil jamais prêt) : les étapes suivantes en dépendent.

## 5. Disponibilité des écrans (`data-ready`)

Contrat entre la page et l’hôte, posé par `web/js/router.js` :

- à chaque rendu de route, le routeur retire `data-ready` de `<html>` ;
- une fois la route montée, il pose `document.documentElement.dataset.ready = '<route>'` (`accueil`, `rechercher`…) dès
  que **deux vérifications de suite, à 80 ms d’intervalle**, trouvent : aucun appel du pont en cours (compteur de
  `trackedCall` dans `web/js/app.js`), aucun squelette (`.skeleton`) ni zone `[aria-busy="true"]` dans `.main` ;
- la surveillance s’arrête dès qu’un autre rendu commence, ou au bout de 2 minutes.

Une page qui charge des données doit donc passer par `ctx.call` et montrer des squelettes ou `aria-busy="true"` tant
qu’elle n’est pas affichée : le signal est alors juste sans une ligne de code dans la page (c’est le cas de l’Accueil et
de la page générique des écrans en cours de portage).

L’hôte exige en plus `document.readyState === 'complete'` et `document.fonts.status === 'loaded'`, puis attend 400 ms
avant l’image. Seul le mode capture lit `data-ready` ; sans `--capture`, l’attribut est posé mais rien n’en dépend.

## 6. Scripts exécutés par l’hôte

- `ExecuteScriptAsync` et `AddScriptToExecuteOnDocumentCreatedAsync` ne reçoivent que des **constantes** de
  `CaptureSequence.cs`. Aucun script ne contient de texte venant de la ligne de commande (le dossier n’entre jamais dans
  un script) ni de la page.
- Ces constantes sont : les préférences de départ ; les gestes (clic sur un bouton de thème, défilement, ouverture et
  fermeture de la palette, `location.hash = '#/rechercher'`, repli du menu) ; les conditions attendues (`data-ready`,
  thème, animations, position de défilement, palette, menu) ; deux relevés (zone d’affichage, erreur affichée : carte
  d’erreur, région d’alerte `role="alert"` ou widget illisible `.is-broken` dans `.main`).
- Un résultat de la page n’est que comparé à `true` (ou lu comme trois nombres pour la zone d’affichage) : il n’est ni
  exécuté ni recopié.
- Le reste de l’hôte est inchangé : navigation limitée à `https://domenia.local/`, requêtes externes refusées, pont fermé,
  gardes de la simulation.

## 7. Délais

| Phase | Limite | Au-delà |
|---|---|---|
| Démarrage de WebView2 (environnement, contrôle, préparation du profil) | 60 s pour l’ensemble, comptées depuis l’ouverture de la fenêtre | arrêt, code 2 |
| Chaque étape (gestes, attentes, image) | 20 s | étape en échec ; la séquence continue, sauf après la première étape (arrêt, code 2, § 4) |
| Interrogation de la page | toutes les 100 ms | — |
| Ensemble de la capture (garde-fou) | 60 + 7 × 20 + 30 = 230 s | ligne `ARRÊT` dans `capture.log`, processus arrêté, code 2 |

Une étape en échec indique dans `capture.log` le geste en cours au moment du dépassement (par exemple « attente de
l’écran Accueil et de ses données ») et, s’il y en a eu, la dernière erreur du moteur.

## 8. Dossier

- Contrôles dans cet ordre : option (dossier absent, option répétée), puis **mode** (simulation exigée, § 1), puis
  dossier. Un refus de mode n’ouvre, ne crée ni ne supprime rien dans le dossier.
- Obligatoire, juste après `--capture`. Un chemin relatif part du dossier courant, puis le chemin complet doit être
  **local** et absolu.
- Refusés : chemins réseau `\\serveur\partage` ou `//serveur/partage`, chemins de périphérique ou étendus (`\\?\…`,
  `\\.\…`), dossiers sur un **lecteur réseau** (lecteur mappé, reconnu par l’état local du poste, sans accès réseau),
  lecteur inexistant, chemin illisible.
- **Liens** : chaque composant existant du chemin est examiné sans suivre le lien (ses attributs, puis les données du
  lien, jamais sa cible). Un lien symbolique ou une jonction dont la cible est un partage (`\\serveur\partage`,
  `\??\UNC\…`) ou un chemin de périphérique est refusé comme un chemin réseau, une cible sur un lecteur réseau comme un
  lecteur réseau ; une cible locale est examinée à son tour (liens relatifs compris), jusqu’à 8 liens enchaînés, au-delà
  le chemin est illisible. Les points de montage de volume (volumes locaux) et les autres points d’analyse (fichiers
  OneDrive à la demande, déduplication) ne sont pas des liens. Le contrôle est refait une fois le dossier créé.
- Créé s’il n’existe pas (dossiers parents compris). Refusé si la création est impossible ou si `capture.log` ne peut
  pas y être écrit.
- En cas de refus : aucune fenêtre, code de sortie 2, message en français sur la sortie d’erreur (en UTF-8) et dans le
  journal technique (`%LOCALAPPDATA%\Domenia\logs\domenia.log`), qui ne recopie pas le chemin.

| Refus | Message |
|---|---|
| dossier absent | Capture refusée : indiquez le dossier des images après --capture. |
| option répétée | Capture refusée : l’option --capture n’est admise qu’une fois. |
| mode annuaire | Capture refusée : le mode capture n’est admis qu’en simulation (--simulation). |
| chemin réseau ou de périphérique, lien vers un partage | Capture refusée : les chemins réseau (\\\\serveur\\partage) et de périphérique ne sont pas admis. Choisissez un dossier local. |
| lecteur réseau, lien vers un lecteur réseau | Capture refusée : ce dossier est sur un lecteur réseau. Choisissez un dossier local. |
| lecteur inexistant | Capture refusée : le lecteur de ce dossier n’existe pas. |
| chemin illisible, lien illisible, plus de 8 liens enchaînés | Capture refusée : le chemin du dossier est illisible. |
| création impossible | Capture refusée : le dossier n’a pas pu être créé ou n’est pas accessible en écriture. |
| journal impossible | Capture refusée : le journal capture.log n’a pas pu être créé dans le dossier. |

Les seules écritures hors de `%LOCALAPPDATA%\Domenia` sont les sept images et `capture.log`, dans ce dossier choisi par
l’opérateur, et la suppression des images de mêmes noms laissées par une capture précédente (§ 3). Les autres
garanties de la simulation (`SIMULATION.md` § 1) restent entières : aucun accès réseau, base locale jamais ouverte,
lecture seule.

## 9. Journal `capture.log`

Remplacé à chaque capture, en UTF-8 avec marque d’ordre des octets (lisible par Windows PowerShell 5.1 et le Bloc-notes),
une ligne horodatée en UTC par événement : version et dossier, mode et raison, fenêtre, profil WebView2 (son nom seul,
sous la forme `%LOCALAPPDATA%\Domenia\WebView2-Capture-Simulation` : le chemin complet contient l’identifiant Windows),
version du moteur WebView2 (embarqué dans le pack ou installé dans Windows), zone d’affichage de la page, chaque étape
(durée, fichier, dimensions, taille, ou échec avec le geste en cours), avertissements (`ATTENTION` : écran qui affiche
une erreur, processus WebView2 en échec, chargement en échec, ancienne image non supprimée), erreurs (`ERREUR`, type et
code HRESULT seulement : le message d’une exception peut contenir un chemin ou un nom de compte, il reste dans le
journal technique avec le détail complet ; seule une image PNG invalide est décrite en clair), arrêts (`ARRÊT`) et
bilan.

Extrait réel (VM du labo, pack publié, `tools/capture-vm.ps1`, 21 octobre 2026, 19 h 22 UTC) :

```text
2026-10-21T19:22:03Z Capture Domenia 2.0.0-dev (.NET 10.0.12) dans C:\DomeniaDev\captures
2026-10-21T19:22:03Z Mode : Simulation (Argument) — Lancé avec l’option --simulation.
2026-10-21T19:22:05Z Fenêtre : zone cliente 1600 × 1000 px, surface WebView2 1600 × 1000 px, 96 ppp.
2026-10-21T19:22:05Z Profil WebView2 de capture : %LOCALAPPDATA%\Domenia\WebView2-Capture-Simulation (vidé au démarrage ; les préférences de l’opérateur ne sont pas touchées).
2026-10-21T19:22:09Z Moteur WebView2 : 154.0.4258.62 (embarqué dans le pack).
2026-10-21T19:22:11Z Zone d’affichage de la page : 1600 × 1000 px CSS, échelle 1.
2026-10-21T19:22:12Z [1/7] accueil-sombre : réussie en 1797 ms — Accueil, thème sombre (accueil-sombre.png, 1600 × 1000 px, 328 Ko).
…
2026-10-21T19:22:17Z [7/7] menu-replie : réussie en 624 ms — Menu replié sur l’écran Rechercher (menu-replie.png, 1600 × 1000 px, 249 Ko).
2026-10-21T19:22:17Z Fin : 7 image(s) sur 7 en 13340 ms ; code de sortie 0.
```

Le journal technique reçoit, en plus des lignes habituelles du démarrage, la demande (« Capture d’écrans demandée :
7 étapes. »), le détail des erreurs et le bilan. Les messages de Domenia n’y recopient pas le dossier de capture ; seul
le détail d’une erreur système peut le contenir.

## 10. Codes de sortie

| Code | Cas |
|---|---|
| 0 | Les sept images sont écrites et la séquence est allée à son terme. |
| 2 | Option, mode annuaire ou dossier refusé, démarrage de WebView2 impossible, première étape en échec (séquence arrêtée), au moins une étape en échec, fenêtre fermée pendant la capture, erreur imprévue sur n’importe quel fil (le journal se termine quand même par sa ligne `Fin` ; aucune boîte de dialogue n’est affichée en mode capture), garde-fou global. |

Sans `--capture`, le code de sortie reste 0, comme avant l’option.

## 11. Dans la VM Domenia du labo

La VM n’a pas de session de bureau ouverte : Domenia lancé depuis une session SSH s’affiche dans la session non
interactive du service, et la capture y fonctionne. `tools/capture-vm.ps1` lance la capture, toujours en simulation, et
affiche `capture.log` puis le code de sortie :

| Paramètre | Défaut | Rôle |
|---|---|---|
| `-Output` | `C:\DomeniaDev\captures` | dossier des images ; une barre oblique finale est admise (doublée devant le guillemet fermant, que Windows lirait sinon comme un guillemet échappé) |
| `-Exe` | pack publié `C:\DomeniaDev\out\Domenia\Domenia.exe`, sinon build Release, sinon build Debug | exécutable à lancer |

Le script, comme `build-vm.ps1`, passe la sortie de la console en UTF-8 : lus à travers SSH, `capture.log` et ses
propres messages gardent leurs accents (Windows PowerShell 5.1 écrit sinon dans la page de code OEM).

Depuis le Mac :

```bash
bash v2/tools/sync-vm.sh
ssh domenia-vm "powershell -NoProfile -ExecutionPolicy Bypass -File C:\DomeniaDev\src\v2\tools\build-vm.ps1 -Configuration Release -Publish"
ssh domenia-vm "powershell -NoProfile -ExecutionPolicy Bypass -File C:\DomeniaDev\src\v2\tools\capture-vm.ps1 -Output C:\DomeniaDev\captures\guides"
scp "domenia-vm:C:/DomeniaDev/captures/guides/*" <dossier local des captures>/
```

Mesuré le 21 octobre 2026 : pack publié (moteur 154.0.4258.62 embarqué) et build Debug (moteur 155.0.4283.62 de
Windows), 7 images sur 7, 1 600 × 1 000, code 0 ; environ 8 s quand Windows connaît déjà les fichiers, environ 30 s à
la première exécution qui suit une compilation (premier chargement des fichiers neufs). Après les corrections du soir
(pack republié, `capture-vm.ps1`) : 7 images sur 7 en 12,6 s avec `-Output C:\DomeniaDev\captures\` (barre finale),
puis en 13,3 s avec le dossier par défaut, accents lisibles à travers SSH ; sans `--simulation` sur la VM jointe,
`Domenia.exe --capture <dossier>` répond code 2 et le message de refus, sans créer le dossier.

## 12. Produire les captures des guides

1. Publier le pack (`build-vm.ps1 -Configuration Release -Publish`) : les images viennent du moteur embarqué, celui que
   reçoivent les opérateurs.
2. Lancer la capture **en simulation** (`capture-vm.ps1`, ou `Domenia.exe --simulation --capture <dossier>` sur un
   poste Windows) : annuaire fictif `example.local`, noms inventés, aucune donnée réelle dans un guide.
3. Contrôler `capture.log` : dernière ligne `Fin : 7 image(s) sur 7 … ; code de sortie 0` et aucune ligne `ATTENTION`.
4. Copier les PNG dans le dossier des images du guide **sans les renommer** : les guides citent ces noms stables, une
   nouvelle capture remplace les images sans toucher au texte.
5. Capturer un jour ouvré : la simulation est déterministe pour une graine, une date et un fuseau, et donne les mêmes
   chiffres d’un jour ouvré à l’autre (287 postes en ligne sur 412…) ; le samedi et le dimanche, le profil week-end en
   montre moins. Les durées relatives (« il y a 13 min ») suivent l’heure de la capture.

La séquence sert les guides, pas l’inverse : un écran dont un guide a besoin s’ajoute comme étape (§ 2), plutôt que
d’adapter le guide aux images disponibles.

| Image | Usage proposé dans les guides |
|---|---|
| `accueil-sombre.png` | présentation générale, tableau de bord |
| `accueil-clair.png`, `accueil-contraste.png` | apparence et accessibilité (thèmes) |
| `accueil-bas.png` | journal des opérations, « Session et vérifications » |
| `palette.png` | palette de commandes (Ctrl K) |
| `page-a-porter.png` | écrans encore en cours de portage |
| `menu-replie.png` | navigation, menu replié (Ctrl B) |

## 13. Code

| Fichier | Rôle |
|---|---|
| `src/Domenia.App/Capture/CaptureArguments.cs` | lecture de `--capture <dossier>`, validation (liens compris) et création du dossier, textes de refus |
| `src/Domenia.App/Capture/CaptureSession.cs` | `capture.log`, suppression des anciennes images, décompte des images, code de sortie, garde-fou global |
| `src/Domenia.App/Capture/CaptureSequence.cs` | zone d’affichage, délais, scripts constants, les sept étapes |
| `src/Domenia.App/Capture/CaptureRunner.cs` | préparation du profil, navigation, exécution des étapes (arrêt si la première échoue), contrôle et écriture des PNG |
| `src/Domenia.App/Program.cs` | option retirée avant le choix du mode, capture refusée hors simulation, `Main` renvoie le code, aucune boîte de dialogue en capture, erreur fatale de tout fil terminée par le code 2 |
| `src/Domenia.App/MainForm.cs` | géométrie fixe, profil de capture, démarrage borné par un délai unique, séquence puis fermeture |
| `src/Domenia.App/AppPaths.cs` | profils `WebView2-Capture` et `WebView2-Capture-Simulation` |
| `web/js/router.js`, `web/js/app.js` | signal `data-ready` et compteur des appels du pont en cours |
| `tools/capture-vm.ps1` | capture en simulation dans la VM du labo |

## 14. Tests à écrire (exécutés à la fin, dans la VM)

Non écrits à ce jour : `tests/Domenia.Tests` ne référence pas `Domenia.App` (exécutable WinForms). Il faudra soit
déplacer `CaptureArguments` et `CaptureFolder` dans un assemblage testable, soit ouvrir les types internes au projet de
tests (`InternalsVisibleTo`).

1. `CaptureArguments.Parse` : sans `--capture`, arguments rendus à l’identique ; `--CAPTURE dossier` admis ; dossier
   absent, vide ou remplacé par une option (`--capture --simulation`) refusé, l’option suivante restant en place ;
   option répétée refusée ; `--capture=dossier` non reconnu (compté parmi les arguments ignorés).
2. `CaptureFolder.Prepare` : `\\serveur\partage`, `//serveur/partage`, `\\?\C:\x`, `\\.\x` refusés **sans aucune E/S** ;
   lecteur inexistant refusé ; dossier relatif résolu puis créé ; fichier existant du même nom refusé ; lien symbolique
   de répertoire vers `\\serveur\partage` (`mklink /D`, mode développeur ou administration) refusé comme chemin réseau,
   sans connexion au serveur (capture réseau), y compris comme composant intermédiaire (`C:\lien\sous-dossier`) ; lien
   vers un lecteur réseau refusé ; jonction et lien relatif vers un dossier local admis ; chaîne de 9 liens refusée ;
   lien posé entre le premier contrôle et la création refusé par le second.
3. Refus du mode : `Domenia.exe --capture C:\x` sur la VM jointe sans `--simulation` (ou avec `DOMENIA_SIMULATION=0`)
   → code 2, message « … n’est admis qu’en simulation » sur la sortie d’erreur et dans le journal technique, aucune
   fenêtre, `C:\x` ni créé ni modifié.
4. `CaptureSession` : `ClearEarlierImages` supprime les sept noms et leurs `.png.tmp`, rien d’autre ; `Error` n’écrit
   que le type et le code, jamais `Exception.Message` ; une exception levée hors du fil de l’interface donne la ligne
   `Fin` et le code 2.
5. `CaptureSequence` : sept étapes aux noms du § 2, noms de fichiers sûrs (minuscules, chiffres, tirets), chaque geste
   a une condition ; tous les scripts sont des champs `const` (vérifié par réflexion : `FieldInfo.IsLiteral`) ;
   `StartupLeft` décroît depuis 60 s et ne passe jamais sous zéro.
6. Page (`tests/web`) : `data-ready` retiré au début d’un rendu, posé seulement après la fin des appels du pont et la
   disparition des squelettes, jamais pour une route remplacée entre-temps.
7. De bout en bout dans la VM : `capture-vm.ps1` donne le code 0, sept PNG de 1 600 × 1 000 et un `capture.log` sans
   `ATTENTION` ; une deuxième capture donne les mêmes images, aux heures affichées près ; `-Output C:\x\` (barre finale)
   fonctionne et les accents du journal restent lisibles à travers SSH ; une page qui ne pose jamais `data-ready` (copie
   du pack dont `web/js/router.js` est modifié) arrête la séquence après la première étape (`ARRÊT`, code 2, aucune
   image) ; une ancienne image d’un nom de la séquence disparaît dès le début, même si WebView2 ne démarre pas.

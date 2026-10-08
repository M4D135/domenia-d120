# Domenia 1.0 — cahier des charges des guides (édition du 8 octobre 2026)

Demande de David (08/10/2026) : « fais une doc avec captures, t'en fais deux : une tech simple avec tuto utilisation
basique, une autre admin complète. Bien présenté, captures etc., inspire-toi de celle qu'on a faite sur le projet Pesto.
En docx et pdf les deux docs. »

## Logiciel
- Domenia 1.0 : console d'administration Active Directory, Windows PowerShell 5.1 + WPF.
- Dépôt : `/Users/david/Documents/Projets/Domenia-D120`, branche `claude/epic-newton-j5ir1w`. Code : `dev/` (paquet).
  Règles du dépôt : `/Users/david/Documents/Projets/Domenia-D120/CLAUDE.md`. Le code fait foi.
- Interface : XAML dans `dev/wad/Domenia-Core.ps1` (fonction `Get-MainXaml`) et modules `dev/wad/modules/*.ps1`.
  Libellés exacts : rechercher avec `grep -F` (beaucoup de textes du code sont sans accents : « Memoire », « a verifier »).
- Lots récents (07-08/10/2026) : tableaux de bord entièrement en widgets (poste, parc, logiciels), vue du parc qui suit
  l'OU de Rechercher et ne fait qu'afficher (décision du 08/10 après essai : plus de choix d'OU ni d'analyse sur l'Accueil),
  requêtes WMI prêtes à l'emploi (catalogue `dev/wad/modules/Domenia-Probes.Model.ps1`), Pinger la liste / Détecter la
  liste / Analyser la liste dans Rechercher, Ouvrir C$ avec le
  compte des opérations poste, Base autonome (emplacement, sauvegarde, copie), retrait de l'atelier support et des
  onglets Commandes / Fiabilité / Opérations et confort. Fichiers : `dev/wad/modules/Domenia-Widgets.UI.ps1`,
  `Domenia-Boards.Model.ps1`, `Domenia-BoardComputer.UI.ps1`, `Domenia-BoardFleet.Model.ps1`,
  `Domenia-BoardSoftware.Model.ps1`, `Domenia-Charts.UI.ps1`, `Domenia-Dashboard.UI.ps1`, `Domenia-Park.UI.ps1`,
  `Domenia-Live.UI.ps1`, `Domenia-Storage.UI.ps1`.

## Outil de fabrication (kit des guides Pesto)
- Dossier : `/Users/david/Documents/Projets/Domenia-D120/guides/` (`build_guide.js`, `PROMPT_GUIDES_AUTRE_LOGICIEL.md`).
- La méthode, le gabarit des procédures et la SYNTAXE du texte sont dans `PROMPT_GUIDES_AUTRE_LOGICIEL.md` : la lire.
- Modèles à imiter (ton, structure, densité) : `/Users/david/Projects/pesto/outils/guides/technicien.md` (23 p.) et
  `/Users/david/Projects/pesto/outils/guides/administrateur.md` (48 p.).

## Lecteurs
- Guide technicien : techniciens de proximité et support, non experts. Tutoriel d'usage de base, direct : gestes et
  résultats, sans mécanique interne, sans parler de modes de test (démonstration, aperçu, données fictives). Quand un
  cas dépasse le technicien : « Prévenez l'administrateur. ». Viser 3 000 à 4 500 mots.
- Guide administrateur : complet. Tout le « pourquoi », l'architecture, l'installation, les droits, la configuration,
  la base autonome, les tableaux de bord et widgets (catalogue complet), les requêtes WMI, la sécurité, les journaux,
  le diagnostic, les tests, la maintenance. Chaque chapitre commence par l'essentiel en 2-3 phrases.

## Captures (identifiants de figures à utiliser, produites par Claude dans la VM de test)
Rendus de la vraie fenêtre WPF avec des valeurs fictives cohérentes (domaine `example.local`, postes `PC-COMPTA-014`,
`PC-ACCUEIL-002`, `PC-RH-031`, utilisateur `Camille Martin` / `cmartin`, OU `Postes`, `Lyon`). Identifiants :
- `connexion` : fenêtre de connexion.
- `accueil` : page d'accueil avec la vue d'ensemble du parc (périmètre suivi depuis Rechercher, « Changer dʼOU », widgets du parc).
- `recherche` : page Rechercher avec une liste de résultats (postes et utilisateurs).
- `recherche-actions` : barre d'actions des résultats (Utilisateur au clic, Revérifier ce poste, Pinger la liste, Détecter la liste, Analyser la liste, Arrêter).
- `fiche-poste` : fiche d'un poste (onglet Poste).
- `actions-poste` : onglet Actions du poste (outils : Ouvrir C$, consoles, Bureau à distance...).
- `tableau-poste` : onglet Tableau de bord du poste (widgets).
- `personnaliser` : même tableau en mode Personnaliser (boutons sur chaque widget, emplacements « Ajouter ici »).
- `editeur-widget` : panneau « Ajouter un widget » (recherche, représentation, taille, section, aperçu).
- `logiciels` : onglet Logiciels avec la synthèse en graphiques.
- `base-autonome` : Outils, Base autonome (emplacement, Sauvegarder, Copier une sauvegarde).
Le guide administrateur peut réutiliser toutes ces figures (chaque identifiant UNE fois par guide) et dire qu'il s'agit
de rendus de la vraie fenêtre avec des valeurs fictives.

## Règles
- Rien d'inventé : chaque libellé entre « » existe dans le code (fragments fixes pour un message composé) ; ce qui
  n'est pas vérifiable n'est pas écrit.
- Aucun secret, aucune donnée réelle (pas de cnamts, pas de noms de personnes réelles, pas d'IP réelles).
- Ne modifier AUCUN fichier hors de `/Users/david/Documents/Projets/Domenia-D120/guides/`.

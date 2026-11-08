# Connexion native : thème et diagnostic

## Recette du pack PROD-LIGHT sur WebView2 140

Le candidat cible le WebView2 Evergreen x64 **140.0.3485.54** du banc. Sans Evergreen,
LIGHT accepte le seul pack WebView2 du Socle 156.0.4314.42 extrait dans son dossier `wad`. Le chargeur de LIGHT
recherche la version stable enregistrée, contrôle ses binaires Microsoft dans le
dossier système puis vérifie quel processus affiche réellement l’interface.
Microsoft documente la [compatibilité des API](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/versioning)
et la [version cible du chargeur](https://learn.microsoft.com/en-us/dotnet/api/microsoft.web.webview2.core.corewebview2environmentoptions.targetcompatiblebrowserversion).

Dans la session de bureau du banc, extraire le ZIP qualifié dans un nouveau dossier
et ouvrir `Domenia.exe`. Vérifier que seule la fenêtre « Domenia — Connexion » est
visible. Choisir « Utiliser un autre compte », constater le champ de mot de passe,
cliquer sur « Annuler », puis « Continuer hors connexion ». L’accueil doit s’ouvrir.
Aucun identifiant n’est nécessaire pour ce parcours.

Le script `v2/tools/test-light-login.ps1` reproduit ces actions sur le vrai exécutable
et écrit une preuve JSON. Lancer depuis Windows PowerShell 5.1 avec `-Package`
(dossier extrait), `-Archive` (ZIP), `-ArchiveSha256`, `-SourceCommit`,
`-BrowserVersion 140.0.3485.54` et `-Evidence` (nouveau fichier). Le script contrôle
le manifeste du ZIP, les fenêtres natives, le processus WebView2 de la version
attendue et le .NET privé. Une preuve sur une autre version de Windows ou
de WebView2 doit être identifiée comme telle. L’authentification AD reste un essai distinct.

Avec `-WindowsIdentity`, le même script fait cet essai distinct : dans une session Windows ouverte avec un compte du
domaine, il choisit « Continuer en tant que … », attend l’unique essai, puis exige l’accueil (`connected`). Un refus
ramène le choix avec son message, relevé dans `loginFeedback` ; le script échoue alors sans nouvel essai. Aucun mot de
passe n’est saisi ni transmis : l’annuaire reçoit l’identité de la session. Cet essai est le seul qui exerce la garde
du transport AD (`AdTransportPrerequisites`) sur le pack. La CI ne l’utilise pas, son compte étant local.

## Entrée initiale du démarrage normal

Au lancement normal en mode annuaire, Domenia présente une fenêtre native **avant le premier chargement de la page** :
« Se connecter avec l’identité Windows », « Utiliser un autre compte » ou « Continuer hors connexion ». Aucun accès
AD ni lecture du coffre ne part à l’ouverture de ce choix. Le premier bouton lance un seul essai intégré Windows ;
le second ouvre la saisie native du compte et du mot de passe, puis le suivi du même essai. L’identité et le secret
ne transitent pas par JavaScript. La page reçoit ensuite l’état obtenu par sa première lecture locale `session.info`.

Échap, la croix ou « Continuer hors connexion » ferment le choix et ouvrent l’interface déconnectée. Annuler la saisie
d’un autre compte ramène au choix sans essai. Un refus ou une annulation de validation ramène aussi au choix, après
la fin réelle de l’appel natif ; aucun réessai ni repli sur Windows n’est automatique. Chaque nouvelle tentative exige
un nouveau geste. La connexion ne lance aucune collecte de l’OU et ne vaut pas validation des droits d’écriture.
Si une étape locale échoue après l’ouverture effective de la session, une lecture locale de l’état évite de proposer
« hors connexion » à tort ou de rejouer l’authentification. Un état local illisible est annoncé avant l’ouverture de la page.

La simulation, la démonstration, les captures, le pilotage E2E et les commandes sans interface ne présentent pas ce
choix. `--no-auto-connect` (alias `-NoAutoConnect`) l’évite explicitement au lancement normal : l’interface s’ouvre
hors connexion et ses actions de connexion restent disponibles. Aucun formulaire web de mot de passe n’est ajouté.

Cause du défaut de recette v2.0.1 : le démarrage naviguait directement vers la page, qui appelait uniquement
`session.info`. L’ajout du bouton web « Se connecter » n’avait pas rétabli le choix natif initial attendu. Le
raccordement natif précédant la première navigation corrige ce parcours, sans ajouter une authentification silencieuse.
Tests de logique ajoutés dans `LoginPresentationTests` ; recette native et tests à exécuter à la fin du développement.

## Saisie et suivi natifs

La saisie du mot de passe reste native. Le mot de passe n’est transmis ni à la page web ni à la trace. Il doit être masqué avant validation ; Verr. Maj est signalé. Échap annule la saisie.

Le bouton « Changer de thème » agit uniquement sur cette présentation et mémorise `accounts.loginTheme` pour les prochaines ouvertures. Un échec d’enregistrement est indiqué. Il ne relance aucune authentification. La fenêtre est limitée à la zone de travail de l’écran et à 800 pixels de largeur. Le contraste système reste prioritaire.

`Auth.LoginWindowMode` dans `Domenia.config.json` accepte `Standard` ou `Debug`, sans changer les droits ni le moteur de validation. Une valeur ambiguë est signalée et laisse le mode Standard ; les restrictions GUI indépendantes restent appliquées.

Après remise de la saisie sécurisée au moteur, une fenêtre de suivi native accompagne le même et unique essai. En mode Debug elle affiche les débuts/fins des phases effectivement traversées : validation, résolution et liaison LDAP, RootDSE, domaine et identité. Horaires et durées sont mesurés. La trace est bornée à 128 lignes et ne contient ni identifiant, ni cible, ni mot de passe, ni texte d’exception. « Copier le diagnostic » copie exactement les lignes affichées. Les étapes indisponibles sur un parcours ne sont pas inventées.

La trace Debug reste visible jusqu’à fermeture. Le mode Standard se ferme au résultat. L’annulation pendant l’attente demande l’arrêt du moteur ; un appel Windows n’est jamais tué, et la réservation physique reste détenue jusqu’à la fin réelle. La saisie sécurisée reste détenue par son appelant jusqu’au retour effectif de la validation. Une validation déjà achevée n’est pas présentée comme annulée rétroactivement.

Cette adaptation conserve deux fenêtres successives : saisie puis suivi. La trace de saisie ne prétend pas qu’un essai a déjà eu lieu. La simulation utilise son moteur propre sans fenêtre de validation réelle. Les tests de logique sont écrits ; la recette native interactive et les tests critiques doivent encore être exécutés dans les deux VM après la fin du développement.

## Correction de recette du 26 octobre 2026

Le démarrage web précédent ne demandait que `session.info`, une lecture locale qui ne connecte pas. L’entrée explicite « Se connecter » est raccordée à `session.connect` et à la fenêtre native de suivi du même essai. L’identité Windows ne nécessite pas de mot de passe ; le choix d’un autre compte reste pris en charge par la saisie native existante. Les fenêtres de saisie et de suivi activent leur fenêtre propriétaire et conservent Échap/Annuler. Aucun secret ne passe par JavaScript.

Les phases de l’essai sont conservées au journal technique également en présentation Standard : file de session, file du transport, préparation du contrôleur, bind, RootDSE, domaine et identité. Les textes et catégories sont fermés, sans nom de compte, DN, valeur AD ou cible. Windows peut résoudre/découvrir le contrôleur à l’intérieur de `Bind` : ce temps n’est pas présenté comme une mesure autonome de découverte. Le délai LDAP ne borne pas à lui seul toute la connexion. La fenêtre affiche le temps total et conserve un état « annulation demandée » jusqu’au retour réel. Une annulation demandée avant la publication de l’identité empêche la publication de cette identité tardive ; les gardes d’époque restent actives.

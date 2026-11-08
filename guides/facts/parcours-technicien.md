# Faits pour le guide technicien — Domenia 1.0 (RC1.11.0)

Relevé du 8 octobre 2026, branche `claude/epic-newton-j5ir1w`, arbre de travail (aucun changement non commité dans `dev/`).
Méthode : lecture du code et recherche littérale (`grep -F`) de chaque libellé. Aucune exécution, aucune VM.
Chemins relatifs à `dev/wad/` : `Core` = `Domenia-Core.ps1`, `modules/X` = `modules/Domenia-X.ps1` (ou `.xaml`).
Les libellés sont recopiés à l'identique, y compris sans accents (« Detecter », « Arreter »). Les guillemets `« »` encadrent le libellé exact ; `…` ou `<valeur>` signale une partie calculée à l'exécution (message composé : ne citer que les fragments fixes).

## 0. Ordre d'usage proposé (parcours technicien)

1. Lancer `Domenia.exe` et se connecter (fenêtre « Domenia · Connexion »).
2. Repérer la fenêtre principale : menu de gauche, bandeau, case « Lecture seule », aide « ? », journal en bas.
3. Rechercher une personne ou un poste (page « Rechercher »), lire la liste, vérifier un poste au clic, double-clic pour la fiche.
4. Consulter la fiche (utilisateur, poste, groupe).
5. Assistance poste : onglet « Actions » (Ouvrir C$, consoles, Bureau à distance, Ping), inventaire, « Tableau de bord », « Logiciels ».
6. Accueil : vue d'ensemble du parc par OU (Pinger l'OU, Détecter, Analyser).
7. Relations utilisateur / poste.
8. Outils > Base autonome : emplacement et sauvegarde.
9. Messages fréquents et quoi faire.

## 1. Lancement et connexion

### 1.1 Lancement

| Fait | Source |
|---|---|
| Cible : Windows PowerShell 5.1 x64, interface WPF. « Lancer `Domenia.exe`. » | `dev/LIRE-MOI.md:4` |
| Pack PROD : `Domenia.exe` et `wad`. Si Windows bloque les fichiers : `wad/Support/DEBLOQUER_TOUT.cmd` | `dev/LIRE-MOI.md:8-12` |
| Fenêtre de chargement : titre « Domenia 1.0  Initialisation » (deux espaces), texte « Preparation... », compteur « 0 s », boutons « Ouvrir le journal » et « Annuler » | Core:20029, 20041, 20045, 20046, 20047 |
| Mode de connexion livré : `Standard` (fichier `Domenia.login-mode.cfg`, et `Auth.LoginWindowMode` dans `Domenia.config.json`) | `Domenia.login-mode.cfg`, Core:25376 |

### 1.2 Fenêtre de connexion (XAML `Get-DomeniaStandardLoginXaml`, Core:25185)

| Élément | Libellé exact | Source |
|---|---|---|
| Titre de la fenêtre | « Domenia · Connexion » | Core:25189 |
| Titre | « Connexion à Domenia » | Core:25261 |
| Sous-titre | « Votre compte Active Directory » | Core:25262 |
| Champ compte (étiquette) | « Compte Windows » | Core:25269 |
| Aide du champ compte | « Saisissez votre compte AD habituel : DOMAINE\identifiant, identifiant@domaine ou le format déjà utilisé. Seul l’identifiant peut être mémorisé. » | Core:25270 |
| Champ mot de passe (étiquette) | « Mot de passe » | Core:25271 |
| Aide du mot de passe | « Mot de passe du compte saisi. Il n’est pas enregistré sur le disque. » | Core:25272 |
| Alerte majuscules | « Verr. Maj activé : le mot de passe distingue les majuscules. » | Core:25273 |
| Case à cocher | « Mémoriser uniquement l’identifiant » | Core:25274-25275 |
| Bouton afficher le mot de passe | « Afficher » | Core:25277 |
| Bouton principal | « Se connecter » (touche Entrée aussi) | Core:25292, 25483 |
| Bouton | « Annuler » | Core:25291 |
| Bouton | « Utiliser mon compte Windows » (visible si `Auth.AllowWindowsSession`, vrai par défaut ; grisé hors session de domaine) | Core:25294, 25437-25445 |
| Mention | « Le mot de passe n’est jamais enregistré. » | Core:25295 |
| En cas d'erreur | boutons « Ouvrir le journal » et « Copier le diagnostic » | Core:25284, 25285 |
| Attente | « Connexion à Domenia », « Vérification du compte… », bouton « Annuler la connexion » | Core:25301, 25302 |

Infobulle du bouton Windows à l'exécution : « Utiliser la session Windows courante : <identité> » (Core:25442) ou « Indisponible : DOMENIA nest pas execute sous un compte utilisateur de domaine. » (Core:25445).

### 1.3 Messages de la fenêtre de connexion

| Message exact | Source | Indice affiché dessous (exact) |
|---|---|---|
| « Identifiant manquant. » | Core:25044 | — |
| « Mot de passe manquant. » | Core:25049 | — |
| « Ce compte correspond a un objet ordinateur Active Directory et ne peut pas servir de login interactif. » | Core:25054 | — |
| « La session Windows courante nest pas un compte utilisateur de domaine. » | Core:25060 | — |
| « Verification du compte administrateur. » / « Verification de la session Windows courante. » | Core:25081 | — |
| « Identifiant ou mot de passe incorrect. » | Core:24801 | « Verifie les identifiants avant tout nouvel essai. » (Core:24826) |
| « Ce compte est verrouille. » | Core:24804 | catégorie restriction : « Lis la restriction indiquee avant tout nouvel essai. Ne multiplie pas les tentatives. » (Core:24829) |
| « Ce compte est desactive. » | Core:24807 | idem |
| « Le mot de passe de ce compte a expire. » | Core:24810 | si code 52f : « Verifie d abord l expiration du mot de passe : change-le (Ctrl+Alt+Suppr, Modifier un mot de passe) puis reessaie. » (Core:24828) |
| « Acces refuse par AD. Consulte le diagnostic. » | Core:24798 | « Verifie le contexte, les droits du compte et les restrictions. Details dans le journal. » (Core:24825) |
| « Erreur interne pendant la connexion. Consulte le diagnostic. » | Core:24795 | « Ce defaut ne prouve pas un mauvais mot de passe. Ouvre le journal. » (Core:24822) |
| « Echec de validation du compte. » | Core:24815 | par défaut : « Ouvre le journal de connexion pour identifier l etape en echec. » (Core:24833) |
| Réseau ou délai | — | « Verifie le reseau, le DNS ou le VPN. Details dans le journal. » (Core:24832) |
| « Delai depasse. La validation a ete arretee sans bloquer l interface. » | Core:24873 | — |
| « Verification annulee. » | Core:25458 | « Vous pouvez corriger les informations puis reessayer. » (Core:25459) |
| Succès : « Session Windows validee. » ou « Compte valide. » | Core:24774 | — |

### 1.4 Lecture seule au démarrage

- Domenia démarre toujours en lecture seule (commentaire Core:24374 ; étape « Etat initial de securite », Core:24379).
- Message de barre d'état après connexion : « Pret. Connexion validee, mode lecture seule actif. » (Core:24418).
- Il n'y a pas d'option « lecture seule » dans la fenêtre de connexion : c'est la case du bandeau (voir 2.2).

## 2. Fenêtre principale

Titre de la fenêtre : « Domenia 1.0 » (Core:3565) ; en écriture, suffixe « [ECRITURE AD ACTIVE] » (Core:22390).

### 2.1 Menu de gauche

| Libellé | Infobulle | Source | Remarque |
|---|---|---|---|
| « Domenia » / « Votre console d’assistance » | — | Core:4162, 4165 | en-tête du menu |
| « Accueil » | « Ouvrir : Accueil. » | Core:4181-4184 | |
| « Rechercher » | « Ouvrir : Rechercher. » | Core:4187-4190 | |
| « Fiche » | « Ouvrir : Fiche. » | Core:4193-4196 | grisé sans objet choisi |
| « Assistance poste » | « Ouvrir : Assistance poste. » | Core:4199-4202 | visible pour un poste seulement (Core:9449) |
| « Relations » | « Ouvrir : Relations. » | Core:4205-4208 | |
| « Atelier support » | — | Core:4211-4214 | `Visibility="Collapsed"` : retiré, ne pas documenter |
| « Comptes » | « Ouvrir : Comptes. » | Core:4217-4220 | |
| « Outils » | « Ouvrir : Outils. » | Core:4223-4226 | |
| « Réduire le menu » | replie le menu en icônes | Core:4168-4171 | |
| Pied : « DOMENIA 1.0 · RC1.11.0 » et « Les actions restent sous votre contrôle. » | — | Core:4176-4177 | |

Rubrique grisée : l'infobulle reçoit « Selectionnez une ligne adaptee dans les resultats ; sa fiche se prepare sans changer de page. » (modules/UX.UI:162).

Titres de page affichés dans le bandeau (modules/UX.UI:166-169) : « Accueil », « Recherche et filtre OU », « Fiche de l'objet », « Relations utilisateur / poste », « Assistance poste », « Comptes et accès », « Outils et vérifications ».

### 2.2 Bandeau (en-tête)

| Élément | Libellé / contenu exact | Source |
|---|---|---|
| Retour / avancer | flèches ← → ; infobulles « Revient à lʼétape précédente (Alt+Gauche) … » et « Revient à lʼétape suivante (Alt+Droite) … » | Core:4275, 4276 |
| Recherche globale | texte d'invite « Rechercher dans tout le domaine… », bouton « Rechercher » | Core:4259, 4272 |
| Badge | « Accès » (comptes temporaires et accès à revoir) | Core:4277-4282 |
| Badge | « Opérations » (suivi des opérations) | Core:4285-4290 |
| Palette | « Ctrl + K » (« Ouvre la palette des actions disponibles. Raccourci Windows : Ctrl+K. ») | Core:4293 |
| Thème | bouton clair / sombre (icône 🌞) | Core:4294-4297 |
| Aide | « ? » : affiche ou masque l'aide à droite | Core:4300 |
| Titre de page + badge de session | « Session AD en préparation », puis « Session AD · <domaine> » | Core:4314 ; modules/UX.UI:177 |
| Ligne d'état | `LblStatus` (messages de la barre d'état) | Core:4325 |
| Tâche en cours | barre d'activité et « Annuler » (masqués hors tâche) | Core:4333-4335 |
| Case | « Lecture seule » (cochée au démarrage) | Core:4339 |
| Profil | liste « Essentiel » / « Expert » | Core:4340-4342 |
| Bandeau écriture | « MODE ECRITURE AD ACTIF » (masqué en lecture seule) | Core:4327-4330 |
| Bouton « Identites » | masqué (`Collapsed`) | Core:4336 |

Infobulle de la case « Lecture seule » : « Coché : les écritures AD et les actions distantes classées comme modificatrices sont bloquées. Décocher ne donne pas de droits supplémentaires ; les confirmations restent nécessaires. » (Core:4339).

Décocher « Lecture seule » : fenêtre « Attention : mode ecriture » avec le texte « Tu vas activer le mode ecriture Active Directory. … Activer le mode ecriture ? » et boutons « Oui » / « Non » (Core:19619-19627 ; boutons Core:1875, 1880).
- Non : « Mode lecture seule conserve. » (Core:19634).
- Oui : « MODE ECRITURE AD ACTIF : les garde-fous restent actifs et chaque action sensible demande confirmation. » (Core:19641).
- Recocher : « Mode lecture seule actif : ecritures AD, GPUpdate et redemarrage distant bloques. » (Core:19609).

Profil : « Essentiel » est livré par défaut (`Domenia.ui-profile.cfg` = `Tech`). Essentiel masque les onglets « Attributs », « Droits effectifs », « WMI », « Verification », « Commandes », « Journal » (modules/UX.UI:202-203). Changement : « Interface Essentiel active. Les droits ne sont pas modifies. » (message composé, Core:2313-2314). Texte d'accueil : « La consultation est protégée par défaut » / « Le mode Essentiel simplifie les vues. La case Lecture seule contrôle les modifications : ce sont deux réglages indépendants. » (Core:4418-4419).

### 2.3 Aide contextuelle (colonne de droite, bouton « ? »)

| Libellé | Source |
|---|---|
| « Aide contextuelle » ; bouton « › » pour masquer | Core:6222, 6223 |
| « Contexte de travail », « Objet actuellement chargé », « Aucune fiche ouverte » | Core:6229-6231 |
| « Comptes utilisés » : « Annuaire », « Postes », « Secrets » ; « Identité choisie ≠ droits confirmés sur la cible. » | Core:6233-6237 |
| « Aide et prochaines étapes » : « 1 » « Trouver » « Rechercher une personne ou un poste. » ; « 2 » « Consulter » « Vérifier la fiche et la source des données. » (l'étape 3 « Préparer » est masquée) | Core:6242-6287 |
| Bouton « Ouvrir les comptes » | Core:6292 |
| « À quoi sert cet élément ? » / « Survolez un contrôle ou utilisez Tab pour lire son rôle ici. Les champs de mot de passe ne sont jamais recopiés dans cette aide. » | Core:6297-6298 |

Les textes d'aide par contrôle viennent aussi de `modules/Domenia-UX.help.json`.

### 2.4 Journal de session (bas de fenêtre)

| Libellé | Source |
|---|---|
| « Journal de session » | Core:6317 |
| Case « Suivre » (défilement automatique) | Core:6319 |
| « Etat moteur », « Copier », « Effacer » (« Efface seulement le journal affiche. »), « Réduire » | Core:6320-6323 |
| « Dans le journal » + champ de recherche, bouton « Suivant », case « Retour à la ligne », taille 10 à 18 | Core:6328-6332 |
| Infobulle : « Événements et erreurs de la session. Désactivez Suivre pour lire sans défilement automatique. Copier n’anonymise pas les noms internes. » | Core:6326 |

Autre journal : Accueil > « Détails de la session et outils de vérification » > « Ouvrir le journal » (journal d'audit, ouvert dans le Bloc-notes, Core:4456, 17159-17165). Onglet « Journal » d'Outils : profil Expert seulement (Core:6205 ; modules/UX.UI:203).

### 2.5 Raccourcis clavier (Core:15757-15771, sauf mention)

| Touche | Effet | Source |
|---|---|---|
| Ctrl+F | page Rechercher, curseur dans la recherche globale | Core:15762 |
| Entrée (recherche globale) | lance la recherche dans tout le domaine | Core:19329-19333 |
| Échap (dans la recherche globale) | vide le texte et les résultats | Core:15771-15779 |
| Entrée (ligne de résultat) | ouvre la fiche | Core:19379-19383 |
| Ctrl+K | palette des actions | Core:15759 |
| Ctrl+D | Accueil | Core:15767 |
| Ctrl+I | Outils > Base autonome | Core:15769 |
| Ctrl+L | Outils > Journal (passe en Expert, Core:9415-9417) | Core:15768 |
| Ctrl+Maj+C | copie le résumé de l'objet | Core:15760 |
| Ctrl+T | thème clair / sombre | Core:15770 |
| F5 | recharge l'arbre des OU | Core:15758 |
| F1 | Outils | Core:15761 |
| Alt+Gauche / Alt+Droite | étape précédente / suivante | Core:4275-4276 ; modules/Search.UI:278-283 |
| Échap (confirmation dans la page) | réponse sûre (Annuler) | modules/Inline.UI:30 ; modules/Inline.xaml:5 |

## 3. Accueil : vue d'ensemble du parc

> Remplacé le 08/10/2026 (décision de David) : la vue d'ensemble de l'Accueil suit l'OU choisie dans Rechercher (Get-DomeniaFleetScope), n'a plus de sélecteur ni de réglage FleetScopeDn, et ne lance aucune analyse ; « Choisir l OU... », « Tout le domaine », « Pinger l OU », « Detecter les utilisateurs », « Analyser l OU (WMI) », « Arreter » et LblFleetRun sont retirés. Les analyses partent de Rechercher : Pinger, Détecter et Analyser la liste (BtnParkAnalyze, Start-DomeniaParkAnalysis). Les requêtes du parc partent avec Analyser la liste. Source à jour : guides/administrateur.md, chapitres 3, 8 et 10.


### 3.1 Haut de page

« Que souhaitez-vous faire ? » / « Retrouvez une personne ou un poste, consultez sa fiche, puis préparez votre intervention. » (Core:4358-4359). Tuiles : « Rechercher » (« Nom, identifiant, adresse mail ou poste »), « Choisir une OU » (« OU et conteneurs du domaine »), « Gérer les comptes » (« Annuaire, accès aux postes et secrets ») (Core:4363-4411). Tuile « Préparer un dossier » masquée (Core:4389).

### 3.2 Carte « Vue d ensemble du parc » (Core:4422-4447 ; modules/Dashboard.UI)

| Élément | Libellé exact | Infobulle (exacte) | Source |
|---|---|---|---|
| Titre | « Vue d ensemble du parc » | — | Core:4427 |
| Sous-titre initial | « Calculee depuis la base autonome locale. Pour un parc complet : Outils, Base autonome, Mettre a jour tout. » | — | Core:4428 |
| Bouton | « Actualiser » | « Recalcule la vue d ensemble a partir de la base autonome locale. Aucune requete AD ni poste. » | Core:4425 |
| Étiquette + champ | « Perimetre » ; champ en lecture seule | « OU de depart du tableau de bord et des analyses. Vide : tout le domaine indexe (consultation seulement). » | Core:4433-4434 |
| Bouton | « Choisir l OU... » | « Choisir l OU de depart dans l annuaire. » | Core:4435 |
| Bouton | « Tout le domaine » | « Revient au domaine entier pour la consultation. Les analyses demandent une OU. » | Core:4436 |
| Bouton | « Pinger l OU » | « Ping des postes indexes de l OU choisie, avec confirmation. Jamais le domaine entier. » | Core:4439 |
| Bouton | « Detecter les utilisateurs » | « Ping puis utilisateur console des postes de l OU choisie ; associations actualisees si changement. » | Core:4440 |
| Bouton | « Analyser l OU (WMI) » | « Ping, utilisateur console et releve WMI leger (modele, memoire, disque C:, build, demarrage) de chaque poste de l OU ; resultats conserves pour ce tableau de bord. » | Core:4441 |
| Bouton | « Arreter » | « Arrete les nouvelles lectures ; les resultats obtenus sont conserves. » | Core:4442 |
| Ligne d'avancement | `LblFleetRun` | — | Core:4444 |

- « Choisir l OU... » ouvre un sélecteur intégré : titre « Perimetre du tableau de bord », consigne « Choisissez l OU de depart : les statistiques et les analyses se limitent a ses postes. » (modules/Dashboard.UI:74) ; champ + « Rechercher », texte « Rechercher affiche les OU ; saisir un nom permet d affiner. », colonnes « Nom », « Identifiant / DNS », « Description », boutons « Annuler » et « Choisir » (modules/Embedded.UI:283-296, 288). Le choix est mémorisé entre les sessions (modules/Dashboard.UI:70, 76).
- Après calcul, le champ affiche le DN de l'OU ou « Tout le domaine indexe » (modules/Dashboard.UI:108) ; le sous-titre devient « Base autonome locale et derniers releves : <n> postes actifs dans le perimetre, calcul du <date>. Parc incomplet ? Outils, Base autonome, Mettre a jour tout. » (modules/BoardFleet.Model:234).
- Le calcul est lancé à l'ouverture de la fenêtre (Core:24420) ; pendant le calcul : « Calcul de la vue d ensemble depuis la base locale... » (modules/Dashboard.UI:60).

Messages :

| Message exact | Source | Sens / quoi faire |
|---|---|---|
| « Analyse impossible : choisissez d abord une OU : aucune analyse sur le domaine entier. » | modules/Dashboard.UI:86, 96 | choisir une OU avec « Choisir l OU... » |
| « Analyse impossible : actualisez d abord la vue d ensemble de cette OU. » | modules/Dashboard.UI:87, 96 | cliquer « Actualiser » |
| « Analyse impossible : aucun poste indexe dans cette OU. Mettez a jour la base autonome. » | modules/Dashboard.UI:89, 96 | prévenir l'administrateur (ou Outils > Base autonome) |
| « Vue d ensemble non calculee : base occupee, reessayez dans un instant. » | modules/Dashboard.UI:64, 105 | réessayer |
| « Aucune base autonome active : vue d ensemble indisponible. » | modules/Dashboard.UI:57 | prévenir l'administrateur |
| « Releve impossible : Un releve est deja en cours. » | modules/Park.UI:36, 58 | attendre ou « Arreter » |
| « Releve impossible : Attendez la confirmation des enregistrements locaux avant un nouveau releve. » | modules/Park.UI:38 | attendre |
| « Releve impossible : Aucun poste indexe dans cette OU. » | modules/Park.UI:44 | — |

Confirmation dans la page (pas de fenêtre ; Échap = réponse sûre) (modules/Park.UI:71-76 ; modules/Inline.UI:48-85 ; modules/Inline.xaml) :

| Bouton | Titre de la confirmation | Message (fragments fixes) | Bouton de confirmation / sûr |
|---|---|---|---|
| « Pinger l OU » | « Pinger les postes affiches » | « <n> postes de <OU>. Ping ICMP seulement. » | « Pinger » / « Annuler » |
| « Detecter les utilisateurs » | « Detecter sur les resultats affiches » (le code range l'OU dans la portée « Results », Park.UI:45, 52) | « <n> postes de <OU>. Ping puis utilisateur console ; associations actualisees si changement. » | « Verifier les sessions » / « Annuler » |
| « Analyser l OU (WMI) » | « Analyser le perimetre » | « <n> postes de <OU>. Ping, utilisateur console et releve WMI leger (modele, memoire, disque C:, build, demarrage), quatre postes au maximum a la fois. Resultats conserves pour le tableau de bord. » | « Verifier les sessions » / « Annuler » |

Avancement (modules/Park.UI:9-10) : « Ping en cours : <a>/<b> postes pingues, <c> joignables, <d> sans reponse. » ; « Releve en cours : <a>/<b> postes verifies, <c> joignables, <d> identites en cache, <e> associations actualisees, <f> lectures non confirmees. » ; fins : « Ping termine », « Releve termine », « Arret demande ». Ajouts possibles : « Enregistrement local en attente. », « Stockage a verifier dans Fiabilite. » (Park.UI:12-13). À la fin, la vue d'ensemble se recalcule seule (Park.UI:15).

### 3.3 Widgets du parc (catalogue `Fleet`, modules/Boards.Model:52-68, 17 widgets, disposition par défaut = catalogue entier, Boards.Model:257-259)

Sections et widgets : « Vue d ensemble » (« Etat du parc », « Points d attention ») ; « Inventaire du perimetre » (« Postes actifs », « Postes inactifs (90 j et plus) », « Postes sous Windows 10 », « Utilisateurs detectes », « Derniere analyse ») ; « Repartition » (« Systemes d exploitation », « Derniere connexion au domaine », « Postes par unite d organisation », « Presence reseau ») ; « Releves WMI » (« Modeles », « Versions de Windows », « Memoire installee », « Espace libre sur C: », « Disque C: presque plein », « Non redemarres depuis 30 j »).
Sous-titres de section : « Base autonome locale », « Systemes, activite et unites d organisation », « Derniere analyse de l OU » (modules/Widgets.UI:139-150).
Indices de section vide : « Aucun poste actif indexe dans ce perimetre : mettez a jour la base autonome (Outils, Base autonome, Mettre a jour tout). » (BoardFleet.Model:170) ; « Analysez l OU (WMI) pour remplir cette section : modeles, memoire, disques, versions et demarrages. » (BoardFleet.Model:175).
La barre d'outils et la personnalisation sont les mêmes que pour le tableau de bord du poste (voir 6.3).

Carte repliée « Détails de la session et outils de vérification » (Core:4448-4553) : boutons « Racine du domaine », « Copier », « Verifier l application », « Vider le cache », « Ouvrir le journal » ; champs « Domaine », « Serveur / DC », « Compte execution AD », « Mode » (« Lecture seule (securite par defaut) » ou « Ecriture autorisee sous controles », Core:24183), « Base DN », « Branche courante », « Resultats affiches », « Module AD », « Droits effectifs », « Taches », « Cache visite », « Diagnostic DOMENIA », « Liens user-machine », « Stats liste courante », « Objet selectionne ».

## 4. Rechercher

### 4.1 Deux façons de chercher

- Barre du haut (recherche globale) : « Recherche globale dans tout le domaine : personne, compte, mail ou poste. L’OU et les filtres de la liste sont ignorés. La limite de résultats reste appliquée. » (Core:4252). Bouton « Rechercher » : « Recherche dans tout le domaine, tous types, sans filtre OU, de présence ou de liste. Aucun poste sondé avant sélection. » (Core:4272).
- Arbre des OU à gauche de la page : « Parcourir les OU », bouton « ↻ » (recharge l'arbre), « La barre du haut cherche partout. Cliquez une OU pour consulter son contenu. » (Core:4579-4584).
- Préfixes facultatifs dans la recherche globale : `utilisateur:` (`user:`, `u:`), `poste:` (`pc:`, `machine:`, `ordinateur:`), `groupe:` (`group:`, `g:`), `mail:` (`email:`, `courriel:`) (modules/Search.Model:44-49). Un préfixe inconnu est cherché comme texte (Search.Model:63).
- Minimum de caractères : message « Saisis au moins <n> caracteres, ou * pour un apercu. » (Core:9828 ; minimum par défaut 2, modules/Search.UI:17).

### 4.2 Arbre et périmètre OU

| Libellé | Source |
|---|---|
| Bouton « Tout le domaine » | Core:4594 |
| Carte « PÉRIMÈTRE SÉLECTIONNÉ » : nom (« Tout le domaine » par défaut), « Choisissez une OU dans l’arbre. » | Core:4597-4599 |
| Bouton « Afficher cette OU » (« Retour au contenu de l’OU, sans perdre la recherche du bandeau. ») | Core:4602 |
| Case « Inclure les sous-OU » (cochée par défaut ; décochée = enfants directs seulement) | Core:4603 |
| Volet « Voir le chemin LDAP », bouton « Copier le chemin » | Core:4604-4607 |
| État de l'arbre « Arbre pret. » | Core:4611 |
| Bandeau de restauration : boutons « Relire » et « Choisir une autre OU » | Core:4589-4590 |

Menu clic droit de l'arbre : « Afficher le contenu de cette branche », « Actualiser l arborescence », « Revenir a la racine du domaine », « Copier le chemin (DN) », « Nouveau dans cette branche » (écriture, grisé en lecture seule), « Analyser les droits sur cette branche » (Core:12956-12975).

### 4.3 Filtres

| Filtre | Libellé exact et valeurs | Source |
|---|---|---|
| Titre | « Périmètre des résultats » ; résumé « Dans : tout le domaine | Sous-OU incluses » | Core:4623-4624 |
| Type | « Type d’objet » : « Tous », « Utilisateurs », « Machines », « Groupes », « OU et conteneurs » | Core:4628-4634 |
| Présence | « Présence réseau » : « Tous », « En ligne », « Sans réponse au ping », « Non vérifié », « Erreur de ping » | Core:4638-4644 |
| Limite | « Limite » (100 par défaut) ; « Nombre maximum de résultats affichés (20 000 au plus). » | Core:4648-4649 |
| Vue de travail | « Vue de travail » + bouton « Afficher » | Core:4652-4655 |

- Type et Présence sont grisés pendant une recherche globale (déclencheur `Tag=Global`, Core:4627, 4637) : ils filtrent le contenu d'une OU.
- Infobulle Présence : « Filtre les observations réseau mémorisées en mode OU. Sans réponse au ping ne prouve pas que Windows est éteint. Aucun ping collectif. » (Core:4639).
- Vues de travail (modules/Search.Model:382-386) : « Comptes expirant sous 30 jours », « Comptes desactives », « Objets modifies depuis 7 jours », « Postes de cette OU » (OU sélectionnée), « Postes sans connexion depuis 90 jours ». Sans choix : « Choisissez dʼabord une vue de travail dans la liste. » (modules/Search.UI:48) ; « Postes de cette OU » sans OU : « Choisissez dʼabord une OU dans lʼarbre pour cette vue. » (Core:9819).

### 4.4 Barre des résultats et filtre local

| Libellé | Infobulle / rôle | Source |
|---|---|---|
| « Actualiser » | « Actualise le mode affiché : recherche globale sans filtres, ou contenu de l’OU avec ses filtres. » | Core:4682 |
| « Effacer » | « Efface le texte et les résultats sans modifier l’OU sélectionnée. Tout le domaine retire le filtre OU. » | Core:4683 |
| « Exporter CSV » | « Exporte les resultats affiches, ou uniquement les lignes selectionnees, au format CSV. » | Core:4684 |
| « Charger la suite » | « Disponible quand la liste est limitée : relit la même recherche avec une limite doublée, jusquʼà 20 000 lignes, sans doublon ni ancien contexte. » | Core:4686 |
| Compteur | « 0 objet » au départ ; titre « Résultats » | Core:4687-4688 |
| Filtre local | « Dans les résultats » + champ (« Filtre local littéral dans le nom, login, type, présence et association. Plusieurs mots se combinent. Aucun appel AD. La limite LDAP reste inchangée. ») ; bouton « Effacer le filtre » | Core:4691-4693 |

Compteur (modules/Search.Model:329-339) : « <n> résultat(s) · liste complète » ; « <n> chargé(s) · liste limitée à <limite> : affinez ou chargez la suite » ; à 20 000 : « … : affinez la recherche » ; « · lecture en cours » ; « · <n> visible(s) après filtre local ». Ligne du filtre : « <a> / <b> lignes visibles » + « · recherche globale sans filtre local » ou « · filtre local » (modules/Live.UI:833). Erreur partielle : « Liste partielle · <n> résultat(s) AD · vérification incomplète » (modules/Live.UI:815).
Export : « Aucun resultat a exporter. » / « <n> ligne(s) exportee(s). » (Core:10660, 10664).

### 4.5 Ligne d'actions (sous la barre des résultats)

| Libellé | Infobulle exacte | Source | Libellé court (fenêtre étroite) |
|---|---|---|---|
| Case « Utilisateur au clic » (cochée par défaut) | « Un clic lance un ping unique sur le poste. Cochée : lit aussi son utilisateur console. Décochée : ping seulement. Jamais de sondage collectif. » | Core:4696 | — |
| « Revérifier ce poste » | « Poste sélectionné seulement : relance un ping unique et la lecture utilisateur. Grisé pour un autre type d objet ou une sélection multiple. Si le compte est refusé ou CIM désactivé, seul le ping reste disponible. Aucun balayage. » | Core:4697 | « Revérifier » (modules/UX.UI:306) |
| « Pinger la liste » | « Grisé si la liste ne contient aucun poste. Ping seul des postes affichés après vos filtres : met à jour la présence réseau, sans lecture de session ni association. Confirmation avant envoi. » | Core:4698 | « Pinger » (UX.UI:309) |
| « Détecter la liste » | « Grisé si la liste ne contient aucun poste. Ping puis lecture de la console des seuls postes affichés, après vos filtres (OU, recherche, présence, filtre local). Confirmation avec le nombre de postes avant toute lecture. Cache et associations conservés. » | Core:4699 | « Détecter » (UX.UI:310) |
| « Arrêter » | « Actif pendant une détection : arrête les nouvelles lectures et conserve les résultats déjà obtenus. » | Core:4700 | — |

Lignes d'état sous les boutons : « Selectionnez une ligne pour precharger sa fiche. Double-clic : ouvrir. » et « Un clic : vérifier ce poste · Double-clic : ouvrir la fiche · Aucune sonde de liste » (Core:4702). À l'exécution (modules/Live.UI:840) : « Sélection : un ping + utilisateur si activé · double-clic : fiche · aucun contrôle collectif », « ping à la sélection · utilisateur désactivé », « poste sélectionné : <n> en attente, <m> en cours », « compte distant refusé · détection suspendue », « validation AD suspendue · revoir la connexion », suivis de l'état d'enregistrement (« Enregistre. » ou « En memoire : … », modules/Cache.Model:359-364).

Confirmations (modules/Park.UI:71-76) :
- « Pinger la liste » : titre « Pinger les postes affiches », message « <n> postes dans les resultats affiches. Ping ICMP seulement, quatre postes au maximum a la fois ; aucune lecture de session ni association. », boutons « Pinger » / « Annuler ».
- « Détecter la liste » : titre « Detecter sur les resultats affiches », message « <n> postes dans les resultats affiches. Lecture legere de la console Windows (CIM/DCOM), quatre postes au maximum a la fois. Seuls les comptes nouveaux ou modifies sont resolus dans AD. Les sessions RDP ne sont pas recensees. Associations et cache conserves entre les lancements ; aucun inventaire complet, aucune tache distante. », boutons « Verifier les sessions » / « Annuler ».
- La détection sur tout le parc est retirée : « Releve impossible : detection sur tout le parc retiree. Filtrez la liste dans Rechercher puis Detecter la liste. » (Park.UI:34).
- Erreur : « Releve impossible : Aucun poste dans les resultats affiches. » (Park.UI:50).

### 4.6 Colonnes de la liste (Core:4719-4749)

« Type », « Nom », « Utilisateur connecté (console) », « Vérification utilisateur », « Fraîcheur AD », « Compte » (affichée seulement si une ligne a un compte, modules/Live.UI:105-111), « UPN / DNS », « Association mémorisée », « Source lien », « Qualification », « Présence réseau », « Etat », « OS », « Derniere connexion », « Mail », « Description », « Modifie », « Chemin complet ».

Valeurs (modules/Live.Model:88-127) :
- « Utilisateur connecté (console) » : le compte, « Aucun compte console », « Non déterminé », ou « <compte> (cache) ».
- « Vérification utilisateur » : « Console observée », « Lecture réussie », « Accès refusé », « Compte distant refusé », « Délai dépassé », « Non confirmé », « Utilisateur non vérifié », « Vérification en cours », « À vérifier », « Non vérifié · sélectionner le poste ».
- « Présence réseau » : « En ligne », « Sans réponse au ping », « Non vérifié », « Erreur de ping », « Vérification en cours », avec « (cache) » pour une observation ancienne. Détail : « Pas de réponse ICMP : poste indisponible ou ICMP filtré, sans preuve qu'il est éteint. » (Live.Model:123).

Liste vide : « Aucun résultat affiché » / « Sélectionnez une OU à gauche ou saisissez un nom en haut. Les filtres OU, type et sous-OU se combinent. Une liste vide ne prouve pas une absence dans AD. » (Core:4755-4756) ; filtre local vide : « Aucune ligne à afficher » (Core:4761).

### 4.7 Clic, double-clic, menu clic droit

- Un clic : précharge la fiche sans changer de page ; pour un poste, un ping et la lecture utilisateur si « Utilisateur au clic » est coché (infobulle de la liste, Core:4705).
- Double-clic ou Entrée : ouvre la page « Fiche », onglet « Resume » (Core:10302-10304, 19379-19383).
- Menu clic droit (`Build-DomeniaObjectsContextMenu`, Core:12810-12937) :
  - « Ouvrir la fiche de <nom> » (12835) ; pour un poste « Rechercher l'utilisateur associe » (12838) ; pour un utilisateur « Associer un poste a ce compte », « Rechercher les postes de ce compte », « Rechercher le poste associe » (12843-12849) ; « Ouvrir le conteneur parent » (12853).
  - Poste : sous-menu « Poste distant » : « Ping », « Bureau a distance », « Partage C$ », « Gestion de l ordinateur », « Observateur d evenements », « Copier une commande PSRemote », puis « Forcer la mise a jour des strategies » et « Redemarrer le poste » (grisés en lecture seule) (12858-12869).
  - Poste : sous-menu « Collecte » : « Inventaire rapide », « Inventaire complet », « Logiciels installes », « Explorateur WMI », « Diagnostic distant », « Detecter le dernier utilisateur », « Charger BitLocker », « Charger LAPS » (12873-12882).
  - « Analyser » : « Droits effectifs », « Relire l objet depuis AD », « Tester la presence reseau » (12887-12890).
  - « Copier » : « Le nom », « Le login », « L UPN ou le DNS », « L association », « Le DN », « La ou les lignes selectionnees », « Le resume complet » (12895-12911).
  - « Exporter la liste en CSV » (12913).
  - « Modifier » (écritures ; en lecture seule, infobulle « Le mode lecture seule est actif. Decoche la case du bandeau pour activer les ecritures. ») : utilisateur « Deverrouiller le compte », « Activer le compte », « Desactiver le compte », « Forcer le changement de mot de passe », « Deplacer / changer d'OU... » ; poste « Activer le compte machine », « Desactiver le compte machine » ; « Supprimer l objet » (12917-12935).
  - Sans sélection : « Aucune ligne selectionnee » (12815).

## 5. Fiche (objet sélectionné)

En-tête de page « Fiche de l'objet ». Sans objet : « Selectionnez un objet dans Rechercher. », bouton « Reessayer la lecture » (Core:4768). Pendant la lecture : « La fiche se prepare en arriere-plan. » (Core:5158).

Onglets visibles selon le type (`Set-VisibleTabsForType`, Core:9433-9459) :
- Tous : « Resume » ; « Appartenances » (utilisateur, poste, groupe) ; « Attributs » et « Droits effectifs » en Expert.
- Utilisateur : « Utilisateur », « Coordonnees », « Compte ».
- Groupe : « Groupe ». OU / conteneur : « Unite d organisation ».
- Poste : la page « Assistance poste » s'ajoute au menu (voir 6).

### 5.1 « Resume » (Core:4769-4810)

Titre « Objet selectionne ». Champs : « Type », « Nom », « Classe », « GUID », « Cree », « Modifie », « Chemin complet », « Presence » (« Poste : joignable ou non. Utilisateur : etat du poste qui lui est associe. »), « Cible testee ». Boutons : « Copier le resume », « Ouvrir le parent », « Supprimer » (écriture : « Supprime definitivement l objet. Deux confirmations sont demandees. »). Mention : « Clic droit sur le chemin pour copier le DN ou agir sur l objet. »

### 5.2 Utilisateur

- Onglet « Utilisateur » (Core:4815-4884), titre « Fiche utilisateur » : « Prenom », « Nom », « Nom affiche », « Login », « UPN », « Mail », « Telephone », « Bureau », « Description », « Fonction », « Service », « Societe », « Responsable », « Presence », « Etat », « Derniere connexion », « Pwd last set », « Expiration », « Options du compte », « Postes associes » + bouton « Ouvrir le poste » (« Aucun poste associe. »), bouton « Enregistrer » (écriture).
- Onglet « Coordonnees » (Core:4889-4949) : « Adresse » (« Rue », « Ville », « Departement ou region », « Code postal », « Pays »), « Telephonie » (« Domicile », « Mobile », « Telecopie », « Telephone IP », « Page web », « Matricule »), « Profil et session » (« Chemin du profil », « Script de connexion », « Dossier de base », « Lecteur de base », « Postes autorises »), « Enregistrer » (écriture).
- Onglet « Compte » (Core:4955-5040) — toutes écritures : « Actions sur le compte » : « Déverrouiller le compte », « Activer », « Desactiver » ; « Nouveau mot de passe », « Confirmation », « Deverrouiller ensuite », « Changement obligatoire », « Reinitialiser le mot de passe » ; « Options de compte » + « Appliquer » ; « Expiration » + « Fixer », « Jamais », « Expirer le mot de passe » ; « Deplacer vers » + « Deplacer » ; « Groupe » + « Ajouter », « Retirer ».

### 5.3 Groupe

Onglet « Groupe » (Core:5046-5071) : titre « Groupe », « Nom », « Description », « Enregistrer » (écriture), champ du DN du membre, « Ajouter membre », « Retirer membre » (écritures), liste « Membres » (« Membres directs du groupe. Clic droit pour rechercher ou copier. »). Onglet « Appartenances » : « Groupes » (« Groupes dont cet objet est membre. Clic droit pour rechercher ou copier. ») (Core:5093-5097).

### 5.4 Écritures bloquées en lecture seule (`Get-WriteControlMap`, Core:22246-22257)

Boutons grisés en lecture seule, infobulle « Desactive : mode lecture seule actif. » (Core:22460) : enregistrements de fiches (utilisateur, coordonnées, poste, groupe), attributs, déverrouiller / activer / désactiver (utilisateur et poste), options de compte, expiration, expirer le mot de passe, réinitialiser le mot de passe, ajout / retrait de groupe ou de membre, déplacer, « Renommer dans AD », « Supprimer », création d'OU.

## 6. Assistance poste (page visible pour un poste)

Sans poste : « Selectionnez un objet dans Rechercher. » + « Reessayer la lecture » (Core:5417). Onglets dans l'ordre (Core:5418-5878) : « Machine », « Tableau de bord », « Actions », « Sessions Windows », « Diagnostic », « Inventaire », « Logiciels », « WMI » (Expert), « Secrets ».

### 6.1 Onglet « Machine » (Core:5418-5482)

Titre de carte « Fiche du poste ». Champs : « Nom », « DNS », « Presence », « OS », « Version », « Description », « Localisation », « Responsable », « Etat », « Derniere connexion », « Options du compte », « Utilisateur associe », « Source », « Qualification », « Detecte le ». Bloc « Actions » : « Detecter l utilisateur » (« Recherche le dernier utilisateur connu du poste. Un lien deja enregistre n est pas remplace. »), « Ouvrir l utilisateur », « Enregistrer » (écriture).

### 6.2 Onglet « Actions » (Core:5507-5548)

Titre « Actions sur le poste ».

| Bouton | Infobulle exacte | Écriture ? | Source |
|---|---|---|---|
| « Activer » | « Reactive le compte du poste dans le domaine. » | oui (compte AD) | Core:5513 |
| « Desactiver » | « Desactive le compte du poste. Il ne pourra plus s authentifier. » | oui (compte AD) | Core:5514 |
| « Ping » | « Teste si le poste repond sur le reseau. » | non | Core:5515 |
| « Bureau à distance » | « Ouvre une connexion Bureau a distance vers ce poste. » (lance `mstsc.exe /v:<poste>`, Core:17077) | non | Core:5516 |
| « Ouvrir C$ » | « Ouvre le partage administratif C du poste dans l explorateur. » | non | Core:5517 |
| « Gestion de l ordinateur » | « Ouvre la console Gestion de l ordinateur sur ce poste. » | non | Core:5518 |
| « Journaux » | « Ouvre l Observateur d evenements sur ce poste. » | non | Core:5519 |
| « Services » | « Ouvre la console Services. Utilise Action puis Se connecter pour cibler ce poste. » | non | Core:5520 |
| « Commande PowerShell » | « Copie une commande de connexion PowerShell distante dans le presse-papiers. » | non | Core:5521 |
| « Exécuter un programme » | « Lance un programme sur ce poste via une tache planifiee RunOnce unique et auto-supprimee. » | oui (bloqué au clic en lecture seule, Core:16953) | Core:5522 |
| « Actualiser les stratégies » | « Force la mise a jour des strategies de groupe sur le poste. Demande confirmation. » | oui (grisé en lecture seule, Core:22469-22476) | Core:5523 |
| « Redemarrer » | « Redemarre le poste. Demande confirmation. » | oui (grisé en lecture seule) | Core:5524 |
| « Nouveau nom » + « Renommer dans AD » | « Renomme le compte d’ordinateur dans l’annuaire. Cette action ne renomme pas Windows sur le poste. » | oui | Core:5532-5534 |
| « Groupe » + « Ajouter » / « Retirer » | « Ajoute ce poste au groupe indique. » / « Retire ce poste du groupe indique. » | oui | Core:5543-5546 |

Fonctionnement vérifié dans le code :
- « Ouvrir C$ » : ouvre d'abord `\\<poste>\C$` avec le compte des opérations poste (compte saisi dans « Diagnostic », sinon compte de connexion Domenia), vérifie le port 445, puis lance l'Explorateur (Core:17015-17056). Succès : « C$ de <poste> ouvert avec <compte>. » (Core:17043). Échec : erreur « Ouvrir C$ de <poste> … » avec, selon le cas, « le partage du poste ne repond pas (port 445). » ou « acces a \\<poste>\C$ refuse pour <compte> : <motif Windows> » (Core:17027, 17034, 17048).
- « Gestion de l ordinateur », « Journaux », « Services » : même ouverture préalable sur `IPC$`, puis `compmgmt.msc /computer=`, `eventvwr.exe /computer:`, `services.msc /computer=` (Core:17053-17060, 17079). Si l'ouverture préalable échoue, la console s'ouvre quand même avec la session Windows : « Console ouverte avec la session Windows : <motif> » (Core:17050).
- Session Windows sans mot de passe (connexion par « Utiliser mon compte Windows ») : pas d'ouverture préalable (Core:17021).
- « Ping » : état « Ping de <poste>... », résultat dans la barre d'état « Ping <poste> : #1 <statut> <n>ms <adresse> » (Core:17075, 17073, 16821).
- « Commande PowerShell » : copie `Enter-PSSession -ComputerName '<poste>'` et affiche « Commande PowerShell distante copiee dans le presse-papiers : … Aucun second interpreteur PowerShell n est lance, afin de limiter les faux positifs antivirus. » (Core:17082-17084).
- « Actualiser les stratégies » : confirmation « Forcer immediatement la mise a jour des strategies sur <poste> ? » ; « Redemarrer » : « Redemarrer immediatement <poste> ? » (Core:17088, 17099), boutons « Oui » / « Non ».
- En lecture seule : « Actualiser les stratégies » et « Redemarrer » ont l'infobulle « Desactive : cette action modifie le poste distant et le mode lecture seule est actif. » (Core:22476) ; « Exécuter un programme » reste cliquable mais s'arrête sur « … est une modification distante et reste bloquee tant que le mode lecture seule est actif. » (Core:16839, 16953).
- Compte des opérations poste (onglet « Diagnostic ») : « Compte poste », « Mot de passe », « Utiliser ce compte » (« Utilise ce compte pour interroger les postes. Il n est jamais enregistre sur le disque. »), « Compte de connexion » (Core:5574-5601). Libellé d'état : « Operations poste : session Windows <identité>. », « Operations poste : compte saisi <compte>, en memoire seulement. », « Operations poste : compte de connexion Domenia <compte> (CIM, C$, consoles). » (Core:17005-17007).

### 6.3 Onglet « Tableau de bord » et widgets (Core:5490-5506 ; modules/Widgets.UI, modules/Boards.Model)

- Titre « Tableau de bord du poste » ; texte « Lancez un inventaire (Rapide ou Complet) : le tableau de bord se remplit avec ses resultats. » (Core:5494-5495).
- Boutons « Inventaire rapide » (« Lit l inventaire du poste (CIM) puis remplit ce tableau de bord. ») et « Inventaire complet » (« Inventaire complet, plus long : ajoute correctifs, evenements et details. ») (Core:5497-5498).
- Vide : « Lancez un inventaire rapide ou complet : chaque widget se remplit avec ses resultats. » (modules/Dashboard.UI:10) ; cartes « Pas encore de donnees » / « Les widgets se remplissent apres la premiere lecture. » (Widgets.UI:115-116).
- Après inventaire : « Tableau de bord de l inventaire du <date>. » (modules/Dashboard.UI:126) si aucun résumé.
- Catalogue `Computer` (Boards.Model:8-49, 42 widgets), sections : « Vue d ensemble » (« Etat general », « Points d attention »), « Identite du poste », « Compte machine dans Active Directory », « Ressources », « Activite », « Securite et etat ». Sous-titres : « Etat general et points a verifier », « Materiel, systeme et session », « Attributs lus dans l annuaire avec la fiche », « Mesurees pendant l inventaire », « Services, processus et journal Systeme », « Protection, correctifs et configuration » (Widgets.UI:141-147).

Barre d'outils du tableau (`New-DomeniaBoardToolbar`, Widgets.UI:185-222) :

| Bouton | Infobulle exacte | Quand | Source |
|---|---|---|---|
| « Actualiser les requetes » | « Execute les requetes WMI des widgets (lecture seule) sur le perimetre, avec confirmation. » | seulement si un widget de requête WMI est présent ; pas sur Logiciels | Widgets.UI:197 |
| « Ajouter un widget » | « Choisir une information du tableau de bord ou une requete prete a l emploi. » | toujours | Widgets.UI:198 |
| « Personnaliser » | « Deplacer, redimensionner, modifier ou retirer les widgets. » | hors personnalisation | Widgets.UI:203 |
| « Par defaut » | « Revient a la disposition livree (annulable). » | en personnalisation | Widgets.UI:200 |
| « Terminer » | « Quitte la personnalisation. » | en personnalisation | Widgets.UI:201 |
| « Annuler » | « Revient a la disposition precedente. » | après une modification (à gauche, précédé du texte d'annulation) | Widgets.UI:212 |

- En personnalisation : consigne « Glissez un widget pour le deplacer ; clic droit pour sa representation, sa taille ou sa place. » (Widgets.UI:218) ; tuile en pointillés « Ajouter ici » au bout de chaque section (Widgets.UI:237 ; infobulle « Ajouter un widget dans la section <section>. », 256) ; deux boutons ronds sur chaque widget, infobulles « Modifier : <titre> » et « Retirer : <titre> » (Widgets.UI:469-470), visibles en permanence en personnalisation, au survol sinon (471-476).
- Glisser-déposer : un widget déposé sur un autre prend sa place et sa section (Widgets.UI:477-480).
- Menu clic droit d'un widget (toujours disponible, Widgets.UI:400-435) : « Modifier... », « Representation » (choix selon la donnée), « Taille » (« Compacte », « Moyenne », « Large »), « Deplacer » (« Au debut de la section », « Vers la gauche », « Vers la droite », « A la fin de la section »), « Retirer du tableau de bord ».
- Représentations (Boards.Model:199) : « Chiffre cle », « Jauge », « Anneau », « Barres », « Histogramme », « Courbe », « Liste », « Liste de points », « Score ».
- Textes d'annulation (Widgets.UI:534-789) : « Disposition par defaut appliquee », « Widget retire », « Representation changee », « Taille changee », « Widget deplace », « Widget ajoute », « Widget modifie ». « Retirer » et « Par defaut » n'ont pas de confirmation : on revient en arrière avec « Annuler » (Widgets.UI:558-562).
- Tout retiré : « Aucun widget » / « Tous les widgets ont ete retires. Ajoutez-en un, ou revenez a la disposition par defaut avec Personnaliser. » (Widgets.UI:115-116).

Fenêtre « Ajouter un widget » (« Modifier le widget » en modification) (`Show-DomeniaBoardEditor`, Widgets.UI:614-800) :
- Gauche : « Informations disponibles », recherche « Rechercher : disque, utilisateur, BitLocker... », liste groupée « Tableau de bord · <section> » et « Requetes WMI · <catégorie> », badge « affiche » pour ce qui est déjà présent (Widgets.UI:589-651).
- Droite : « Titre », « Representation », « Taille », « Section » (section par défaut « Mes widgets ») ; « Apercu » ; sans choix : « Choisissez une information dans la liste. » (Widgets.UI:689-782).
- Boutons « Annuler » (« Ferme sans rien changer. ») et « Ajouter » (« Ajoute le widget choisi au tableau de bord. ») ou « Enregistrer » (Widgets.UI:719-724).
- Catalogue des requêtes WMI : 53 lignes en 8 catégories (« Materiel » 13, « Systeme » 9, « Disques » 6, « Reseau » 6, « Securite » 5, « Logiciels et services » 9, « Utilisateurs » 3, « Evenements » 2) (modules/Probes.Model:7-61).

« Actualiser les requetes » : sur le poste, interroge le poste sélectionné ; sur l'Accueil, les postes de l'OU (jamais le domaine) ; confirmation titrée « Sonder pour les widgets » (Park.UI:76). Messages : « Aucune requete WMI sur ce tableau de bord : ajoutez un widget de requete. », « Choisissez une OU : jamais le domaine entier. », « Actualisez la vue du parc : le perimetre a change depuis le dernier calcul. », « Aucun poste dans le perimetre. », « Aucun poste selectionne. » (Widgets.UI:855-867).

### 6.4 Onglet « Inventaire » (Core:5629-5683)

Titre « Inventaire du poste ». Boutons « Rapide » (« Materiel, systeme, disques, reseau, securite, correctifs, logiciels, services, comptes, partages et imprimantes. »), « Complet » (« Ajoute les processus, les taches planifiees, les certificats, les connexions reseau et les erreurs recentes. Plus long. »), « Copier », « Exporter CSV ». Filtre « Categorie » (« Toutes »). Colonnes « Categorie », « Element », « Valeur », « Source ». Volet « Detail par source » : « Categorie », « Acces », « Elements », « Duree ms », « Detail ».
Le même inventaire remplit l'onglet « Tableau de bord » (Core:12050).
Messages : « Selectionne un poste, puis lance l inventaire. » (5651) ; « Inventaire rapide en cours sur <poste>... » / « Inventaire complet en cours sur <poste>... » (12099) ; fin : « <poste> : <n> element(s) sur <a> source(s) accessibles, <b> refusee(s), <c> indisponible(s), <d> autre(s), en <ms> ms. » (12059-12060) ; « Inventaire impossible : <détail> » (12080) ; « Selectionne une machine avant de lancer l inventaire. » (12089).

### 6.5 Onglet « Logiciels » (Core:5697-5770)

Titre « Logiciels installes ». Boutons / cases : « Charger les logiciels », « Par utilisateur », « Applications Store » (« Plus long. »), « Mises a jour », « Copier », « Exporter CSV ». Volet dépliable « Synthese en graphiques » (ouvert par défaut ; texte initial « Chargez les logiciels pour afficher la synthese. »). Filtres « Filtre » et « Portee » (« Toutes », « Machine », « Utilisateur », « Store »). Colonnes « Nom », « Version », « Editeur », « Installe le », « Taille », « Portee », « Archi », « Type », « Emplacement », « Desinstallation », « Source ». Volet « Detail par portee ». Clic droit : « Logiciels detectes. Clic droit pour copier un nom ou une commande de desinstallation. »
Widgets « Software » (Boards.Model:71-78, 8 widgets) : « Synthese » (« Logiciels », « Taille declaree », « Installes en plusieurs versions », « Sans editeur declare »), « Repartition » (« Editeurs », « Architecture », « Portee d installation », « Plus gros logiciels ») ; pas de bouton « Actualiser les requetes ».
Messages : « Selectionne un poste, puis charge la liste. » (5736), « Lecture des logiciels de <poste>... » (13562), « <n> logiciel(s) affiche(s) sur <total>. » (13489), « Lecture impossible : <détail> » (13546), synthèse « <n> … Synthese calculee sur la liste chargee. » (BoardSoftware.Model:160), « Aucun logiciel lu. » (Dashboard.UI:134).

### 6.6 Autres onglets du poste (rappel)

- « Sessions Windows » : « Lire les sessions » ; colonnes « ID », « Compte », « Domaine », « État », « Protocole », « Information » ; « Lecture à la demande, distincte du dernier utilisateur connu. Un accès refusé ne signifie pas absence de session. » (Core:5553-5555).
- « Diagnostic » : « Lancer le diagnostic » (DNS, joignabilité, ports, SMB, WinRM, WMI, système, disque, session), « Copier le rapport » ; colonnes « Controle », « Etat », « Methode », « Duree ms », « Detail » (Core:5556-5617).
- « Secrets » : « BitLocker », « LAPS », « Afficher », « Copier », « Copier tout », « Vider » ; lectures disponibles même en lecture seule (Core:5878-5910 ; Core:22267-22275 ; modules/Secrets.UI:46).

## 7. Relations utilisateur / poste (Core:5273-5405)

- En-tête (lot L04, RC1.14) : « Relations utilisateur / poste », « Sélectionnez un utilisateur ou un poste depuis Rechercher. », un seul statut (`LblLinkProbeStatus`) et le bouton « ? » qui affiche ou masque les précautions (« Une association mémorisée n'est pas une preuve de session ouverte. La détection réseau reste volontaire. », « Détection des utilisateurs connectés : dans Rechercher, filtrez la liste puis « Détecter la liste ». Aucune détection sur tout le parc. », état de la détection du parc).
- Onglet « Associations » : deux zones. À gauche, boutons « Supprimer l'association », « Restaurer … » (nomme l'association, par exemple « Restaurer jdupont → PC01 »), « Exporter » ; colonnes « Utilisateur », « Machine », « Qualification » (puce), « Date » (heure locale), « Source », « Conservation », « Détails ». À droite, panneau « Ajouter une association » : « Sélectionnez d'abord un utilisateur ou un poste dans Rechercher. Ensuite choisissez Détecter ou Rechercher. ».
  - « Détecter » : « Détecter les postes », « Arrêter », « Ouvrir le poste », « Associer ce poste » ; « Options de détection » : « Périmètre » (« Postes connus et candidats AD », « Machines de la liste chargée », « OU sélectionnée dans Rechercher »), « Maximum de postes (1 à 50) » (20), « Lire aussi les indices Kerberos du contrôleur (7 jours) » ; confirmation « Périmètre à confirmer avant toute lecture des postes » avec « Annuler » / « Lancer la détection ».
  - « Rechercher » : bouton « Rechercher », colonnes « Poste », « DNS », « Description », « Saisissez au moins deux caractères. », « Associer ce poste » ; confirmation « Confirmer l'association » avec « Annuler » / « Associer ».
- Onglet « Toutes les associations » : « Importer », « Annuler l'import » (après un import), « Restaurer … », « Nettoyer », « Exporter tout » ; filtre texte, puces « Déclaré », « Observé », « Contradictoire », compteur ; aperçu d'import (« N° », « Utilisateur », « Poste », « Résultat », « Motif », boutons « Importer N association(s) » et « Annuler ») ; liste « Associations orphelines » (« Retirer », « Utilisateur », « Poste », « Motif », « Source », « Date », boutons « Retirer la sélection » et « Fermer »). Onglet « Détail ».
- Messages : « Association introuvable : déjà retirée ou rechargée. Aucune modification. », « Suppression annulée : aucune association modifiée. », « Aucune suppression locale à restaurer. » (modules/Relations.UI:539, 579, 587).
- Aucun contrôle « lecture seule » trouvé dans `Domenia-Relations.UI.ps1` / `.Model.ps1` (les associations sont locales, pas dans AD) — non vérifié à l'écran.

## 8. Outils > Base autonome (Core:5924-6075 ; modules/Storage.UI:597-643)

Page « Outils » (« Outils et vérifications ») : onglets visibles en Essentiel : « Base autonome », « Charge & stats », « Domaine » ; « Verification » et « Journal » en Expert ; « Fiabilité », « Opérations et confort », « Commandes » masqués dans le XAML (Core:5932, 5973, 6140 ; UX.UI:202-203). Attention : la règle du profil Expert rend « Commandes » visible (`TabCmdlets=$expert`, UX.UI:203) alors que le brief le dit retiré — non vérifié à l'écran ; sans objet pour le guide technicien (profil Essentiel).

Onglet « Base autonome » :

| Élément | Libellé exact | Infobulle exacte | Source |
|---|---|---|---|
| Titre | « Base autonome DOMENIA » | — | Core:6020 |
| Bouton | « Mettre a jour tout » | « Relit tous les utilisateurs et postes, reconstruit la base autonome et resynchronise les associations connues. Peut durer plusieurs minutes. » | Core:6023 |
| Bouton | « Mettre a jour les changements » | « Ne relit que les objets modifies depuis la derniere passe grace a uSNChanged/whenChanged. Beaucoup plus rapide. » | Core:6024 |
| Bouton | « Ouvrir l objet » / « Exporter CSV » | — | Core:6025-6026 |
| Cadre | « Emplacement et sauvegarde » | — | Core:6030 |
| Champ | chemin du fichier de la base (lecture seule) ; « Aucune base active. » sinon | « Fichier de la base autonome de ce domaine. Le chemin peut etre copie. » | Core:6031 ; Storage.UI:600 |
| Bouton | « Ouvrir l emplacement » | « Ouvre le dossier de la base dans l explorateur, fichier selectionne. » | Core:6033 |
| Bouton | « Sauvegarder maintenant » | « Copie coherente de la base (sauvegarde SQLite a chaud) dans son dossier Backups. L original n est pas modifie. » | Core:6034 |
| Bouton | « Copier une sauvegarde vers... » | « Sauvegarde la base puis copie cette sauvegarde vers le fichier de votre choix (cle USB, partage...). » | Core:6035 |
| Ligne d'état | « Sauvegardes : <dossier> · derniere le <date> » ou « … · aucune pour l instant » | — | Storage.UI:605 |

- « Copier une sauvegarde vers... » ouvre une fenêtre d'enregistrement titrée « Copier une sauvegarde de la base », nom proposé `Domenia-AAAAMMJJ-HHmm.db`, type « Base SQLite (*.db) » (Storage.UI:621-623).
- Sauvegardes conservées : 7 par défaut (`LocalStore.DatabaseBackupCount`), délai 30 s (`BackupTimeoutSeconds`) (Storage.UI:629).
- Messages : « Sauvegarde de la base en cours... » (630), « Sauvegarde de la base enregistree : <fichier> » (636), « Sauvegarde de la base copiee : <fichier> » (635), « Sauvegarde de la base impossible : <motif> » (631, 641 ; motif possible « aucune base active a sauvegarder. », 628), « Aucune base active a afficher. » (611).
- Autres éléments de l'onglet (plutôt administrateur) : « Releve du parc », case « Releve manuel uniquement », « Lire le journal du controleur », « Oublier les releves », état « Aucun releve. » ; recherche locale « Rechercher » ; colonnes « Type », « Nom », « Identifiant », « UPN ou DNS », « Etat », « Association », « Score », « Correspondance », « Detail » (Core:6042-6075).

## 9. Messages fréquents (barre d'état ou fenêtre)

Erreurs d'opération (`Show-DomeniaOperationError`, Core:2069-2079) : message dans la barre d'état et fenêtre d'erreur se terminant par « Le detail technique a ete enregistre dans le journal Domenia. » (Core:2077). Texte = « <opération> : <explication> <suite> » (Core:2040) ou, à défaut :

| Fragment fixe | Source | Que faire (proposition) |
|---|---|---|
| « … : le compte utilise ne possede pas les droits necessaires. » | Core:2045 | prévenir l'administrateur |
| « … : les identifiants ont ete refuses. » | Core:2048 | vérifier le compte des opérations poste ; sinon prévenir l'administrateur |
| « … : le controleur de domaine ou le poste distant est indisponible. » | Core:2051 | vérifier que le poste est allumé et joignable (Ping) |
| « … : l'objet n'existe plus ou a ete deplace. Recharge les donnees. » | Core:2054 | relancer la recherche |
| « … : le delai d'attente a ete depasse. L'etat distant doit etre verifie avant de recommencer. » | Core:2063 | vérifier avant de relancer |
| « … a echoue. » | Core:2015 | ouvrir le journal ; prévenir l'administrateur |

Explications structurées (modules/Access.Model:129-138) : « Identifiants rejetes par la ressource. » / « Fournir un autre compte pour cette ressource. Aucun nouvel essai automatique. » ; « Compte verrouille, expire ou restreint. » ; « Droit refuse pour ce compte sur cette ressource. » / « Utiliser un compte autorise ou demander le droit manquant. » ; « Delai depasse : aucune reponse de la ressource. » / « Relire quand la ressource repond. Ce n est pas un rejet d identifiants. » ; « Ressource injoignable (reseau, nom ou service distant). » / « Verifier le nom, le reseau et le service distant, puis relire. » ; « Prerequis absent sur ce poste ou sur la cible. » ; « Issue inconnue apres envoi. » / « Verifier le resultat avant toute nouvelle action. Aucun rejeu. » ; « Erreur non classee. » / « Consulter le detail technique. ».

Autres messages fréquents :

| Message exact | Source | Situation |
|---|---|---|
| « Saisis au moins <n> caracteres, ou * pour un apercu. » | Core:9828 | recherche trop courte |
| « Recherche différée : écriture active ou à vérifier. » | Core:9804 | une écriture est en cours |
| « La liste affichée nʼest plus la recherche courante : relancez la recherche. » | modules/Live.UI:870 | « Charger la suite » sur une ancienne liste |
| « Desactive : mode lecture seule actif. » | Core:22460 | bouton d'écriture grisé |
| « Desactive : cette action modifie le poste distant et le mode lecture seule est actif. » | Core:22476 | GPUpdate / redémarrage grisés |
| « Hors ligne : relisez Active Directory avant toute modification. » | Core:16840 | action distante sur données hors ligne |
| « Selectionne une machine avant de lancer l inventaire. » | Core:12089 | inventaire sans poste |
| « Aucun resultat a exporter. » | Core:10660 | export vide |
| « En memoire uniquement : stockage local indisponible, rien n est enregistre. » | modules/Cache.Model:359 | stockage local en panne : prévenir l'administrateur |
| « En memoire uniquement : enregistrement suspendu apres des echecs. Reprise dans Fiabilite. » | modules/Cache.Model:360 | prévenir l'administrateur |
| « En memoire : <n> modification(s) a enregistrer. » / « Enregistre. » | modules/Cache.Model:363-364 | état normal |
| « Observation en memoire seulement : stockage local indisponible. » | modules/Park.UI:150 | relevé non enregistré |
| « Demande retiree : <motif> » | modules/Inline.UI:94 | confirmation remplacée ou périmée |

Quoi transmettre à l'administrateur (éléments existants) : « Copier le diagnostic » (connexion), « Copier » du journal de session, « Copier le rapport » (diagnostic poste), « Ouvrir le journal » (journal d'audit, sans mot de passe ni clé : infobulle Core:4456).

## 10. Écarts, points non vérifiés et pièges pour la rédaction

1. Aucun parcours n'a été joué : ni VM, ni capture regardée. Ordre visuel, libellés tronqués, états grisés et apparition des badges « Accès » / « Opérations » non vus à l'écran.
2. Le brief nomme la capture `fiche-poste` « onglet Poste » : cet onglet n'existe pas. C'est l'onglet « Machine » de la page « Assistance poste », dont la carte s'intitule « Fiche du poste » (Core:5418, 5441).
3. La tâche cite « Ouvrir le dossier, Sauvegarder, Copier une sauvegarde » : les boutons réels sont « Ouvrir l emplacement », « Sauvegarder maintenant », « Copier une sauvegarde vers... » (Core:6033-6035).
4. La tâche cite « Observateur » : le bouton de l'onglet Actions s'appelle « Journaux » (infobulle « Ouvre l Observateur d evenements sur ce poste. ») ; le menu clic droit dit « Observateur d evenements » (Core:5519, 12864).
5. Texte périmé dans l'onglet Actions : « Le partage C$ et le bureau a distance utilisent ta session Windows, pas le compte de connexion Active Directory. » (Core:5548) contredit le code d'« Ouvrir C$ » (ouverture avec le compte des opérations poste, Core:17015-17045). Le Bureau à distance utilise bien `mstsc` sans compte. Ne pas recopier cette phrase pour C$ ; signaler à l'administrateur / au développeur.
6. `dev/LIRE-MOI.md:19` mentionne « Détecter sur tout le parc » dans Relations : retiré dans le code (modules/Park.UI:33-34 ; Core:5281). LIRE-MOI est en retard.
7. Le brief annonce 52 requêtes WMI ; le catalogue compte 53 lignes (modules/Probes.Model:8-60).
8. Titre de confirmation pour « Detecter les utilisateurs » (Accueil) : par lecture du code, « Detecter sur les resultats affiches » (la cible OU est rangée en portée « Results », Park.UI:45, 52, 76) ; bouton de confirmation « Verifier les sessions » aussi pour « Analyser l OU (WMI) ». Non vu à l'écran.
9. État du bouton « Arreter » de l'Accueil : aucun code ne le grise (seul « Arrêter » de Rechercher est géré, Park.UI:21-25) ; non vérifié.
10. Visibilité de la colonne d'aide et du journal au démarrage, et repli automatique sous 940 unités de hauteur (modules/UX.UI:222-233) : non vus.
11. Le message d'erreur exact d'« Ouvrir C$ » dépend du classement (structuré ou textuel) : ne citer que les fragments fixes.
12. Mode Essentiel / Expert : Ctrl+L ou une route vers « Journal » bascule en Expert (Core:9415-9417) : à signaler si le guide cite Ctrl+L.
13. Les libellés sans accents du code (« Detecter », « Arreter », « Perimetre », « Choisir l OU... », « Pinger l OU », « Actualiser les requetes », « Par defaut ») doivent être cités tels quels.

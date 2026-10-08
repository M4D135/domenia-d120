# Fiche de faits : tableaux de bord, widgets et requêtes WMI (guide administrateur)

Domenia 1.0, dépôt `/Users/david/Documents/Projets/Domenia-D120`, branche `claude/epic-newton-j5ir1w` (dernier commit lu : `225d5a7`, lot 2026-10-08). Relevé du 08/10/2026, **uniquement dans le code** (aucun écran vu, VM non touchée).

Conventions :
- Chemins abrégés : `Boards.Model` = `dev/wad/modules/Domenia-Boards.Model.ps1`, `Widgets.UI` = `dev/wad/modules/Domenia-Widgets.UI.ps1`, `BoardComputer` = `dev/wad/modules/Domenia-BoardComputer.UI.ps1`, `BoardFleet` = `dev/wad/modules/Domenia-BoardFleet.Model.ps1`, `BoardSoftware` = `dev/wad/modules/Domenia-BoardSoftware.Model.ps1`, `Probes` = `dev/wad/modules/Domenia-Probes.Model.ps1`, `Charts.UI` = `dev/wad/modules/Domenia-Charts.UI.ps1`, `Dashboard.UI` = `dev/wad/modules/Domenia-Dashboard.UI.ps1`, `Park.UI` = `dev/wad/modules/Domenia-Park.UI.ps1`, `Park.Model` = `dev/wad/modules/Domenia-Park.Model.ps1`, `Live.Model` = `dev/wad/modules/Domenia-Live.Model.ps1`, `Engine.Worker` = `dev/wad/modules/Domenia-Engine.Worker.ps1`, `Core` = `dev/wad/Domenia-Core.ps1`.
- Les textes entre « » sont recopiés tels quels du code (souvent sans accents : « Memoire », « Representation »). Un message composé est donné avec ses fragments fixes et `<n>`, `<OU>`, `<poste>` à la place des valeurs.
- Les libellés des clés de tableau (titres, sections, descriptions) ont été extraits par script directement des lignes du catalogue, avec leur numéro de ligne.

## 1. Les trois tableaux de bord et leur place dans l'interface

L'essentiel : trois tableaux, tous faits de widgets (décision David 2026-10-07, `Boards.Model:1-4`, `Widgets.UI:1-5`). Chaque tuile ou graphique est un widget modifiable, redimensionnable, déplaçable et retirable ; on en ajoute depuis le catalogue intégré ou depuis les requêtes WMI prêtes à l'emploi (sauf tableau Logiciels).

| Tableau (code) | Où il apparaît (libellés exacts) | Panneau XAML | Données sources | Réf. |
|---|---|---|---|---|
| Fleet (parc) | Page « Accueil » (`TabDashboard`), carte « Vue d ensemble du parc », sous les boutons d'analyse | `PnlFleetDashboard` | Agrégats de la base autonome locale (action `FleetStats`) + observations en cache (présence, utilisateur console, relevé WMI léger, résultats de requêtes) | `Core:4353`, `Core:4427`, `Core:4447`, `Dashboard.UI:53-61`, `Engine.Worker:135-147` |
| Computer (poste) | Espace « Assistance poste » (`WsComputer`), onglet « Tableau de bord » ; titre « Tableau de bord du poste » ; boutons « Inventaire rapide » et « Inventaire complet » | `PnlComputerDashboard` | Lignes et mesures du dernier inventaire du poste (CIM) + attributs du compte ordinateur lus avec la fiche ; aucune nouvelle requête au poste | `Core:5490-5505`, `modules/Domenia-UX.UI.ps1:168`, `BoardComputer:1-3` |
| Software (logiciels) | Espace « Assistance poste », onglet « Logiciels », après « Charger les logiciels », dans l'extenseur « Synthese en graphiques » | `PnlSoftwareDashboard` | Liste de logiciels lue par le worker logiciels (Name, Publisher, Version, Architecture, Scope, SizeKb) | `Core:5697-5716`, `BoardSoftware:1-9`, `Dashboard.UI:129-140` |

Textes d'en-tête et d'état :
- Accueil : texte initial « Calculee depuis la base autonome locale. Pour un parc complet : Outils, Base autonome, Mettre a jour tout. » (`Core:4428`) ; pendant le calcul « Calcul de la vue d ensemble depuis la base locale... » (`Dashboard.UI:60`) ; échec « Vue d ensemble non calculee : » + « base occupee, reessayez dans un instant. » ou « reponse incomplete. » (`Dashboard.UI:64`, `:104-105`, `BoardFleet:22-26`) ; sans base « Aucune base autonome active : vue d ensemble indisponible. » (`Dashboard.UI:57`) ; résumé après calcul « Base autonome locale et derniers releves : <n> postes actifs dans le perimetre, calcul du <date>. Parc incomplet ? Outils, Base autonome, Mettre a jour tout. » (`BoardFleet:234`).
- Poste : « Lancez un inventaire (Rapide ou Complet) : le tableau de bord se remplit avec ses resultats. » (`Core:5495`, `BoardComputer:362`) ; après inventaire « Tableau de bord de l inventaire du <date>. » suivi de « Donnees lues par CIM, sans nouvelle requete. L inventaire complet ajoute correctifs, processus et evenements. » ou « Mesures chiffrees indisponibles (inventaire par tache distante) : seules les tuiles sont remplies. » (`BoardComputer:358-363`). Info-bulle de l'onglet : « Synthese graphique du dernier inventaire du poste : disques, memoire, correctifs et etat. Aucune requete supplementaire. » (`Core:5490`). Bouton « Inventaire rapide » : « Lit l inventaire du poste (CIM) puis remplit ce tableau de bord. » ; « Inventaire complet » : « Inventaire complet, plus long : ajoute correctifs, evenements et details. » (`Core:5497-5498`).
- Logiciels : « Chargez les logiciels pour afficher la synthese. » (`Core:5713`) ; « Aucun logiciel lu. » (`Dashboard.UI:134`, `BoardSoftware:57`) ; « <n> logiciels lus. Synthese calculee sur la liste chargee. » (« logiciel lu. » au singulier) (`BoardSoftware:158-160`).
- Changement d'objet sélectionné : les tableaux Poste et Logiciels oublient leurs données et leur « Annuler » ; le tableau Poste affiche « Lancez un inventaire rapide ou complet : chaque widget se remplit avec ses resultats. » (`Dashboard.UI:4-13`).

## 2. Catalogue intégré des widgets

Format du catalogue : une ligne par widget `Clé|Section|Titre|Nature|Représentation|Taille|Description` (`Boards.Model:6-80`, lecture `Boards.Model:82-99`). L'ordre du catalogue est l'ordre de la disposition livrée (`Boards.Model:257-260`, identifiants `b-<clé>`). Totaux : 42 widgets Poste, 17 widgets Parc, 8 widgets Logiciels (67 au total).

### 2.1 Tableau du poste (Computer), 42 widgets

| Clé | Section | Titre (libellé exact) | Nature | Représentation par défaut | Taille | Description (texte exact) | Réf. |
|---|---|---|---|---|---|---|---|
| `computer.health` | Vue d ensemble | Etat general | Health | Health (Score) | S (Compacte) | Score calcule a partir des points d attention | Boards.Model.ps1:8 |
| `computer.attention` | Vue d ensemble | Points d attention | List | List (Liste de points) | L (Large) | Problemes detectes, du plus grave au moins grave | Boards.Model.ps1:9 |
| `computer.os` | Identite du poste | Systeme | Value | Kpi (Chiffre cle) | S (Compacte) | Version commerciale de Windows et build | Boards.Model.ps1:10 |
| `computer.model` | Identite du poste | Modele | Value | Kpi (Chiffre cle) | S (Compacte) | Fabricant, modele et numero de serie | Boards.Model.ps1:11 |
| `computer.cpu` | Identite du poste | Processeur | Value | Kpi (Chiffre cle) | S (Compacte) | Modele, coeurs et threads | Boards.Model.ps1:12 |
| `computer.memory` | Identite du poste | Memoire installee | Value | Kpi (Chiffre cle) | S (Compacte) | Memoire physique et barrettes | Boards.Model.ps1:13 |
| `computer.uptime` | Identite du poste | En service depuis | Value | Kpi (Chiffre cle) | S (Compacte) | Duree depuis le dernier demarrage | Boards.Model.ps1:14 |
| `computer.user` | Identite du poste | Utilisateur connecte | Value | Kpi (Chiffre cle) | S (Compacte) | Session console au moment de l inventaire | Boards.Model.ps1:15 |
| `computer.ip` | Identite du poste | Adresse IP | Value | Kpi (Chiffre cle) | S (Compacte) | Adresse IPv4 et passerelle | Boards.Model.ps1:16 |
| `computer.domain` | Identite du poste | Domaine | Value | Kpi (Chiffre cle) | S (Compacte) | Domaine et role du poste | Boards.Model.ps1:17 |
| `computer.ad.password` | Compte machine dans Active Directory | Mot de passe machine | Value | Kpi (Chiffre cle) | S (Compacte) | Age du mot de passe du compte ordinateur | Boards.Model.ps1:18 |
| `computer.ad.lastlogon` | Compte machine dans Active Directory | Derniere connexion au domaine | Value | Kpi (Chiffre cle) | S (Compacte) | Attribut lastLogonTimestamp | Boards.Model.ps1:19 |
| `computer.ad.account` | Compte machine dans Active Directory | Compte ordinateur | Value | Kpi (Chiffre cle) | S (Compacte) | Actif ou desactive, date de creation | Boards.Model.ps1:20 |
| `computer.ad.ou` | Compte machine dans Active Directory | Unite d organisation | Value | Kpi (Chiffre cle) | S (Compacte) | OU qui contient le poste | Boards.Model.ps1:21 |
| `computer.ad.laps` | Compte machine dans Active Directory | Mot de passe LAPS | Value | Kpi (Chiffre cle) | S (Compacte) | Expiration du mot de passe administrateur local | Boards.Model.ps1:22 |
| `computer.ad.managedby` | Compte machine dans Active Directory | Gere par | Value | Kpi (Chiffre cle) | S (Compacte) | Attribut managedBy | Boards.Model.ps1:23 |
| `computer.ad.clock` | Compte machine dans Active Directory | Horloge du poste | Value | Kpi (Chiffre cle) | S (Compacte) | Ecart avec le poste d administration | Boards.Model.ps1:24 |
| `computer.memory.usage` | Ressources | Memoire utilisee | Number | Gauge (Jauge) | S (Compacte) | Memoire occupee au moment de l inventaire | Boards.Model.ps1:25 |
| `computer.cpu.load` | Ressources | Charge du processeur | Number | Gauge (Jauge) | S (Compacte) | Charge du processeur au moment de l inventaire | Boards.Model.ps1:26 |
| `computer.battery` | Ressources | Batterie | Number | Gauge (Jauge) | S (Compacte) | Charge restante des postes portables | Boards.Model.ps1:27 |
| `computer.disk.system` | Ressources | Disque systeme | Distribution | Pie (Anneau) | M (Moyenne) | Espace utilise et libre sur C: | Boards.Model.ps1:28 |
| `computer.disk.volumes` | Ressources | Autres volumes | Distribution | Bar (Barres) | M (Moyenne) | Espace libre des autres volumes, en pourcentage | Boards.Model.ps1:29 |
| `computer.services` | Activite | Services Windows | Distribution | Pie (Anneau) | M (Moyenne) | Services en cours, arretes et desactives | Boards.Model.ps1:30 |
| `computer.processes` | Activite | Processus les plus gourmands | Distribution | Bar (Barres) | L (Large) | Memoire utilisee par processus, en Mo | Boards.Model.ps1:31 |
| `computer.events` | Activite | Erreurs systeme par source | Distribution | Bar (Barres) | M (Moyenne) | Journal Systeme des 3 derniers jours | Boards.Model.ps1:32 |
| `computer.antivirus` | Securite et etat | Antivirus | Value | Kpi (Chiffre cle) | S (Compacte) | Produit antivirus declare a Windows | Boards.Model.ps1:33 |
| `computer.firewall` | Securite et etat | Pare-feu | Value | Kpi (Chiffre cle) | S (Compacte) | Profils du pare-feu actifs | Boards.Model.ps1:34 |
| `computer.bitlocker` | Securite et etat | BitLocker | Value | Kpi (Chiffre cle) | S (Compacte) | Protection du volume systeme | Boards.Model.ps1:35 |
| `computer.wsus` | Securite et etat | Windows Update | Value | Kpi (Chiffre cle) | S (Compacte) | Serveur WSUS configure | Boards.Model.ps1:36 |
| `computer.reboot` | Securite et etat | Redemarrage en attente | Value | Kpi (Chiffre cle) | S (Compacte) | Redemarrage demande par une installation | Boards.Model.ps1:37 |
| `computer.services.stopped` | Securite et etat | Services automatiques arretes | Value | Kpi (Chiffre cle) | S (Compacte) | Services automatiques a l arret | Boards.Model.ps1:38 |
| `computer.devices` | Securite et etat | Peripheriques en erreur | Value | Kpi (Chiffre cle) | S (Compacte) | Peripheriques signales en erreur | Boards.Model.ps1:39 |
| `computer.drivers` | Securite et etat | Pilotes non signes | Value | Kpi (Chiffre cle) | S (Compacte) | Pilotes sans signature numerique | Boards.Model.ps1:40 |
| `computer.admins` | Securite et etat | Administrateurs locaux | Value | Kpi (Chiffre cle) | S (Compacte) | Membres du groupe Administrateurs | Boards.Model.ps1:41 |
| `computer.sessions` | Securite et etat | Sessions et comptes locaux | Value | Kpi (Chiffre cle) | S (Compacte) | Comptes et sessions du poste | Boards.Model.ps1:42 |
| `computer.autostart` | Securite et etat | Demarrage automatique | Value | Kpi (Chiffre cle) | S (Compacte) | Programmes lances au demarrage | Boards.Model.ps1:43 |
| `computer.shares` | Securite et etat | Partages | Value | Kpi (Chiffre cle) | S (Compacte) | Dossiers partages par le poste | Boards.Model.ps1:44 |
| `computer.printers` | Securite et etat | Imprimantes | Value | Kpi (Chiffre cle) | S (Compacte) | Imprimantes installees | Boards.Model.ps1:45 |
| `computer.display` | Securite et etat | Affichage | Value | Kpi (Chiffre cle) | S (Compacte) | Carte graphique et resolution | Boards.Model.ps1:46 |
| `computer.physicaldisk` | Securite et etat | Disque physique | Value | Kpi (Chiffre cle) | S (Compacte) | Modele et interface du disque | Boards.Model.ps1:47 |
| `computer.certificates` | Securite et etat | Certificats machine | Value | Kpi (Chiffre cle) | S (Compacte) | Certificats du magasin ordinateur | Boards.Model.ps1:48 |
| `computer.hotfix` | Securite et etat | Dernier correctif | Value | Kpi (Chiffre cle) | S (Compacte) | Date du dernier correctif installe | Boards.Model.ps1:49 |

### 2.2 Tableau du parc (Fleet), 17 widgets

| Clé | Section | Titre (libellé exact) | Nature | Représentation par défaut | Taille | Description (texte exact) | Réf. |
|---|---|---|---|---|---|---|---|
| `fleet.health` | Vue d ensemble | Etat du parc | Health | Health (Score) | S (Compacte) | Score calcule a partir des points d attention | Boards.Model.ps1:52 |
| `fleet.attention` | Vue d ensemble | Points d attention | List | List (Liste de points) | L (Large) | Problemes detectes sur le perimetre | Boards.Model.ps1:53 |
| `fleet.machines` | Inventaire du perimetre | Postes actifs | Value | Kpi (Chiffre cle) | S (Compacte) | Comptes ordinateur actifs du perimetre | Boards.Model.ps1:54 |
| `fleet.stale` | Inventaire du perimetre | Postes inactifs (90 j et plus) | Value | Kpi (Chiffre cle) | S (Compacte) | Sans connexion au domaine depuis 90 jours | Boards.Model.ps1:55 |
| `fleet.win10` | Inventaire du perimetre | Postes sous Windows 10 | Value | Kpi (Chiffre cle) | S (Compacte) | Fin de support le 14/10/2025 | Boards.Model.ps1:56 |
| `fleet.users` | Inventaire du perimetre | Utilisateurs detectes | Value | Kpi (Chiffre cle) | S (Compacte) | Utilisateurs vus sur les postes | Boards.Model.ps1:57 |
| `fleet.lastcheck` | Inventaire du perimetre | Derniere analyse | Value | Kpi (Chiffre cle) | S (Compacte) | Date du dernier releve des postes | Boards.Model.ps1:58 |
| `fleet.os` | Repartition | Systemes d exploitation | Distribution | Pie (Anneau) | M (Moyenne) | Systemes declares dans l annuaire | Boards.Model.ps1:59 |
| `fleet.lastlogon` | Repartition | Derniere connexion au domaine | Series | Column (Histogramme) | M (Moyenne) | Anciennete de la derniere connexion | Boards.Model.ps1:60 |
| `fleet.ou` | Repartition | Postes par unite d organisation | Distribution | Bar (Barres) | M (Moyenne) | Postes par OU ou sous-OU | Boards.Model.ps1:61 |
| `fleet.presence` | Repartition | Presence reseau | Distribution | Pie (Anneau) | M (Moyenne) | Resultat des derniers releves | Boards.Model.ps1:62 |
| `fleet.models` | Releves WMI | Modeles | Distribution | Bar (Barres) | M (Moyenne) | Modeles des postes analyses | Boards.Model.ps1:63 |
| `fleet.releases` | Releves WMI | Versions de Windows | Distribution | Pie (Anneau) | M (Moyenne) | Versions commerciales relevees | Boards.Model.ps1:64 |
| `fleet.ram` | Releves WMI | Memoire installee | Series | Column (Histogramme) | M (Moyenne) | Postes par quantite de memoire | Boards.Model.ps1:65 |
| `fleet.diskfree` | Releves WMI | Espace libre sur C: | Series | Column (Histogramme) | M (Moyenne) | Postes par espace libre du disque systeme | Boards.Model.ps1:66 |
| `fleet.lowdisk` | Releves WMI | Disque C: presque plein | Value | Kpi (Chiffre cle) | S (Compacte) | Postes avec moins de 10 % libre | Boards.Model.ps1:67 |
| `fleet.uptime` | Releves WMI | Non redemarres depuis 30 j | Value | Kpi (Chiffre cle) | S (Compacte) | Postes a redemarrer | Boards.Model.ps1:68 |

### 2.3 Tableau des logiciels (Software), 8 widgets

| Clé | Section | Titre (libellé exact) | Nature | Représentation par défaut | Taille | Description (texte exact) | Réf. |
|---|---|---|---|---|---|---|---|
| `software.count` | Synthese | Logiciels | Value | Kpi (Chiffre cle) | S (Compacte) | Nombre de logiciels et d editeurs | Boards.Model.ps1:71 |
| `software.size` | Synthese | Taille declaree | Value | Kpi (Chiffre cle) | S (Compacte) | Somme des tailles connues | Boards.Model.ps1:72 |
| `software.multiversion` | Synthese | Installes en plusieurs versions | Value | Kpi (Chiffre cle) | S (Compacte) | Logiciels presents en plusieurs versions | Boards.Model.ps1:73 |
| `software.nopublisher` | Synthese | Sans editeur declare | Value | Kpi (Chiffre cle) | S (Compacte) | Logiciels sans editeur renseigne | Boards.Model.ps1:74 |
| `software.publishers` | Repartition | Editeurs | Distribution | Pie (Anneau) | M (Moyenne) | Principaux editeurs | Boards.Model.ps1:75 |
| `software.architecture` | Repartition | Architecture | Distribution | Pie (Anneau) | M (Moyenne) | Logiciels 32 et 64 bits | Boards.Model.ps1:76 |
| `software.scope` | Repartition | Portee d installation | Distribution | Pie (Anneau) | M (Moyenne) | Installation machine ou utilisateur | Boards.Model.ps1:77 |
| `software.largest` | Repartition | Plus gros logiciels | Distribution | Bar (Barres) | L (Large) | Taille declaree, en Mo | Boards.Model.ps1:78 |

Remarque : le fournisseur Logiciels calcule aussi `software.health` et `software.attention` (fonction commune `Complete-DomeniaBoardData`, `Boards.Model:181-193`, appelée en `BoardSoftware:59` et `:161`), mais ces clés ne sont pas dans le catalogue Logiciels : elles ne s'affichent jamais (une clé hors catalogue est écartée, `Boards.Model:292-293`). Aucun point d'attention n'est émis par le fournisseur Logiciels.

### 2.4 Sous-titres des sections (texte exact)

Source : `Widgets.UI:137-154`.

| Section | Sous-titre affiché |
|---|---|
| Vue d ensemble | Etat general et points a verifier |
| Identite du poste | Materiel, systeme et session |
| Compte machine dans Active Directory | Attributs lus dans l annuaire avec la fiche |
| Ressources | Mesurees pendant l inventaire |
| Activite | Services, processus et journal Systeme |
| Securite et etat | Protection, correctifs et configuration |
| Inventaire du perimetre | Base autonome locale |
| Repartition (Parc) | Systemes, activite et unites d organisation |
| Repartition (Logiciels) | Editeurs, architecture, portee et taille |
| Releves WMI | Derniere analyse de l OU |
| Synthese | Calculee sur la liste chargee |

Une section créée par l'utilisateur ou une catégorie de requête (par exemple « Materiel ») n'a pas de sous-titre.

### 2.5 Textes d'aide des sections vides (texte exact)

Une section sans widget rempli mais avec une aide affiche ce texte (`Widgets.UI:97-105`).

| Tableau | Section | Texte | Réf. |
|---|---|---|---|
| Poste | Identite du poste | Lancez un inventaire (Rapide ou Complet) pour remplir cette section. | `BoardComputer:348` |
| Poste | Compte machine dans Active Directory | Ouvrez la fiche du poste dans l annuaire pour lire son compte machine. | `BoardComputer:349` |
| Poste | Ressources | « Mesures chiffrees indisponibles (inventaire par tache distante). » ou « Aucune mesure relevee pendant cet inventaire. » ou « Lancez un inventaire pour mesurer la memoire, le processeur et les disques. » | `BoardComputer:350` |
| Poste | Activite | Inventaire complet requis : correctifs, processus et evenements. | `BoardComputer:351` |
| Poste | Securite et etat | Inventaire complet requis : protection, correctifs et configuration. | `BoardComputer:352` |
| Parc | Repartition | Aucun poste actif indexe dans ce perimetre : mettez a jour la base autonome (Outils, Base autonome, Mettre a jour tout). | `BoardFleet:170` |
| Parc | Releves WMI | Avec une OU : « Analysez l OU (WMI) pour remplir cette section : modeles, memoire, disques, versions et demarrages. » ; sans OU : « Choisissez une OU puis analysez-la (WMI) pour remplir cette section : modeles, memoire, disques, versions et demarrages. » | `BoardFleet:175` |
| Logiciels | Synthese et Repartition | Aucun logiciel lu : chargez les logiciels du poste pour remplir cette section. | `BoardSoftware:58` |

## 3. Natures de données, représentations et tailles

### 3.1 Natures (contrat de données)

Contrat `New-DomeniaBoardEntry` (`Boards.Model:137-155`) : Value = un texte ; Number = une mesure avec maximum facultatif (jauge) ; Distribution = parts d'un tout ; Measure = valeurs numériques regroupées en tranches ; Series = tranches ordonnées ; List = lignes Niveau/Texte ; Health = score. États possibles d'une entrée : vide, Ok, Warn, Alert, Off (`Boards.Model:146`).

### 3.2 Représentations permises par nature (`Get-DomeniaBoardVisuals`, `Boards.Model:201-214`)

Noms affichés (`Get-DomeniaBoardVisualNames`, `Boards.Model:198-200`) : Kpi « Chiffre cle », Gauge « Jauge », Pie « Anneau », Bar « Barres », Column « Histogramme », Line « Courbe », Text « Liste », List « Liste de points », Health « Score ».

| Nature | Représentations permises (la première est la préférée) | Texte d'explication de l'éditeur (`Widgets.UI:732`) |
|---|---|---|
| Value | Chiffre cle, Liste | Information textuelle : chiffre cle ou liste. |
| Number avec maximum | Jauge, Chiffre cle, Liste | Mesure : jauge, chiffre cle ou liste. |
| Number sans maximum | Chiffre cle, Liste | (même texte) |
| Distribution | Anneau, Barres, Histogramme, Liste, Chiffre cle | Repartition : anneau, barres, histogramme, liste ou chiffre cle. |
| Measure | Histogramme, Barres, Courbe, Chiffre cle, Liste | Valeurs numeriques : histogramme, barres, courbe, chiffre cle ou liste. |
| Series | Histogramme, Courbe, Barres, Liste, Chiffre cle | Serie ordonnee : histogramme, courbe, barres, liste ou chiffre cle. |
| List | Liste de points | Liste de points a verifier. |
| Health | Score, Chiffre cle | Score de sante : anneau ou chiffre cle. |
| autre | Chiffre cle, Liste | (aucun) |

Règle de correction : une représentation enregistrée qui n'est plus permise est remplacée par la préférée (`Resolve-DomeniaBoardVisual`, `Boards.Model:215-221`). Le sous-menu « Representation » n'apparaît que si plus d'une représentation est permise (`Widgets.UI:417`).

Les trois widgets Number du poste ont tous un maximum : « Memoire utilisee » (maximum = mémoire totale en Go), « Charge du processeur » (100), « Batterie » (100, sens inversé `LowIsBad`) (`BoardComputer:177`, `:181`, `:187`).

À noter : `Probes` définit aussi `Get-DomeniaProbeVisuals` (`Probes:72-81`), exporté mais **non utilisé** par l'interface ; l'éditeur et le menu utilisent `Get-DomeniaBoardVisuals` avec la nature calculée par `Get-DomeniaProbeKind` (`Widgets.UI:416`, `:752`, `Boards.Model:399-408`).

### 3.3 Tailles (`Get-DomeniaBoardSize`, `Boards.Model:222-243`)

Noms : S « Compacte », M « Moyenne », L « Large » (`Boards.Model:223`). Valeurs en pixels : largeur × hauteur ; « auto » = la carte s'ajuste à son contenu avec la hauteur minimale indiquée.

| Représentation | Compacte (S) | Moyenne (M) | Large (L) |
|---|---|---|---|
| Kpi (Chiffre cle) | 230 × 118 | 345 × 118 | 475 × 118 |
| Text (Liste) | 300 × auto, min 118 | 420 × auto, min 250 | 560 × auto, min 250 |
| Pie (Anneau) | 310 × 250 | 390 × 250 | 490 × 250 |
| Bar, Column, Line | 320 × 250 | 440 × 250 | 600 × 250 |
| Gauge (Jauge) | 230 × 250 | 300 × 250 | 380 × 250 |
| List (Liste de points) | 380 × auto, min 250 | 500 × auto, min 250 | 660 × auto, min 250 |
| Health (Score) | 230 × 250 | 300 × 250 | 380 × 250 |

Compléments :
- Taille absente ou invalide : taille du catalogue, sinon Compacte pour un Chiffre cle et Moyenne pour le reste (`Boards.Model:306`, éditeur `Widgets.UI:755`). Une représentation inconnue prend le tableau Kpi ; une taille inconnue prend M (`Boards.Model:240-241`).
- Une Liste d'une donnée Value a une hauteur minimale ramenée à 118 au plus (`Widgets.UI:360`).
- Dans une section qui mélange cartes hautes et tuiles compactes (hauteur < 140), les tuiles sont empilées deux par deux pour s'aligner sur les cartes de 250 (`Widgets.UI:262-298`, commentaire `Boards.Model:226-227`).
- Limites de rendu : un anneau montre 8 parts au plus (les plus petites regroupées en « Autres ») (`Charts.UI:487-493`) ; la carte des points d'attention affiche 9 lignes au plus puis « et <n> autre(s) point(s) » (`Charts.UI:384`, `:427`) ; une Liste affiche 10 lignes au plus puis « et <n> autre(s) » (`Charts.UI:951`, `:980`) ; les barres sont limitées au nombre de lignes qui tiennent dans la hauteur (26 px par ligne) (`Charts.UI:677-680`).
- Jauge : passe à l'orange au-delà de 80 % et au rouge au-delà de 90 %, sens inversé pour la batterie (orange sous 20 %, rouge sous 10 %) (`Charts.UI:607`, `:635-636`).
- Chiffre cle sans valeur : « Non lu » (`Widgets.UI:365`). Widget sans donnée affiché en personnalisation : carte vide « Aucune donnee pour le moment » (`Widgets.UI:447`, `Charts.UI:321`).

## 4. Disposition : stockage, réinitialisation, annulation

### 4.1 Stockage

- Clé de réglage par tableau : `Dashboard.Computer.Layout`, `Dashboard.Fleet.Layout`, `Dashboard.Software.Layout` ; valeur = tableau JSON compact d'éléments `{Id, Source, Key, Visual, Title, Size, Group}` (`Widgets.UI:36-42`, `Boards.Model:246`, `:311-316`).
- `Source` vaut `Builtin` (catalogue intégré) ou `Probe` (requête WMI) (`Boards.Model:253`). `Title` vide = titre par défaut (nom du catalogue ou de la requête) ; l'éditeur enregistre un titre vide quand on garde le nom par défaut (`Widgets.UI:781`).
- Réglages enregistrés dans le fichier `Domenia.settings.json` du sous-dossier `Preferences` du dossier de données (`Core:2797-2808`, `Core:2991`), écriture atomique avec copie `.bak` (`Core:2866`), différée de 1,5 s pour regrouper les changements (`Core:2969-2985`). Seules les clés listées dans `Get-DomeniaDefaultSettings` survivent au rechargement ; les six clés des tableaux y figurent (`Core:2919-2925`, lecture `Core:2937-2943`). L'emplacement exact du dossier de données n'est pas établi dans cette fiche.
- Ancien format : `Widgets.Computer` et `Widgets.Fleet` (widgets de requêtes de la première version). Lus seulement si `Dashboard.<Tableau>.Layout` est vide, fusionnés dans la disposition (section = catégorie de la requête, sinon « Requetes » ; identifiant `p-<ancien id>`), puis vidés au premier enregistrement (`Widgets.UI:14-24`, `:39`, `:50-55`, `Boards.Model:261-283`).
- Nettoyage à la lecture : widget intégré inconnu du catalogue écarté ; requête inconnue écartée (quand le catalogue est fourni) ; identifiants rendus uniques ; représentation et taille corrigées (`Boards.Model:261-310`).
- Rien d'enregistré : disposition livrée. Une liste vide enregistrée (`[]`) est un tableau vidé volontairement et reste vide (`Boards.Model:273-274`).
- Un changement qui ne change rien n'est ni enregistré ni proposé à l'annulation (`Widgets.UI:49-51`). Les réglages comparent la casse (`Core:3014-3015`).
- Périmètre du tableau du parc : réglage `FleetScopeDn` (DN de l'OU de départ, vide = tout le domaine indexé), mémorisé entre les sessions (`Dashboard.UI:66-80`, `Core:2920`).

### 4.2 Réinitialisation et annulation

- « Par defaut » (visible en personnalisation) : info-bulle « Revient a la disposition livree (annulable). » ; applique la disposition livrée (`Widgets.UI:200`, `:558`).
- Annulation à un seul niveau : la barre affiche le texte de la dernière opération suivi d'un point, puis le bouton « Annuler » (info-bulle « Revient a la disposition precedente. ») (`Widgets.UI:210-214`, `:551-557`). Textes d'opération : « Widget deplace », « Widget retire », « Representation changee », « Taille changee », « Widget modifie », « Widget ajoute », « Disposition par defaut appliquee » (`Widgets.UI:534`, `:558`, `:562-565`, `:785`, `:789`).
- L'annulation est perdue quand de nouvelles données arrivent (`Widgets.UI:76`) et, pour Poste et Logiciels, quand on sélectionne un autre objet (`Dashboard.UI:7`). « Annuler » lui-même ne se ré-annule pas (`Widgets.UI:52`, `:554`).
- « Retirer » n'a pas de confirmation : l'annulation sert de filet (`Widgets.UI:562`).
- Widget ajouté sans donnée encore lue : message « Widget enregistre : il s affichera des que ses donnees seront lues. » (`Widgets.UI:59-64`).

## 5. Barre d'outils, mode Personnaliser, menu clic droit, glisser-déposer

### 5.1 Barre d'outils de chaque tableau (`Widgets.UI:185-223`)

| Bouton (libellé exact) | Quand | Info-bulle exacte | Réf. |
|---|---|---|---|
| Actualiser les requetes | Tableaux Poste et Parc, s'il y a au moins un widget de requête | Execute les requetes WMI des widgets (lecture seule) sur le perimetre, avec confirmation. | `Widgets.UI:196-197` |
| Ajouter un widget | Toujours | Choisir une information du tableau de bord ou une requete prete a l emploi. | `Widgets.UI:198` |
| Personnaliser | Hors personnalisation | Deplacer, redimensionner, modifier ou retirer les widgets. | `Widgets.UI:203` |
| Par defaut | En personnalisation | Revient a la disposition livree (annulable). | `Widgets.UI:200` |
| Terminer | En personnalisation | Quitte la personnalisation. | `Widgets.UI:201` |
| Annuler | Après une modification de disposition | Revient a la disposition precedente. | `Widgets.UI:212` |

### 5.2 Mode Personnaliser

- Bascule par « Personnaliser » / « Terminer » ; redessin sans animation d'entrée (`Widgets.UI:549`).
- Texte d'aide à gauche : « Glissez un widget pour le deplacer ; clic droit pour sa representation, sa taille ou sa place. » (`Widgets.UI:217-218`).
- Chaque section reçoit à sa fin une tuile en pointillés « Ajouter ici » (bouton accessible au clavier ; info-bulle « Ajouter un widget dans la section <section>. ») qui ouvre l'éditeur avec cette section présélectionnée (`Widgets.UI:224-261`, `:99`).
- Les deux boutons ronds de chaque widget restent visibles : « Modifier : <titre> » et « Retirer : <titre> » (`Widgets.UI:469-471`). Hors personnalisation, ils n'apparaissent qu'au survol ou au focus clavier (`Widgets.UI:475-478`).
- Les widgets sans donnée restent visibles (carte « Aucune donnee pour le moment ») ; hors personnalisation, un widget intégré sans donnée est masqué (`Widgets.UI:440`, `:447`).
- Tableau sans aucun widget : titre « Aucun widget », texte « Tous les widgets ont ete retires. Ajoutez-en un, ou revenez a la disposition par defaut avec Personnaliser. » ; widgets présents mais vides : « Pas encore de donnees » avec « Les widgets se remplissent apres la premiere lecture. » ou le texte d'attente du tableau (`Widgets.UI:113-119`).
- Après une action, le focus clavier revient sur le bouton correspondant du tableau redessiné (`Widgets.UI:542-577`).

### 5.3 Menu clic droit d'un widget (`New-DomeniaBoardMenu`, `Widgets.UI:400-435`)

Disponible sur chaque widget, en personnalisation ou non (`Widgets.UI:474`).
- « Modifier... » (ouvre l'éditeur) (`:414`)
- « Representation » > noms des représentations permises, la courante cochée (`:415-421`)
- « Taille » > « Compacte », « Moyenne », « Large », la courante cochée (`:422-425`)
- « Deplacer » > « Au debut de la section », « Vers la gauche », « Vers la droite », « A la fin de la section » (`:426-431`)
- séparateur, puis « Retirer du tableau de bord » (`:432-433`)

Les déplacements du menu restent dans la section du widget (`Boards.Model:385-393`).

### 5.4 Glisser-déposer

- Actif en permanence (pas seulement en personnalisation) : le glisser démarre après 8 px de mouvement bouton gauche enfoncé ; le widget glissé passe en semi-transparence (`Widgets.UI:479-492`).
- Lâché sur un autre widget : il prend sa place et sa section (après lui si on glisse vers l'avant, avant lui si on glisse vers l'arrière) ; une barre bleue verticale marque la cible (`Widgets.UI:493-501`, `Boards.Model:356-375`).
- Lâché dans une section hors d'un widget : il va à la fin de cette section (même section ou autre) (`Widgets.UI:87-91`, `:528-533`).
- Défilement automatique de la page près du bord haut ou bas (48 px) pendant le glisser (`Widgets.UI:504-513`).
- Le déplacement est appliqué après la fin du glisser, puis enregistré avec l'annulation « Widget deplace » (`Widgets.UI:514-535`).

## 6. Éditeur « Ajouter un widget » / « Modifier le widget »

Source : `Show-DomeniaBoardEditor`, `Widgets.UI:611-813`. Fenêtre intégrée de 900 × 640.
- Titre de fenêtre : « Ajouter un widget » ou « Modifier le widget » (`:625`).
- Colonne gauche (ajout seulement, masquée en modification) : champ de recherche (nom accessible « Rechercher une information », indication « Rechercher : disque, utilisateur, BitLocker... ») et liste « Informations disponibles » (`:636-678`).
- Groupes de la liste : « Tableau de bord · <section> » pour le catalogue intégré, puis « Requetes WMI · <catégorie> » pour les requêtes (Poste et Parc seulement ; jamais sur Logiciels) (`:582-601`). Chaque ligne : nom en gras, description (pour une requête : « <Classe> (<espace de noms>) »), badge « affiche » si l'information est déjà sur le tableau (lecteur d'écran : « , deja affiche ») (`:589`, `:595`, `:599`).
- Recherche sans accents ni casse ; tous les mots tapés doivent être présents (nom, description, section ; pour une requête : nom, catégorie, classe) (`:762-766`, `Boards.Model:447-454`).
- Colonne droite : champs « Titre », « Representation », « Taille », « Section » (noms accessibles « Titre du widget », « Representation », « Taille », « Section »), texte de nature (tableau 3.2), puis « Apercu » (cadre de 320 px de haut) (`:681-716`). La liste « Section » est modifiable : on peut taper une nouvelle section ; elle propose les sections présentes et celles du catalogue (`:694-696`).
- Boutons : « Annuler » (info-bulle « Ferme sans rien changer. ») et « Ajouter » (« Ajoute le widget choisi au tableau de bord. ») ou « Enregistrer » (« Enregistre les changements de ce widget. ») ; « Ajouter » est grisé tant que rien n'est choisi (`:718-729`). Liste filtrée sans sélection : « Choisissez une information dans la liste. » (`:770-773`).
- Section vide à l'enregistrement : « Mes widgets » (`:782`). Nouveau widget ajouté à la fin de sa section, ou en fin de tableau si la section est nouvelle (`Boards.Model:326-339`). Changer la section d'un widget l'envoie à la fin de la nouvelle section (`Boards.Model:344-354`).
- Aperçu en direct : données réelles si le tableau en a, sinon exemple de même nature (libellés « Exemple A », « Exemple B », « Exemple C », « Apercu », « Apercu : la valeur reelle apparait apres lecture ») (`:602-610`, `Boards.Model:455-468`).
- À l'ouverture en ajout : première information non encore affichée (de la section demandée) présélectionnée, focus dans la recherche ; en modification : focus dans « Titre » (`:796-811`).

## 7. Score de santé et points d'attention

### 7.1 Formule (`Get-DomeniaBoardHealth`, `Boards.Model:171-180`)

- Score = 100 − 25 × (points critiques « Alert ») − 10 × (points « Warn »), jamais sous 0. Les lignes d'information (« Info ») ne comptent pas.
- Verdict : au moins un point critique → « Critique » ; sinon score ≥ 85 → « Bon etat » ; score ≥ 60 → « A surveiller » ; sinon « Degrade ».
- Couleur d'état : rouge (Alert) si un point critique ou score < 60 ; orange (Warn) s'il y a des points à surveiller ; vert (Ok) sinon.
- Conséquences : 1 point à surveiller = 90 « Bon etat » ; 2 à 4 = 80 à 60 « A surveiller » ; 5 ou plus sans critique = 50 ou moins « Degrade » ; 1 critique = 75 « Critique ».
- Détail du widget de score : « <n> critique(s) · <m> a surveiller » ou « Aucun point a verifier » ; titre du widget de points : « <n> point(s) a verifier » ou « Rien a signaler » (`Boards.Model:187-191`).
- Le score et la liste sont calculés sur **toutes** les vérifications, que leur widget soit affiché ou non (`Boards.Model:181-182`). Liste triée : critiques, puis à surveiller, puis informations (`Boards.Model:189`).
- Carte des points : « Toutes les verifications sont au vert. » quand il n'y a rien ; « Rien d urgent · <n> information(s) » s'il n'y a que des informations (`Charts.UI:400`).

### 7.2 Règles du tableau du poste (`BoardComputer`)

| Vérification | Seuil | Niveau | Message exact (fragments fixes) | Réf. |
|---|---|---|---|---|
| Mot de passe du compte ordinateur (`pwdLastSet`) | plus de 45 jours | Warn | « Mot de passe machine renouvele il y a <n> jours : relation d approbation a verifier. » | `:13-19` |
| Dernière connexion au domaine (`lastLogonTimestamp`) | plus de 90 jours | Warn | « Aucune connexion au domaine depuis <n> jours. » | `:22-28` |
| Compte ordinateur désactivé (`userAccountControl` bit 2) | désactivé | Alert | « Compte ordinateur desactive dans AD. » | `:31-36` |
| Mot de passe LAPS (`msLAPS-PasswordExpirationTime`, sinon `ms-Mcs-AdmPwdExpirationTime`) | expiration passée | Warn | « Mot de passe LAPS expire (rotation en attente). » | `:43-49` |
| Décalage d'horloge (mesuré par l'inventaire) | plus de 300 s | Alert | « Horloge decalee de <n> s : Kerberos refusera l authentification. » | `:55-60` |
| Décalage d'horloge | plus de 60 s | Warn | « Horloge decalee de <n> s. » | `:58` |
| Windows 10 (build 19043, 19044, 19045) | toujours | Alert | « <version> : fin de support depuis le 14/10/2025, poste a migrer. » | `:89-98`, `Boards.Model:120` |
| Durée de fonctionnement | plus de 30 jours | Warn | « Pas de redemarrage depuis <n> jours. » | `:120-132` |
| Mémoire utilisée | plus de 90 % | Warn | « Memoire utilisee a plus de 90 %. » | `:172-178` |
| Batterie | moins de 20 % | Warn | « Batterie a <n> %. » | `:183-188` |
| Disque système (C:, sinon premier volume) | moins de 10 % libre | Alert | « Disque <C:> presque plein : <n> % libre. » | `:192-206` |
| Disque système | moins de 20 % libre | Warn | « Disque <C:> : <n> % libre. » | `:201` |
| Autres volumes | moins de 10 % libre | Alert | « Volume <X:> presque plein : <n> % libre. » (entre 10 et 20 % : barre orange, sans point d'attention) | `:208-221` |
| Erreurs du journal Système (3 jours) | au moins une | Warn | « <n> erreur(s) dans le journal Systeme sur 3 jours. » | `:254-259` |
| Pare-feu | au moins un profil désactivé | Warn | « Pare-feu : <n> profil(s) desactive(s). » | `:267-273` |
| BitLocker (volume C: d'abord) | non protégé | Warn | « BitLocker : <état>. » | `:275-285` |
| Redémarrage en attente | demandé | Warn | « Redemarrage en attente. » | `:290-297` |
| Services automatiques arrêtés, Périphériques en erreur, Pilotes non signés | au moins un | Warn | « <n> services automatiques arretes. », « <n> peripheriques en erreur. », « <n> pilotes non signes. » (titre mis en minuscules) | `:300-321` |
| Dernier correctif installé | plus de 60 jours | Warn | « Dernier correctif installe il y a <n> jours. » | `:328-342` |

Autres textes utiles des widgets du poste : « Plus de 45 jours : relation d approbation a verifier », « Renouvele le <date> » (`:18`) ; « Plus de 90 jours : poste peut-etre inactif », « <date> (replique a 14 j pres) » (`:27`) ; « Actif » / « Desactive », « Cree le <date> » (`:36`) ; « Valide » / « Expire », « Expiration le <date> » (`:48`) ; « A l heure » (écart < 2 s), « Plus de 5 min : Kerberos refusera l authentification », « Ecart avec ce poste d administration » (`:59`) ; « Plus de 30 jours : redemarrage conseille » (`:131`) ; « Moins de 20 % : poste a brancher » (`:187`) ; « Barrettes non exposees (machine virtuelle ?) » (`:117`) ; rôles du domaine « Poste autonome », « Poste membre du domaine », « Serveur autonome », « Serveur membre », « Controleur de domaine secondaire », « Controleur de domaine principal » (`:156`) ; parts de l'anneau des services « En cours », « Arretes (automatiques) », « Arretes (manuels) », « Desactives » (`:237-243`). Les widgets « Administrateurs locaux », « Sessions et comptes locaux », « Demarrage automatique », « Partages », « Imprimantes », « Certificats machine » comptent sans lever de point d'attention (`:304-309`).

### 7.3 Règles du tableau du parc (`BoardFleet`)

| Vérification | Seuil | Niveau | Message exact (fragments fixes) | Réf. |
|---|---|---|---|---|
| Postes sous Windows 10 (système déclaré dans l'annuaire) | au moins un | Alert | « <n> poste(s) sous Windows 10, fin de support depuis le 14/10/2025. » | `:77`, `:119` |
| Postes sans connexion au domaine | 90 jours ou plus | Warn | « <n> poste(s) sans connexion au domaine depuis 90 jours ou plus : a verifier ou nettoyer. » | `:83`, `:120` |
| Comptes ordinateur jamais connectés | au moins un | Warn | « <n> compte(s) ordinateur jamais connecte(s). » | `:84`, `:121` |
| Postes sans réponse au dernier relevé | au moins un | Info (ne compte pas dans le score) | « <n> poste(s) sans reponse au dernier releve. » | `:107`, `:122` |
| Disque C: (relevé WMI) | moins de 10 % libre | Alert | « <n> poste(s) avec moins de 10 % libre sur C:. » | `:190-191`, `:230` |
| Démarrage (relevé WMI) | plus de 30 jours | Warn | « <n> poste(s) non redemarre(s) depuis plus de 30 jours. » | `:201`, `:231` |

Calculs du parc :
- Postes pris en compte : comptes ordinateur actifs de la base locale (`object_type='Machine'`, état différent de « Desactive ») dont le DN est l'OU choisie ou sous elle ; périmètre vide = tout le domaine indexé (`Engine.Worker:138`, `BoardFleet:30-38`, `:69`).
- Tranches de dernière connexion : « <7j », « 7-30j », « 30-90j », « 90-180j », « >180j », « Jamais » (toutes gardées, même vides) (`:71`, `:79-84`, `:146-151`).
- Systèmes : préfixe « Microsoft » retiré, « Professionnel » / « Professional » abrégé en « Pro », vide = « Systeme non renseigne » ; 6 premiers + « Autres » (`:74-76`, `:137-145`).
- Postes par OU : tout le domaine = OU qui contient le poste ; OU choisie = sa sous-OU directe, « (directement dans l OU) » ou « Hors OU » ; titre « Postes par sous-OU » avec une OU ; 10 premières + « Autres » (`:85-92`, `:152-160`).
- Présence : « En ligne », « Sans reponse » (états contenant Sans, Erreur ou Hors), « Non verifie » (y compris les postes jamais observés) (`:96-115`, `:161-168`).
- Relevés WMI : modèles (8 premiers + « Autres », « Modele inconnu ») ; versions (« Version inconnue », « Build <n> ») ; mémoire en tranches « 4 Go et - » (≤ 4,5 Go), « 8 Go » (≤ 9), « 16 Go » (≤ 17), « 32 Go » (≤ 33), « + de 32 Go » ; espace libre C: « < 10 % », « 10-25 % », « 25-50 % », « > 50 % ». « Disque C: presque plein » n'apparaît que si une taille de disque a été lue, « Non redemarres depuis 30 j » que si une date de démarrage a été lue (`:174-232`).
- Textes des tuiles : « dans l OU choisie » ou « <n> utilisateurs actifs au total » (`:130`) ; « Derniere connexion au domaine : a verifier ou nettoyer » (`:131`) ; « Fin de support le 14/10/2025 » (`:132`) ; « <n> associations au total » (`:133`) ; « Aucune » et « <n> postes avec releve WMI » (`:134`) ; « Moins de 10 % libre » (`:226`) ; « Redemarrage conseille » (`:229`).

### 7.4 Versions de Windows reconnues (`Get-DomeniaWindowsRelease`, `Boards.Model:115-132`)

Postes : 26200 Windows 11 25H2, 26100 Windows 11 24H2, 22631 Windows 11 23H2, 22621 Windows 11 22H2, 22000 Windows 11 21H2, 19045 Windows 10 22H2, 19044 Windows 10 21H2, 19043 Windows 10 21H1. Serveurs (légende contenant « server ») : 26100 Windows Server 2025, 20348 Windows Server 2022, 17763 Windows Server 2019, 14393 Windows Server 2016. Note Windows 10 : « Fin de support le 14/10/2025 : a migrer » ; autres : « Build <n> ».

### 7.5 Tableau des logiciels (`BoardSoftware`)

Aucune règle d'attention. Textes : « <n> editeur » ou « <n> editeurs », ou « Aucun editeur declare » (`:63-68`) ; « Somme des tailles connues » avec « (<n> sur <total>) » si toutes les tailles ne sont pas connues (`:70-78`) ; « Aucun doublon de version », « <nom> : <n> versions », « <nom> et <n> autre(s) » (`:80-89`) ; « Tous les editeurs sont renseignes » (`:91-96`) ; anneaux Éditeurs (6 premiers + « Autres », « Editeur non renseigne »), Architecture et Portée (« Non precise ») (`:98-120`) ; 8 plus gros logiciels en Mo (`:122-156`).

## 8. Catalogue des requêtes WMI prêtes à l'emploi

Source : `Get-DomeniaProbeCatalog`, `Probes:5-71`. Une ligne par requête : `Id|Catégorie|Nom|Espace de noms|Classe|Propriétés|Filtre|Mode|Transformation|Représentation` (`Probes:2`). 53 lignes, dont `sec.uac` (« Contrôle de compte (EnableLUA) », `Probes:40`) retirée du catalogue à la lecture (`Probes:69`) : **52 requêtes proposées**, en 8 catégories (Materiel 13, Systeme 9, Disques 6, Securite 4, Reseau 6, Logiciels et services 9, Utilisateurs 3, Evenements 2).

Modes (`Probes:3`, `:98`) : First = première instance ; Count = nombre d'instances ; All = toutes les instances, chacune comptée. Transformations (`Probes:4`, `:99-115`) : Text (texte nettoyé), GB (octets → Go, 1 décimale), GBfromKB (Ko → Go), MB (octets → Mo), Mbps (bit/s → Mbit/s), Number, DaysSince (jours depuis la date), Year (année de la date), PercentFree (100 × libre / taille), Release (build → nom de version, serveur si ProductType ≠ 1), Map:a=b;c=d (table de correspondance). Unités affichées : « % », « Go », « Mo », « j », « Mbit/s » (`Boards.Model:409-413`).

Nature d'une requête (`Get-DomeniaProbeKind`, `Boards.Model:399-408`) : sur le tableau du poste, toujours Value (Chiffre cle ou Liste) ; sur le tableau du parc, Measure si la transformation n'est pas un Map et que le mode est Count ou la transformation numérique (GB, GBfromKB, MB, Mbps, Number, DaysSince, PercentFree), sinon Distribution. Les colonnes de représentation par défaut ci-dessous appliquent cette règle à la représentation du catalogue (`Widgets.UI:595`). La colonne « Ligne » donne la ligne de `Probes`.

### 8.1 Catégorie « Materiel »

| Id | Nom (libellé exact) | Classe | Espace de noms | Propriétés | Filtre | Mode | Transformation | Tableau du parc : nature / représentation par défaut | Tableau du poste : représentation par défaut | Ligne |
|---|---|---|---|---|---|---|---|---|---|---|
| `hw.maker` | Fabricant | `Win32_ComputerSystem` | `root\cimv2` | Manufacturer | (aucun) | First | `Text` | Distribution / Pie (Anneau) | Kpi (Chiffre cle) | 8 |
| `hw.model` | Modele | `Win32_ComputerSystem` | `root\cimv2` | Model | (aucun) | First | `Text` | Distribution / Bar (Barres) | Kpi (Chiffre cle) | 9 |
| `hw.ram` | Memoire installee | `Win32_ComputerSystem` | `root\cimv2` | TotalPhysicalMemory | (aucun) | First | `GB` | Measure / Column (Histogramme) | Kpi (Chiffre cle) | 10 |
| `hw.cpu` | Processeur | `Win32_Processor` | `root\cimv2` | Name | (aucun) | First | `Text` | Distribution / Bar (Barres) | Kpi (Chiffre cle) | 11 |
| `hw.cores` | Coeurs du processeur | `Win32_Processor` | `root\cimv2` | NumberOfCores | (aucun) | First | `Number` | Measure / Column (Histogramme) | Kpi (Chiffre cle) | 12 |
| `hw.threads` | Processeurs logiques | `Win32_ComputerSystem` | `root\cimv2` | NumberOfLogicalProcessors | (aucun) | First | `Number` | Measure / Column (Histogramme) | Kpi (Chiffre cle) | 13 |
| `hw.bios` | Version du BIOS | `Win32_BIOS` | `root\cimv2` | SMBIOSBIOSVersion | (aucun) | First | `Text` | Distribution / Bar (Barres) | Kpi (Chiffre cle) | 14 |
| `hw.biosyear` | Annee du BIOS | `Win32_BIOS` | `root\cimv2` | ReleaseDate | (aucun) | First | `Year` | Distribution / Column (Histogramme) | Kpi (Chiffre cle) | 15 |
| `hw.gpu` | Carte graphique | `Win32_VideoController` | `root\cimv2` | Name | (aucun) | First | `Text` | Distribution / Bar (Barres) | Kpi (Chiffre cle) | 16 |
| `hw.screens` | Nombre d ecrans | `Win32_DesktopMonitor` | `root\cimv2` | Name | (aucun) | Count | `Number` | Measure / Column (Histogramme) | Kpi (Chiffre cle) | 17 |
| `hw.battery` | Batterie presente | `Win32_Battery` | `root\cimv2` | Name | (aucun) | Count | `Map:0=Non;1=Oui;2=Oui` | Distribution / Pie (Anneau) | Kpi (Chiffre cle) | 18 |
| `hw.chassis` | Type de systeme | `Win32_ComputerSystem` | `root\cimv2` | PCSystemType | (aucun) | First | `Map:1=Bureau;2=Portable;3=Station;4=Serveur;5=Serveur;8=Tablette` | Distribution / Pie (Anneau) | Kpi (Chiffre cle) | 19 |
| `hw.serialmissing` | Numero de serie | `Win32_BIOS` | `root\cimv2` | SerialNumber | (aucun) | First | `Text` | Distribution / Text (Liste) | Text (Liste) | 20 |

### 8.2 Catégorie « Systeme »

| Id | Nom (libellé exact) | Classe | Espace de noms | Propriétés | Filtre | Mode | Transformation | Tableau du parc : nature / représentation par défaut | Tableau du poste : représentation par défaut | Ligne |
|---|---|---|---|---|---|---|---|---|---|---|
| `os.caption` | Edition de Windows | `Win32_OperatingSystem` | `root\cimv2` | Caption | (aucun) | First | `Text` | Distribution / Pie (Anneau) | Kpi (Chiffre cle) | 21 |
| `os.release` | Version de Windows | `Win32_OperatingSystem` | `root\cimv2` | BuildNumber, ProductType | (aucun) | First | `Release` | Distribution / Pie (Anneau) | Kpi (Chiffre cle) | 22 |
| `os.arch` | Architecture | `Win32_OperatingSystem` | `root\cimv2` | OSArchitecture | (aucun) | First | `Text` | Distribution / Pie (Anneau) | Kpi (Chiffre cle) | 23 |
| `os.uptime` | Jours depuis le dernier demarrage | `Win32_OperatingSystem` | `root\cimv2` | LastBootUpTime | (aucun) | First | `DaysSince` | Measure / Column (Histogramme) | Kpi (Chiffre cle) | 24 |
| `os.installyear` | Annee d installation de Windows | `Win32_OperatingSystem` | `root\cimv2` | InstallDate | (aucun) | First | `Year` | Distribution / Column (Histogramme) | Kpi (Chiffre cle) | 25 |
| `os.lang` | Langue du systeme | `Win32_OperatingSystem` | `root\cimv2` | OSLanguage | (aucun) | First | `Map:1036=Francais;1033=Anglais (US);2057=Anglais (UK);1031=Allemand;1034=Espagnol;1040=Italien` | Distribution / Pie (Anneau) | Kpi (Chiffre cle) | 26 |
| `os.tz` | Fuseau horaire | `Win32_TimeZone` | `root\cimv2` | Caption | (aucun) | First | `Text` | Distribution / Bar (Barres) | Kpi (Chiffre cle) | 27 |
| `os.pagefile` | Fichier d echange (Mo) | `Win32_PageFileUsage` | `root\cimv2` | AllocatedBaseSize | (aucun) | First | `Number` | Measure / Column (Histogramme) | Kpi (Chiffre cle) | 28 |
| `os.freeram` | Memoire libre (Go) | `Win32_OperatingSystem` | `root\cimv2` | FreePhysicalMemory | (aucun) | First | `GBfromKB` | Measure / Column (Histogramme) | Kpi (Chiffre cle) | 29 |

### 8.3 Catégorie « Disques »

| Id | Nom (libellé exact) | Classe | Espace de noms | Propriétés | Filtre | Mode | Transformation | Tableau du parc : nature / représentation par défaut | Tableau du poste : représentation par défaut | Ligne |
|---|---|---|---|---|---|---|---|---|---|---|
| `disk.cfree` | Espace libre sur C: (%) | `Win32_LogicalDisk` | `root\cimv2` | FreeSpace, Size | `DeviceID='C:'` | First | `PercentFree` | Measure / Column (Histogramme) | Kpi (Chiffre cle) | 30 |
| `disk.csize` | Taille de C: (Go) | `Win32_LogicalDisk` | `root\cimv2` | Size | `DeviceID='C:'` | First | `GB` | Measure / Column (Histogramme) | Kpi (Chiffre cle) | 31 |
| `disk.count` | Nombre de volumes locaux | `Win32_LogicalDisk` | `root\cimv2` | DeviceID | `DriveType=3` | Count | `Number` | Measure / Column (Histogramme) | Kpi (Chiffre cle) | 32 |
| `disk.media` | Type de disque physique | `MSFT_PhysicalDisk` | `root\Microsoft\Windows\Storage` | MediaType | (aucun) | First | `Map:3=Disque dur;4=SSD;5=SCM;0=Non precise` | Distribution / Pie (Anneau) | Kpi (Chiffre cle) | 33 |
| `disk.health` | Sante du disque physique | `MSFT_PhysicalDisk` | `root\Microsoft\Windows\Storage` | HealthStatus | (aucun) | First | `Map:0=Sain;1=Avertissement;2=Defaillant;5=Inconnu` | Distribution / Pie (Anneau) | Kpi (Chiffre cle) | 34 |
| `disk.removable` | Supports amovibles connectes | `Win32_LogicalDisk` | `root\cimv2` | DeviceID | `DriveType=2` | Count | `Number` | Measure / Column (Histogramme) | Kpi (Chiffre cle) | 35 |

### 8.4 Catégorie « Securite »

| Id | Nom (libellé exact) | Classe | Espace de noms | Propriétés | Filtre | Mode | Transformation | Tableau du parc : nature / représentation par défaut | Tableau du poste : représentation par défaut | Ligne |
|---|---|---|---|---|---|---|---|---|---|---|
| `sec.bitlocker` | Chiffrement BitLocker de C: | `Win32_EncryptableVolume` | `root\cimv2\Security\MicrosoftVolumeEncryption` | ProtectionStatus | `DriveLetter='C:'` | First | `Map:0=Non protege;1=Protege;2=Inconnu` | Distribution / Pie (Anneau) | Kpi (Chiffre cle) | 36 |
| `sec.av` | Antivirus declare | `AntiVirusProduct` | `root\SecurityCenter2` | displayName | (aucun) | All | `Text` | Distribution / Bar (Barres) | Kpi (Chiffre cle) | 37 |
| `sec.localusers` | Comptes locaux actives | `Win32_UserAccount` | `root\cimv2` | Name | `LocalAccount=TRUE AND Disabled=FALSE` | Count | `Number` | Measure / Column (Histogramme) | Kpi (Chiffre cle) | 38 |
| `sec.shares` | Partages hors administratifs | `Win32_Share` | `root\cimv2` | Name | `Type=0` | Count | `Number` | Measure / Column (Histogramme) | Kpi (Chiffre cle) | 39 |

### 8.5 Catégorie « Reseau »

| Id | Nom (libellé exact) | Classe | Espace de noms | Propriétés | Filtre | Mode | Transformation | Tableau du parc : nature / représentation par défaut | Tableau du poste : représentation par défaut | Ligne |
|---|---|---|---|---|---|---|---|---|---|---|
| `net.adapter` | Carte reseau connectee | `Win32_NetworkAdapter` | `root\cimv2` | Name | `NetConnectionStatus=2` | All | `Text` | Distribution / Bar (Barres) | Kpi (Chiffre cle) | 41 |
| `net.speed` | Vitesse du lien (Mbit/s) | `Win32_NetworkAdapter` | `root\cimv2` | Speed | `NetConnectionStatus=2` | First | `Mbps` | Measure / Column (Histogramme) | Kpi (Chiffre cle) | 42 |
| `net.dhcp` | Adresse DHCP | `Win32_NetworkAdapterConfiguration` | `root\cimv2` | DHCPEnabled | `IPEnabled=TRUE` | First | `Map:True=DHCP;False=Fixe` | Distribution / Pie (Anneau) | Kpi (Chiffre cle) | 43 |
| `net.dns` | Premier serveur DNS | `Win32_NetworkAdapterConfiguration` | `root\cimv2` | DNSServerSearchOrder | `IPEnabled=TRUE` | First | `Text` | Distribution / Bar (Barres) | Kpi (Chiffre cle) | 44 |
| `net.gateway` | Passerelle | `Win32_NetworkAdapterConfiguration` | `root\cimv2` | DefaultIPGateway | `IPEnabled=TRUE` | First | `Text` | Distribution / Bar (Barres) | Kpi (Chiffre cle) | 45 |
| `net.wifi` | Wi-Fi connecte | `Win32_NetworkAdapter` | `root\cimv2` | Name | `NetConnectionStatus=2 AND Name LIKE '%Wi%Fi%'` | Count | `Map:0=Non;1=Oui;2=Oui` | Distribution / Pie (Anneau) | Kpi (Chiffre cle) | 46 |

### 8.6 Catégorie « Logiciels et services »

| Id | Nom (libellé exact) | Classe | Espace de noms | Propriétés | Filtre | Mode | Transformation | Tableau du parc : nature / représentation par défaut | Tableau du poste : représentation par défaut | Ligne |
|---|---|---|---|---|---|---|---|---|---|---|
| `soft.printers` | Nombre d imprimantes | `Win32_Printer` | `root\cimv2` | Name | (aucun) | Count | `Number` | Measure / Column (Histogramme) | Kpi (Chiffre cle) | 47 |
| `soft.defaultprinter` | Imprimante par defaut | `Win32_Printer` | `root\cimv2` | Name | `Default=TRUE` | First | `Text` | Distribution / Bar (Barres) | Kpi (Chiffre cle) | 48 |
| `soft.startup` | Programmes au demarrage | `Win32_StartupCommand` | `root\cimv2` | Name | (aucun) | Count | `Number` | Measure / Column (Histogramme) | Kpi (Chiffre cle) | 49 |
| `soft.stoppedauto` | Services automatiques arretes | `Win32_Service` | `root\cimv2` | Name | `StartMode='Auto' AND State='Stopped'` | Count | `Number` | Measure / Column (Histogramme) | Kpi (Chiffre cle) | 50 |
| `soft.running` | Services en cours d execution | `Win32_Service` | `root\cimv2` | Name | `State='Running'` | Count | `Number` | Measure / Column (Histogramme) | Kpi (Chiffre cle) | 51 |
| `soft.spooler` | Service Spouleur d impression | `Win32_Service` | `root\cimv2` | State | `Name='Spooler'` | First | `Text` | Distribution / Pie (Anneau) | Kpi (Chiffre cle) | 52 |
| `soft.wuauserv` | Service Windows Update | `Win32_Service` | `root\cimv2` | State | `Name='wuauserv'` | First | `Text` | Distribution / Pie (Anneau) | Kpi (Chiffre cle) | 53 |
| `soft.hotfixcount` | Nombre de correctifs installes | `Win32_QuickFixEngineering` | `root\cimv2` | HotFixID | (aucun) | Count | `Number` | Measure / Column (Histogramme) | Kpi (Chiffre cle) | 54 |
| `soft.processes` | Processus en cours | `Win32_Process` | `root\cimv2` | Name | (aucun) | Count | `Number` | Measure / Column (Histogramme) | Kpi (Chiffre cle) | 55 |

### 8.7 Catégorie « Utilisateurs »

| Id | Nom (libellé exact) | Classe | Espace de noms | Propriétés | Filtre | Mode | Transformation | Tableau du parc : nature / représentation par défaut | Tableau du poste : représentation par défaut | Ligne |
|---|---|---|---|---|---|---|---|---|---|---|
| `user.console` | Utilisateur de la console | `Win32_ComputerSystem` | `root\cimv2` | UserName | (aucun) | First | `Text` | Distribution / Text (Liste) | Text (Liste) | 56 |
| `user.profiles` | Profils utilisateurs sur le poste | `Win32_UserProfile` | `root\cimv2` | LocalPath | `Special=FALSE` | Count | `Number` | Measure / Column (Histogramme) | Kpi (Chiffre cle) | 57 |
| `user.sessions` | Sessions ouvertes | `Win32_LogonSession` | `root\cimv2` | LogonId | `LogonType=2 OR LogonType=10` | Count | `Number` | Measure / Column (Histogramme) | Kpi (Chiffre cle) | 58 |

### 8.8 Catégorie « Evenements »

| Id | Nom (libellé exact) | Classe | Espace de noms | Propriétés | Filtre | Mode | Transformation | Tableau du parc : nature / représentation par défaut | Tableau du poste : représentation par défaut | Ligne |
|---|---|---|---|---|---|---|---|---|---|---|
| `evt.syserrors` | Erreurs systeme (24 h) | `Win32_NTLogEvent` | `root\cimv2` | EventCode | `Logfile='System' AND EventType=1 AND TimeGenerated>='{SINCE_24H}'` | Count | `Number` | Measure / Column (Histogramme) | Kpi (Chiffre cle) | 59 |
| `evt.unexpected` | Arrets inattendus (7 j) | `Win32_NTLogEvent` | `root\cimv2` | EventCode | `Logfile='System' AND EventCode=6008 AND TimeGenerated>='{SINCE_7D}'` | Count | `Number` | Measure / Column (Histogramme) | Kpi (Chiffre cle) | 60 |

## 9. Exécution des requêtes : « Actualiser les requetes »

L'essentiel : les requêtes ne partent que sur demande, après confirmation, en lecture seule, sur une OU choisie (tableau du parc) ou sur le poste sélectionné (tableau du poste), jamais sur le domaine entier ; quatre postes au plus à la fois.

### 9.1 Périmètre et refus (`Start-DomeniaWidgetProbe`, `Widgets.UI:851-872`)

- Requêtes exécutées : celles des widgets de requête du tableau (sans doublon) (`:854`).
- Aucune : « Aucune requete WMI sur ce tableau de bord : ajoutez un widget de requete. » (`:855`).
- Parc : périmètre vide ou racine du domaine → « Choisissez une OU : jamais le domaine entier. » (`:859`) ; périmètre changé ou nouvelle connexion depuis le dernier calcul → « Actualisez la vue du parc : le perimetre a change depuis le dernier calcul. » (`:860-861`) ; aucun poste → « Aucun poste dans le perimetre. » (`:863`). Cibles = postes indexés de l'OU calculés par la vue d'ensemble (`:862`).
- Poste : aucun poste sélectionné → « Aucun poste selectionne. » (`:867`) ; cible = le poste sélectionné seul (`:868-870`).
- Refus communs du relevé (préfixe « Releve impossible : ») : « Releve distant indisponible en demonstration. », « Un releve est deja en cours. », « Attendez la fin de la maintenance locale. », « Attendez la confirmation des enregistrements locaux avant un nouveau releve. », « Aucune base autonome active. », « Aucun poste indexe dans cette OU. » (`Park.UI:34-44`, `:58`).

### 9.2 Confirmation et déroulement

- Préparation : lecture des cibles dans la base locale (tâche « Preparer le releve du parc », 60 s), texte « Lecture des postes et des sessions conservees en cache... » (`Park.UI:55-57`).
- Confirmation en ligne : titre « Sonder pour les widgets », message « <n> postes de <OU ou poste>. <k> requete(s) WMI des widgets en lecture seule, plus ping et utilisateur console ; quatre postes au maximum a la fois. Resultats conserves pour les tableaux de bord. », boutons « Verifier les sessions » et « Annuler » (`Park.UI:72`, `:76`).
- Concurrence : 4 lectures au plus en même temps, une admission par tick de 250 ms ; tâche « Console du parc : <poste> » ; délai de la tâche min(150 ; 20 + 8 × nombre de requêtes) secondes avec requêtes, 20 s sinon (`Park.UI:93`, `:125-130`).
- Arrêt automatique : identifiants rejetés (AuthRejected), 3 échecs ou un conflit d’enregistrement local ; pause (sans arrêt) tant que 64 enregistrements locaux attendent (`Park.UI:121-124`, `:145`).
- Suivi : « Releve en cours : <d>/<N> postes verifies, <x> joignables, <r> identites en cache, <c> associations actualisees, <f> lectures non confirmees. » puis « Releve termine » avec les mêmes compteurs (`Park.UI:9-10`), affiché sous les boutons de l'Accueil (`LblFleetRun`, `Park.UI:16`).
- Fin : la vue d'ensemble est recalculée depuis la base, et le tableau du poste redessiné (`Park.UI:15`, `Dashboard.UI:115-117`).

### 9.3 Ce que fait le worker sur chaque poste (`Get-DomeniaLiveProbeCode`, `Live.Model:155-255`)

1. Nom de poste contrôlé (253 caractères au plus, lettres, chiffres, `.`, `_`, `-`) sinon « Cible distante invalide. » (`:157-158`).
2. Ping ICMP unique, 900 ms, adresse IPv4 préférée (`:172-193`).
3. Session CIM en DCOM avec l’identité des opérations poste (`Get-WMachineCredential` : `MachineCredential` du contexte, à défaut l’identité d’administration distante, `Core:8499-8504`), délai d'opération 4 s (borné entre 2 et 8), lecture de `Win32_ComputerSystem.UserName` (`Live.Model:203-216`). Si CIM est désactivé dans la configuration : « Contrôle réseau uniquement. Aucune lecture du compte console. » et aucune requête (`:198-202`).
4. Requêtes des widgets, dans la même session CIM, seulement si la lecture de la console a réussi (`:226-247`) :
   - Le paquet transmis au worker ne contient que l'Id, l'espace de noms, la classe, les propriétés, le filtre et le mode, jamais un texte WQL libre (`ConvertTo-DomeniaProbePayload`, `Probes:87-91`, commentaire « read-only SELECT built by the worker »).
   - Contrôle avant appel : classe `^[A-Za-z0-9_]+$`, espace de noms `^[A-Za-z0-9_\\]+$`, sinon « Requete refusee. » ; propriétés non conformes ignorées (`Live.Model:234-235`).
   - `{SINCE_24H}` et `{SINCE_7D}` remplacés par la date UTC d'il y a 24 h ou 7 jours (`:229`, `:236`).
   - Appel `Get-CimInstance` avec `-Namespace`, `-ClassName`, `-Property`, `-Filter` (lecture d'instances ; aucune méthode WMI invoquée par ce chemin), délai 10 s au moins (`:237-240`).
   - Limites du résultat : `Count` = toutes les instances ; `Rows` = 20 premières instances ; dates en UTC ISO ; tableau → premier élément ; texte coupé à 200 caractères ; une erreur est notée par requête sans arrêter les autres (`:241-244`).
5. Analyse WMI légère (« Analyser l OU (WMI) » seulement) : `Win32_OperatingSystem` (Caption, BuildNumber, LastBootUpTime), `Win32_ComputerSystem` (Manufacturer, Model, TotalPhysicalMemory), `Win32_LogicalDisk` filtre `DeviceID='C:'` (Size, FreeSpace) (`:217-225`).

### 9.4 Conservation et lecture des résultats

- Chaque résultat est fusionné dans l'observation du poste : dernier résultat de chaque requête, anciennes requêtes du poste conservées ; relevé WMI léger précédent gardé s'il n'y en a pas de nouveau (`Park.Model:13-21`).
- Observation gardée en mémoire et enregistrée dans la base locale (métadonnée `ParkSession`, table `park_session_cache`) ; sinon « Observation en memoire seulement : stockage local indisponible. » (`Park.UI:147-150`, `Engine.Worker:142-143`).
- Lecture par les widgets (`Get-DomeniaWidgetResults`, `Widgets.UI:818-850`) : Parc = observations des postes sous l'OU courante (avec « Tout le domaine », toutes les observations en cache) ; Poste = observation du poste sélectionné.
- Agrégation (`Measure-DomeniaWidgetData`, `Probes:118-154`) : textes comptés (8 premières valeurs + « Autres », résumé « Le plus frequent : <valeur> (<n>) ») ; nombres Number ou DaysSince avec 8 valeurs distinctes au plus : une barre par valeur ; sinon tranches : Go 4, 8, 16, 32, 64, 128, 256, 512 ; jours 1, 7, 30, 90, 180, 365 ; pourcentage 10, 25, 50, 75 ; Mbit/s 100, 1000 ; autres : 0, 1, 2, 3, 5, 10 si le maximum ≤ 10, sinon cinquièmes du maximum ; étiquettes « <= <x> », « <a>-<b> », « > <x> » ; résumé « Moyenne <m> · min <a> · max <b> ».
- Affichage (`ConvertFrom-DomeniaProbeMeasure`, `Boards.Model:414-446`) : sans résultat, tuile « En attente » avec « Actualiser les requetes pour remplir ce widget » ; Parc : titre « <nom> (<n> postes) », Measure = moyenne avec unité et « Moyenne · min <a> · max <b> », Distribution = valeur la plus fréquente avec « <n> poste(s) sur <N> » et centre « <N> postes » ; Poste : la valeur lue (ou « <n> valeurs : <v1>, <v2>, <v3> »), détail « <catégorie> · <nom> ».

## 10. Analyses de la vue d'ensemble du parc (page Accueil)

### 10.1 Périmètre (`Core:4431-4437`, `Dashboard.UI:66-80`)

- Libellé « Perimetre », champ en lecture seule (info-bulle « OU de depart du tableau de bord et des analyses. Vide : tout le domaine indexe (consultation seulement). »), valeur affichée = DN de l'OU ou « Tout le domaine indexe » (`Dashboard.UI:108`).
- « Choisir l OU... » (info-bulle « Choisir l OU de depart dans l annuaire. ») : sélecteur « Perimetre du tableau de bord », consigne « Choisissez l OU de depart : les statistiques et les analyses se limitent a ses postes. » ; enregistré immédiatement puis vue recalculée (`Dashboard.UI:74-79`).
- « Tout le domaine » (info-bulle « Revient au domaine entier pour la consultation. Les analyses demandent une OU. »).
- « Actualiser » (info-bulle « Recalcule la vue d ensemble a partir de la base autonome locale. Aucune requete AD ni poste. ») (`Core:4425`).

### 10.2 Boutons d'analyse (`Core:4438-4444`, `Dashboard.UI:81-97`, `Park.UI:26-78`)

| Bouton (libellé exact) | Info-bulle exacte | Ce qui est lu | Confirmation (titre / bouton) | Réf. |
|---|---|---|---|---|
| Pinger l OU | Ping des postes indexes de l OU choisie, avec confirmation. Jamais le domaine entier. | Ping ICMP seul (présence réseau), aucune lecture de session ni association | « Pinger les postes affiches » / « Pinger » ; message « <n> postes de <OU>. Ping ICMP seulement. » | `Core:4439`, `Park.UI:74`, `:76` |
| Detecter les utilisateurs | Ping puis utilisateur console des postes de l OU choisie ; associations actualisees si changement. | Ping, puis `Win32_ComputerSystem.UserName` (CIM/DCOM) ; association utilisateur/poste mise à jour si elle change (source « Console CIM/DCOM ») | « Detecter sur les resultats affiches » / « Verifier les sessions » ; message « <n> postes de <OU>. Ping puis utilisateur console ; associations actualisees si changement. » | `Core:4440`, `Park.UI:74`, `:76`, `:151-156` |
| Analyser l OU (WMI) | Ping, utilisateur console et releve WMI leger (modele, memoire, disque C:, build, demarrage) de chaque poste de l OU ; resultats conserves pour ce tableau de bord. | Comme « Detecter », plus le relevé WMI léger (9.3, point 5) qui remplit la section « Releves WMI » | « Analyser le perimetre » / « Verifier les sessions » ; message « <n> postes de <OU>. Ping, utilisateur console et releve WMI leger (modele, memoire, disque C:, build, demarrage), quatre postes au maximum a la fois. Resultats conserves pour le tableau de bord. » | `Core:4441`, `Park.UI:73`, `:76` |
| Arreter | Arrete les nouvelles lectures ; les resultats obtenus sont conserves. | Stoppe les admissions ; les lectures en cours se terminent | aucune | `Core:4442`, `Park.UI:97-106` |

Refus (préfixe « Analyse impossible : ») : « choisissez d abord une OU : aucune analyse sur le domaine entier. », « actualisez d abord la vue d ensemble de cette OU. », « aucun poste indexe dans cette OU. Mettez a jour la base autonome. » (`Dashboard.UI:86-89`, `:96`). Le ping seul affiche « Ping en cours : <d>/<N> postes pingues, <x> joignables, <y> sans reponse. » (`Park.UI:10`). Les sessions RDP ne sont pas recensées (`Live.Model:248`, `Park.UI:153`).

## 11. Animation d'entrée et réglage Windows

- À chaque nouvelle lecture, les cartes apparaissent l'une après l'autre (fondu 420 ms et montée de 14 px en 520 ms, décalage de 38 ms par carte plafonné à 520 ms), puis les anneaux et barres se dessinent et les chiffres comptent depuis 0 (900 ms, nombres entiers de 2 et plus en tête de texte) (`Charts.UI:158-166`, `:198-240`).
- Un tableau construit masqué joue son entrée à sa première apparition (`Charts.UI:200`, `:207-217`).
- Les modifications de disposition redessinent sans entrée ; seul le widget modifié ou déplacé rejoue son apparition (`Widgets.UI:44`, `:120-125`). L'aperçu de l'éditeur joue l'entrée (`Widgets.UI:743`).
- Désactivée quand l'animation Windows est coupée (`SystemParameters.ClientAreaAnimation` faux ; commentaire : accessibilité, session à distance), ou par la variable interne `DomeniaReduceMotion` utilisée par les tests et par `dev/wad/maintenance/Preview-DomeniaUi.ps1` pour des captures fixes (`Charts.UI:116-120`, `:145`, `maintenance/Preview-DomeniaUi.ps1:226`). Aucun réglage Domenia ne la coupe.

## 12. Écarts relevés et points non vérifiés

- Rien n'a été vu à l'écran : tout vient du code (VM non utilisée pour cette fiche).
- Info-bulle de l'extenseur « Synthese en graphiques » : « Editeurs, installations par mois et plus gros logiciels, calcules sur la liste chargee. » (`Core:5711`) ; le catalogue Logiciels n'a aucun widget « installations par mois » (`Boards.Model:70-79`). Texte en retard sur le code.
- Titres de confirmation hérités : « Pinger l OU » ouvre « Pinger les postes affiches » et « Detecter les utilisateurs » ouvre « Detecter sur les resultats affiches », car une OU est traitée comme une liste affichée (`Park.UI:45`, `:52`, `:76`). À confirmer à l'écran avant de citer ces titres dans un guide.
- Le suivi peut afficher « Stockage a verifier dans Fiabilite. » (`Park.UI:13`) alors que l'onglet « Fiabilité » est masqué (`Core:5932`, `Visibility="Collapsed"`). À vérifier.
- `Get-DomeniaProbeVisuals` (`Probes:72-81`) n'est pas utilisé par l'interface (voir 3.2).
- `software.health` et `software.attention` calculés mais jamais affichés (voir 2.3).
- Le chemin du réglage Windows qui pilote `ClientAreaAnimation` (nom de l'option dans Paramètres) n'est pas dans le code : non vérifié.
- L'emplacement du dossier de données (parent de `Preferences`) n'est pas établi ici (`Core:20003` le fixe au démarrage).
- Le worker n'écrit pas de texte « SELECT » : il passe classe, propriétés et filtre à `Get-CimInstance` ; la formule « read-only SELECT built by the worker » est un commentaire du code (`Probes:88`).
- Sur le tableau du parc avec « Tout le domaine », les widgets de requête montrent les résultats déjà en cache de tous les postes, mais « Actualiser les requetes » est refusé (`Widgets.UI:826-830`, `:859`).

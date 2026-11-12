# Mises à jour et diffusion de Domenia 2

Les contrôles de livraison sont implémentés ; les preuves de chaque version publiée sont consignées dans REPRISE.md. Une compilation seule ne vaut pas validation des packs.

## Correctifs publiés en 2.1.7

Une mise à jour aboutit de nouveau, depuis Paramètres comme par `livraison appliquer`. Le contrôle de santé du nouveau code
annulait sa propre page de vérification : chaque mise à jour revenait aux anciens binaires (code 3) sans en donner la
raison. Le contrôle charge désormais cette page et refuse toute autre navigation. Un retour automatique indique sa cause,
dans le message et dans le bilan de la transaction.

Les commandes de maintenance `Domenia.exe livraison …` (aperçu et application d’une mise à jour, reprise,
restauration, désinstallation) fonctionnent de nouveau : depuis 2.0.8, la ligne de commande d’automatisation les
interceptait et répondait « Commande inconnue ». La mise à jour depuis Paramètres n’était pas touchée. Une restauration
vers une version antérieure à 2.1.6 est refusée, avant toute modification, tant qu’une configuration par défaut est
écrite sur place : ces versions refusent tout fichier absent de leur manifeste et ne démarreraient pas. Déplacer
`wad/Domenia.settings.seed.json` hors du dossier, puis relancer l’aperçu. `Domenia.exe --check-settings-seed` rend le
code 2 pour un fichier invalide au lieu de s’arrêter sur une erreur.

## Correctifs publiés en 2.1.6

« Définir comme configuration par défaut » écrit désormais un seul fichier, `wad/Domenia.settings.seed.json`, dans le
dossier du logiciel ouvert, comme GLPI Pilot. Jusqu’en 2.1.5, ce bouton fabriquait une copie complète du pack, avec un
nouveau ZIP et de nouvelles empreintes, parce que tout fichier absent du manifeste bloquait le démarrage. Le contrôle
du pack admet maintenant ce fichier à cet emplacement, hors manifeste, comme `Domenia.config.json`. Le ZIP officiel, le
manifeste et les binaires restent inchangés et la mise à jour garde le fichier. Une configuration déjà présente est
sauvegardée dans les exports avant remplacement. Le profil qui l’a définie ne se la voit pas reproposer. Une copie
préparée avant 2.1.6, dont le manifeste liste ce fichier, reste valide ; sa mise à jour vers un pack officiel laisse
le fichier en place au lieu de le retirer avec l’ancien code.

Réécrire les mêmes choix ne change rien : l’heure d’export n’est pas comparée, le fichier en place est conservé à
l’octet. La page relit son état après chaque écriture, si bien que plusieurs écritures se suivent sans « Relire mes
choix ». « Revoir la proposition du pack » dit aussi quand une décision est déjà enregistrée.

## Correctifs publiés en 2.1.5

Le choix « CIM / WinRM » ouvre de nouveau la session WinRM. En 2.1.4, la session ouverte avec l’identité de la session
Windows était refusée avant tout échange (E_INVALIDARG) : chaque source échouait en 0x80070057. La session s’ouvre
désormais sans argument d’options vide. Les réponses WinRM sont lues comme les lectures DCOM : projections renvoyées
en fragment XML, dates CIM converties au format DMTF, références des sessions ouvertes rendues en chemins WMI.
Sur un poste sans écouteur WinRM (cas par défaut de Windows 11), la première source rend « Injoignable » avec son code
(0x80338012) et les suivantes échouent aussitôt avec le même code, sans nouvelle tentative de connexion : chaque
reconnexion coûtait environ 4 s et l’inventaire s’arrêtait sur son délai sans nouvelle donnée. Un poste injoignable
affiche désormais son code, en DCOM comme en WinRM.

Le démarrage du processus de lecture ne compte plus dans le délai de la première requête et comprend sa préparation :
chargement local du chemin de lecture (sérialisation, règles WQL, composant WinRM ou WMI, lecture du registre), sans
contact avec le poste. Sur le poste de banc, ce premier passage coûtait jusqu’à 9,5 s à la première source et, en
WinRM, dépassait avec le refus de 4 s le délai de la requête (borne propre de 12 s, durée consignée à chaque
démarrage). Ce démarrage, y compris celui d’un processus neuf après une requête restée sans réponse, ne compte pas non
plus dans le délai sans nouvelle donnée de l’inventaire (25 s) ; le plafond total est inchangé. Le mode Automatique
garde l’ordre DCOM d’abord.

Sans accélération graphique (machine virtuelle sans carte graphique, certaines sessions à distance), les animations en
boucle s’arrêtent après un passage et l’aurore du fond reste immobile : au repos, elles occupaient jusqu’à 1,7 des
2 cœurs du poste de banc et retardaient la lecture du poste. Le choix Animations est conservé ; Paramètres > Apparence
l’indique.

Une valeur de registre absente d’une clé existante (code 1 du fournisseur de registre WMI) est lue comme absente et
non plus comme un échec : en 2.1.4, les valeurs facultatives de chaque clé de désinstallation écartaient chaque
programme (0 logiciel pour 31 clés sur le poste de banc) et « Site AD » ne lisait qu’une requête sur deux.
« Logiciels installés » indique aussi le code du premier échec de lecture du registre. Au démarrage, la lecture de la
configuration d’interface écrit d’abord un choix encore en attente au lieu d’être refusée (« Des préférences attendent
leur enregistrement ») ; la configuration du pack est de nouveau proposée dès ce démarrage.

Valeurs enregistrées et schéma 11 révision 2 inchangés. Sur le poste de banc, l’inventaire rapide en Automatique lit
les 27 sources par DCOM en 26,4 s (19 sur 27 avant le plafond de 55 s en 2.1.4 ; Système en 1,2 s au lieu de 9,5 s),
dont 4 logiciels. Banc administrateur conforme (poste sans écouteur WinRM) ; lecture WinRM réussie non observée sur le
banc, à vérifier sur un poste où WinRM est actif.

## Correctifs publiés en 2.1.4

Les lectures distantes laissent le poste décider pour le compte choisi, y compris un compte saisi. Les écritures
gardent leur validation préalable. Les OU enregistrées sont recherchées dans la base locale au démarrage et après
un changement de session, sans LDAP automatique ; un arbre fraîchement lu reste prioritaire. La consultation
d’état de l’Accueil accepte l’absence d’OU sans erreur et sans démarrer une campagne. Les budgets affichent
l’âge en jours et la durée de campagne en minutes. En mode Automatique, l’inventaire lit d’abord par WMI / DCOM,
comme Domenia 1 ; un poste injoignable en DCOM est relu une seule fois par WinRM s’il est autorisé. Le choix
« CIM / WinRM » reste exclusif. Une source plus lente que son délai est marquée « Interrompu » sans arrêter les
suivantes ; une requête restée sans réponse au-delà de son délai arrête son processus de lecture et les sources
suivantes sont lues par un processus neuf (deux fois au plus par lecture). La lecture des pilotes dispose de
20 secondes, celle du mode de Defender de 10 secondes. Le délai distant configuré (45 s par défaut) ne coupe plus
une lecture qui annonce son propre budget : l’inventaire rapide garde ses 55 s, le complet 150 s, et les logiciels,
services, diagnostic et sondes leur durée annoncée. Un arrêt de la lecture native consigne au journal la
phase et le code d’erreur du processus de lecture. En WinRM, une erreur d’appel n’arrête plus le processus de
lecture : chaque source est dite en échec avec son code numérique, « injoignable » sans écouteur. Les lectures WinRM
filtrées en WQL visent l’espace de noms entier. Limite connue : sur le banc, « CIM / WinRM » échoue encore sur chaque
source en 0x80070057 ; le mode Automatique lit en DCOM. Dans une fenêtre étroite, la zone de recherche de la barre du
haut masque le raccourci puis le libellé au lieu de déborder. Le titre de la fenêtre nomme le poste, l’objet ou le
sujet ouvert au lieu de « Aucune sélection ». Valeurs enregistrées et schéma 11 révision 2 inchangés.
Qualification automatique réussie. Banc du 11 novembre : inventaire rapide en Automatique par DCOM, 19 sources sur 27
avant le plafond de 55 s sur le poste de banc, sans arrêt du processus de lecture. Version publiée le 11 novembre
2026 après le go de David, détails dans REPRISE.md.

## Correctifs publiés en 2.1.3

Les étapes de l’actualisation restent stables pendant la progression. La consultation « Données et cache » utilise
un inventaire léger ; les plans de modification gardent leur empreinte complète. Les encadrés de mise à jour
utilisent la largeur disponible. La version affichée est courte (2.1.3) ; l’identité complète reste dans les
preuves techniques. Qualification automatique réussie ; version publiée le 10 novembre 2026 après le go de David, détails dans REPRISE.md.

## Pack de production

Depuis le 8 novembre 2026, seul le pack **PROD-LIGHT** est publié. Le ZIP embarque .NET et les
composants de Domenia, sans moteur WebView2. Au lancement, l’application cherche son moteur dans cet ordre :

1. le runtime WebView2 Evergreen Microsoft x64 **140.0.3485.54** ou ultérieur, installé pour la machine ;
2. sinon le pack WebView2 du Socle **156.0.4314.42** extrait dans `wad\runtime\webview2` : chaque fichier
   est comparé à l’index épinglé dans Domenia et la signature Microsoft des deux binaires principaux est vérifiée ;
3. sinon un message propose ces deux solutions avec le lien du pack du Socle :
   <https://github.com/M4D135/socle-windows/releases/tag/webview2-156.0.4314.42>. Rien n’est téléchargé.

Pour le Socle, extraire `Socle_WebView2-156.0.4314.42_Windows-x64.zip` dans le dossier `wad` de Domenia, sans
rien renommer : `wad\runtime\webview2` contient alors exactement les fichiers du pack. Un fichier en plus, en moins
ou modifié bloque le démarrage avec le nom du fichier. Les mises à jour de Domenia conservent ce dossier.

Les mises à jour restent dans l’édition installée. Un poste encore en **PROD** (2.0.8 et avant, WebView2 embarqué)
ne reçoit plus de nouvelle version : y extraire manuellement le ZIP PROD-LIGHT, avec Evergreen ou le pack du Socle.
Le ZIP contient `Domenia.exe` à la racine et le dossier `wad/` à côté.

Les sources associées à une livraison sont disponibles dans le dépôt GitHub au
commit indiqué par `wad/package-release.json`. Le fichier `source-commit.json`
accompagne les preuves de livraison. Les nouveaux packs contiennent uniquement
les fichiers nécessaires à la production.

## Installer une version

Depuis le pack 2.0.4, la racine contient `Domenia.exe` et `wad`. Pour quitter une ancienne disposition plate, extraire dans un **nouveau dossier**, puis adapter le raccourci. Le profil utilisateur reste conservé. Ne pas superposer les fichiers ; l’assistant de cette version refuse les transitions entre dispositions différentes. Reprendre les anciennes transactions avec un ancien pack de même disposition.

Dans **Paramètres → Mises à jour**, choisir explicitement le dossier de diffusion mémorisé ou un ZIP local. Depuis 2.1.0, Domenia ne consulte plus GitHub pour ses mises à jour et ne contient aucun client réseau pour cela. L’ouverture de la page ne cherche rien. Le ZIP local exige `SHA256SUMS.txt` dans le même dossier. Le partage utilise les droits de la session Windows ; Domenia ne mémorise aucun mot de passe de partage.

Vérifier version, provenance et SHA-256, puis demander **Préparer**. Cette étape copie le pack en espace privé et contrôle le ZIP, les composants, les chemins et les métadonnées. Elle n’installe rien. Un catalogue modifié, un transfert incomplet, une empreinte différente ou une version ambiguë provoque un refus, sans essayer silencieusement une autre source. La préparation et ses preuves restent conservées en cas d’échec ; le plafond local empêche de multiplier indéfiniment les tentatives.

Après préparation, la confirmation est limitée à dix minutes et au plan exact. L’assistant utilise le même exécutable vérifié, depuis un dossier extérieur à l’installation. Il attend la fin physique du parent ; une opération réelle encore active peut empêcher la fermeture. Une autre instance gardant le paquet ouvert empêche son remplacement. Aucun autre utilisateur n’est déconnecté.

Le code précédent est sauvegardé et relu avant remplacement. Le marqueur d’installation reste présent jusqu’au contrôle lié à la transaction : exécutable installé, runtime embarqué, WebView2 et JavaScript local. L’accusé doit correspondre au processus, au paquet et à la tentative, puis les processus de contrôle doivent être terminés. Le bilan distingue réussite, restauration des anciens binaires et état incertain. Il ne prétend pas vérifier la connexion AD ni les données métier ; celles-ci sont ouvertes au lancement normal suivant. Le bouton **Ouvrir** reste réservé au résultat vérifié.

Un échec après remplacement peut restaurer les anciens **binaires** lorsque la fin des processus est prouvée. Les bases, préférences, profils et données ne sont jamais restaurés aveuglément. Une fin physique inconnue conserve le marqueur et les preuves, sans compensation automatique.

## Reprise et retour à la version précédente

Conserver le dossier frère `.<installation>.domenia-lifecycle` et l’identifiant de transaction du bilan. Depuis un paquet vérifié distinct de la cible, les commandes `livraison apercu-reprise <cible> <transaction>` ou `livraison apercu-restauration <cible> <transaction>` produisent un plan. Lire ses changements et sa valeur `Confirmation`, puis utiliser respectivement `livraison reprendre <cible> <transaction> <Confirmation>` ou `livraison restaurer <cible> <transaction> <Confirmation>`. Aucun chemin n’est un ordre d’effacement. Une reprise imposant un contrôle de santé ne peut pas contourner cette exigence. Ne pas supprimer le marqueur pour forcer le démarrage.

Une configuration par défaut écrite sur place (`wad/Domenia.settings.seed.json`) est admise à partir de 2.1.6. Avant de restaurer une version antérieure, déplacer ce fichier hors du dossier de Domenia : depuis 2.1.7, l’aperçu de restauration le rappelle et refuse sans rien modifier.

Un code de sortie 0 confirme l’action annoncée ; 3 signale que la mise à jour a échoué mais que l’ancien code a été restauré ; 2 signifie refus ou interruption. Lire le résultat complet : une restauration des binaires ne restaure pas une base migrée.

### Cache 2.0.5 et retour arrière

Les paquets 2.0.5, 2.0.6, 2.0.7, 2.0.8, 2.1.0, 2.1.1 et 2.1.2 déclarent le schéma 11, révision native 2 ; 2.0.6, 2.0.7, 2.0.8, 2.1.0, 2.1.1 et 2.1.2 ne changent pas le format. La première écriture du nouveau cache par poste ou d’une campagne paginée migre la base dans une transaction, après sauvegarde vérifiée. Les anciennes lignes sont relues avant conversion ; une interruption annule toute la conversion. Les autres tables et les lectures historiques restent prises en charge.

Les anciens exécutables refusent une base migrée en révision 2. Un retour à 2.0.4 exige donc une sauvegarde datant d’avant cette migration ; remplacer seulement les binaires ne suffit pas. Conserver cette sauvegarde et utiliser le parcours de restauration explicite. Les nouvelles mesures enregistrées depuis la sauvegarde ne sont pas réinjectées automatiquement dans l’ancien format.

## Diffuser les fichiers

Une livraison contient :

```text
Domenia_<version>_PROD-LIGHT_Windows-x64.zip
SHA256SUMS.txt
Domenia-reference-exemple-v1.json     (facultatif, référentiel relu)
```

Le ZIP de la livraison contient directement `Domenia.exe` et le dossier `wad/`. Les bibliothèques, `web/`, `runtime/`, `guides/`, `package-release.json` et `package-manifest.json` se trouvent sous `wad/`. Les chemins du manifeste restent relatifs à la racine contenant l’EXE. PROD-LIGHT est utilisable sans installation de .NET ; il utilise le moteur WebView2 du poste, sinon le pack du Socle extrait dans `wad`. Domenia n’a pas de lanceur Admin distinct ; les droits de la session et les contrôles d’écriture restent applicables.

Sur un partage administré, réserver l’écriture aux diffuseurs et donner la lecture aux utilisateurs. Copier chaque archive sous un nom temporaire, vérifier son SHA-256 puis renommer. Publier `SHA256SUMS.txt` **en dernier**, par remplacement après transfert complet. Un même catalogue peut lister plusieurs versions et des patches de référence. Le client conserve son édition, choisit la plus récente version stable compatible et refuse les ambiguïtés. Il ne lance jamais automatiquement une archive nouvellement apparue.

Le sidecar contient une ligne par fichier : 64 chiffres hexadécimaux, deux espaces, nom simple. Produire ses valeurs sur les fichiers effectivement diffusés, par exemple avec `Get-FileHash -Algorithm SHA256`. Les SHA détectent une corruption ou un mélange ; ce ne sont pas des signatures d’éditeur. Ne pas réutiliser une empreinte d’exemple ou d’un ZIP reconstruit.

Exemple de métadonnées de structure, valeurs entre chevrons à remplacer par les preuves réelles :

```json
{
  "project": "Domenia", "version": "2.1.2", "architecture": "win-x64", "packageType": "PROD-LIGHT",
  "build": "2.1.2+<SHA256 des entrées de build>", "sourceCommit": "<commit Git 40 chiffres>",
  "executableSha256": "<SHA256 de Domenia.exe>", "dataSchemaVersion": 11, "dataSchemaRevision": 2,
  "dependencies": { ".NET": "<version embarquée>", "WebView2": "Evergreen" }
}
```

Le manifeste des composants contient leurs chemins relatifs, tailles et SHA-256. Les ajouts de composants hors manifeste sont refusés. Les fichiers opérateur explicitement admis comme configuration suivent leur propre contrat ; ils ne donnent jamais le droit d’ajouter du code. Les patches métier ont leur aperçu et leurs reçus distincts : voir `REFERENTIELS.md`.

## Retrouver les sources d’une livraison

Lire le champ `sourceCommit` dans `wad/package-release.json`, puis ouvrir ce commit
dans le [dépôt Domenia](https://github.com/M4D135/domenia-d120). Le workflow de
qualification prépare les deux archives de production à partir du même build Windows.
Les ZIP et leurs empreintes sont vérifiés avant diffusion.

## Diffuser ses réglages par défaut

Extraire le ZIP officiel dans un dossier, régler Domenia, puis choisir dans Paramètres > Configuration à diffuser
« Définir comme configuration par défaut ». Domenia écrit les réglages sélectionnés dans l’aperçu dans
**`wad/Domenia.settings.seed.json`**, à côté du logiciel ouvert. Ce dossier est alors prêt à diffuser :

```text
Domenia.exe
wad/
wad/Domenia.settings.seed.json
```

Ce fichier est hors manifeste, comme `wad/Domenia.config.json` : le ZIP officiel, son `SHA256SUMS.txt`, le manifeste et
les binaires restent inchangés. On peut aussi extraire le ZIP officiel ailleurs puis y copier le fichier dans `wad`. Ne
pas l’ajouter dans le ZIP officiel, que l’assistant de mise à jour vérifie par son empreinte. Une configuration déjà
présente est sauvegardée dans les exports de Domenia (`Domenia.settings.seed.avant-remplacement.json`) avant
remplacement ; sans dossier d’exports, elle est conservée et rien n’est écrit. Le dossier doit être sur un disque local
et accessible en écriture (pas Program Files ni un partage réseau) : régler Domenia dans un dossier extrait, puis le
diffuser. La mise à jour par
l’assistant garde le fichier, comme `Domenia.config.json`.

Le fichier contient uniquement les préférences approuvées et les éléments d’interface choisis : jamais les mots de passe,
identités de connexion ou données d’annuaire. Une OU de travail peut être incluse explicitement ; son import ne déclenche
pas de lecture AD ou de partage. `wad/Domenia.config.json` reste distinct et n’est pas modifié par cette action.

Sur un profil vierge, ces réglages sont importés automatiquement vers les données utilisateur. Sur un profil existant, le
premier lancement avec cette version et cette configuration propose de remplacer ou conserver les réglages, après aperçu
et sauvegarde préalable. Le choix est mémorisé ; l’export/import manuel reste disponible. Le profil qui a défini la
configuration ne se la voit pas reproposer. La démonstration prépare uniquement un résultat fictif.

Une copie préparée avant 2.1.6 liste ce fichier dans son manifeste. Elle reste valide, mais son fichier ne peut pas être
remplacé sur place : extraire le ZIP officiel dans un nouveau dossier et y définir la configuration. Sa mise à jour vers
un pack officiel laisse le fichier en place, hors du nouveau manifeste. `tools/vm.sh <lot> publish --zip --seed FICHIER`
fabrique encore un pack depuis les sources commitées avec le fichier dans son manifeste (même limite).

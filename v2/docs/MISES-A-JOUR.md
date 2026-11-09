# Mises à jour et diffusion de Domenia 2

État de développement : les contrôles décrits sont implémentés ; la recette critique des archives finales et la publication restent à consigner dans REPRISE.md. Une compilation seule ne vaut pas validation des packs.

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

Dans Paramètres, « Définir comme configuration par défaut » prépare une **nouvelle copie de l’édition de production ouverte** avec les réglages explicitement sélectionnés dans l’aperçu. Un dossier local est choisi, puis Domenia y crée un sous-dossier de diffusion distinct contenant le pack, son ZIP et `SHA256SUMS.txt`. Les binaires et le manifeste du logiciel actuellement ouvert restent inchangés. Une interruption conserve la copie incomplète, qui ne doit pas être diffusée.

Le fichier `wad/Domenia.settings.seed.json` fait partie du manifeste de cette copie. Il contient uniquement les préférences approuvées et les éléments d’interface choisis : jamais les mots de passe, identités de connexion ou données d’annuaire. Une OU de travail peut être incluse explicitement ; son import ne déclenche pas de lecture AD ou de partage. Le fichier local local `wad/Domenia.config.json` n’est pas copié par cette action.

Sur un profil vierge, ces réglages sont importés automatiquement vers les données utilisateur. Sur un profil existant, le premier lancement avec cette version et cette configuration propose de remplacer ou conserver les réglages, après aperçu et sauvegarde préalable. Le choix est mémorisé ; l’export/import manuel reste disponible. La démonstration prépare uniquement un résultat fictif.

Pour fabriquer directement un pack depuis les sources commitées : `tools/vm.sh <lot> publish --zip --seed /chemin/vers/Domenia.settings.seed.json`. Le script fige les octets, les relie au transfert par SHA-256 et demande au codec compilé dans la VM de les valider avant publication. Le seed est inclus avant le calcul des manifestes des éditions de production et des empreintes des ZIP. Ne pas ajouter ou modifier manuellement le seed dans un pack déjà manifesté : utiliser le bouton de préparation ou republier.

# Domenia 1.0

Application Windows d'administration Active Directory : recherche d'objets, base locale,
inventaire des postes, tableaux de bord et atelier de requêtes.

## Télécharger

Révision **RC1.17.14**, candidate : accueil recentré sur les données, sections déplaçables,
Santé en dernier par défaut, tailles de widgets conservées, progression globale des lots en haut.
Après un délai WMI, une saturation temporaire du moteur attend la libération des lectures en nettoyage
au lieu dʼarrêter le lot et de perdre le poste suivant.
La connexion corrigée dans RC1.17.10 a été confirmée par David sur son poste.
La qualification complète des ZIP et les parcours GUI sur AD restent ouverts.
L’assistant de première configuration reste en haut jusqu’à sa fin. Les mesures de lenteur restent dans le diagnostic, sans avertissements répétitifs dans le journal de session. Guides Word/PDF actualisés.
RC1.17.13 : vérification de la base en arrière-plan, commandes repliables sur les fenêtres très basses et DLL construites de façon déterministe.
RC1.17.14 : occupation de la base complétée (métadonnées de domaine), empreinte des règles de santé stable à la purge des suspensions expirées, identité des associations harmonisée entre grille, résumé et fiche, transport réellement utilisé affiché au lieu dʼêtre déduit, identité du poste contrôlée aussi pour les sondes seules.
Voir les [corrections et preuves du 17 octobre](validation/2026-10-17/rc14-corrections/README.md).

| Pack | Téléchargement direct |
|---|---|
| **PROD** — utilisation | [Domenia_PROD.zip](https://github.com/M4D135/domenia-d120/raw/refs/heads/master/packs/Domenia_PROD.zip) |
| **DEV** — sources et outils | [Domenia_DEV.zip](https://github.com/M4D135/domenia-d120/raw/refs/heads/master/packs/Domenia_DEV.zip) |

[Contenu et reconstruction des packs](packs/README.md) · [Empreintes SHA-256](packs/SHA256SUMS)

## Utilisation

Extrayez complètement le pack puis lancez **Domenia.exe**. Le lanceur et son dossier
**wad** doivent rester ensemble. Cible : Windows PowerShell 5.1 x64, WPF et
.NET Framework 4.7.2 ou ultérieur. La fenêtre de connexion reste au-dessus des
autres fenêtres jusqu’à sa fermeture.

Deux distributions sont prévues :

- **PROD** : `Domenia.exe` et le dossier ordinaire `wad`.
- **DEV** : le même runtime, les sources, les outils de fabrication et les tests.

Dans **Accueil** et sous l’arbre de **Recherche**, choisissez l’OU puis l’action :

- **Base locale** : relire les objets dans AD et enregistrer la copie locale.
- **Postes (ping/WMI)** : relire le ping, la console, l’inventaire léger des postes actifs déjà recensés et les sondes des widgets configurés.
- **Les deux** : terminer l’enregistrement AD, puis relever les postes.

Ces actions couvrent toujours **l’OU et ses sous-OU**, indépendamment des filtres et de la limite
de la liste. Le nombre de postes est confirmé avant collecte ; **Arrêter** empêche la phase suivante.
Les mesures demandées par **Postes** sont fraîchement relues ; les anciennes valeurs restent datées
en cas d’échec. **Recalculer la vue** relit seulement les données locales : la date du calcul,
la date AD et celles du ping/WMI restent distinctes.

Dans **Outils > Base autonome**, privilégiez **Mettre à jour l’OU choisie**.
Choisissez son emplacement dans l’arbre, avec recherche et chargement progressif.
Cette action inclut les sous-OU et conserve les autres branches. Les onglets
**Mise à jour**, **Données** et **Stockage** séparent les opérations et affichent
leur progression. Ces lectures actualisent la copie locale, sans modifier l'annuaire.

Les vues indiquent leur périmètre et la fraîcheur des données. Un objet recensé,
un poste actif et un poste joignable sont trois informations distinctes. Les données
absentes ou périmées restent inconnues. L’icône de détail des indicateurs ouvre
les objets ou la requête correspondante ; le crayon sert à modifier la présentation.
Le zoom **− / 100 % / +** conserve la taille d’interface choisie.

Dans **Recherche**, la barre **Requêtes** réunit les filtres Annuaire et les requêtes
locales : filtrez la liste, épinglez vos favoris, puis cliquez sur **Exécuter**.
Le périmètre est l’OU choisie dans Recherche, avec la profondeur affichée. Les
résultats locaux distinguent les correspondants, les inconnus et les non-correspondants ;
leur compteur indique la population recensée et toute limite d’affichage.

Pour une recherche AD, le compteur indique les lignes visibles parmi les lignes chargées.
**Liste partielle** signale une lecture interrompue ; **Limite atteinte** indique le plafond demandé.
Le bandeau **Dernière requête AD : délai dépassé** signale une attente expirée, sans conclure
à une coupure générale. Une lecture AD réussie rétablit le bandeau de connexion. La recherche attend
par défaut jusqu’à **2 minutes sans nouvelle ligne AD**, avec un plafond total de **15 minutes**.
La lecture utilise des pages de **250 objets** ; les réglages des anciennes installations sont
relevés automatiquement au minimum prévu. Le journal précise la durée et les lignes reçues
en cas d’interruption.

L’atelier se trouve dans **Outils > Atelier de requêtes** ; le petit crayon de
Recherche y mène directement. Il partage une bibliothèque entre **Recherche**,
le **tableau général** et le **tableau d’un poste**. L’onglet **Bibliothèque** propose **152 modèles prêts**
classés en 14 catégories, avec recherche, description et origine des informations.
Son catalogue décrit 105 champs pris en charge, dont
78 sondes, avec leur origine et leurs conditions de collecte. Les requêtes évaluent
les données locales ; la collecte distante reste une action explicite. Elle regroupe
les propriétés WMI compatibles. La collecte sélective de l’Atelier peut réutiliser les mesures
encore fraîches selon son réglage ; les actions générales **Postes** et **Les deux** les relisent.

## Documentation

| Public | Word | PDF |
|---|---|---|
| Technicien | [Guide technicien](DOC/Domenia-1.0-Guide-technicien.docx) | [Guide technicien](DOC/Domenia-1.0-Guide-technicien.pdf) |
| Administrateur | [Guide administrateur](DOC/Domenia-1.0-Guide-administrateur.docx) | [Guide administrateur](DOC/Domenia-1.0-Guide-administrateur.pdf) |

[Installation, mise à jour et fabrication](dev/LIRE-MOI.md) ·
[Sources des guides](guides/LIRE-KIT.md) ·
[Bilan des améliorations et preuves](validation/2026-10-13/README.md)

## Modifier et reconstruire

Modifiez les sources du DEV puis lancez **dev/FABRIQUER_PROD.cmd** sous Windows.
L'outil fabrique un nouveau dossier PROD, vérifie ses composants et régénère les
contrats et manifestes. Il utilise PowerShell 5.1 ; aucun Python ni compilateur
n'est nécessaire pour assembler des DLL déjà construites.

Les sources C# propres à Domenia sont dans `dev/native`. Le moteur de requêtes
commun est épinglé dans `dev/vendor/m4d-admin-common`. Les tests et leur portée
sont conservés avec les sources et dans le dossier de validation. Les essais avec
un parc synthétique et les contrôles WPF en VM restent distincts de la recette
sur un domaine réel.

Chaque widget affiche la source et les dates des données, avec un petit ↻ permanent qui relit la source. La première configuration prépare automatiquement sa vue après la lecture de la base.

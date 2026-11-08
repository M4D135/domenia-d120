# Domenia 1.0 RC1.8 : relations par sélection et alignements

Build : `2026.10.01-DOMENIA-1.0-RC1.8-RELATIONS`.
Base : archives originales Domenia RC1.7 de cette conversation. Version candidate, à valider sous Windows.

## 1. Corrections visuelles

### Recherche du bandeau

Le champ utilisait une marge de contenu ajoutée à son remplissage, alors que le texte indicatif était positionné séparément. Il a maintenant un modèle dédié : un seul remplissage, un hôte de texte sans marge dupliquée et un texte indicatif qui reprend aussi la marge interne du curseur bidirectionnel de WPF. Police, taille, graisse et alignement sont partagés. Aucun espace n'est ajouté au texte saisi ni à la requête LDAP.

Le contrôle natif fourni mesure le point de départ du caractère avec `GetRectFromCharacterIndex`, puis celui du texte indicatif. Ce contrôle WPF reste à exécuter sur Windows ; les vérifications XML exécutées ici ne sont pas une mesure de pixels.

### Activité

Le commentaire de l'opération passe dans la première colonne extensible, alignée à gauche sous le titre. L'ancien emplacement réservé au bandeau de mode écriture se trouve à sa droite, avant la barre et Annuler. La ligne de 44 unités WPF reste réservée en permanence. Les dimensions et les positions des compteurs, de la barre et d'Annuler ne dépendent toujours pas de leur visibilité.

L'avertissement d'écriture n'est pas retiré. Le nom long se tronque sur une seule ligne et reste disponible au survol. Aucun changement de moteur, de droit ou d'annulation n'est nécessaire à ces deux corrections.

## 2. Relations : la sélection n'est plus noyée dans tous les liens

Le panneau contient quatre onglets distincts :

| Onglet | Contenu |
|---|---|
| **Utilisateur sélectionné** / **Poste sélectionné** | Les associations enregistrées correspondant à la sélection et à son identité connue. Une absence est explicitement affichée. |
| **Toutes les associations** | La liste locale complète. Elle ne remplace plus la vue de la sélection lorsqu'un contrôle prend le focus. |
| **Postes trouvés / indices** | Postes candidats relus dans AD et indices supplémentaires, avec origine, état et date. Une ligne avec seulement une adresse IP n'est pas un poste AD identifié. |
| **Détail de la recherche** | Sources lues, erreurs et limites : refus AD, refus poste, timeout, résultat vide, budget atteint, etc. |

Un simple clic sur un utilisateur dans Rechercher fixe ce contexte sans ouvrir sa fiche ni sonder de poste. Le double-clic conserve l'ouverture de la fiche. Une multisélection n'est pas transformée en recherche inverse collective. Le nom de l'utilisateur retenu est affiché au-dessus des commandes ; les champs édités d'une fiche ne servent pas à choisir sa cible.

Une actualisation des associations ne sélectionne jamais automatiquement l'onglet Toutes. Exporter utilise le tableau d'associations actif ; Supprimer utilise sa ligne sélectionnée. Les colonnes des tableaux existants conservent leurs noms/liaisons pour préserver les préférences.

## 3. Pourquoi l'ancienne recherche pouvait ne rien remonter

Plusieurs défauts concrets ont été retirés du parcours RC1.7 :

- `TabRelations.GotFocus` rappelait `Refresh-LinkGrid -All`. Cet événement se propageait depuis les contrôles enfants et réaffichait tous les liens.
- La recherche inverse ne reprenait pas systématiquement les associations déjà connues comme résultats historiques de départ.
- La boucle de balayage transmettait une variable `$cred` non définie à la création de session CIM. Elle ne suivait donc pas correctement le choix du compte poste utilisé par le parcours de détection unitaire.
- Un filtrage préalable par ping pouvait éliminer une machine dont ICMP est bloqué alors qu'une lecture de console reste possible.
- Des refus de lecture étaient absorbés par les tentatives de secours. Certaines sources de dernier utilisateur enregistré pouvaient être présentées comme une session actuelle.
- Une adresse IP issue d'un événement de contrôleur était normalisée comme un nom de machine, avec perte de la partie suivant le premier point.
- Les anciens callbacks ne vérifiaient pas suffisamment l'utilisateur exact : une sélection de type Utilisateur ne suffit pas à rattacher le résultat au bon compte.

Ces constats reposent sur le code des archives RC1.7. Ils n'établissent pas lequel explique à lui seul le poste de l'utilisateur, et aucun résultat réel sur le domaine n'est prétendu validé ici.

## 4. Nouveau parcours explicite

### Recherche sans sonde de poste

**Rechercher les postes** relit le compte exact (DN, identifiant et GUID), reprend les liens connus et examine les indices AD, notamment `managedBy` et les mentions du compte dans description/emplacement. Une association connue garde sa date historique. Un responsable déclaré ou un nom dans une description reste un indice : ces données ne prouvent pas une connexion actuelle.

Le journal du contrôleur est optionnel et décoché. S'il est demandé, les événements 4768 sont ciblés sur le SID du compte, sur sept jours et au maximum 100 événements du contrôleur choisi. L'adresse IP entière et la date sont conservées comme indice, sans conversion hasardeuse en nom de poste ni association automatique. Un refus de lecture est affiché.

### Vérification volontaire des consoles

Les options sont repliées par défaut. **Vérifier les consoles des postes, après confirmation** est décoché. Après activation, le bouton Rechercher demande une confirmation mentionnant la cible, la portée et le maximum de postes.

Trois portées sont possibles :

| Portée | Postes contactés |
|---|---|
| Postes connus et indices AD | Candidats identifiés dans le domaine, avec priorité aux liens connus. |
| Machines de la liste chargée | Uniquement les GUID résolus correspondant à cette liste. Les indices trouvés ailleurs ne sont pas sondés. |
| OU sélectionnée | Uniquement les candidats de cette OU et de la profondeur demandée. L'ensemble reste borné et n'est pas un inventaire exhaustif du domaine. |

Le maximum proposé est de 20 postes, réglable de 1 à 50. Le budget de recherche est de 120 secondes lorsqu'une vérification est demandée ; les appels CIM demandent quatre secondes par opération. Ces valeurs sont des bornes de programmation, pas une garantie qu'un appel natif ou le système répondra exactement dans ce délai.

Le worker utilise **le compte poste configuré ou son compte alternatif**, en CIM/DCOM. Le compte de lecture AD reste distinct. Il n'ajoute aucun service, aucun fichier, aucune tâche planifiée et ne tente pas PsExec. Il n'active pas WinRM. Aucun ping préalable ne bloque la lecture de console. Un rejet d'identifiants suspend les nouvelles tentatives de ce canal.

Seule une console renvoyant le compte qualifié du domaine attendu ou son UPN exact peut être confirmée. Un compte local homonyme, un nom non qualifié, une réponse provenant d'un autre nom de machine ou un compte d'un autre domaine n'est pas associé automatiquement.

**La propriété UserName de Win32_ComputerSystem est limitée à la console.** Elle ne fournit pas un inventaire de toutes les sessions RDP. Une console vide ne prouve pas l'absence de connexions RDP ; la vue Sessions existante reste distincte.

### Associations enregistrées

Les consoles effectivement confirmées, avec ordinateur et utilisateur relus dans AD, rejoignent la sauvegarde locale existante par lot. Les liens manuels sont préservés, y compris si une nouvelle observation porte sur le même utilisateur. Un indice AD/IP n'est jamais enregistré automatiquement comme relation confirmée.

Le bouton **Associer ce poste** dans les candidats permet une déclaration locale volontaire, après confirmation. Il ne prétend pas confirmer une connexion et ne modifie pas l'AD.

Une erreur, une console vide ou un autre utilisateur observé ne supprime pas un ancien lien. L'historique reste présenté comme tel. Si la file d'enregistrement ne peut pas accepter la mise à jour, un message le signale : une observation en mémoire n'est pas présentée comme déjà enregistrée sur disque.

## 5. Réactivité et contexte

Le parcours reste dans un runspace. Une file concurrente publie les étapes et les candidats en cours de lecture ; l'interface traite de petits lots (au plus huit événements, budget coopératif de quatre millisecondes par passage). La file est bornée et le résultat final contient l'ensemble borné des résultats même si des mises à jour intermédiaires n'ont pas été affichées.

Les retours sont vérifiés par session, domaine, serveur/comptes, génération, identifiant de demande, DN, login et GUID. Changer d'utilisateur invalide le parcours précédent. Une annulation arrête la prise en compte de ses résultats, ne supprime pas les associations et ne garantit pas l'arrêt instantané d'un appel Windows déjà parti.

Les enregistrements passent par la file locale existante et se font par lot. Le remplacement global du tableau d'associations n'est pas exécuté à chaque événement de progression. Les ressources LDAP et les sessions CIM créées par ce nouveau parcours sont libérées dans des blocs finally.

**Charger une OU ou rechercher globalement ne lance toujours aucun balayage de postes.** Ping et utilisateur restent réservés à une sélection de machine, sauf une vérification inverse explicitement demandée dans les options ci-dessus.

## 6. Ce qui est conservé

Authentification et login FILPRO sans mini-journal, compteurs fixes, barre d'activité à hauteur réservée, recherche globale indépendante de l'OU, cache et schéma SQLite, restauration de l'arbre/colonnes, politiques d'écriture, reçus et consentements, sondes unitaires à la sélection. Les binaires, les configurations et les modules métier non concernés ne changent pas.

Le registre reste à **55 opérations**, avec la mise à jour explicite du seul corps `UserComputerProbe` et de l'empreinte globale. Le nouveau module de présentation/recherche inverse rejoint le chargeur fermé (21 modules, 235 fonctions déclarées), sans suppression du contrôle de démarrage.

## 7. Installation

Fermer Domenia après la fin des opérations. Extraire DEV dans un **dossier distinct**, puis depuis ce dossier `dev` :

```powershell
# Remplacer par le dossier actuel qui contient Domenia.exe et wad.
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\Domenia' -WhatIf
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\Domenia'
```

Conserver l'installation, les données, les reçus et les configurations. L'installateur garde `wad\data` et les réglages existants, ne remplace pas les données de `%LOCALAPPDATA%\Domenia\Data`, sauvegarde le code et installe ensemble le nouveau module, le cœur et les manifestes. Il ne faut pas remplacer un script isolément.

PROD conserve `prod/Domenia.exe` et `prod/wad` seulement à la racine. Le déblocage est dans `wad/Support/DEBLOQUER_TOUT.cmd`. Aucun test, aperçu ou outil de développement n'est requis au démarrage PROD. L'exécutable est celui de RC1.7, non recompilé et non signé ; le moteur annonce RC1.8.

## 8. Vérifications, tests et aperçu

Exécutés sur l'hôte Linux : audit général Python (structure, contrats, XML et essais SQLite existants), audit ciblé des modifications et des comparaisons d'empreintes, construction et contrôle indépendant des deux ZIP. Les rapports des versions précédentes restent historiques.

**Non exécutés ici : Windows PowerShell 5.1, WPF, rendu des pixels, authentification, LDAP/CIM sur un domaine, trafic réseau ou benchmark de fluidité.** Une analyse lexicale et un test XML ne remplacent pas le parseur natif ni une mesure WPF.

`TESTER-RELATIONS.cmd` fournit **65 scénarios Windows isolés**. Ils appellent les vraies fonctions et le vrai corps du worker avec des LDAP/CIM/événements fictifs ; aucune connexion réelle n'est lancée. Ils couvrent la séparation des liens, les contextes et annulations, les GUID recréés, les comptes distincts, l'absence de scan implicite, les portées, les refus, les limites, les dates historiques, les IP intactes et les ressources libérées. Les douze derniers scénarios mesurent les vrais contrôles WPF clair/sombre, le départ du texte et la stabilité de l'activité.

L'installateur lance cette suite avant la copie et exige un rapport complet sans scénario ignoré. Les tests de chargement des modules ont été adaptés au nouveau contrat. Les suites antérieures de comportement restent incluses ; leurs audits de diff historiques ne sont pas des audits de cette version.

`APERCU-RELATIONS.cmd` exécute la même suite puis ouvre les vrais contrôles avec deux comptes et postes fictifs, dont un refus de console. Il n'authentifie personne, ne lit pas le cache personnel et n'active pas les actions métier. Ce n'est pas une capture vérifiée ici ni une démonstration de réussite sur le domaine.

### Recette réelle

1. Choisir un utilisateur dans la recherche, ouvrir Relations : son nom et ses seuls liens connus doivent apparaître. Cliquer les contrôles ne doit pas changer pour Toutes.
2. Passer volontairement dans Toutes les associations, puis revenir à Utilisateur sélectionné. Vérifier l'export du bon tableau et les colonnes mémorisées.
3. Rechercher sans cocher la vérification réseau : observer les indices et le détail des lectures. Aucun poste distant ne doit être sondé.
4. Choisir des candidats ou une petite OU de recette, un maximum réduit et un compte poste autorisé. Confirmer la vérification et examiner chaque résultat, y compris refus et délai.
5. Changer d'utilisateur pendant une lecture lente : aucun résultat ou lien de la précédente requête ne doit être attribué au nouveau compte.
6. Contrôler le placeholder, une saisie courte/longue, les deux thèmes, la disposition de l'activité et la restauration du cache après fermeture normale.

## Références primaires

- Microsoft WPF `TextBoxBase` et `TextBoxView` (transfert du Padding à l'hôte et marge du curseur bidirectionnel) : dépôt dotnet/wpf, sources PresentationFramework.
- Microsoft Learn, `Win32_ComputerSystem.UserName` : https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-computersystem
- Microsoft Learn, événement 4768 : authentification Kerberos et adresse source, pas inventaire universel des postes de l'utilisateur.
- Microsoft Reference Source, `ConcurrentQueue<T>` : le parcours reste compatible avec .NET Framework et ne dépend pas de la méthode Clear des versions .NET modernes.

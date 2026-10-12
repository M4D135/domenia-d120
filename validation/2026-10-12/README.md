# Domenia 1.0 — bilan des améliorations

Ce bilan couvre les 30 points du programme demandé et les ajouts de la session.
Les détails, fichiers concernés, preuves et limites sont dans le
[registre complet](completion-ledger-20261012.json).

## Changements principaux

- Mises à jour locales atomiques, checkpoints fiables, réconciliation des objets déplacés ou absents et fraîcheur explicite.
- **Tout relire dans lʼOU choisie** est l’action principale et comprend ses sous-OU. Sans sélection valide, le sélecteur s’ouvre.
- **Tout relire dans le domaine** est séparé, confirmé et annoncé long et occasionnel. Ces lectures actualisent la copie locale, sans écrire dans AD.
- Atelier de requêtes, bibliothèque, filtres réutilisables en recherche et sondes de dashboard ; 78 définitions de sondes et 29 widgets Parc.
- Comptages et listes partagent le périmètre, le filtre et l’identité des objets ; tri global avant pagination de 200 éléments.
- Base autonome : réglages défilants, état/progression visibles, tableau redimensionnable, colonnes lisibles et détails compacts.
- Connexion autonome Standard/Debug maintenue au-dessus des autres fenêtres jusqu’à sa fermeture ; remise à zéro après succès, annulation et erreur. La reconnexion embarquée ne promeut pas la fenêtre principale.
- Moteur Query partagé épinglé, noyau C# ciblé et deux distributions classiques. PROD reste `Domenia.exe` avec le dossier `wad`.

## Les 30 points

| N° | Sujet | Réalisation |
|---|---|---|
| 1 | Lectures partielles et checkpoints fiables | Implémenté |
| 2 | Fraîcheur et couverture des données | Implémenté |
| 3 | Objets déplacés, supprimés et désactivés | Implémenté |
| 4 | SQLite atomique, lots isolés et arrêt/reprise | Implémenté |
| 5 | Sauvegarde vérifiée, restauration et corruption | Implémenté |
| 6 | Requêtes AD bornées, collecte groupée, inconnu distinct du négatif | Implémenté |
| 7 | Protection des opérations critiques | Implémenté |
| 8 | Clés de cache, TTL et invalidations | Implémenté |
| 9 | Métriques du cache et purge sûre | Implémenté |
| 10 | Réduction des copies et relectures répétées | Implémenté |
| 11 | Lots SQLite, index et agrégats | Implémenté |
| 12 | Workers, réactivité UI, heartbeat et annulation | Implémenté |
| 13 | Phases de collecte, progression, OU, quotas et erreurs | Implémenté |
| 14 | Attributs AD minimaux et lectures coûteuses ciblées | Implémenté |
| 15 | Dashboard autonome et consultation détaillée | Implémenté |
| 16 | Comptages cohérents avec portée, source et date | Implémenté |
| 17 | Sélecteurs OU indépendants et pratiques | Implémenté |
| 18 | États vide, incomplet, ancien ou inconnu explicites | Implémenté |
| 19 | Correspondance exacte entre tuile et objets | Implémenté |
| 20 | Libellés français homogènes | Implémenté |
| 21 | Résultats compacts et détails repliables | Implémenté |
| 22 | Tri typé global des dates et tailles | Implémenté |
| 23 | Virtualisation, colonnes et DPI | Implémenté |
| 24 | Contraste, clavier et accessibilité | Implémenté |
| 25 | Cartes, graphiques, confirmations et erreurs utiles | Implémenté |
| 26 | Exports français exploitables | Implémenté |
| 27 | Tests et prévention des régressions | Implémenté |
| 28 | Mesures de performances et parc de 5 000 postes ou plus | Implémenté |
| 29 | Réduction de duplication et retrait de code abandonné | Implémenté |
| 30 | Documentation DOCX/PDF V1.0 | Implémenté |

## Contrôles exécutés

Les [preuves Windows](windows/qualification.json) proviennent de la VM **CNAMTS-W11-01**,
Windows PowerShell **5.1.26100.6584 x64 STA**. Les données sont fictives, sans accès à AD.
Les rapports des différentes archives sont conservés avec les comparaisons de fichiers
et de fonctions qui relient les reprises ciblées. Les premiers échecs restent traçables ;
les rapports de reprise indiquent les corrections effectivement validées. Les copies
texte versionnées normalisent LF et les espaces de fin de ligne ; les originaux restent
conservés dans le dossier local `validation-Windows-20261012`.

| Contrôle | Résultat |
|---|---|
| Cœur / règles | 207 / 547 contrôles réussis |
| Requêtes / résilience / détection Parc | 105 / 32 / 22 réussis |
| Tableaux WPF | 40 réussis |
| Tri global / DN échappés / persistance | 545 / 284 / 155 réussis |
| Actions OU / domaine | 18 réussis |
| Cycle de vie du login | 8 scénarios, 74 assertions réussies |
| Fabrique PROD sous PowerShell 5.1 | 91 composants identiques et démarrage CheckOnly réussi |
| Packaging local | 30 tests réussis |
| Fenêtre Base | 11 lignes complètes à 1080p, 3 à 720p, clips des parents inclus |
| Captures | 23 PNG d’au moins 1920×1080, sans infobulles, 22 assertions documentaires réussies |

Le [banc synthétique de 10 000 postes](domenia-scale-dn-final-10000.json) passe **29 122 assertions**,
avec 78 sondes et 29 widgets. Il mesure notamment environ 3,85 s d’écriture initiale SQLite,
0,21 s de parcours des pages de requête et 2,28 s des pages de Base. La mémoire gérée conservée
au point de mesure est de **704,3 Mio**, la base de **98 Mio**. Ces chiffres viennent du banc
local macOS/PowerShell 7 et ne sont pas une mesure du réseau, d’AD ou de la fluidité Windows.

## Guides

Deux guides **Domenia 1.0**, sans historique produit : technicien **24 pages**, administrateur
**63 pages**, **25 figures par guide**. DOCX et PDF sont dans [DOC](../../DOC).
Les 87 pages ont été relues visuellement. Le [rapport documentaire](documentation-qa.json)
lie les quatre fichiers et les captures à leurs empreintes SHA-256.

## Archives

Les contrôles d’intégrité et les manifestes passent. Les **91 fichiers runtime** sont identiques
entre DEV et PROD ; les manifestes de distribution sont propres à chacun.
Voir le [rapport de construction](build-report.json) et la
[comparaison avec les sources](archive-source-equivalence.json).

| Pack | SHA-256 |
|---|---|
| DEV | `47B21D448E2B4BAFE03E246B0B433725C1013DE628D19C1119E06954E71570F0` |
| PROD | `E323AAEDD5E3072C9FC24DA82A6959853136F80EC53143428A6AA2B04F890BE9` |

Le DEV contient `FABRIQUER_PROD.cmd` pour régénérer PROD sous Windows PowerShell 5.1,
à partir des sources et DLL livrées, sans Python ni compilateur pour cet assemblage.

## Portée et limites

- Les rendus WPF sont natifs, hors écran en **session 0**. Les événements de test sont routés par WPF ; aucune manipulation humaine du bureau ni vérification Alt-Tab entre applications n’est revendiquée.
- Aucune recette complète sur un domaine réel : droits, LDAP/WMI, réplication, latence réseau et écritures AD restent à qualifier dans le SI cible.
- Le contrôle formel de release demeure `WindowsQualification=NOT_EVALUATED` et `Publishable=false`. Les contrôles rapides demandés ne sont pas convertis en qualification exhaustive.
- Le cache est borné par la mémoire, le disque et la rétention ; aucune capacité infinie. Les détails de limite par stockage figurent dans le guide administrateur.
- La restauration de sauvegarde est manuelle ; pas d’assistant ni de planificateur automatique. La qualification multi-écrans/DPI dynamique et lecteur d’écran reste ouverte.
- Le suivi D001–D120 antérieur conserve ses règles de qualification ; le bilan des 30 améliorations ne force pas ses champs `acceptance_passed` à vrai.

## GitHub

Sources, documents et preuves publiés sur **master** (commit applicatif `b80718b`).
Les **13 branches distantes déjà fusionnées** ont été supprimées dans la même transaction,
avec vérification de leur référence exacte ; leurs commits restent dans l’ascendance de master.
Les clones, worktrees et archives locaux sont conservés. Voir le
[reçu vérifié](publication-receipt.json) et le [plan de nettoyage](github-cleanup-plan.json).
Aucune release GitHub formellement qualifiée sur AD n’a été créée.

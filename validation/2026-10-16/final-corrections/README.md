# RC1.17.12 — corrections finales du 16 octobre 2026

Lʼassistant de première configuration apparaît désormais au-dessus du tableau de bord tant que son parcours reste à terminer. Sa dernière étape conserve le premier calcul automatique ajouté en RC1.17.11.

Les ralentissements passagers des publications dans lʼinterface sont conservés dans les traces et le diagnostic de lenteur, sans avertissement répété dans le journal de session. Les erreurs opérationnelles, refus et délais dépassés restent visibles.

Après lʼenregistrement dʼun lot ping, la vue WPF de la source est maintenant actualisée une fois par lot. Le simple appel à `Items.Refresh()` redessinait la collection sans réévaluer son filtre : les valeurs étaient correctes mais les lignes pouvaient rester dans un filtre devenu faux. Le défaut est reproduit dans `park-before.json` et corrigé dans `park-after.json` (2 cas réussis).

Les deux guides Word et PDF sont remis à jour : premier calcul, assistant en haut, tailles fixes, déplacement des sections, suivi du lot, sources et dates et boutons de relecture. Les illustrations historiques sont conservées. Voir `documentation-qa.json` pour les fichiers, empreintes, 31/80 pages et le détail exact de la vérification visuelle.

## Vérifications ciblées sur les sources

Exécution native Windows PowerShell 5.1 x64 STA dans CNAMTS-W11-01, avec données fictives et réseau simulé. Aucun AD/WMI réel et aucune campagne générale relancée.

| Rapport | Réussites | Échecs |
|---|---:|---:|
| `interface-telemetry.json` | 10 | 0 |
| `search-counter.json` | 12 | 0 |
| `last-user.json` | 21 | 0 |
| `search-presence.json` | 68 | 0 |
| `park-after.json` | 2 | 0 |
| `navigation.json` | 2 | 0 |

Les fixtures de recherche suivent maintenant le circuit de persistance, les identités GUID et les frontières dʼauthentification actuels. Le test des vues personnelles initialise lʼordre des colonnes WPF non affichées ; leurs indices restaient à −1 dans ce montage, ce qui supprimait la disposition lors de sa validation. Les champs et la largeur sont restaurés dans le test corrigé. Le contrôle de planification du parc laisse trois ticks pour les deux cibles, sans modifier les assertions de confirmation et de non-collecte.

## Portée de la livraison

Les corrections fonctionnelles RC1.17.11 restent présentes : accueil allégé, Santé en dernier par défaut, sections déplaçables, tailles S/M/L fixes, reprise après saturation liée à un délai WMI, suivi du lot complet, premier calcul et métadonnées des widgets. Les requêtes WMI personnalisées de lʼatelier conservent leur parcours de collecte explicite ; les boutons des widgets standards relisent leurs sources.

La liste générale garde 151 points implémentés avec qualification en attente et 9 points de qualification seule (41, 43, 106, 114, 116, 125, 126, 129, 130). Aucun `acceptance_passed` nʼest ajouté. Les scénarios de domaine réel, coffre Windows, LAPS, double écran/DPI, lecteur dʼécran, charge 10 000/20 000 postes, disque plein physique et recette humaine restent à qualifier. Les anciennes observations géométriques de la campagne RC1.17.8 ne sont pas requalifiées par cette livraison ; lʼhypothèse de modification des bindings XAML proposée par lʼagent nʼest pas intégrée sans preuve.

OpenCode est utilisé avec le modèle gratuit `opencode/glm-5.3-flash-free`. Ses propositions sont relues ; elles ne constituent pas une preuve dʼexécution. La demande Spark sur les deux cas Park a été annulée après leur résolution et vérification, sans réponse publique ni code intégré.

À la demande finale de David, les travaux sont figés pour commit/push sans nouvelle campagne. La seconde passe OpenCode est interrompue : ses ajustements de fixtures Boards (dépendance QueryDetails, libellé Partiel et lignes incomplètes) sont conservés après relecture, sans revendiquer de nouvelle exécution Windows. Le contrôle géométrique tolère le pixel dʼarrondi entre deux textes centrés dans la même rangée. La qualification complète Boards/Geometry reste ouverte.

## Archives RC1.17.12

Construction et contrôle dʼintégrité réussis. Les 172 fichiers dʼexécution PROD/DEV sont identiques et correspondent aux sources, hors manifestes propres aux éditions. Voir `delivery.json`. Les archives finales ne sont pas réexécutées en VM après la demande de commit/push immédiat ; les 115 cas Windows ci-dessus portent sur les sources ciblées. Le statut reste candidat.

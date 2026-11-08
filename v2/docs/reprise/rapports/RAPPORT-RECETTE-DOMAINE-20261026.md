# Domenia 2.0.1 — correctifs et recette finale du 26 octobre 2026

**Les correctifs sont poussés, les deux workflows Windows sont réussis et le pack final a passé une recette de lecture réelle du domaine. La performance du démarrage sur VM reste non qualifiée ; la recette manuelle de David reste à effectuer.**

Branche : `codex/v2-correctifs-recette-20261026`, depuis `31ba4eaadffc44b1de88380b523bce99655c3411`.
Source exacte des nouveaux packs : [`ba2eb50c82a218a602f12c646d38f058e59d6414`](https://github.com/M4D135/domenia-d120/commit/ba2eb50c82a218a602f12c646d38f058e59d6414).
Identité de fabrication : `2.0.1+ba8bd5d4d78c21baa1dfc37d7cbf4fbda3a1a9888f4fce471ced0f2a49251883`.
Le commit documentaire postérieur ne change pas ces octets. Les anciens packs FBE et leurs preuves sont conservés ; la release et le tag v2.0.0 restent intacts. Aucune nouvelle release n’a été publiée.

## Causes établies et corrections

- Le contrôle d’intégrité précédait tout retour visible. Une fenêtre native décrit désormais les phases avant WebView2, permet la demande d’annulation et conserve le contrôle SHA256 complet. Un tampon partagé remplace les tampons de lecture conservés par fichier ; les handles vérifiés restent détenus. Les traces séparent intégrité, composition, interface et connexion.
- Le démarrage web consultait l’état de session sans constituer une connexion explicite. L’entrée **Se connecter** est raccordée au moteur, avec un seul essai suivi, annulation et protection contre les résultats d’un ancien contexte. L’autre compte conserve sa saisie native. Les états déconnecté, OU à choisir, lecture nécessaire et erreur sont distincts.
- Une réponse LDAP valide associant un attribut simple vide et sa variante par plage était refusée comme doublon. Ce cas précis est corrigé ; les contrôles de bornes, limites, doublons réels, GUID et USN restent actifs. Les diagnostics sont corrélés et bornés, sans valeurs AD. Une erreur préalable arrête les collectes suivantes et conserve base, sauvegarde et état d’erreur.
- Le mode configuré, la connexion et l’autorisation effective d’écriture sont distingués. La lecture reste le défaut ; les gardes moteur vérifient les conditions de session avant et après les préconditions. La maintenance locale autorisée reste possible hors connexion.
- Les déplacements décoratifs des pictogrammes fonctionnels sont retirés. Les cartes contiennent les SHA complets et copiables ; états longs, notifications et petite hauteur sont corrigés et testés.
- La première recette VM a révélé un faux succès du pilote E2E quand la fermeture n’avait pas de code de sortie confirmé. Le dernier commit corrige ce verdict, conserve l’erreur de fermeture et teste ce comportement. Il ne change aucun fichier produit `v2/src/` ou `v2/web/` par rapport à FBE.

Les commits français de code vont de `1dc6f64e` à `fbe5caab`, puis `ba2eb50c` pour le pilote. L’ordre final a été : code et push → GitHub → nouvelle recette VM.

## Contrôles GitHub réellement exécutés

[Livraison et tests 40317233027](https://github.com/M4D135/domenia-d120/actions/runs/40317233027), job `121552775714`, et [compilation 40317232775](https://github.com/M4D135/domenia-d120/actions/runs/40317232775), job `121552774935` : succès sur le SHA BA2.

| Contrôle | Résultat |
|---|---|
| Debug et Release | 0 erreur, 0 avertissement |
| Sélection C# critique | 679 réussis ; 1 718 autres non exécutés |
| Autocontrôles du pilote E2E | 25 réussis |
| Python | 31 réussis : 15 + 8 + 8 |
| Web | 79 réussis dans chacun des deux passages |
| Application empaquetée, simulation | 6 scénarios réussis, 71 captures |
| Revue visuelle CI | 105 PNG examinés ; réserves détaillées conservées |

SDK et dépendances déjà disponibles ; aucun téléchargement de dépendance ni installation de runtime global. Les copies privées du pack sont .NET 10.0.13 et WebView2 155.0.4283.62. Les binaires PROD/DEV sont identiques ; les **1 658 fichiers source DEV, soit 35 732 328 octets**, correspondent aux blobs Git annoncés. Les empreintes des artefacts GitHub, archives locales et manifestes ont été vérifiées.

## Recette finale en domaine

Le poste joint au domaine a exécuté le **PROD BA2 exact**, avec l’identité Windows de la session interactive. Le pilote seul a été compilé avec le SDK 10.0.401 déjà présent : 0 erreur, 0 avertissement, 25 autocontrôles réussis. L’application n’a pas été reconstruite dans la VM.

**Un scénario réel réussi, 43/43 étapes incluant le démarrage** : état déconnecté, connexion Windows unique, choix d’une OU de laboratoire existante avec assertion du DN intégral, plan de trois étapes, sauvegarde, lecture AD complète et reçu SQLite. Le mode choisi ne demande ni ping ni WMI. **Aucune écriture AD n’a été exécutée.**

Le reçu affiche **56 objets** ; l’audit de la copie SQLite trouve **57 lignes**, dont l’OU racine exclue du compteur UI : 19 sous-OU, 15 utilisateurs, 18 ordinateurs et 4 groupes. Les SHA, lot et révision affichés ont été transcrits indépendamment des pixels puis rapprochés de la base. La sauvegarde a été rehachée : intégrité SQLite correcte, même magasin, révision antérieure au lot. Le journal d’opérations a été rehaché ; aucun checkpoint de campagne ou de sondage n’est présent. Le SHA du lot concorde entre UI et reçu SQLite ; le JSONL initial n’étant plus présent, il n’a pas été recalculé à partir d’un contenu reconstruit.

Les **43 captures** de cette passe ont été examinées. Les deux SHA sont visibles en entier, sans débordement vers la carte voisine. Fermeture normale confirmée : **2 445 ms, code 0**, aucune erreur de fermeture. La tâche de test a été retirée ; aucune instance Domenia restante et le bureau Windows reste ouvert. Le contrôle d’intégrité après recette réussit, comme celui d’avant recette.

Les tentatives précédentes restent conservées : deux expirations du démarrage à 90 s sans lecture AD ; une sélection échouée car l’OU autorisée pour les écritures n’existe pas dans ce laboratoire ; une lecture FBE réussie dont le succès global a été rejeté faute de fermeture confirmée. Aucun de ces échecs n’est effacé ou requalifié par le passage final. Le domaine réel n’est donc plus « non exécuté », mais la reproduction sur l’OU des photos initiales reste absente.

## Mesures de démarrage et limites

| Environnement / mode | Mesure | Valeur |
|---|---|---|
| BA2 CI, premier / second lancement normal | Premier retour visible externe | 128 / 133 ms |
| BA2 CI, premier / second lancement normal | InterfaceReady observé externe | 3 394 / 2 406 ms |
| FBE VM, premier lancement normal observé | InterfaceReady depuis l’amorçage géré | 209 382 ms |
| FBE VM, lancement normal répété | InterfaceReady depuis l’amorçage géré | 34 596 ms |
| BA2 VM, mode E2E domaine | Démarrage du pilote jusqu’à la page prête | 47 201 ms |
| BA2 VM, mode E2E domaine | InterfaceReady depuis l’amorçage géré | 39 357 ms |
| BA2 VM, connexion seule | Trace jusqu’au dernier marqueur de validation | 1 613 ms |

Sur le premier lancement normal FBE observé, intégrité 95 321 ms, composition 26 575 ms et WebViewControl 70 139 ms ; sur le répété, 12 367 / 1 827 / 7 036 ms. Le retour natif apparaît à 976 / 230 ms depuis l’amorçage géré. Ces phases sont coûteuses dans cette VM, mais ces deux observations portent sur le même code : **ce n’est pas un gain logiciel avant/après**.

Aucun cache OS n’a été purgé et aucun vrai froid contrôlé n’a été établi. Le plafond E2E explicite de 360 s est une tolérance de diagnostic ; les délais des étapes et LDAP sont inchangés. Les métriques externes, gérées et E2E ont des bornes différentes. L’épisode de bureau VM figé puis rétabli ne permet pas d’attribuer la lenteur à une cause démontrée. Aucune modification du réseau, des services, des politiques, protections ou runtimes globaux, aucun reboot/logoff effectué par l’agent.

## Packs et prochaine recette manuelle

| Archive | SHA256 exact |
|---|---|
| `Domenia_2.0.1_PROD_Windows-x64.zip` | `fe8a3a271d49c57a2458f94205f51d9c1ae1f579263a88ee507a4e09aad2184a` |
| `Domenia_2.0.1_DEV_Windows-x64.zip` | `0a5df511797a658953a8bb9372e595a2a9079e931094e5c0d97dfdf111276511` |

Exécutable commun : `9527480cbcb345c6d492270e5b5178f5882d1c956d55caf5ed826d0711483816`. Les nouveaux fichiers sont dans le dossier de livraison `paquets-ba2eb50c`. Les anciens ZIP à la racine des livrables restent historiques.

À faire manuellement : extraire le PROD dans un dossier neuf après comparaison du SHA ; mesurer deux lancements normaux ; tester Se connecter et l’autre compte natif (premier plan, Tab, Échap) ; choisir puis mémoriser l’OU ; actualiser sa base et examiner sauvegarde/lecture/reçu ; observer les icônes au moins 18 s avec différentes tailles/thèmes ; vérifier réessai, changement de compte/OU et les DPI disponibles. La recette détaillée accompagne les packs.

Restent non qualifiés : performance VM à froid et amélioration comparable, incident de l’OU initiale, grand attribut LDAP réel, saisie native d’un autre compte/annulation/focus, persistance normale des préférences (E2E isolé), DPI Windows 125/150 %, écritures AD et parcours strict de deux postes VM. Le contrôleur de domaine et le poste de test ne constituent pas deux postes de recette. Quelques cadrages défilés/rognages et notifications transitoires sont documentés dans les revues ; aucune validation humaine ni certification globale du catalogue n’est déduite des tests.

Les six photos mentionnées dans la demande n’ont pas été jointes au fil disponible ; les corrections s’appuient sur leur description, le code et les nouvelles preuves exécutées. Les données SQLite et sauvegardes brutes du laboratoire restent privées, hors Git et hors archives de livraison.

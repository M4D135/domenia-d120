# RC1.17.39 — contrôles critiques ciblés

Passe en cours ; aucune qualification générale ni livraison finale revendiquée. VM DOMENIA-FIRSTRUN-20261020 conservée, Windows PowerShell 5.1 x64 STA. Données de test isolées, pas d’écriture AD ni de changement de stratégie.

## Résultats acquis sur le premier candidat

- Démarrage avec contrôle du manifeste et chargeur fermé : réussi. Contrôle de compatibilité de source PS5.1 : 342 fichiers, zéro erreur.
- Aperçu local : 19/19 ; recherche WPF et Dispatcher réel : 16/16. Les premiers échecs provenaient d’imports manquants dans les fixtures ; rapports initiaux conservés. WiringCache : 190 cas réussis lors de la passe initiale, son cas D024 échoué passe après ajout des deux vrais helpers (rapport `WiringCache-final.json`). La suite complète n’a pas été rejouée.
- Préférences : 9/9 ; maintenance SQLite et sauvegardes : 33/33 ; pannes stockage : 8/8 ; RemoteStore : 34 cas réussis. Le disque plein est simulé par `max_page_count` et produit le vrai `SQLITE_FULL` ; aucun volume physique rempli, donc le rapport StorageFaults reste `Qualifying=false`.
- Santé : 23/23 règles ; 5 000 objets synthétiques en 1 437 ms. Aucun gain avant/après établi.
- Connexion/démarrage : 48/48 cas sans AD. CollectCircuit : 7 contrôles AST, pas des essais réseau.
- AD/WMI réel : premier poste en délai dépassé (budget de test réduit à 2 secondes), poste suivant DC01 lu avec succès puis résultat inscrit dans SQLite. Lot clôturé 2/2, un échec attendu, pas d’arrêt global. Réseau, callbacks et stockage non simulés.
- Parcours UIA réel : connexion Windows, Premiers pas, OU sans collecte implicite, collecte AD confirmée, préparation du dashboard, recherche, fiche, poste, santé, fermeture normale. Fiche : 300 ms ; première ligne de recherche : 12 959 ms sur ce passage. Ce ne sont pas des mesures comparatives sur une VM au repos. Les captures pixels étaient indisponibles pendant ce passage verrouillé ; la réussite UIA n’est pas une validation visuelle. Session déverrouillée ensuite, capture du bureau réussie.
- Guides DOCX/PDF régénérés et relus visuellement ; copies DOC identiques par SHA256. Captures intégrées RC20 conservées explicitement comme historiques. `doc_sync` réussi.

## Liaison aux sources et limites

`rc39-critical-tests/Environment.json` porte les empreintes de Core, du chargeur, de la release et du manifeste. Les rapports WMI et UIA portent également leurs empreintes. Le candidat DEV était B79F1B11821162F5D7CC0BFADCE44C0D4EE2B30D9DA834B789C29227E2E9BD65 ; PROD D82C17B915A3CA4CB9332E873970E2FF3AF50906D8169493D97CD4B953D3AF53. Leurs 174 fichiers applicatifs étaient identiques.

La revue intermédiaire a motivé les compléments 6, 8 et 38 ; leurs résultats R2/R4 figurent ci-dessous et restent distincts des preuves du premier candidat. Les archives finales doivent encore être reliées au runtime figé et au contrôle visuel final. Aucun résultat ci-dessus ne certifie un code futur.

Endurance longue, gros parc réel, multi-écrans, Narrateur, variations DPI et qualification générale restent hors de cette passe critique demandée. Aucune clôture formelle D001–D120 par `acceptance_passed=true`.

Les JSON sont conservés en UTF-8 ; quelques journaux texte disponibles restent des pièces complémentaires. Les scripts reproduisent les appels du labo sans secret.

## Delta après stabilisation des points 6, 8 et 38

Le candidat `FCBB2FBC…` DEV / `9035B033…` PROD a passé les contrôles de paquet (176 fichiers applicatifs identiques), puis les bancs ciblés dans `rc39-final-delta/`. Les résultats suivants sont nouveaux : favoris 20/20, associations 5/5, diagnostic 4/4, modules 185/185, QueryTargets 39/39, WiringCache D024 1/1, règles BoardFleet26/Collection49/DirectorySync11/Observability17. Le contrôle natif du démarrage vérifie176 fichiers/133 modules ; il ne compile pas les types WPF différés.

Les échecs ont déclenché des corrections : référence System.Xaml/System.Core manquante dans l'arbre, garde de cache acceptant un CLR enveloppé comme PSCustomObject ; fixtures UTC de LocalPreview, clé Filter dupliquée de Navigation et dépendance réelle de Park non importée. Les assertions sont conservées/renforcées. Le rapport Boards filtré indiquait Complete=true : corrigé avec Subset/SelectionComplete. Les anciens reçus restent inchangés.

Le premier harnais Start-Process/WaitForExit retourne ExitCode=null sous ce Windows. Son tableau Done ne prouve donc pas un succès de processus ; les résultats ci-dessus viennent des rapports individuels et du journal natif. Le harnais de relance utilise System.Diagnostics.Process avec capture asynchrone des deux flux et code de sortie effectif. Relance limitée aux bancs affectés, sans répétition des contrôles AD/WMI/santé/stockage inchangés.

## Retests R2 et R4 : succès ciblés confirmés

Les reçus R2 et leur [environnement](rc39-final-retest/Environment.json) confirment :

| Banc | Résultat | Portée |
|---|---|---|
| [LocalPreview](rc39-final-retest/LocalPreview.json) | 21/21 | Inclut les deux cas Programme 6 ; SQLite native, données locales/synthétiques. |
| [QueryTargets](rc39-final-retest/QueryTargets.json) | 39/39 | Vrais records/DLL ; évaluation locale, aucun AD/WMI/réseau. |
| [Boards Programme 38](rc39-final-retest/Boards.json) | 4/4 | `SelectionComplete=true`, `Complete=false` : filtre exécuté, pas les 73 cas de la suite. |
| [TreeRendering](rc39-final-retest/TreeRendering.json) | 4/4 | Ordonnancement coopératif avec vrais types de données ; pas de preuve de virtualisation WPF. |
| [Navigation Programme 8](rc39-final-retest/Navigation.json) | 5/5 | `Subset=true`, `Complete=false` ; contrôles WPF réels, dépendances externes doublées. |
| [Rules-Park](rc39-final-retest/Rules-Park.json) | 14/14 | Règles pures sous PowerShell 5.1, sans WPF/réseau ni preuve du raccordement complet. |

[R4 TreeVirtualization](rc39-tree-r4/TreeVirtualization.json) réussit **8/8** sous WPF réel : 10 000 DTO synthétiques, révélation lointaine, recyclage/favori, groupe, filtre, feuille non lue et annulation de session. Les neuf cibles mesurées produisent 40 conteneurs au premier relevé et 61 au maximum ; les parcours programmés n’appellent pas les doubles de lecture AD. `SyntheticOnly=true` : aucun AD réel, aucun réseau et aucun benchmark de mémoire du processus.

Les trois échecs de révélation R2/R3 restent dans l’historique. Le diagnostic a identifié un trigger du thème qui imposait un panneau standard aux enfants ; la correction précède R4. Le [reçu R2 WiringRecherche en échec](rc39-final-retest/WiringRecherche.json) reste conservé. [R4 WiringRecherche](rc39-tree-r4/WiringRecherche.json), lancé sans filtre, donne **47/53** : les dix cas précédemment ciblés réussissent, mais six autres cas échouent. Le [retest R5](rc39-final-close/WiringRecherche.json) réussit cinq des six cas ; [R6 D028](rc39-wiring-final/WiringRecherche.json) réussit le dernier cas après correction de sa dépendance de fixture. Aucun échec connu ne reste parmi ces cas : **47 R4 + 5 R5 + 1 R6**. Les 53 cas ne sont pas rejoués ensemble et les retests filtrés restent `Complete=false`. Les autres succès R1 ci-dessus restent acquis dans leur portée ; ils ne sont pas tous rejoués en R2/R4.

Le runtime et les preuves doivent encore être rapprochés des archives finales et du contrôle visuel. **Passe critique partielle, livraison non finale ; point 59 hors passe, aucune qualification des 60 points.**

## Contrôle visuel final : profil déplacé manuellement

Le premier lancement visuel du pack final est **rejeté** par [Diagnostic.json](rc39-visual-initial/Diagnostic.json), malgré le `Passed=true` du [script de navigation](rc39-visual-initial/VisualFinal-Result.json). Huit erreurs ont été signalées, notamment « Contexte de lecture ne correspond pas a la base » et « Base appartenant a un autre contexte ». Le profil SQLite avait été copié, application fermée, de `RC39-critical-ui/prod/wad/data` vers `RC39-final-ui/prod/wad/data`. Cette copie change le chemin attendu sans réidentifier la base : `Get-DomeniaStoreId` calcule le SHA256 du chemin complet et du domaine normalisés ; les gardes de lecture et d’écriture refusent l’ancienne identité. Cela rend cette fixture déplacée incohérente ; ce lancement ne constitue pas une validation visuelle réussie.

La correction de fixture réinstalle uniquement le runtime final dans le répertoire original `C:\DomeniaLab\RC35-qualification\RC39-critical-ui\prod`, avec son `data` conservé et le même domaine. Root confirme l’upgrade en place et les 177 fichiers vérifiés (archive SHA256 `82752528…`) ; le retest exige un arbre peuplé et aucun nouveau journal ERROR. Aucun StoreId ni métadonnée SQLite n’est modifié manuellement. Pour déplacer une base à un autre chemin, utiliser la maintenance Déplacer/Restaurer : elle vérifie domaine, schéma, intégrité et empreinte, attribue l’identité du chemin cible à une copie, puis confirme la bascule. Une copie brute du profil n’est pas ce parcours de migration. Retest visuel en cours à ce jalon ; résultat et examen des pixels restent attendus.

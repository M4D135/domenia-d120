# Domenia v2.0.0 — fabrication et contrôles de la livraison manuelle

Date : **25 octobre 2026**. Rapport rédigé après lecture des journaux et reçus du passage Windows réussi. Aucune nouvelle suite n'a été exécutée pour cette rédaction.

## État et décision applicable

**La [release v2.0.0](https://github.com/M4D135/domenia-d120/releases/tag/v2.0.0) est publiée avec PROD, DEV et SHA256SUMS.txt depuis le 25/10/2026 à 20:56:19 UTC. Les contrôles CI du lot exact sont réussis, les empreintes des pièces jointes sont relues sur GitHub et 20 captures ont été examinées par les assistants. La recette utilisateur et son appréciation visuelle humaine restent en attente.**

David a autorisé la livraison sans attendre les deux VM, avec recette manuelle ultérieure : « si go sans ces tests vm, on peut pas, je testerai a la main du coup », puis « verifie bien tout, je teste a la main ensuite ». Cette décision est consignée dans [DECISIONS.md](../../DECISIONS.md) et le [parcours de livraison](../../LIVRAISON-FINALE.md). Elle ne transforme aucune validation absente en succès.

| Élément | Référence exacte |
|---|---|
| Version | `2.0.0` |
| Commit source des archives | `4ec63be686895aa46469877a7711c1cd87965cf2` |
| Passage Windows | [40231087873](https://github.com/M4D135/domenia-d120/actions/runs/40231087873), réussi |
| Identité de build | `2.0.0+21839747f2e6be9042dd39c5b8f331f208f25e01fa422d9362af1b54c9895d84` |
| Runner / SDK | `win25-vs2026 / 20261021.278.1` ; SDK `10.0.402` déjà installé |
| Fin du reçu de livraison | `2026-10-25T20:42:58.1228861+00:00` |
| Recette utilisateur | `userManualAcceptance: pending` |
| Recettes domaine, UI native réelle et deux VM | `domainAcceptance`, `uiAcceptance`, `twoVmAcceptance: not-run` |
| Revue des captures | 20 images examinées par les assistants, avec limites ; recette visuelle humaine en attente. Le reçu CI originel conserve `visualReview: pending` |
| Publication | Release `423656685`, publiée le `2026-10-25T20:56:19Z` ; le reçu CI originel conserve `published: false` |

Le garde strict `release-guard.py` demeure disponible et inchangé. Sa qualification complète des deux VM n'a pas réussi, faute de ces preuves ; aucun `eligible:true` n'est annoncé. Le reçu distinct de livraison manuelle porte `eligibleForManualDelivery: true`, qui qualifie l'intégrité des archives pour cette remise autorisée, sans recette métier ni certification d'authenticité.

## Résultats réellement lus

Les chemins de preuve ci-dessous sont relatifs à la racine du ZIP `Domenia_2.0.0_PREUVES_CI.zip`.

| Contrôle | Résultat observé | Preuve |
|---|---|---|
| Compilation Debug | 0 erreur, 0 avertissement | `domenia-v2-ci/logs/build-Debug.log` |
| Compilation Release | 0 erreur, 0 avertissement | `domenia-v2-ci/logs/build-Release.log` |
| C# critiques | **587 réussis, 0 échec** ; 587 retenus sur 2 379 enregistrés, **1 792 non exécutés** | `domenia-v2-ci/logs/critical-csharp.log` |
| Tests Python du garde strict | **15 réussis** | `domenia-v2-ci/logs/critical-release-guard.log` |
| Tests Python du vérificateur de livraison manuelle | **7 réussis** | `domenia-v2-delivery/logs/critical-manual-package-tests.log` |
| Web, sélection critique | **69 réussis, 0 échec** | `domenia-v2-delivery/logs/web/web-20261025T204049-83923a62b7b94fd19a53d2dc6958f5ff/report.json` |
| UI, mode simulation | **6 réussis, 0 échec, 0 ignoré, 0 invalide** | `domenia-v2-delivery/logs/ui-simulation/report.json` |
| Structure et empreintes des preuves navigateur | `passed`, relecture des empreintes après validation | `domenia-v2-delivery/logs/browser-evidence.json` |
| Archives et sources | `integrity: verified`, empreintes relues après validation | `domenia-v2-delivery/logs/manual-package-verification.json` |
| Orchestration du lot | `state: completed`, `phase: completed` | `domenia-v2-delivery/logs/delivery-result.json` |

Les 587 lignes C# `OK` et les 15 puis 7 lignes Python `ok` concordent avec les totaux de fin et les codes de sortie nuls. Les contrôles Python du garde strict testent ce garde ; ils ne constituent pas son approbation des archives. Les suites C# hors sélection n'ont pas été relancées.

Les six scénarios UI utilisent le véritable exécutable PROD du lot, en **simulation**. Chaque scénario finit avec un code de sortie nul, sans erreur de console, et chaque étape possède une capture :

| Scénario | Étapes et captures |
|---|---:|
| `accueil/actualiser-ou` | 14 |
| `accueil/catalogue-widgets` | 10 |
| `fiche/modifier-description` | 14 |
| `operations/releve-reprise` | 11 |
| `parametres/collecte-fenetre` | 11 |
| `synchro/parc-partage` | 11 |
| **Total** | **71** |

Une capture Web supplémentaire est conservée avec le rapport Web, soit 72 PNG au total. Le vérificateur contrôle la structure, les CRC, les chemins, l'unicité et les empreintes des PNG. **Il n'effectue pas leur examen visuel humain.** Les interactions de simulation ne sont pas une recette d'administration sur le domaine réel.

## Démarrages et runtimes privés

La publication applicative utilise un apphost configuré avec `AppHostDotNetSearch=AppRelative`, `AppHostRelativeDotNet=runtime/dotnet`, `RuntimeFrameworkVersion=10.0.13` et `RollForward=Disable`. Les copies sont issues des composants déjà présents sur le runner :

| Composant | Origine et contenu | Empreinte de l'inventaire privé |
|---|---|---|
| .NET `10.0.13` | `C:\Program Files\dotnet` ; hôte, hostfxr, NETCore et WindowsDesktop, 480 fichiers / 179 658 551 octets ; aucun SDK ni ASP.NET ajouté | `04bf4f12732451e2b665be6fb670a9c6c4151ffc8d72a9aa429956fd0a14ddcf` |
| WebView2 `155.0.4283.62` | `C:\Program Files (x86)\Microsoft\EdgeWebView\Application\155.0.4283.62` ; copie privée qualifiée, 909 827 702 octets | `6f2ba7aa4eb996a5e93bb05dd2f08b582d0ea887c902f7a9bb067c34769ccc80` |

Les reçus `dotnet-copy.json` et `webview-copy.json` portent les provenances `installed-dotnet-private-copy` et `installed-webview2-private-copy`. La copie WebView2 n'est pas présentée comme une distribution « Fixed Version » téléchargée. Le SHA256 de son `msedgewebview2.exe` est `93acbcad0b6f390ae1ce6a1dbf1e09e165520a7f1196eb22323afa64a9bba96b`.

Les preuves suivantes se trouvent dans `domenia-v2-delivery/logs/` :

- `prod-start.json`, `dev-start.json` et `prod-after-ui.json` : `--check-only` réussit avec le code `0`. Les modules observés viennent de `runtime/dotnet/host/fxr/10.0.13/hostfxr.dll` et `runtime/dotnet/shared/Microsoft.NETCore.App/10.0.13/coreclr.dll`, dans le paquet testé.
- `missing-private-runtime.json` et son journal d'erreur : une copie de contrôle sans runtime privé échoue comme attendu avec le code natif **`-2147450749`**. Le diagnostic donne uniquement `search options: [ app_relative ]` et le chemin privé manquant. Le runtime global est présent sur ce même runner ; aucun repli global n'est observé dans ce contrôle. Le runtime global n'a pas été renommé ou supprimé.
- `web-critical.json` et `ui-simulation-critical.json` : les hôtes .NET de contrôle et les six processus Domenia UI utilisent le runtime privé ; les processus navigateur observés proviennent de `runtime/webview2/msedgewebview2.exe` du paquet. Aucun timeout, erreur d'observation ou erreur de nettoyage n'est enregistré.
- `cli-version.json` et `cli-version.stdout.log` : la commande locale `version` réussit et expose le contrat `Domenia.Automation/1` et l'identité de build ci-dessus, sans base ni profil lus.

Le reçu de livraison indique `dependenciesDownloaded: false`, `installedRuntimeModified: false` et `serviceNetworkModified: false`. Les dépendances proviennent des paquets NuGet versionnés et des copies privées ci-dessus. Ces démarrages réussis portent sur ce runner Windows et ces archives ; la recette sur les postes de David reste à faire.

## Archives figées et provenance

Le script de préparation compare les octets des sources aux blobs du commit exact avant publication applicative. Le DEV contient le manifeste `developer/source-commit.json` : **1 649 fichiers source**, **35 579 459 octets**, sans configuration de diffusion ajoutée (`seed: null`). Les sources, ressources et composants sont ensuite confrontés aux manifestes et aux deux archives ; les empreintes sont relues en fin de validation.

Les valeurs ci-dessous sont celles du vérificateur CI, lues dans `manual-package-verification.json` :

| Archive | Octets | SHA256 |
|---|---:|---|
| `Domenia_2.0.0_PROD_Windows-x64.zip` | 483 367 128 | `b9c521e2d86d15eca1dda902765aa6aa839affe7cfe993b6a505425e4f0d48a2` |
| `Domenia_2.0.0_DEV_Windows-x64.zip` | 503 019 384 | `c8eaf856aa5c62419c6884ad381bd312f8eabe8301efe90180b13aaa7f9ff459` |

Les deux paquets portent le même `Domenia.exe` de **162 816 octets**, SHA256 **`67d2f14edd1c5f001f939b666e984c5fde8726ec27e82d943c0d604cc894b654`**, ainsi que la même identité de build et le même schéma **11 / révision 1**. Le contrôle compare aussi leurs composants et ressources ; il ne se limite pas à cet exécutable.

Le fichier `SHA256SUMS.txt` de 201 octets couvre exactement les deux ZIP ; son SHA256 est `f4cebe9fafd563c722cdabc600e7986b825b1d507e0e66a46905219ac5cb42dd`. L'empreinte SHA256 assure une comparaison d'intégrité, **pas une signature d'authenticité** : le reçu conserve `publisherTrust: not-established`.

Ces valeurs sont des preuves produites par le runner. Le vérificateur d'archives ne réalise lui-même ni compilation ni démarrage : ses champs `binaryBuildProvenance: not-established-by-this-tool` et `runtimeExecution: not-run` délimitent sa portée. Les preuves de compilation, de source Git et d'exécution sont celles, distinctes, du même passage CI décrites plus haut.

Les archives restent liées au commit source `4ec63be686895aa46469877a7711c1cd87965cf2`. La présente clôture documentaire est postérieure à leur fabrication : **elle ne reconstruit pas les archives, ne change pas leurs octets et ne remplace pas leur commit source par le SHA du commit documentaire**.

## Conservation des preuves

Le ZIP `Domenia_2.0.0_PREUVES_CI.zip` a été rehashé après récupération :

`f9e0cd517393c21adf2a3cb6bc2a162fe6cc585c924f08867a86dd1d5f260979`

Il est conservé dans `/workspace/scratch/5c44e97f30e5/domenia-delivery-v2.0.0/` ; son extraction de revue est dans le sous-dossier `proofs/`. Ces chemins désignent l'espace de travail de cette reprise. Les chemins relatifs des journaux restent utilisables après extraction du ZIP ailleurs.

Empreintes recalculées lors de cette lecture, pour les preuves principales :

| Chemin relatif dans le ZIP | SHA256 |
|---|---|
| `domenia-v2-ci/logs/build-Debug.log` | `0120a694e356fadd432e0bf1c94470977f6441fa011783afe805ff188cf1d92b` |
| `domenia-v2-ci/logs/build-Release.log` | `e1c3ac1da7533cba12b9b882522c7fd1e814ca83efd79e530a54006d9aacb37d` |
| `domenia-v2-ci/logs/critical-csharp.log` | `58b36325f13fd4c46190958748d4f72c90e4ad78d10783b33b6f6a3e94c3a71e` |
| `domenia-v2-ci/logs/critical-release-guard.log` | `70262408d4ed2fb99d4d15ed681e0469a841ed569b064580bc7b7ab7edde850a` |
| `domenia-v2-delivery/logs/critical-manual-package-tests.log` | `8e29028586ad9eedf478bc058655da8653e11fdbab2625c98a1d2432f5c63a00` |
| `domenia-v2-delivery/logs/delivery-result.json` | `a0a53cfc3cdbe42cbeeb104b879bdea1ded3cf67c39be9fc78864aeb05d10f23` |
| `domenia-v2-delivery/logs/manual-package-verification.json` | `63301e8e227851fac82b86ab9dd98afdb7dcccec353fd854609d3174f42a4f1a` |
| `domenia-v2-delivery/logs/browser-evidence.json` | `aceda0d0cfcdb8642e8beb90f27406ff525aec12d7b69126e783e87d1160366e` |

Les autres reçus, journaux de démarrage, inventaires privés et captures sont conservés dans ce même ZIP. Le rapport navigateur donne les empreintes individuelles des 71 captures UI et de la capture Web ; elles ne sont pas recopiées ici.

## Développement intégré et limites conservées

Les raccordements prioritaires ont été développés depuis GitHub : reprises108 et leurs consommateurs, réglages124/125 effectifs au démarrage, reprise durable Accueil249 jusqu'à l'UI, collectes widgets290–292 jusqu'à l'acquittement du résultat, CLI067 locale en lecture seule. Le lot123 resté sur Spark/Mac n'a pas été récupéré ni revendiqué. Les sondes personnelles191 utilisent le catalogue de profil et leurs définitions immuables dans Accueil, Poste, l'Atelier/Query4 et les observations CLI locales. Les rapports de lots et [FEATURES.md](../../FEATURES.md) détaillent les chemins et restrictions.

Les preuves CI sont celles d'une sélection critique, de contrôles locaux Windows et de parcours de simulation. Elles ne certifient pas les **993 statuts historiques** du catalogue. Les scénarios natifs de domaine, les deux VM `CNAMTS-DC01` et `DOMENIA-FIRSTRUN-20261020`, les opérations de recette réelles et l'appréciation visuelle humaine ne sont pas déduits des succès automatisés.

La [recette manuelle v2.0.0](../../RECETTE-MANUELLE-V2.0.0.md) reste à effectuer par David, en conservant les refus et résultats réels. Les contraintes restent applicables : `dev/` en lecture seule, WAPT exclu, aucune dépendance téléchargée, aucun changement de service/runtime installé/réseau, aucun reboot/logoff ; toute écriture AD autorisée uniquement dans `OU=Domenia-Tests,DC=cnamts,DC=local`.

Les échecs de fabrication antérieurs ne sont pas effacés : `db67e742` / run `40228835330` s'arrête sur une syntaxe PowerShell après les 587 C# et 15 Python ; `a3bb9ccd` / run `40229330702` s'arrête après les copies privées, avant archive, sur la mesure des dictionnaires ordonnés du manifeste sous PowerShell 5.1. Le passage `4ec63be6` ci-dessus fournit la preuve de fabrication réussie après correction.

La publication et la revue des captures ci-dessous complètent ces preuves, sans reconstruire les archives ni réécrire leurs reçus CI.


## Revue réelle des captures

Les assistants ont ouvert **20 images** avec le visualiseur : 10 pour Accueil/Opérations, 6 pour Paramètres/Synchronisation, 3 pour Fiche et la page des tests Web critiques. Aucun défaut visuel bloquant n'a été observé dans les portions examinées. Ce résultat porte sur ces captures de simulation ; il ne vaut pas recette humaine globale.

- Accueil : plan et état final simulé lisibles ; la sauvegarde et le reçu SQLite réels restent sans objet dans ce mode.
- Catalogue : ajout, carte Présence réseau et notification de retrait visibles ; le menu masque une partie de la carte et aucune capture ne couvre toute la page après retrait.
- Fiche : plan limité à un champ et reçu vérifié par relecture visibles ; la capture après fermeture montre encore le panneau en transition. Le champ relu derrière le panneau passe l'assertion du scénario mais n'est pas directement visible dans cette image.
- Opérations : confirmation, lot et demande d'arrêt lisibles ; aucune fin physique de collecte ni persistance après interruption n'est déduite.
- Paramètres : saisie invalide signalée, grille de collecte et confirmation d'enregistrement lisibles ; persistance après relancement non qualifiée par ces captures.
- Synchronisation : aperçu, confirmation et reçu simulé visibles ; une capture présente le panneau en transition et son titre partiellement masqué.

Les avertissements d'icône absente, de mesures anciennes, de collecte partielle et d'erreur de ping ne sont pas transformés en réussite de collecte native. Le compte rendu local de revue conserve les noms, SHA256, observations et limites des 20 images ; les captures d'origine restent dans l'artefact CI.

## Transfert et publication vérifiés

Le connecteur limite chaque téléchargement d'artefact à 512 Mio. L'artefact initial regroupé dépassait cette limite. Le [passage de transfert 40232453893](https://github.com/M4D135/domenia-d120/actions/runs/40232453893), commit d'outillage `e541c96847f19883be8bc7d8e714c6bde3b3097b`, a vérifié l'artefact source puis séparé ses fichiers pour leur transfert. Aucun binaire ni archive n'a été reconstruit.

Les ZIP ont été rehashés après récupération, puis leurs longueurs et SHA256 ont été confrontés aux métadonnées des pièces jointes GitHub avant et après publication :

| Pièce jointe | Identifiant GitHub | Résultat |
|---|---:|---|
| PROD | `676101746` | 483 367 128 octets, SHA256 conforme au tableau précédent |
| DEV | `676103773` | 503 019 384 octets, SHA256 conforme au tableau précédent |
| SHA256SUMS.txt | `676102417` | 201 octets, SHA256 `f4cebe9fafd563c722cdabc600e7986b825b1d507e0e66a46905219ac5cb42dd` |

La release n'est plus un brouillon. Le tag `refs/tags/v2.0.0` désigne exactement `4ec63be686895aa46469877a7711c1cd87965cf2`. La branche de référence `v2` a été relue et reste à `9b1c0333c34020ad88c1448874b91eff884d5406` ; les modifications restent sur la branche dédiée. `dev/` est inchangé.

Le contrôle automatique d'approbation a refusé de joindre séparément le ZIP de preuves, la revue JSON et le guide à la release, en raison d'une diffusion supplémentaire de journaux/captures non explicitement autorisée. Aucune pièce jointe supplémentaire n'a été déposée. Aucune copie des journaux et captures n'a été publiée par un autre moyen. La release contient les trois fichiers demandés ; le guide existe déjà dans les packs et les preuves restent dans les artefacts CI, dont l'expiration annoncée est le 8 novembre 2026.

La mise à jour documentaire qui contient ce rapport ne déclenche aucune nouvelle qualification et ne modifie ni les paquets ni leur commit source. La recette manuelle de David reste **en attente**.

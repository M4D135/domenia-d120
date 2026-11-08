# Garde de livraison finale Domenia 2

## 30/10/2026 — packs 2.0.8 publiés

La [release v2.0.8](https://github.com/M4D135/domenia-d120/releases/tag/v2.0.8) contient les ZIP du commit `5f4ed1ce8ead97b01e44653bba21e83d5b5f894c`. Retour terrain sur 2.0.7 (OU ADCC-Lab du domaine de test) : un poste sans enregistrement DNS faisait passer le relevé de présence en « Échec », l’actualisation en « partielle » et proposait « Reprendre », qui ne pouvait que reposer la même question. Un nom absent du DNS est désormais un résultat : l’étape est terminée et le compte rendu le nomme (« 1 nom absent du DNS »), sans reprise. Seules les causes passagères (DNS indisponible ou trop lent, adresse ou réseau indisponible, erreur ICMP, délai dépassé) laissent l’étape « Incomplète » et reprenable, avec leur cause écrite ; quand aucun nom de l’OU n’est résolu, l’étape ajoute « aucun nom résolu : vérifiez le DNS de ce poste ». Même format de données que 2.0.5 à 2.0.7. CI de compilation et livraison réussies, recette VM : annuaire : 6 réussis, 0 en échec, 132 ignorés (réservés à la simulation) ; simulation : 136 réussis, 0 en échec, 2 ignorés (réservés au mode annuaire). Sources DEV et SHA256 GitHub vérifiés. Recette exécutée sur une VM Windows 11 jointe au domaine de test (identité intégrée de la session, aucun mot de passe saisi par l’outil) ; ce n’est pas une recette utilisateur ni une validation sur le domaine de production. Le cas réel est vérifié sur l’OU ADCC-Lab : « Tout actualiser » se termine avec « 0 poste en ligne sur 5 · 4 sans réponse · 1 nom absent du DNS ». La reprise de l’actualisation laissée par 2.0.7 dans le profil de l’opérateur n’est vérifiée que par les tests C# (le harnais E2E utilise son propre profil), de même que les causes DNS passagères et le cas « aucun nom résolu », sans panne provoquée. Les tests de 3 500 et 100 000 postes restent simulés. La revue visuelle native et la recette utilisateur restent en attente. Rapport : `RAPPORT-PRESENCE-DNS-2.0.8-20261030.md`. Catalogue courant : `packs/manifest.json`.

## 29/10/2026 — packs 2.0.7 publiés

La [release v2.0.7](https://github.com/M4D135/domenia-d120/releases/tag/v2.0.7) contient les ZIP du commit `c6b226f5838fc3621d066535210d94d8ed9993a5`. Finitions de l’interface relevées par la vérification des captures de la recette 2.0.6 : la loupe des champs de recherche reste visible dans les panneaux latéraux, les dialogues et les filtres de grille (une infobulle ne positionne plus un champ), le cadre de sélection des contrôles segmentés de Schéma et de l’Atelier est sous son bouton, chaque exemple de la carte Syntaxe de Rechercher tient sur une ligne, et le pied du menu de gauche garde sa hauteur menu déplié ou replié, sa poignée de largeur se saisissant de nouveau à la souris. Même format de données que 2.0.5 et 2.0.6 ; look et animations conservés. CI de compilation et livraison réussies, recette VM : annuaire : 5 réussis, 0 en échec, 132 ignorés (réservés à la simulation) ; simulation : 135 réussis, 1 en échec, 1 ignoré (réservé au mode annuaire) ; relance ciblée de parametres/copie-destination : 3 réussis, 0 en échec, 0 ignoré ; 113 captures en thèmes clair, sombre et contraste élevé, 0 en échec. Sources DEV et SHA256 GitHub vérifiés. Recette exécutée sur une VM Windows 11 jointe au domaine de test (identité intégrée de la session, aucun mot de passe saisi par l’outil) ; ce n’est pas une recette utilisateur ni une validation sur le domaine de production. Les tests de 3 500 et 100 000 postes restent simulés. La revue visuelle native et la recette utilisateur restent en attente. L’échec intermittent de parametres/copie-destination (clic perdu, réussi 3 fois sur 3 en relance ciblée, écran non modifié par 2.0.7) reste à analyser. Rapport : `RAPPORT-FINITIONS-2.0.7-20261029.md`. Catalogue courant : `packs/manifest.json`.

## 29/10/2026 — packs 2.0.6 publiés

La [release v2.0.6](https://github.com/M4D135/domenia-d120/releases/tag/v2.0.6) contient les ZIP du commit `6d33175eea8788e0f50be3f0d5b5838c31d1f905`. Correctif issu des recettes VM de la 2.0.5 et de la 2.0.6 : Échap ferme de nouveau le panneau ou le dialogue du dessus quand son bouton focalisé disparaît, les notifications qui restent ne couvrent plus les boutons d’un dialogue quelle que soit sa hauteur, un écran n’est signalé prêt qu’à la fin de sa transition, Comptes ouvre le compte urgent après une OU vide, une passe de recette de l’interface corrige 117 défauts visuels relevés sur les 137 scénarios de simulation, puis 30 autres relevés sur les captures des trois thèmes, et l’Assistance résiste à une forte charge. Le compte de session et « Replier le menu » restent visibles en bas du menu. Même format de données que 2.0.5 ; look et animations conservés. CI de compilation et livraison réussies, recette VM : annuaire : 5 réussis, 0 en échec, 132 ignorés (réservés à la simulation) ; simulation : 136 réussis, 0 en échec, 1 ignoré (réservé au mode annuaire) ; 113 captures en thèmes clair, sombre et contraste élevé, sans échec. Sources DEV et SHA256 GitHub vérifiés. Recette exécutée sur une VM Windows 11 jointe au domaine de test (identité intégrée de la session, aucun mot de passe saisi par l’outil) ; ce n’est pas une recette utilisateur ni une validation sur le domaine de production. Les tests de 3 500 et 100 000 postes restent simulés. La revue visuelle native et la recette utilisateur restent en attente. Rapport : `RAPPORT-RECETTE-VM-2.0.6-20261029.md`. Catalogue courant : `packs/manifest.json`.

## 28/10/2026 — packs 2.0.5 publiés

La [release v2.0.5](https://github.com/M4D135/domenia-d120/releases/tag/v2.0.5) contient les ZIP du commit `003fc51e6440f0dbab972910159bf0ddaabfb7a8`. Connexion avec nom simple et identifiant mémorisé facultatif, Atelier guidé et bibliothèque enrichie, Accueil personnalisable, campagnes par sous-OU avec reprise durable, moteur de lecture temporisé, cache par nature de donnée, comptes protégés et quatre méthodes optionnelles de collecte temporaire. Le look et les animations sont conservés. CI de compilation et livraison réussies, sources DEV et SHA256 GitHub vérifiés. Aucune VM ni authentification AD réelle exécutée pour ces octets. Les tests de 3 500 et 100 000 postes utilisent des transports simulés ; ils vérifient les bornes et les contrats, sans qualifier le débit d’un domaine réel. La recette utilisateur et la revue visuelle native restent en attente. Rapport : `RAPPORT-MOTEUR-CACHE-2.0.5-20261028.md`. Catalogue courant : `packs/manifest.json`.

## 28/10/2026 — packs 2.0.4 publiés

La [release v2.0.4](https://github.com/M4D135/domenia-d120/releases/tag/v2.0.4) contient les ZIP exacts du commit `648749200f066cb3aad7764e7ab6faa40fc1764f`. CI de compilation et de livraison réussies, fichiers locaux et SHA256 GitHub concordants. Compte simple accepté dans le domaine courant, fenêtre principale invisible pendant le login et pack `Domenia.exe` + `wad`. Extraire dans un nouveau dossier, sans superposer à un ancien pack plat. Aucune VM, authentification AD réelle ou revue visuelle native exécutée pour cette version. La recette utilisateur reste en attente ; les validations des packs précédents ne sont pas réattribuées à ces octets. Voir le [rapport 2.0.4](reprise/rapports/RAPPORT-LOGIN-2.0.4-20261028.md) et le [catalogue courant](../../packs/manifest.json).

## 26 octobre 2026 — carte de connexion 2.0.3 publiée

Les archives exactes sont celles du commit `66192551ac4950031d09d08340b3f75917094f7f`, contrôlées dans le [passage Windows 40398683357](https://github.com/M4D135/domenia-d120/actions/runs/40398683357). La [release v2.0.3](https://github.com/M4D135/domenia-d120/releases/tag/v2.0.3) est publiée le 26/10/2026 à 21:18:30 UTC (`424779339`). Les tailles et SHA-256 de ses trois assets concordent avec les ZIP exacts. Le tag désigne le commit construit. Le [rapport 2.0.3](reprise/rapports/RAPPORT-CARTE-CONNEXION-2.0.3-20261026.md) couvre la CI et la revue native à 96 DPI. La collecte AD et le ping du 2.0.2 ne sont pas relancés et ne qualifient pas ces octets. Les publications 2.0.2, 2.0.1 et 2.0.0 restent conservées.

## 26 octobre 2026 — qualification ciblée du correctif 2.0.2 terminée

Les archives exactes sont celles du commit `f6d5ac5a8c62d29e96931ad65319a65847db6a31`, contrôlées dans le [passage Windows 40368684978](https://github.com/M4D135/domenia-d120/actions/runs/40368684978). L’ordre demandé est respecté : corrections, contrôles GitHub, puis recette VM en domaine. Leur qualification est terminée dans le périmètre du [rapport du correctif](reprise/rapports/RAPPORT-CORRECTIFS-COLLECTE-LOGIN-20261026.md), qui distingue CI, lancement natif normal, matrice visuelle fictive et parcours domaine.

La concordance du compteur avec SQLite et une lecture AD indépendante est acquise, ainsi que l’audit historique du reçu OU dans ses limites documentées. Le ping explicite unique affiche une réponse ICMP et passe l’audit de sa persistance et de son identité LDAP. Le contrôle d’intégrité après fermeture et le nettoyage final passent ; les preuves restent conservées. Aucune réussite de la recette humaine, des DPI élevés, de l’authentification avec un autre compte, de la performance ou du parcours strict des deux postes VM n’en est déduite. Aucun inventaire antérieur non vide n’était disponible pour vérifier sa préservation.

La [release v2.0.2](https://github.com/M4D135/domenia-d120/releases/tag/v2.0.2) est publiée le 26/10/2026 à 18:49:52 UTC (`424632843`). Les tailles et SHA-256 de ses trois assets publics concordent avec les ZIP exacts et le fichier d’empreintes. Le tag désigne le commit construit ; les binaires ne sont pas reconstruits et les commits documentaires ne sont pas réattribués au paquet. Les publications 2.0.0 et 2.0.1 restent conservées. Le [guide 2.0.2](RECETTE-MANUELLE-V2.0.2.md), inclus dans le commit construit et l’intégrité du pack, décrit les observations utilisateur encore attendues ; il ne remplace pas les résultats du rapport ni la garde stricte des deux VM.

## 26 octobre 2026 — publication manuelle des packs correctifs 2.0.1

**Dernière décision de David : les téléchargements courants doivent être les packs v2, avec la v1 en historique.**
La v2 est intégrée sur `master`. La publication manuelle autorisée porte sur les deux ZIP **2.0.1**
déjà qualifiés dans leur périmètre, construits depuis `ba2eb50c82a218a602f12c646d38f058e59d6414`.
Elle utilise la [release v2.0.1](https://github.com/M4D135/domenia-d120/releases/tag/v2.0.1),
sans reconstruire les archives et sans remplacer la release 2.0.0.

Les [liens directs PROD/DEV et SHA256](../../packs/README.md) et le
[manifeste de provenance](../../packs/manifest.json) désignent les octets exacts du
[run 40317233027](https://github.com/M4D135/domenia-d120/actions/runs/40317233027).
Avant d’annoncer leur disponibilité, vérifier la présence des trois fichiers sur la release, leurs tailles
et leurs SHA256 : PROD `fe8a3a271d49c57a2458f94205f51d9c1ae1f579263a88ee507a4e09aad2184a`,
DEV `0a5df511797a658953a8bb9372e595a2a9079e931094e5c0d97dfdf111276511`,
`SHA256SUMS.txt` `9d6fc0c3ed2a7f964ab7951e204fd61078c2aaf0434a0abc941c4056986b6292`.
Le tag [v1-historique-20261026](https://github.com/M4D135/domenia-d120/tree/v1-historique-20261026)
conserve les anciens packs v1 ; ils ne sont plus les téléchargements courants.

La CI et la recette réelle de lecture sur un poste joint au domaine sont décrites dans le
[rapport final](reprise/rapports/RAPPORT-RECETTE-DOMAINE-20261026.md) : 43 étapes réussies,
fermeture normale avec code 0, aucune écriture AD exécutée. La [recette manuelle ciblée](RECETTE-MANUELLE-V2.0.1.md)
reste `pending`. La performance VM et le parcours strict des **deux postes VM** restent non qualifiés.
Cette autorisation de publication ne produit aucun `eligible:true` et ne complète aucune preuve absente.
Le vérificateur manuel n’accepte que les versions 2.0.0 et 2.0.1 explicitement autorisées ; ses garanties
d’archives, de sources et de SHA256 ainsi que la garde stricte des deux VM restent inchangées.
Le premier et le second lancement restent distingués, sans purge du cache Windows ni affirmation
d’un démarrage à cache système froid.

## 0. Historique — décision du 25 octobre 2026 pour la livraison manuelle v2.0.0

**David autorise la préparation et la livraison des packs PROD/DEV v2.0.0 sans attendre la recette des deux VM ; il les testera à la main.** La [décision datée](DECISIONS.md) remplace, pour cette livraison seulement, l’obligation antérieure d’obtenir les validations domaine/UI/native des deux VM avant publication. Elle ne transforme aucun contrôle non exécuté en réussite.

Preuve disponible : [run 40224745081, job 121263620296](https://github.com/M4D135/domenia-d120/actions/runs/40224745081/job/121263620296), SHA `1e877d650df71b37716b0b0840726238f632db7d`.

| Vérification | État attesté |
| --- | --- |
| Windows Debug et Release | Zéro erreur, zéro avertissement |
| Tests C# critiques | 587 réussis sur 587, zéro échec |
| Contrôles Python critiques de livraison | 15 réussis sur 15 |
| Job ciblé / `result.json` | Code `0` ; `critical`, `releaseGuardCritical`, `debug`, `release` à `passed` |
| Domaine, UI et deux VM | `domain`, `ui`, `twoVM` à **`not-run`** |
| Recette manuelle de David | À effectuer ; aucun résultat présumé |

La livraison manuelle doit conserver les deux archives exactes, `SHA256SUMS.txt`, leur commit source et leurs manifestes, ainsi que la référence de cette CI. Le DEV contient les mêmes binaires et ressources que le PROD et les sources correspondant au commit déclaré. La CI citée qualifie son SHA ; une nouvelle archive ou un nouveau commit n’acquiert pas automatiquement cette preuve. Les contrôles d’intégrité et de provenance de la préparation restent obligatoires, et tout défaut de ces contrôles bloque la remise du paquet concerné.

Les notes de livraison doivent annoncer la dérogation et les validations absentes, avec le [guide de recette manuelle](RECETTE-MANUELLE-V2.0.0.md). Aucun résultat positif de cette recette n’est prérempli. La dérogation n’étend aucune autorisation : isolation des profils/démonstration, gardes d’écriture et OU `OU=Domenia-Tests,DC=cnamts,DC=local` conservées ; `dev/` en lecture seule, WAPT exclu, aucun téléchargement de dépendance ni changement de service/runtime/réseau, reboot ou logoff.

### Outil strict conservé et autorisation humaine distincte

`release-guard.py` conserve exactement le parcours strict décrit aux sections 1 à 5. Sans les preuves des deux VM, il doit refuser l’éligibilité : ne pas modifier ses exigences, compléter artificiellement ses preuves ou annoncer `eligible:true`. Les tests Python verts vérifient le fonctionnement de cette garde ; ils ne rendent pas les paquets éligibles au parcours strict.

La publication manuelle autorisée ici est tracée par cette décision, indépendamment du verdict strict. Le reçu de préparation peut donc rester `candidate-unvalidated`, et les résultats `domain`, `ui`, `twoVM` restent `not-run`. Les sections suivantes conservent la procédure de qualification complète et les exigences historiques ; leurs interdictions de publication faute de recette sont remplacées **uniquement pour cette dérogation v2.0.0**. Une future qualification par l’outil devra produire toutes ses preuves réelles.

Le chemin GitHub de préparation est `tools/release-manual-ci.ps1`, après la CI critique du même SHA. Il utilise les runtimes déjà présents, sous forme de copies privées qualifiées dans le paquet, et complète le DEV avec les NuGet versionnés. Son reçu porte `manual-user-pending`. Il vérifie chargement privé, refus du démarrage sans runtime privé, intégrité PROD/DEV, sélection Web critique et six parcours UI de simulation avec captures ; les résultats exacts doivent être lus après exécution. `verify-manual-packages.py` atteste l’intégrité pour cette livraison manuelle, et `verify-ci-browser-evidence.py` contrôle les rapports et PNG. Aucun de ces outils ne valide les deux VM ou la recette réelle. Les captures doivent être examinées et les archives exactes conservées avant publication.

## Parcours strict conservé — préparation et qualification complète

La préparation d'un candidat et l'autorisation de publier sont distinctes. `vm.sh LOT publish --zip` prépare les archives depuis des sources commitées et contrôle leur intégrité ; le reçu de préparation porte `validationStatus: candidate-unvalidated`. Ni ce reçu, ni un build, ni un code processus zéro ne constituent la recette finale.

**Aucune preuve des deux VM n'est créée par cette documentation.** Dans ce parcours strict, l'absence des deux dossiers ci-dessous interdit la publication. Les exceptions de livraison manuelle v2.0.1 et v2.0.0 sont consignées dans les décisions datées ci-dessus ; elles ne modifient pas le verdict de cette garde.

## 1. Préparer et conserver le même lot

Terminer le développement, commiter et pousser la branche. Compiler Debug et Release dans Windows sans erreur ni avertissement. Préparer les candidats avec le publisher existant, sans reconstruire leurs exécutables entre leur recette et la publication. Conserver les journaux bruts de compilation, `.release-source.json`, les deux ZIP exacts et `SHA256SUMS.txt`.

Le DEV doit contenir les mêmes binaires et ressources que le PROD, ainsi que `developer/source-commit.json` et les sources qualifiées. La garde relit les deux archives sans les extraire et vérifie chemins Windows, doublons, liens, tailles, ratios, manifestes, métadonnées, commit, couverture exacte et SHA-256 de chaque entrée. Un simple nom de ZIP ou un EXE identique ne suffisent pas.

## 2. Exécuter les contrôles critiques dans les deux VM

Les VM autorisées restent :

| VM | UUID système attendu |
| --- | --- |
| `CNAMTS-DC01` | `7625c944-b4fc-4f8b-ac23-c796cc1be791` |
| `DOMENIA-FIRSTRUN-20261020` | `bc2f1ac0-9545-49bd-a0f5-cb89d352cf61` |

La capture rapproche l'UUID lu localement dans `Win32_ComputerSystemProduct`, le nom Windows et une session interactive. Si la correspondance VirtualBox/SMBIOS ne concorde pas, arrêter la qualification et expliquer l'écart ; ne pas remplacer un UUID par une valeur commode. Aucun reboot, logoff, téléchargement ou changement de service/réseau n'est nécessaire.

Sur **chacune** des deux VM, avec le même lot de tests compilé :

1. Exécuter `Domenia.Tests.exe --critical` et conserver sa sortie UTF-8 intégrale. Une sélection vide, un échec, un total incohérent ou une classe critique manquante sont refusés.
2. Exécuter le harnais WebView2 avec `--critical` dans le bureau déjà ouvert et avec son runtime local prévu. Conserver le `report.json` et `page.png` du même passage.
3. Exercer les scénarios UI ciblés sur le **PROD extrait exact**, avec un dossier de rapport neuf pour chaque invocation. La garde exige les cas ci-dessous, et refuse tout cas ignoré ou non terminé parmi les rapports fournis.
4. Effectuer la recette native explicite décrite dans `reprise/RECETTE-NATIVE-CODEX.md` en mode `--critical-canary`, avec le canari de description et sa compensation sous `OU=Domenia-Tests,DC=cnamts,DC=local`. Les quatre lectures retenues sont `directory.scope`, `audit.machineIdentity`, `operations.history`, `poste.inventory` ; les 26 autres contrats restent explicitement non exécutés. Conserver `evidence.jsonl`, les reçus et les traces d'exécution. Chaque résultat brut retenu doit ensuite être qualifié ; `Returned`, `ProtocolCompleted` et `qualified:false` ne sont pas des succès métier.

Sélection UI automatique minimale :

| Mode | Identifiants des scénarios existants |
| --- | --- |
| Simulation | `accueil/actualiser-ou`, `accueil/catalogue-widgets`, `fiche/modifier-description`, `operations/releve-reprise`, `parametres/collecte-fenetre`, `synchro/parc-partage` |
| Annuaire | `parametres/apparence-theme`, `parametres/recherche-reglage`, `schema/panneau-annuaire` |

Les premiers exercent le circuit et ses garde-fous sur données fictives. Les seconds contrôlent le shell et les réglages en mode réel sans écrire dans l'annuaire. **Ils ne couvrent pas seuls les nouvelles fonctionnalités ou l'UI native : la revue explicite suivante reste obligatoire.** Les seuls scénarios natifs qui écrivent doivent rester dans l'OU autorisée, et aucun scénario de reboot/logoff n'entre dans cette recette.

## 3. Capturer les preuves existantes

Le script `tools/capture-release-evidence-vm.ps1` ne lance ni application ni test. Il contrôle le paquet extrait, qualifie les sources et lit l'identité de la VM ; il copie les rapports et captures existants dans un dossier neuf sans écraser les passages antérieurs. Le snapshot conserve les SHA des rapports **et de chaque capture UI** ; remplacer une image après sa capture invalide les preuves. Il n'ajoute aucun verdict positif.

Le pack contrôlé est le PROD-LIGHT extrait (`Domenia.exe` et `wad\`, manifeste au format 2 dans `wad\`) ; un PROD de labo (format 1) ou un ancien pack à plat reste lisible. Si le pack WebView2 du Socle a été extrait dans `wad\runtime\webview2`, chacun de ses 257 fichiers est comparé à l'index épinglé des sources ; tout autre fichier hors manifeste est refusé.

Exemple de forme, à renseigner avec les chemins du lot et de ses passages réels :

```powershell
.\tools\capture-release-evidence-vm.ps1 -FinalValidation `
  -VmName 'DOMENIA-FIRSTRUN-20261020' `
  -SourceRoot 'C:\DomeniaDev\src\LOT\v2' `
  -Pack 'C:\DomeniaDev\recette\PROD-LIGHT' `
  -TestDirectory 'C:\DomeniaDev\tests-valides' `
  -DebugBuildLog 'C:\DomeniaDev\preuves\build-Debug.log' `
  -ReleaseBuildLog 'C:\DomeniaDev\preuves\build-Release.log' `
  -CSharpLog 'C:\DomeniaDev\preuves\critical-csharp.log' `
  -WebReport 'C:\DomeniaDev\preuves\web\report.json' `
  -UiReport @('C:\DomeniaDev\preuves\ui-simulation\report.json', 'C:\DomeniaDev\preuves\ui-annuaire\report.json') `
  -NativeEvidence 'C:\DomeniaDev\preuves\native\evidence.jsonl' `
  -EvidenceRoot 'C:\DomeniaDev\preuves-finales'
```

Les deux dossiers uniques produits sont réunis dans un dossier de preuves, en conservant leurs noms. Le script affiche la référence de leur `snapshot.json`. Une référence est toujours un objet `{ "path": "chemin/relatif", "length": nombre_d_octets, "sha256": "64 caractères hexadécimaux minuscules" }`, calculé depuis les vrais octets. Les chemins absolus, liens, jonctions et traversées sont refusés par la garde.

## 4. Revue fonctionnelle et UI

Un relecteur examine les sorties natives, captures et scénarios. Il établit pour chaque VM un document `Domenia.ReleaseReview/1` avec exactement :

- `format`, `reviewer` (nom du relecteur), `reviewedAt` (ISO 8601 avec fuseau) ;
- `sourceCommit`, `machine`, `packageManifestSha256`, identiques au snapshot ;
- `native` : une propriété pour chacune des quatre lectures critiques retenues, listées dans `NATIVE_READS` de `release-guard.py`, avec `{ "verdict": "passed", "note": "constat observé et raison de la qualification" }` ; les 26 lectures omises ne sont jamais déclarées validées ;
- `checks` : les dix parcours ci-dessous. Chaque valeur contient `verdict`, `note` et `evidence` (liste de références vers les vrais fichiers). Aucun `passed` ne doit être prérempli dans un modèle ou déduit d'un code zéro.

| Identifiant | Contrôle et preuve attendue |
| --- | --- |
| `portable-start` | Démarrage du PROD extrait, fenêtre native visible et état cohérent. |
| `configuration-defaults` | Profil vierge, profil existant, aperçu, sauvegarde et choix de conservation/remplacement. |
| `demonstration-isolation` | Entrée, action fictive, réinitialisation, sortie et conservation du contexte réel. |
| `update-rollback` | Préparation de copie locale, contrôle d'intégrité, mise à jour et retour arrière vérifiés sur copies dédiées. |
| `read-retry-stop` | Reprise des seules lectures admissibles, arrêt, refus et absence de réémission risquée. |
| `settings-effective` | Modification des budgets/réglages, effet réel mesuré et remise des valeurs initiales. |
| `home-resume` | Interruption et reprise explicite du plan Accueil, identité et données déjà enregistrées conservées. |
| `widget-collection` | Ajout, file et progression visibles, refus/annulation sans fausse mesure réussie. |
| `offline-cli-read-only` | CLI locale, sortie et code réels, absence de mutation ou accès annuaire. |
| `ad-scope-receipts` | Plan de canari, reçus et restauration indépendante dans la seule OU autorisée. |

Une capture PNG réellement examinée est requise pour chaque parcours UI. La CLI peut produire seulement ses journaux. Les captures des étapes E2E sont également relues et doivent exister ; un rapport JSON seul n'est pas une preuve UI suffisante. La revue doit décrire les limites natives restantes plutôt que les déclarer réussies.

Le dossier final `release-evidence.json` possède exactement `format: "Domenia.ReleaseEvidence/1"`, `version: "2.0.0"`, `sourceCommit`, `packages` et `vms`. `packages` contient les références `prod`, `dev`, `sha256`. `vms` contient exactement deux objets avec les références `snapshot` et `review`.

## 5. Autoriser la publication des octets exacts

Depuis le poste de pilotage disposant déjà de Python 3 (aucun paquet Python requis), après récupération des preuves des deux VM :

```bash
python3 v2/tools/release-guard.py --evidence /chemin/preuves/release-evidence.json --commit SHA_COMPLET
```

Cette commande relit les fichiers et archives, compare les deux lots de tests, vérifie les sorties critiques et l'existence de la revue complète, puis recontrôle les empreintes. Elle échoue si une preuve manque ou diffère. Elle ne lance aucune suite et ne contacte pas GitHub. Son éventuel résultat `eligible:true` autorise seulement les deux ZIP dont elle affiche les SHA ; `published` reste `false`.

La publication doit utiliser exactement ces ZIP et ce `SHA256SUMS.txt`, sur le même commit. Toute correction du code, reconstruction, nouvelle configuration diffusée ou modification d'un paquet rend les anciennes preuves insuffisantes pour les nouveaux octets. Dans ce parcours strict, aucun tag ou upload `v2.0.0` ne doit être produit après un refus de la garde ; la dérogation manuelle de la section 0 ne change pas ce refus en réussite.

Le SHA établit la cohérence du dossier ; il ne crée ni signature d'éditeur, ni preuve cryptographique de l'identité du relecteur. La qualification des résultats natifs et l'examen visuel restent des actes explicites enregistrés. Un résultat vert n'est jamais présenté comme une validation exhaustive du catalogue.

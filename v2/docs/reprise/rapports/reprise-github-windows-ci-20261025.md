# Windows via GitHub Actions — preuves de la reprise du 25/10/2026

## Portée

À la demande de David, le même moyen d'exécution Windows que le projet GLPI a été utilisé : GitHub Actions. La branche de développement est `codex/v2-finalisation-20261025`, issue de `v2` à `9b1c0333c34020ad88c1448874b91eff884d5406`. Les fichiers du lot123 restés sur Spark/Mac ne sont pas récupérés par cette méthode.

Le workflow versionné `.github/workflows/domenia-v2-windows.yml` compile les onze projets, dont les projets de tests, sur Windows x64. Il utilise le SDK 10.0.402 préinstallé, compatible avec le `global.json` du dépôt, et les cinq paquets NuGet versionnés contrôlés par SHA256. Le seul feed de restauration est local. Aucun SDK, runtime ni paquet applicatif n'est téléchargé ; aucun service ni réglage réseau n'est modifié.

Les sorties CI dépendent du runtime installé sur le runner. Elles ne sont pas des packs PROD autonomes et ne sont pas publiées comme tels. Les journaux, empreintes d'entrée et `result.json` sont conservés dans l'artefact du run pendant 14 jours.

## Compilations réellement lues

Chaque ligne ci-dessous correspond à des journaux de job lus, avec **Debug et Release réussis, zéro avertissement et zéro erreur**. Un résultat ne couvre que son commit et ses ancêtres.

| Commit GitHub | Lot inclus | Run / job Windows |
| --- | --- | --- |
| `c60ebd110091eefb0185c55e7df9030fec28db8e` | Socle CI hors ligne | [40213483359](https://github.com/M4D135/domenia-d120/actions/runs/40213483359) / `121229525937` |
| `2b34e9b0371eb4c4817dcf26c3f9e7ce28736b50` | Premiers consommateurs des reprises108 | [40214071981](https://github.com/M4D135/domenia-d120/actions/runs/40214071981) / `121231297772` |
| `fea4c18117d07145d669859f16140739dde03329` | Accueil249, widgets290–292, fin physique, réglages/CLI, garde de livraison et chargeur strict | [40215771359](https://github.com/M4D135/domenia-d120/actions/runs/40215771359) / `121236451103` |
| `c134f5fa0af2530523e76370c13b3eb0faddc00f` | Fin physique des inventaires partagés | [40216313386](https://github.com/M4D135/domenia-d120/actions/runs/40216313386) / `121238089184` |
| `154e81402207662085422042eb58d8dbe4b8ac9f` | Sondes personnelles Accueil et SELECT des campagnes | [40217067051](https://github.com/M4D135/domenia-d120/actions/runs/40217067051) / `121240435579` |
| `c6dd5e0d754ba2a3d349ce0f77e2ae33b29ce48a` | Export local des observations personnelles par la CLI | [40217196365](https://github.com/M4D135/domenia-d120/actions/runs/40217196365) / `121241084482` |
| `abeb0c7b954cc3e9ae8717e033f8b6c934f9b332` | Cartes et relevés personnels explicites de Poste | [40218525632](https://github.com/M4D135/domenia-d120/actions/runs/40218525632) / `121244811780` |
| `bd350707f568a8ecc3c9923883a532bdd3304625` | Mêmes baux LDAP/machine conservés pendant les reprises108 | [40219618795](https://github.com/M4D135/domenia-d120/actions/runs/40219618795) / `121248131252` |
| `180b97c4b70a2bf0105e551500cd0a5d61d87c79` | Atelier Query/4, consommateurs typés, CLI et préparation du passage critique | [40220125380](https://github.com/M4D135/domenia-d120/actions/runs/40220125380) / `121249678456` |
| `ac56d748434c085ba2c8f5cf0c093d1f593f2002` | Correctifs des premiers échecs critiques ; compilation ordinaire sans suite | [40221961403](https://github.com/M4D135/domenia-d120/actions/runs/40221961403) / `121255257934` |
| `bc4ff640fcdfb1e026e34c7e647412da70580dcb` | Sauvegardes SQLite bornées et diagnostic des ACL ; compilation ordinaire sans suite | [40222970595](https://github.com/M4D135/domenia-d120/actions/runs/40222970595) / `121258339517` |
| `11eeab84068d079b4fd7c373e2308c3593182c5d` | Conservation exacte de l'ACL Windows ancienne ; compilation ordinaire sans suite | [40224029291](https://github.com/M4D135/domenia-d120/actions/runs/40224029291) / `121261494898` |
| `1e877d650df71b37716b0b0840726238f632db7d` | Lanceur Python corrigé ; compilations incluses dans le passage critique vert | [40224745081](https://github.com/M4D135/domenia-d120/actions/runs/40224745081) / `121263620296` |

Pour `c6dd5e0d`, Debug s'est terminé à `2026-10-25T17:38:30Z`, Release à `17:39:20Z`. L'entrée `DOMENIA_CRITICAL_REQUESTED` était `false` : **aucun test exécuté** dans ces runs automatiques.

Pour `abeb0c7b`, Debug s'est terminé à `2026-10-25T17:53:43Z`, Release à `17:54:25Z`. Les changements ultérieurs de l'admission OneShot et de l'Atelier ne sont pas inclus dans ce SHA.

Pour `bd350707`, Debug s'est terminé à `2026-10-25T18:07:46Z`, Release à `18:08:40Z`. L'échec précédent `d8915aea`, [run 40219330418](https://github.com/M4D135/domenia-d120/actions/runs/40219330418), provenait d'une assertion de test recevant `bool?` au lieu de `bool` (CS1503). La correction exige explicitement `Confirmed == true` ; elle n'affaiblit pas l'assertion. Aucun test exécuté dans ces compilations.

Les autres échecs intermédiaires sont conservés dans Actions : nullabilité du DN de la CLI, autorisation des blocs unsafe dans le projet de tests qui lie le worker natif, puis ambiguïté du type `ProbeReading` dans la simulation Accueil. Ils ont été corrigés dans des commits distincts ; un résultat vert ultérieur ne transforme pas les anciens runs en réussites. Le premier passage du lot Atelier `c84b633c` est détaillé ci-dessous.

Son [premier run 40219898054](https://github.com/M4D135/domenia-d120/actions/runs/40219898054), job `121248990437`, a échoué sur CS0136 : la variable `expected` d'un test de simulation était redéclarée dans une boucle. Le flux aléatoire extérieur est renommé `expectedStream` dans le lot préparant la validation critique, sans modification de l'assertion. Aucun test exécuté dans ce run.

Le correctif `180b97c4` compile réellement : Debug terminé à `2026-10-25T18:13:42Z`, Release à `18:14:20Z`, zéro erreur et zéro avertissement dans les journaux lus. Ce run ordinaire ne lance aucune suite. La demande documentaire `ae1a5a1e4a1bdc64a5062e6952514d61b1e17800` conserve le même code et lance séparément le passage critique depuis la branche de validation ; ses résultats ne sont pas déduits de ce build.

## Passage critique et limites

Le développement et le push doivent précéder les suites. L'option explicite du workflow, ou la branche dédiée `codex/v2-validation-critique-20261025` créée à partir du développement terminé, sélectionne seulement `Domenia.Tests.exe --critical`. Les pushes ordinaires continuent à compiler sans exécuter de suite. Le harnais refuse une sélection vide ou une classe attendue absente.

Le workflow prépare aussi l'exécution finale des quinze tests critiques de refus de `tests/tools/test_release_guard.py`, avec le Python préinstallé et sans dépendance externe. Cette sélection purement locale porte sur la garde de publication ; ses fixtures synthétiques ne peuvent constituer les preuves d'acceptation demandées. Les deux résultats sont enregistrés séparément.

Dernier passage lu : `1e877d650df71b37716b0b0840726238f632db7d`, [run 40224745081](https://github.com/M4D135/domenia-d120/actions/runs/40224745081), job `121263620296` : **succès**.
Debug à 19:11:34 UTC, Release à 19:12:10 UTC : zéro erreur et avertissement. Les **587 tests C# critiques passent, zéro échec**
à 19:13:15 UTC, sur 2 379 enregistrés ; les 1 792 autres ne sont pas exécutés. Les **quinze tests de garde passent** à 19:13:16 UTC,
code 0. Le résultat distingue explicitement ces quatre contrôles réussis des deux VM et de l'UI/native, toujours `not-run`.
L'archive originale des douze fichiers de preuve est conservée dans `preuves-ci-20261025-1e877d65.zip`, avec digest vérifié ;
voir `validation-critique-github-20261025.md` pour les horodatages, empreintes et liens exacts.

Le runner GitHub permet de compiler et d'exécuter les tests C# locaux sous Windows. Il ne prouve pas les accès AD/SMB du laboratoire, le comportement du WebView dans les sessions utilisateurs des deux VM, ni la recette native réelle. Aucune commande de recette native n'est ajoutée au workflow CI.

Les validations finales restent exigées sur `CNAMTS-DC01` et `DOMENIA-FIRSTRUN-20261020`, avec preuves UI/native réellement revues. L'accès à ces bureaux n'est pas disponible dans cet environnement. **Deux VM et UI/native non vérifiées, aucun PROD/DEV v2.0.0 publié.** La garde `tools/release-guard.py` exige ces preuves avant toute publication finale.

L'historique des passages reste conservé : refus de sélection initial, 524 réussites/44 échecs sur `27d7fccd`, 562/21 sur `ac56d748`,
565/20 sur `bc4ff640`, puis 587/0 sur `11eeab84` avec lancement Python refusé. Le dernier passage `1e877d65` corrige ce lancement et
termine les deux sélections critiques. Les résultats antérieurs restent consultables dans Actions et dans
`validation-critique-github-20261025.md` ; aucun ancien échec n'est réécrit en réussite.

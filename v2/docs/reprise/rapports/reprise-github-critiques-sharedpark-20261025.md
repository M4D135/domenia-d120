# Corrections critiques SharedPark et annexe de sauvegarde — 25 octobre 2026

## Dernier état vérifié

Au SHA `1e877d650df71b37716b0b0840726238f632db7d`, le job GitHub ciblé est **réussi, code de sortie 0** : compilations Windows Debug/Release sans erreur ni avertissement, **587 tests C# critiques réussis sans échec** et **15 contrôles Python réussis sur 15**. Les 20 anciens échecs SharedPark sont résolus. La preuve détaillée figure au cinquième passage ci-dessous ; les passages historiques sont conservés. Les validations `domain`, `ui` et `twoVM` restent `not-run` : la recette domaine/UI/native sur deux VM Windows n’est pas déclarée verte.

## Preuves de départ

- Run Windows `40220607341`, SHA testé `27d7fccd` ; compilation Debug/Release sans erreur ni avertissement, puis sélection critique : 524 réussites, 44 échecs sur 568 cas ; 1 801 tests hors sélection non exécutés.
- Le journal de ce run relève 16 échecs `SharedParkApplyTests` et 3 échecs `NativeSharedParkIntegrationTests` avant le succès attendu de publication. Le reçu reste `Unknown`, ou le point de contrôle après publication n’est pas atteint.
- La création d’un TSV absent réussit. Les 7 tests directs `SharedParkPublicationAclTests` réussissent ; leur fixture de remplacement existant protège systématiquement la DACL de départ. Ils ne couvrent pas une cible dont la DACL hérite encore du parent.
- `NativeStorageBackupTests.Exported_backup_round_trip_recovers_its_exact_plan_named_preferences_annex` atteint un refus `Initialisez et vérifiez la base avant cette écriture.`

## Corrections

### Publication et ACL héritée

La comparaison après `File.Replace` portait sur le SDDL entier de la cible initiale, alors que le temporaire est volontairement créé avec une DACL privée protégée. L’hypothèse ciblée est la conservation du drapeau de protection du temporaire lors de la fusion de DACL par Windows. Le premier journal ne conserve pas l’exception interne : cette cause précise reste à confirmer au prochain passage Windows.

`SharedParkPublicationFile` permet maintenant de retirer ce seul drapeau lorsque cela restitue **exactement** le SDDL initial en mémoire, avant toute application. Une différence d’ACE, de provenance héritée, d’ordre, de propriétaire ou de cible continue à refuser la publication. Le nouveau fichier est lié à l’identité physique du temporaire, l’ancien à son identité et à son SHA, et la politique du parent est relue avant/après l’opération. Le propriétaire du nouveau fichier doit rester celui du temporaire préparé.

La lecture d’une cible existante ne demande aucun droit supplémentaire si son ACL est déjà exacte. La remise d’héritage seule ouvre un second handle avec `WRITE_DAC`, pendant que le premier interdit écriture et renommage ; identité, SHA, propriétaire, SDDL observé et parent sont à nouveau qualifiés avant application, puis l’ACL et le propriétaire sont relus. Cette séquence n’est pas un CAS atomique des permissions : un acteur disposant de `WRITE_DAC` peut encore intervenir entre contrôle et application, comme autour de la fusion de permissions de `ReplaceFile`. Toute différence observable conserve l’état incertain ; aucun rejeu ni retour arrière automatique n’est ajouté.

Une capture interne facultative de l’exception de publication est raccordée uniquement à la fixture `SharedParkApplyTests`. Le prochain journal critique indiquera le type, le message, le HRESULT et l’éventuelle cause interne derrière `Unknown`. Le reçu normal ne reçoit pas ces données techniques. Une défaillance de cet observateur ne remplace jamais l’issue `Unknown`.

### Détention des répertoires

`SharedParkPublicationFile.PathPins` et `SharedParkBackupFiles.Pin` ouvraient leurs parents avec `FILE_READ_ATTRIBUTES` seul (`0x80`). Un accès limité aux attributs ne constitue pas la détention attendue pour refuser un renommage de répertoire par le mode de partage Windows. Le même défaut a été observé dans la famille critique `ReferencePatchScopeTests`.

Les deux ouvertures demandent maintenant `FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES` (`0x81`), avec partage lecture/écriture et sans partage suppression. Elles n’énumèrent pas les dossiers et ne demandent aucun droit d’écriture. Les créations d’enfants restent possibles ; les ancêtres doivent rester fixés jusqu’à fermeture des handles.

### Sauvegarde/restauration

Après restauration, `CompatibleDirectoryCache` sélectionne une nouvelle instance de `DomeniaDatabase`. La fixture appelait directement `active.SaveFleetAsync`, sans initialiser cette instance. Le garde `EnsureReady` refusait donc correctement avant la mutation que le test voulait provoquer.

La fixture utilise maintenant `setup.Cache.SaveFleetAsync`, chemin normal qui passe par l’initialisation/vérification du cache. Une assertion supplémentaire exige que la révision SQLite ait réellement augmenté de un avant de tester le refus de réappliquer l’ancienne annexe. Le garde de production et les assertions sur l’empreinte, l’annexe exacte, les préférences et le reçu sont conservés.

## Cas critiques écrits

Quatre cas sont ajoutés à `SharedParkPublicationAclTests`, déjà dans la sélection critique :

1. Conservation exacte d’une DACL héritée, puis d’une DACL mêlant héritage et ACE explicite.
2. Refus d’une ACE modifiée après renommage, sans la remplacer ni compenser les octets publiés.
3. Refus du renommage d’un ancêtre pendant `PathPins`, création d’un enfant autorisée et renommage possible après `Dispose`.
4. Même détention vérifiée au travers de `SharedParkBackupFiles.Open` pour les preuves privées.

Les 19 scénarios de publication existants gardent leurs exigences `Applied`, commit réel, conservation des preuves et vérification à froid. Aucun résultat attendu n’est abaissé à `Unknown`.

Un cinquième cas, dans `SharedParkApplyTests`, injecte la défaillance de l’observateur diagnostic après publication : résultat incertain, intention conservée et absence de commit SQLite restent exigés.

## Validation initiale, avant les passages Windows ci-dessous

- Relecture statique et `git diff --check` effectués.
- Aucun build ni test exécuté localement pendant ces corrections.
- Résultat du prochain run critique Windows : **non vérifié à la rédaction**.
- Recette UI/native sur deux VM Windows : **non vérifiée**. Ce rapport n’autorise aucune publication PROD/DEV.

Références de contrat Win32 : [ReplaceFileW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-replacefilew), [CreateFileW](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew), [ObjectSecurity.SetAccessRuleProtection](https://learn.microsoft.com/en-us/dotnet/api/system.security.accesscontrol.objectsecurity.setaccessruleprotection).

## Second passage Windows — ac56d748

Run `40221973309`, job `121255294635` : Debug/Release sans erreur ni avertissement ; sélection critique 562 réussites, 21 échecs sur 583 cas.

Les quatre nouveaux cas ACL/pins et le cas de diagnostic sont verts. Les 16 cas Apply et 3 cas d’intégration restent en échec. Les lignes `DIAG` du journal des fixtures Apply donnent toutes le même refus : `InvalidDataException`, « Droits de la cible existante non conservés ; état incertain. », HRESULT `80131501`. Ce refus se produit dans `ConfirmPublishedPermissions`, avant le point de contrôle `Published` et avant les écritures locales ; il n’est donc pas causé par le commit SQLite.

La seule remise du drapeau de protection ne résout pas ces cas. La comparaison exacte reste en place. Le parent des fixtures ACL vertes reçoit une politique explicite, tandis que les fixtures Apply/intégration conservent la politique héritée de l’arborescence temporaire Windows. Pour distinguer une différence réelle d’ACE d’un drapeau de descripteur, le refus interne transporte maintenant les SDDL initial et observé dans `Exception.Data` ; seule la fixture les écrit dans le journal de tests, sans changer le reçu public.

Un cas supplémentaire `A_target_with_the_native_Windows_temporary_parent_DACL_remains_exact_after_replacement` conserve cette politique Windows native, exige le SDDL entier après remplacement et affiche les deux descripteurs si la publication refuse. Il ne réécrit pas le parent pour rendre la fixture acceptable.

À ce stade, ce complément est diagnostique : aucune différence supplémentaire de droits n’est acceptée sans preuve. Les 19 échecs ne sont pas encore déclarés résolus et un nouveau passage Windows après commit/push reste à effectuer. Aucun test local exécuté.

## Troisième passage Windows — bc4ff640 : transformation prouvée

Run `40222981005`, job `121258369692` : Debug/Release sans erreur ni avertissement ; 565 réussites, 20 échecs sur 585 cas critiques. La sauvegarde/restauration et Platform sont vertes. Les 19 parcours SharedPark et le nouveau cas au parent Windows natif échouent encore.

Les diagnostics donnent exactement :

```text
Initial : D:(A;ID;FA;;;SY)(A;ID;FA;;;BA)(A;ID;FA;;;LA)
Publié  : D:AI(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;LA)(A;ID;FA;;;SY)(A;ID;FA;;;BA)(A;ID;FA;;;LA)
Parent  : D:(A;OICIID;FA;;;SY)(A;OICIID;FA;;;BA)(A;OICIID;FA;;;LA)
```

Il ne s’agit pas du seul ajout de `AI` : trois ACE explicites sont apparues devant les trois ACE héritées, dans le même ordre et avec les mêmes SID et masques. Le log prouve cette transformation après `ReplaceFile`, sans prouver son implémentation interne ni l’origine de chaque ACE explicite.

### Finalisation ciblée du descripteur confirmé

`SharedParkPublicationDacl` reconnaît uniquement la forme observée : DACL initiale présente de révision 2, sans protection ni indicateur d’héritage automatique ou autre drapeau d’interprétation de DACL, composée exclusivement d’ACE simples d’autorisation héritées. La DACL observée doit porter uniquement l’ajout `AI`, contenir exactement deux fois le nombre initial d’ACE, puis présenter dans cet ordre une copie binaire de chaque ACE initiale dont seul `ID` est retiré, suivie des ACE initiales intactes. Type, SID, masque, longueur, ordre, héritage, révision et drapeaux supplémentaires restent contrôlés. Les drapeaux `DiscretionaryAclUntrusted` et `ServerSecurity` sont aussi refusés.

Cette reconnaissance autorise une unique finalisation vers le descripteur confirmé ; elle n’autorise pas à accepter les doublons comme résultat final. Les autres formes legacy restent refusées sans déduction de compatibilité.

Pour cette seule forme, le code appelle `SetFileSecurityW` avec `DACL_SECURITY_INFORMATION = 4`. Il fournit les octets du descripteur binaire capturé avant publication par `GetAccessControl`, sans reconstruction depuis le SDDL ni résolution d’alias de SID. Le masque n’écrit ni propriétaire, ni groupe, ni SACL. Microsoft documente cette ancienne API pour les fichiers, tout en la déclarant obsolète ; les API modernes imposent le modèle courant d’héritage. `SetKernelObjectSecurity`, explicitement déconseillé par Microsoft pour les objets de système de fichiers, n’est pas utilisé.

L’appel par nom s’effectue pendant la détention des handles sans partage suppression sur le fichier et ses ancêtres. Le second handle établit l’admission `WRITE_DAC` et requalifie immédiatement identité, SHA, longueur, propriétaire, DACL observée et parent. Après l’appel, le SDDL initial **entier**, les ACE binaires, leurs drapeaux, la révision de DACL, le propriétaire et le parent doivent être identiques aux états attendus. Un échec natif ou une relecture différente laisse `Unknown` et les preuves ; aucun autre chemin ACL ni nouvelle publication n’est essayé. La fenêtre non atomique face à un détenteur concurrent de `WRITE_DAC` reste explicitement documentée.

### Vérification écrite et état

Deux tests critiques de reconnaissance sont ajoutés à la classe ACL déjà sélectionnée. Ils refusent ACE ajoutée/retirée/permutée, type, masque, SID ou héritage modifiés, ACL initiale explicite ou de refus, drapeaux inattendus et révision de `RawAcl` modifiée. Le cas natif exige maintenant aussi que propriétaire et groupe ne changent pas pendant la finalisation. Le scénario d’ACE concurrente est appliqué au parent configuré et au parent Windows natif.

Relecture statique et `git diff --check` effectués. Aucun test ni build local exécuté. À la préparation de ce correctif, son résultat natif n’était pas encore vérifié ; les 20 échecs du passage `bc4ff640` étaient alors les derniers résultats établis. Le passage suivant apporte la preuve d’exécution.

Sources Microsoft : [SetFileSecurityW](https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-setfilesecurityw), [SetKernelObjectSecurity](https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-setkernelobjectsecurity), [propagation automatique des ACE](https://learn.microsoft.com/en-us/windows/win32/secauthz/automatic-propagation-of-inheritable-aces), [descripteurs absolus et relatifs](https://learn.microsoft.com/en-us/windows/win32/secauthz/absolute-and-self-relative-security-descriptors), [SECURITY_INFORMATION](https://learn.microsoft.com/en-us/windows/win32/secauthz/security-information).

## Quatrième passage Windows — 11eeab84 : sélection C# critique réussie

Preuve : [run GitHub Actions 40224038422, job 121261526049](https://github.com/M4D135/domenia-d120/actions/runs/40224038422/job/121261526049), SHA exact `11eeab84068d079b4fd7c373e2308c3593182c5d`.

- Windows Debug et Release : **zéro erreur et zéro avertissement**.
- Tests C# critiques réellement exécutés : **587 réussis, zéro échec**.
- Tests C# enregistrés : **2 379**, dont **1 792 non sélectionnés et non exécutés**.
- Fin de la sélection C# critique : **25 octobre 2026 à 19:05:35 UTC**.

Tous les 20 échecs SharedPark établis au passage `bc4ff640` sont résolus, y compris le cas utilisant l’ACL native du dossier temporaire Windows. Les parcours de publication/transaction, les gardes d’identité et de permissions, la conservation des preuves, les vérifications à froid et les contre-exemples du matcher ont réellement été exécutés dans cette sélection ; le succès ne repose pas sur la seule compilation.

Le job global échoue **après** cette sélection C#, lors de la résolution de `python` par PowerShell, avant l’exécution des tests de garde concernés. Ce défaut de lancement est traité séparément ; ce run n’est donc pas présenté comme une CI globale verte.

La recette UI/native sur **deux VM Windows** demeure **non vérifiée**. Ce passage GitHub ne remplace pas ces deux validations et n’autorise pas la publication PROD/DEV v2.0.0. Aucun code, test ou commit n’est ajouté par cette mise à jour documentaire.

## Cinquième passage Windows — 1e877d65 : job ciblé réussi

Preuve : [run GitHub Actions 40224745081, job 121263620296](https://github.com/M4D135/domenia-d120/actions/runs/40224745081/job/121263620296), SHA exact `1e877d650df71b37716b0b0840726238f632db7d`.

| Vérification du 25 octobre 2026 | Résultat réel | Fin UTC |
| --- | --- | --- |
| Compilation Windows Debug | Zéro erreur, zéro avertissement | 19:11:34 |
| Compilation Windows Release | Zéro erreur, zéro avertissement | 19:12:10 |
| Sélection C# critique | 587 réussis sur 587, zéro échec | 19:13:15 |
| Contrôles Python critiques de livraison | 15 réussis sur 15 | 19:13:16 |

Le `result.json` de ce passage indique `critical`, `releaseGuardCritical`, `debug` et `release` à `passed`, avec le code de sortie `0`. Le défaut de résolution de Python observé au quatrième passage ne bloque plus ces contrôles ; ils ont cette fois été réellement exécutés et réussis.

Les 20 anciens échecs SharedPark restent résolus dans cette sélection, avec les exigences de conservation exacte des ACL, d’identité et de preuves inchangées. Cette preuve porte sur le SHA indiqué et sur la sélection exécutée, sans prétendre à une suite exhaustive.

Les états `domain`, `ui` et `twoVM` restent explicitement `not-run`. Ce job réussi ne constitue donc pas une recette domaine/UI/native sur deux VM Windows et n’autorise toujours pas la publication PROD/DEV v2.0.0. Cette mise à jour modifie uniquement le rapport ; aucun code, test ou commit n’est ajouté.

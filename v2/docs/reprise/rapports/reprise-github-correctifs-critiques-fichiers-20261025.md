# Correctifs après les échecs critiques Windows : handles et préférences

Preuve de départ : commit `27d7fccd456ea117dbc2a68a638e3a2e1bee6d03`, [run critique 40220607341](https://github.com/M4D135/domenia-d120/actions/runs/40220607341), job `121251158693`.
Debug et Release compilent sans erreur ni avertissement ; la sélection C# a réellement terminé : **524 réussis,
44 en échec, 568 sélectionnés sur 2 369 découverts**, 1 801 non exécutés. Les contrôles Python n'ont pas démarré.
Les présents changements répondent à trois de ces échecs ; ils attendent le prochain passage Windows.

## Protection des répertoires de référentiels

`ReferencePatchScopeTests.Reference_file_handles_pin_real_ancestors_and_refuse_wrong_types` a prouvé qu'un
`Directory.Move` réussissait malgré la détention des ancêtres. `ReferenceFileAccess` demandait uniquement
`FILE_READ_ATTRIBUTES` : une ouverture de métadonnées ne fournit pas la détention en lecture du flux répertoire
nécessaire à la restriction de partage attendue.

L'ouverture demande désormais `FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES` (`0x81`), avec partage lecture/écriture
et sans partage Delete. Aucun droit d'écriture ni suppression n'est demandé et aucun contenu de répertoire n'est
énuméré. Liens, jonctions, mauvais types et absences restent qualifiés depuis le handle natif. Si cette lecture du
répertoire n'est pas autorisée, l'opération échoue ; aucune permission ni ACL n'est modifiée pour l'obtenir.

Le test conserve ses refus de renommage, écriture et suppression pendant la détention, puis prouve que le renommage
redevient possible après la libération effective des handles. Il conserve la comparaison des octets.

Références Microsoft consultées : [constantes de droits fichier](https://learn.microsoft.com/en-us/windows/win32/fileio/file-access-rights-constants),
[contrôle des accès partagés](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdm/nf-wdm-iochecklinkshareaccess),
[CreateFile et partage Delete](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew).
La correction est fondée sur le défaut observé ; seul le prochain test Windows pourra confirmer son résultat.

## Refus physique de remplacement des préférences

Les deux tests `BoardLayoutHistoryTests.Failed_atomic_file_commit_keeps_real_fleet_view_and_history_at_previous_choice`
et `ConfigurationSeedTests.Late_source_mutation_under_commit_lock_and_failed_replacement_leave_previous_document_intact`
attendaient uniquement `IOException`. Le remplacement Windows `File.Move(..., overwrite: true)` a été refusé avec
« Access to the path is denied ». Le contrat .NET prévoit aussi `UnauthorizedAccessException` pour cette opération.

Les tests exigent désormais l'une de ces deux formes de refus disque, sans accepter une erreur métier ou un succès.
Les assertions restent strictes sur les octets, l'état mémoire, l'historique, le jeton de choix et la sauvegarde de la
tentative. Une assertion supplémentaire exige la suppression du temporaire de remplacement. Le stockage de production
n'est pas modifié : il traitait déjà les deux exceptions et ne publie son nouvel état qu'après l'écriture réussie.

Référence : [contrat File.Move](https://learn.microsoft.com/en-us/dotnet/api/system.io.file.move?view=net-10.0).

Relecture statique et `git diff --check` effectués ; aucune compilation ni suite locale. Aucun accès aux deux VM du
laboratoire ni recette UI/native établi. Aucun paquet PROD/DEV v2.0.0 publié.

## Résultat Windows après push

Au SHA `ac56d748434c085ba2c8f5cf0c093d1f593f2002`, [run critique 40221973309](https://github.com/M4D135/domenia-d120/actions/runs/40221973309),
les trois cas corrigés ci-dessus sont réellement réussis. Debug/Release : zéro erreur et zéro avertissement. Les deux
nouveaux contrôles de détention des répertoires de publication/sauvegarde passent également. Le résultat global reste en
échec : 562 réussites et 21 échecs sur 583 tests sélectionnés, dans d'autres chemins décrits au rapport de validation.
Ces réussites locales ne valent pas recette sur les deux VM ni preuve UI/native.

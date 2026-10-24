# Revue MICRO010-FIX1 — 24 octobre 2026

Correctif récupéré contre micro010-recovery.json, sources concurrentes préservées. Snapshot052 VM Debug : trois erreurs, zéro avertissement ; Release non tenté. Journal complet joint. Les deux CS1503 antérieurs ont été corrigés dans les sources des tests, mais la compilation052 s’arrête dans Store avant validation de toute la solution. 17 tests écrits, aucun exécuté.

## Trois diagnostics VM précis

- SharedParkPreviewFile.cs ligne341, CS0117 : Directory.GetAttributes n’existe pas. Employer File.GetAttributes(directory), comme le lecteur009 déjà validé ; conserver le contrôle reparse et le refus des erreurs.
- Ligne345, CS0117 : FileSystemRights.ReadWrite n’existe pas. Construire les droits explicites nécessaires avec FileSystemRights.Read | FileSystemRights.Write | FileSystemRights.Delete | FileSystemRights.Synchronize. Read contient ReadPermissions pour la relecture de DACL. Delete est nécessaire pour DeleteOnClose et Synchronize pour le handle synchrone. Ne pas confondre droits demandés au handle et FileShare.Read, qui doit rester sans partage écriture/suppression.
- Ligne446, CS1929 : la surcharge GetAccessControl(FileStream) ne prend PAS AccessControlSections. Utiliser held.GetAccessControl(), qui retourne Access/Owner/Group depuis le SafeFileHandle ; pas de réouverture par nom.

Les signatures et droits sont vérifiés dans les sources .NET10 et la documentation Windows (liens ci-dessous). Aucun ajout de dépendance ni contournement.

## Deux défauts de revue restant à corriger

1. CloseExpired retire encore Active.Remove(path) et décrémente reservedBytes AVANT de fermer les fichiers, contrairement au commentaire et au rapport FIX1. Une autre admission concurrente peut ainsi prendre les places/octets pendant que les anciens handles restent ouverts (voire attendent gate). Sous Admission, sélectionner seulement les leases expirées, sans retirer ni décrémenter. Fermer ensuite hors Admission ; Dispose libère sa réservation par jeton seulement APRÈS la fermeture physique. Les slots Lease=null restent propriété du Stage ; ne pas les voler. Conserver l’idempotence et les horloges propres déjà corrigées. Réécrire honnêtement le nouveau rapport sur le résultat réel, conserver le précédent comme historique.

2. Si l’expiration survient après le balayage initial, par exemple pendant l’attente de gate ou la relecture, les nouveaux Require à l’intérieur de Read refusent bien, mais laissent encore stream et la réservation ouverts. Le refus d’expiration de cette opération doit aussi fermer/libérer sa propre lease, y compris dans ces chemins tardifs, sans revenir à un verrouillage circulaire et sans rendre des octets expirés. Garder les tests d’expiration existants et les assertions de suppression/comptabilité ; un test déterministe additionnel est utile si un point de synchronisation réel le permet, sans sommeil ni test dépendant d’un nombre arbitraire d’appels internes.

Les lectures de tests compatibles, correction du compteur à1, jeton de réservation, DN parsé, sentinelle protégée et création ACL unique sont conservés. Ne pas refaire le composant entier ni ajouter un autre périmètre. Aucun raccordement/publication/DB/AD.

## Sources primaires relues

- [Implémentation .NET10 FileSystemAclExtensions](https://raw.githubusercontent.com/dotnet/runtime/v10.0.0/src/libraries/System.IO.FileSystem.AccessControl/src/System/IO/FileSystemAclExtensions.cs) : GetAccessControl(FileStream) sans section, et Create transmet les droits explicitement fournis à CreateFile.
- [Énumération FileSystemRights .NET10](https://raw.githubusercontent.com/dotnet/runtime/v10.0.0/src/libraries/System.IO.FileSystem.AccessControl/src/System/Security/AccessControl/FileSystemRights.cs) : Read, Write, Delete et Synchronize distincts, pas de ReadWrite.
- [Contraintes Windows des options de création](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdm/nf-wdm-zwcreatefile) : suppression à fermeture requiert DELETE, mode synchrone requiert SYNCHRONIZE.

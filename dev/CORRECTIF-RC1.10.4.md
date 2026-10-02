# Domenia 1.0 RC1.10.4

Correctif de syntaxe et durcissement du conditionnement.

- Corrige l expression PowerShell invalide de `Confirm-DomeniaRelationAssociation` (`-or (Test-DomeniaAccessBusyWrite)`).
- Le constructeur execute `tools/validate_powershell_static.py` avant toute archive.
- Le preflight parcourt tous les fichiers `.ps1` du DEV, controle etat lexical, delimiters, guillemets typographiques executables et appels de commande nus apres `-or` / `-and`.
- Aucune validation native Windows PowerShell 5.1 n est revendiquee sur cet hote Linux.

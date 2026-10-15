# F01 — construction des workers, 16 octobre 2026

## Correction appliquée

Le miroir Python et le constructeur PROD de LocalStore nʼincluaient que six des neuf modules du générateur réel. Ils omettaient le catalogue injecté et leur recherche des fonctions pouvait inclure des définitions imbriquées.

Les trois parcours prennent maintenant les neuf mêmes modules, leurs fonctions de premier niveau dans lʼordre du fichier et le catalogue versionné. Celui-ci est encodé depuis sa source UTF-8 normalisée en LF ; sa sérialisation ne dépend plus de la version de PowerShell. Sa validation reste active. La vérification dʼintégrité de lʼapplication reste inchangée.

Opération ré-épinglée : **LocalStore uniquement**. Nouvelle empreinte : `D97234AC239FC11351A6E93289FD89967D7E1EC72D78F5D2FD412C89AF4DE4BD`. Empreinte du registre régénérée après revue. Les deux suites Windows qui ne contrôlaient que les here-strings reconstruisent désormais les corps composés.

## Vérifications exécutées

- Construction native de 12 opérations composées sous PowerShell **7.4.20 sur macOS**, sans exécuter leur code, ouvrir la base ou contacter AD : identité octet pour octet avec le constructeur PROD et conformité aux empreintes épinglées.
- LocalStore : **887 212 octets UTF-8**, identiques aussi au miroir Python.
- Analyse statique : 328 fichiers PowerShell, PASS.
- Couche SQLite : audit PASS et 12 tests Python PASS ; la fixture inclut désormais le catalogue réel.
- Paquets DEV et PROD reconstruits ; référence preload mise à jour uniquement pour les deux fonctions portant les empreintes relues.

Le rapport JSON joint est une preuve de construction hors Windows, **pas une qualification Windows PowerShell 5.1**. Les contrôles permanents F01 et leurs tests sont en préparation avec le Spark. Les essais de la VM seront effectués après les modifications, conformément à la décision de David du 16 octobre.

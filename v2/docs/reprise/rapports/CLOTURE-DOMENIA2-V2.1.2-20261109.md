# Clôture de la parité — candidat Domenia 2.1.2

Demande de David du 9 novembre 2026 : « go tout terminer ». Ce rapport complète la clôture de
[TRV-111 et TRV-190](TRV-111-TRV-190-20261109.md), déjà intégrée à master et qualifiée sur les tests critiques.

## PAR-046 : raccordement L16/L02 retrouvé

Le reliquat décrit par le relais du 9 novembre ne correspond plus au code présent. Aucun nouveau transport
ni nouveau délai n'est ajouté : la clôture porte sur des raccordements existants et leurs tests.

- `src/Domenia.Core/Screens/Poste/PosteConfiguration.cs:109` lit `Remote.CommandTimeoutSeconds`, borné de 1 à
  300 secondes, défaut 10. Le rapport de configuration décrit son effet par appel et la limite des appels COM.
- `src/Domenia.Ad/Writes/AdPosteRemoteExecutors.cs:99` et `:350` transmettent la valeur effective dans
  `RemoteWriteRequest`. `:156` détecte également une modification entre préparation et exécution.
- `src/Domenia.Inventory/RemoteWriteNativeBackend.cs:17` convertit la valeur en délai ; elle est utilisée pour
  les lectures d'identité, les connexions, énumérations et méthodes DCOM, l'envoi Wake et la relecture du service.
- `RemoteWriteNativeBackend.WinRm.cs:17` et `:26` l'appliquent aux requêtes et au canal ;
  `RemoteWriteNativeBackend.Task.cs:51` et `:90` à l'attente et au script fermé transmis.
- `tests/Domenia.Tests/RemoteWriteTransportTests.cs:44` vérifie les bornes, le défaut et le changement de
  configuration ; `:83` vérifie qu'un appel natif lent conserve son propriétaire et son identité jusqu'au vrai
  retour. `NativePosteRemoteWriteTests.cs:84` vérifie la transmission de la valeur 23 au fournisseur après reçu.
  `RuntimeConfigurationTests` couvre les autres consommateurs, plafonds et budgets du lot L16.

Un délai d'attente ne prouve pas l'arrêt physique d'un appel COM. Aucun second envoi ni succès implicite ne
découle d'un délai dépassé. Ces garanties restent celles du code existant.

Deux relectures ciblées du Spark, vérifiées sur les fichiers fournis, n'ont identifié aucun défaut concret
bloquant dans ce raccordement. Elles ne remplacent pas une exécution sur un domaine réel.

## Capture des preuves VM

`tools/capture-release-evidence-vm.ps1` reconnaît déjà `wad/package-manifest.json`, le format 2 PROD-LIGHT,
le format 1 historique à plat, et le moteur optionnel du Socle avec index épinglé. La dette « à plat » du relais
est donc obsolète. Le fichier rejoint la vérification syntaxique PowerShell du workflow de livraison ; aucune
exécution sur VM ni modification de ce script n'est annoncée.

## Catalogue et version

PAR-046 passe à `fait` depuis `docs/status/parametres.json`, avec `apply_status.py --only PAR-046`.
Le catalogue et son tableau Markdown comptent **622 faites, 370 améliorées, aucune partielle, aucune à faire,
une abandonnée (PST-001 sur décision de David)** : 993 fonctions. Les anciennes déclarations de statut d'autres
lots ne sont pas rejouées. Leurs archives sont conservées.

La version candidate est 2.1.2, avec les correctifs TRV-111/TRV-190. Les gardes de livraison, leurs tests et les
contrats d'opérations sont alignés. Le schéma reste 11, révision native 2, compatible avec les bases 2.0.5 à 2.1.1.
La [recette manuelle 2.1.2](../../RECETTE-MANUELLE-V2.1.2.md) est préparée, sans résultat prérempli.

## Qualification et limites

- Contrats d'opérations régénérés, diff limité aux empreintes du changement de version, vérification réussie.
- 48 tests Python réussis sur le Mac ; ils ne qualifient pas Windows.
- Qualification complète Windows du candidat : en attente du run de livraison, à renseigner après lecture des preuves.
- Publication : non exécutée. La production reste 2.1.1 ; toute publication demande le go explicite de David.
- Recette sur domaine réel, compte hors Domain Admins, performances réelles et capture VM : non exécutées ici.
  Aucun accès au banc, téléchargement de dépendance ou changement de schéma n'a été effectué.

# Clôture de la parité — Domenia 2.1.2 qualifiée, non publiée

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
- [Qualification complète Windows 42701363001](https://github.com/M4D135/domenia-d120/actions/runs/42701363001),
  source `c2e5edb1fe1841821a02e27e2014a6774015c82e`, réussie sur `windows-2025` : Debug/Release,
  parseur PowerShell incluant la capture, 1 601/1 601 tests C# critiques et 3 043/3 043 complets. Les deux journaux
  contiennent les 15 tests TRV et les trois tests PAR cités, tous réussis.
- 218 contrôles navigateur et 7 simulations réussis ; parcours natif hors connexion réussi avec WebView2
  Evergreen 156.0.4314.58, fermeture code 0, aucune erreur d'observation ni de nettoyage.
- Relecture finale du diff et des notes par le Spark : aucun défaut concret bloquant relevé.
- Publication : non exécutée. La production reste 2.1.1 ; toute publication demande le go explicite de David.
- Recette sur domaine réel, compte hors Domain Admins, performances réelles et capture VM : non exécutées ici.
  Aucun ancien LOGIN de banc n'est appliqué à cette révision. Aucun accès au banc, téléchargement de dépendance
  ou changement de schéma n'a été effectué. La qualification CI ne vaut pas recette visuelle humaine.

## Archive et preuves conservées

ZIP `Domenia_2.1.2_PROD-LIGHT_Windows-x64.zip`, 84 267 433 octets, 788 fichiers.
SHA-256 : `b4fd5a59f571db88ae60a4fe612e44bf58230b28c1c1e0302cc79a88b5082a2f`.
Après téléchargement, empreinte comparée à `SHA256SUMS.txt` et `manual-package-verification.json` ;
`wad/package-release.json` porte le commit source ci-dessus et le schéma 11, révision 2. L'exécutable extrait en
mémoire a l'empreinte `25304074af5eb2e5165ebb2875b1b0a7e81c99d46f692c39055e27037572d3a0`, identique aux preuves CI.
Recherche du nom du domaine de labo (forme complète et courte, casse ignorée) en UTF-8 et UTF-16LE dans chaque
fichier du ZIP : aucune occurrence.

Artefacts GitHub du run (expiration annoncée au 23 novembre 2026 ; copies locales durables conservées) :

- `domenia-v2-delivery-c2e5edb1fe1841821a02e27e2014a6774015c82e-42701363001-1` : ZIP, empreintes et provenance source.
- `domenia-v2-delivery-proofs-c2e5edb1fe1841821a02e27e2014a6774015c82e-42701363001-1` :
  `domenia-v2-ci/logs/result.json`, `critical-csharp.log`, `full-csharp.log` ;
  `domenia-v2-delivery/logs/delivery-result.json`, `browser-evidence.json`, `light-native-login.json`,
  `manual-package-verification.json` et captures.

Empreintes SHA-256 des journaux C# originaux, conservés en UTF-16 :

- Critiques : `a2d45c249878c259b4e16b92d410317546003d7ca09697cb65e5fbea3194a65d`.
- Complets : `824274b1ec8f2b5433392eae4b841a53ab06a0b82820cf4884b1d08a4964f086`.

Ces preuves qualifient le ZIP du commit source cité. Les mises à jour documentaires de clôture ultérieures
ne remplacent ni ce commit, ni son archive, ni les limites des essais.

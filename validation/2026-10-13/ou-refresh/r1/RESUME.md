# Validation Windows préparée — RC1.17.4 R1

## État

**NON EXÉCUTÉE — PC du laboratoire éteint**, confirmé par David le 13 octobre 2026. David prend les tests Windows à sa charge et a autorisé la finalisation sans cette campagne. Aucun processus invité, test, capture ou contrôle PROD de cette révision n’a été lancé. Les trois délais SSH observés sont conservés dans `relay-connectivity.json`.

Les scripts ci-dessous sont préparés et contrôlés syntaxiquement ; leur exécution n’est pas une preuve acquise. Aucun rapport de réussite Windows n’est présent. Ne pas réutiliser les rapports de RC1.17.3 pour qualifier ce candidat.

## Candidat immuable

Répertoire Mac : `/Users/david/Documents/Projets/Domenia-builds/2026-10-13-ou-refresh-rc1174-r1`.

- DEV : `Domenia_1.0_RC1.17.4_DEV.zip` — SHA256 `9e8e0d85d7be7cc2bda1c43bbfd9c8a41c655395ef0010e5196378b504bc8c3d`.
- PROD : `Domenia_1.0_RC1.17.4_PROD.zip` — SHA256 `8ca88099a10c8c5f02cf2d7bb99be131a1ff9b70002cc1737dabd2dc1a7888be`.
- Harnais documentaire : `guides/captures/capture-guides.ps1` — SHA256 `fb8812dee1c6d420badd4bdb8c15bbf8abf7ec1188974de22954017a9165aec5`.

## Reprise éventuelle sur le laboratoire existant

Aucune reprise automatique n’est installée. Quand le relais et la VM de test seront disponibles, depuis la racine du dépôt Mac :

```sh
python3 validation/2026-10-13/ou-refresh/r1/lab-control.py status
python3 validation/2026-10-13/ou-refresh/r1/lab-control.py stage-capture
```

Le contrôleur utilise exclusivement le relais SSH existant et `CNAMTS-W11-01`. Il ne démarre ni VM, ni service, ne modifie pas le réseau et ne lit jamais le contenu du fichier de mot de passe. Les références d’authentification restent dans la configuration privée du relais.

La première phase exécute séquentiellement les nouvelles suites Freshness et OuRefresh, les captures WPF fictives, puis le contrôle direct `Domenia-Start.ps1 -CheckOnly` du PROD extrait. Elle préserve le ZIP et refuse de réutiliser une extraction existante.

Pendant chaque phase, utiliser **uniquement** la commande `status` pour surveiller les processus via le COM VirtualBox de l’hôte. Aucune nouvelle authentification invitée, aucun `copyfrom`, `run` ou autre accès GuestControl tant que le processus est actif. Les états de terminaison anormale doivent être conservés et diagnostiqués, jamais traités comme PASS.

Après terminaison de la première phase :

```sh
python3 validation/2026-10-13/ou-refresh/r1/lab-control.py pull
```

Les originaux seront sous `/tmp/domenia-ou-refresh-r1-originals`. Vérifier `proof/capture-complete.json`, les quatre reçus de processus et `captures/capture-checks.json`. Transmettre les trois rapports de captures aux responsables de la documentation avant tout rendu ; consulter `CAPTURES.md`.

Si cette première phase a réussi :

```sh
python3 validation/2026-10-13/ou-refresh/r1/lab-control.py run-suites
```

La campagne complète comporte **65 étapes**, soit 61 fichiers `Test-*.ps1` distincts et quatre contrôles auxiliaires : Quick étendu 27, Additional 12, AllOffline 23, WiringRecherche 1, Freshness 1 et OuRefresh 1. Les deux suites ciblées de la première phase ne sont pas comptées une seconde fois. Le contrôle PROD et les captures restent séparés du total.

Après terminaison, récupérer à nouveau avec `pull`, contrôler chaque code de sortie et chaque verdict JSON. Un échec, délai dépassé, rapport absent, inventaire incomplet ou changement de source interdit le PASS global. Conserver chaque tentative dans un dossier distinct ; le lanceur refuse d’écraser une campagne complète déjà commencée.

## Limites et preuves à produire

- Les tests utilisent des données fictives locales, sans lecture ou écriture AD, ping réseau ni WMI distant.
- Les vues WPF hors écran de session 0 ne remplacent pas le parcours humain de l’application, également non exécuté ici.
- Conserver les originaux hors Git. Les copies de preuves versionnées doivent être UTF-8/LF, avec manifeste des SHA avant/après normalisation de tous les textes, JSON inclus.
- Vérifier l’identité des archives, les 94 fichiers runtime DEV/PROD, l’inventaire exact des fichiers exécutés et la provenance de chaque PNG avant qualification.
- Aucune mesure de ce banc synthétique n’atteste un débit de collecte Active Directory.

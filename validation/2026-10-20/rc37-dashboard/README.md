# RC1.17.37 — calcul du dashboard

Deux corrections : `Get-DomeniaRawDnParent` s'arrête au premier séparateur LDAP non
échappé ; `Read-IdxWCanonicalObservations` ne relit plus les fiches AD complètes déjà
chargées dans la même transaction pour FleetStats/ParkTargets. Noms, DN et GUID
restent ceux des propriétaires de cette transaction. Les lectures normales
StoreRead et LocalStore gardent leurs lignes AD (option inactive par défaut).
Opérations ré-épinglées : LocalIndexRead et LocalStore ; empreinte du registre régénérée.

## Mesure Windows ciblée

Windows PowerShell 5.1 x64 STA, VM DOMENIA-FIRSTRUN-20261020 conservée, base SQLite
synthétique de 5 000 postes / 46 groupes, sans accès AD ni collecte réseau.
Worker FleetStats complet avec calcul du tableau : **40.40 s → 10.42 s (médianes, −74.2 %)**.
Deux passages par variante, dans l'ordre avant/après/après/avant. La référence
réactive uniquement la lecture AD redondante dans le même worker ; les deux variantes
utilisent le même modèle et la même base. Voir `tests/WorkerCompare.json`.
La base de mesure ne contient pas d'inventaires WMI ; ce résultat ne prédit pas le
temps d'un grand parc chargé de mesures. Les observations remplies et en erreur
sont vérifiées séparément par la régression SQLite.

Le changement du parent DN conserve le tableau complet (comparaison récursive JSON,
`ModelParity.json`). Ses mesures à froid/à chaud sont gardées dans `ModelTimings.json` :
aucun gain indépendant n'est annoncé pour ce changement.

## Vérifications et portée

- Règles communes : 11 cas, dont séparateurs/échappements exhaustifs sur les mots
  de longueur 1 à 6 de l'alphabet x/virgule/antislash (1 092 entrées), plus cas explicites.
- Santé : 20 cas ; santé avancée : 17 ; politiques et explications : 10.
- Projections d'observations : 5 cas.
- WiringCache ciblé : périmètre/GUID/ancienneté, poste hors OU, nouvelle parité des
  observations Fleet/Park avec/sans relecture AD ; référence avec poste non mesuré
  et mesure en échec. Benchmark 5 000 postes séparé.
- Pack final : règles communes rejouées, parseur natif sur les cinq fichiers PowerShell
  modifiés, compatibilité 5.1, `Domenia-Start.ps1 -CheckOnly`.
- Construction : garde statique 251/251, contrats et manifestes vérifiés,
  172 fichiers applicatifs DEV/PROD identiques.

Les suites de santé et Wiring utilisent les sources candidates avant estampillage ;
le module Engine est identique au pack final. Le dernier garde null du parent DN
et les deux assertions associées sont vérifiés sur le pack final.
`SourceBindings.json` relie les preuves aux fichiers et archives.
Les harnesses gardent leurs chemins de labo ; adapter les racines pour reproduire.

Pas de nouvelle recette graphique, de mesure du démarrage, d'endurance ni de collecte
AD/WMI réelle dans cette passe. Les preuves fonctionnelles RC36 restent datées de
[leur version](../rc35-qualification/README.md). Les limites matérielles acceptées
et les états de publication/certificat restent inchangés.

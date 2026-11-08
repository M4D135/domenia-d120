# Correctifs LDAP et prérequis de l’actualisation — 26/10/2026

Base relue : `31ba4eaadffc44b1de88380b523bce99655c3411`, branche de travail
`codex/v2-correctifs-recette-20261026`. Ce rapport décrit le développement ; le rapport
de livraison doit rattacher les résultats Windows au SHA effectivement exécuté.

## Cause établie dans le code

`AdConnection.MaterializeEntryAsync` ajoutait chaque attribut simple dans un dictionnaire,
puis ajoutait sous le même nom le résultat des plages. Une réponse comprenant `member`
**vide** et `member;range=0-1499` provoquait donc le refus générique `Incomplete`, quelle
que soit leur position dans la réponse. Cette forme est explicitement valide dans
[MS-ADTS § 3.1.1.3.1.3.3](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-adts/e27b48db-6f82-44cd-9038-2e54f790cc1f).
Le défaut est établi par la lecture du chemin exécuté. Il reste à confirmer qu’il est
celui rencontré dans l’OU réelle : aucune réponse de `cnamts.local` n’a été capturée ici.

Le compagnon simple vide est désormais ignoré **uniquement en présence d’une tranche
valide correspondante**. Un compagnon non vide, plusieurs tranches ambiguës, un trou,
un chevauchement, un nombre de valeurs incohérent ou un doublon de valeur restent
refusés. Les limites restent inchangées : atteindre la limite sans marqueur terminal
refuse la publication. Les suites emploient le même objet `LdapConnection`, avec GUID,
DN et USN identiques ; une information de cohérence absente ou un changement refuse
la lecture. Aucun réessai automatique n’a été ajouté. Les lecteurs explicites Fiche et
comparaison d’appartenances ainsi que la projection Fiche acceptent aussi le compagnon
vide, sans transformer une première tranche non terminale en liste complète.

## Diagnostic

Chaque recherche indépendante ou snapshot possède une référence aléatoire. Les recherches
du snapshot partagent cette référence et qualifient l’étape : OU, utilisateurs, postes,
groupes ou contacts. Un refus précise catégorie, nom d’attribut validé, bornes demandées
et reçues, terminal `*`, comptes de valeurs, limite, présence des preuves GUID/USN et
nombre de requêtes `search`/`range` réellement envoyées. Les phases de connexion sont
mesurées séparément. Le diagnostic n’inclut aucune valeur AD, DN, compte ou serveur.
Il reste dans l’exception consommée par la campagne et le journal technique local,
avec au plus 16 traces de refus par opération. Les traces réelles du domaine ne doivent
pas être publiées sans examen et expurgation.

## Campagne Accueil

L’ancien repli de « Tout actualiser » poursuivait ping/WMI après échec AD ou lecture
partielle. La demande du 26/10 exige l’arrêt après échec d’un prérequis : la campagne
s’arrête désormais sur erreur et conserve les étapes déjà acquises. Le transport qui
lève une exception n’atteint pas `SaveAsync`/`SaveWithReceiptAsync` : la base antérieure
est préservée, sans faux reçu. La reprise reste une nouvelle confirmation et requalifie
périmètre, identités et acquis.

`RefreshStatusAsync` remplaçait aussi le rapport précis de la session par un rapport
`cancelled` fabriqué depuis le checkpoint. Il conserve désormais le rapport connu pour
le même identifiant. Après réouverture, le checkpoint ne conservant historiquement pas
la cause, l’état est `interrupted` avec cause précédente non enregistrée ; aucun arrêt
volontaire n’est déduit de la seule existence du checkpoint.

## Vérifications exécutées et limites

- `AdRangeMaterializationTests` : neuf tests de transport/projection, incluant une vraie
  collection `SearchResultEntry` construite localement, compagnon vide dans les deux
  ordres, plages successives/terminales, limite exacte, doublons, changements et absences
  d’identité/USN, annulation, absence de lecture implicite et diagnostic borné sans DN.
- `AdAccueilTests` : échec après sauvegarde, conservation du cache et absence de suite
  aux recherches d’objets ou de stockage après le refus.
- `AccueilDurablePipelineTests` : erreur/partiel préalable, sauvegarde acquise, absence de
  ping/WMI, consultation sans perte du statut erreur, reprise préparée sans envoi et état
  honnête après réouverture.
- Sélections adjacentes nécessaires : `AdTransportTests`, `AdFicheObjectTests`,
  `AdFicheReaderTests`, `AdRelationComparisonTests`.

Mise à jour finale : le commit `fbe5caab6808619e727fdb8be597c8fde8270614` réussit
[le passage Windows 40303383351](https://github.com/M4D135/domenia-d120/actions/runs/40303383351) :
Debug/Release sans erreur ni avertissement, **679/679 C# critiques**, dont les neuf tests
de matérialisation par plages et les sélections ci-dessus. Le journal
`domenia-v2-ci/logs/critical-csharp.log` du ZIP de preuves conserve les résultats individuels.
Les 1 718 autres tests C# enregistrés n’ont pas été exécutés. Les 79 tests Web critiques
et six scénarios UI en simulation sont aussi passés ; voir le
[rapport de livraison](RAPPORT-CORRECTIFS-WINDOWS-20261026.md) pour leurs preuves et limites.

Aucun SDK, runtime ou paquet n’a été installé/téléchargé. Aucun appel au domaine ni écriture
AD n’a été effectué. La reproduction du refus dans l’OU réelle, les droits et la lecture
de `cnamts.local` restent **non exécutés**, sans assimilation des réponses de test au domaine.

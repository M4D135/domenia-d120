# Sondes personnelles : Atelier, recettes Query/4 et consommateurs

## Statut et écart prouvé

Reprise GitHub sur `codex/v2-finalisation-20261025`, depuis la base vérifiée `9b1c0333c34020ad88c1448874b91eff884d5406`.
Le lot 123 Spark/Mac n’a pas été récupéré. Développement du présent lot : **code et tests écrits, aucun test exécuté**.
Sa compilation Windows doit être établie sur le SHA du commit/push de ce lot ; les builds précédents ne le prouvent pas.
Les deux VM, les essais natifs réels et la recette UI ne sont pas disponibles ici et restent **NON VÉRIFIÉS**.

D1 fournit le même catalogue à `Domenia-Query.Model.ps1` et `Domenia-Query.UI.ps1`. En D2, les listes de l’Atelier,
`QueryEngine`, `QueryRecordBuilder`, les lecteurs de campagne et les vues du pont ne connaissaient que
`QueryProbeCatalog.All`. Un import personnel Accueil ne pouvait pas y devenir une condition ni une collection typée.
Le SELECT mémorisé de l’Atelier conserve seulement `exists/count` ; il ne remplace pas les valeurs d’une sonde `First/All`.

## Parcours raccordé

1. Le même `ProfileProbeCatalog` alimente le catalogue d’informations et de collections existant de l’Atelier. Le
   compositeur visuel garde ses sélecteurs, valeurs, groupes et paramètres ; aucune UI parallèle ni état global mutable.
2. Les admissions du pont hydratent les références `custom.<64hex>` depuis le profil. `Domenia.Query/4` conserve des
   déclarations `{ Key, Document }` exactes, strictement relues et vérifiées par empreinte. Le compilateur reçoit un
   `QueryProbeContext` immuable propre à la recette. Les formats ordinaires /1 à /3 gardent leur forme canonique.
3. Les propriétés déclarées gardent leurs types texte/nombre/booléen ; les collections gardent toutes les instances
   reçues et leur complétude. Absence, erreur, exclusion DC, troncature et données non représentables restent inconnues
   ou incomplètes. Résumé, explication, répartition, colonnes, valeurs brutes, scripts et exports utilisent ce contexte.
4. Aperçu, plan, couverture, bibliothèque, brouillon, copie/révision/restauration et widgets utilisent les déclarations
   exactes. Un pack n’importe aucune sonde et ne lance aucune collecte. Sa recette reste consultable quand le profil
   manque, avec motif visible ; son usage et sa reprise sont refusés jusqu’à import explicite de la définition exacte.
5. Les plans figent domaine/session, OU et sous-arbre, identité de chaque objet AD, générations de sélection de comptes
   LDAP/Machine et définitions. Un masque de mesures par cible transporte ses seules familles et sondes manquantes
   dans une unique demande : A manquant X et B manquant Y produisent deux lectures, jamais X+Y sur chacun.
6. Le lecteur AD qualifie la cible, conserve un accès commun par poste pour ping/inventaire/console/sondes/SELECT,
   vérifie les réglages avant contact et attend la fin physique du fournisseur. Un ping seul ne consomme aucune
   sélection Machine. La sonde personnelle est requalifiée dans le profil après LDAP, avant CIM et avant cache ; sa
   projection ne reçoit aucune propriété clé CIM supplémentaire. Les rôles DC AD et CIM refusent la projection.
7. Une consommation OneShot autorisée termine les sources prévues du premier poste sous les mêmes accès retenus.
   Les cibles suivantes restent non contactées, comptées par `NotRead` avec `StopReason` et « Relevé partiel ». Un vrai
   changement de compte ou une admission interrompue après consommation arrête toute la demande, y compris quand
   l’appelant n’avait pas fourni de générations facultatives. Aucun compte de repli n’est réacquis pour le poste suivant.
8. Chaque mesure SQLite conserve sa déclaration et sa clé immuable. Un cache peut décrire une provenance ; il ne
   fournit jamais une autorisation d’exécution. L’Accueil durable, les widgets de requêtes Accueil/Poste, Santé et
   Recherche exigent la présence de cette version dans le profil. La CLI exporte Query/4 localement, sans profil importé
   ni mutation de la base. Ce raccord CLI et son test sont coordonnés avec l’intégrateur.
9. Le placement d’une carte de requête Poste précharge le catalogue avant l’écriture atomique des préférences ; le
   callback sous `writeGate` utilise une confirmation pure. Il n’attend pas une lecture du même verrou.

## Bornes préservées

- Catalogue personnel : 64 versions, 256 Kio UTF-8 ; une nouvelle définition n’efface pas les anciennes.
- Recette : 64 Kio en totalité, au plus 64 déclarations ; clés de 71 caractères conservées sans troncature.
- Classes/espace de noms : périmètre existant uniquement, garde commune des 88 classes MSI et propriétés de secret.
- Atelier : au plus 1 000 postes, catalogue embarqué + capacité personnelle pour les identifiants, 32 SELECT,
  500 instances par sonde `All` et une instance `First`, SELECT de 4 000 caractères, budget global de collecte de quatre
  minutes. Les plafonds et délais des sous-lectures natives ne sont pas augmentés.
- Import de recette et configuration ne donnent aucune autorité de lecture ; aucune dépendance, service, runtime,
  réseau, écriture AD, reboot ou logoff n’est modifié par ce lot. `dev/` reste lu comme référence seulement.

## Vérifications écrites, non exécutées

`QueryPersonalProbeTests` : dix scénarios de types et valeurs inconnues, canonicalisation /4 et refus de déclaration
altérée, révisions/packs sans import implicite, SQLite relu à froid, plan/reprise/DC, vraie composition Bridge
catalogue → brouillon → widget → collecte → aperçu/export → copie, refus après changement de profil/compte/OU,
masques de sources par cible et placement avec un vrai `FilePreferenceStore` sous une échéance bornée.

`QueryPersonalProbeNativeTests` : neuf scénarios de projection exacte, refus avant transport, rôle membre et types CIM,
lecture AD/stockage des vraies instances, retrait du profil pendant LDAP ou CIM, bail OneShot composé, ping sans
consommation Machine, fin partielle multi-cibles et refus après consommation suivie d’un échec de qualification.
Les sessions CIM et connexions LDAP y sont injectées : même une exécution verte ne remplacerait pas les deux VM réelles.

`PlatformTests` reflète les huit opérations devenues `LocalRead` parce qu’elles consultent le catalogue du profil.
`AutomationLocalStoreTests` contient le cas coordonné d’export Query/4 exact sans modification des fichiers.
Seule une vérification textuelle de diff/espaces a été effectuée ici ; aucune compilation locale ni suite de tests.

Les revues croisées root/Accueil ont corrigé l’union de sondes par cible, les clés CIM supplémentaires, la réadmission
OneShot entre sources, les contrôles de profil avant publication et la lecture imbriquée sous le verrou de préférences.
Aucune promotion globale des 993 entrées n’est justifiée par ce rapport. Aucun paquet PROD/DEV v2.0.0 n’est publié.

## Première compilation après push

Lot intégré dans `c84b633c5396c0a2b177fe3907c63ccd7b1eaf80`. Le [run Windows 40219898054](https://github.com/M4D135/domenia-d120/actions/runs/40219898054), job `121248990437`, a signalé CS0136 dans `QueryPersonalProbeTests.cs` : deux variables locales portaient le nom `expected` dans des portées imbriquées. Le flux aléatoire du test est renommé `expectedStream` avant le passage critique. Cet échec est conservé ; aucune suite n'a été exécutée et aucun succès de test n'en est déduit.

Correction incluse dans `180b97c4b70a2bf0105e551500cd0a5d61d87c79` : [run Windows 40220125380](https://github.com/M4D135/domenia-d120/actions/runs/40220125380), job `121249678456`, journaux lus. Debug et Release réussis avec **0 avertissement et 0 erreur**, à 18:13:42 puis 18:14:20 UTC le 25/10/2026. Aucun test exécuté dans cette compilation ; les résultats de la sélection critique sont suivis séparément.

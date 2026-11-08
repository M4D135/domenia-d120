# Sondes personnelles : consommateur Poste

Date : 25 octobre 2026. Base de reprise locale : `c6dd5e0d754ba2a3d349ce0f77e2ae33b29ce48a`, branche `codex/v2-finalisation-20261025`.

## Écart prouvé

Dans D1, `dev/wad/modules/Domenia-Widgets.UI.ps1:66,73,1605` fournit `Get-DomeniaProbeCatalog` au tableau Computer ; seul Software en est exclu. Lecture comparative uniquement : aucun fichier `dev/` modifié.

Dans D2 avant ce lot, `PosteBoardLayouts.Catalog/Normalize` et `PosteLayoutOperations` ne résolvaient que le catalogue embarqué. Le lecteur détaillé `AdPosteReader.Probes` et `WmiWorkstationReader.Probes` acceptait uniquement ses 33 définitions. L’import personnel Accueil ne rendait donc pas sa sonde utilisable sur Poste.

## Développement réalisé

- `ProfileProbeCatalog` centralise la lecture du catalogue de profil, la résolution et la confirmation des `FrozenProbe`. Accueil délègue à ce helper ; Poste et Atelier utilisent la même source sans catalogue global mutable.
- La personnalisation Poste expose les définitions personnelles, préserve la clé `custom.` + SHA-256 complète (71 caractères) et garde un identifiant de carte indépendant de 64 caractères au plus. Une carte dont la définition manque reste visible ; sauvegarde, restauration, import direct D1 et collecte refusent une version absente.
- `poste.layout.probe` confirme la définition du profil avant de lire ses valeurs locales. Les cartes scalaires utilisent le cache `Fleet.Probes`, indexé par clé exacte et GUID, et les mêmes transformations que le parc. La provenance indique la date, la classe, le mode, la transformation et la version. Les 33 sondes détaillées conservent leur schéma.
- `poste.personalProbe.plan` prépare localement une carte active et sa cible : identité complète, domaine, époque, base locale, sélection de compte, transport et définition immuable. La préparation expire après cinq minutes, se consomme une seule fois et exige `confirmed=true` pour le relevé. Au plus 16 préparations restent en mémoire.
- `poste.personalProbe.run` appelle le nouveau lecteur Poste, puis relit le cache avant de rendre le reçu. Une modification de carte, d’identité, de compte, de session, de base, de configuration ou la disparition de la définition refuse la poursuite. Un ajout indépendant au catalogue ne réaffecte pas les versions existantes.
- `AdPosteReader.PersonalProbes` exige un contexte de profil. Il qualifie la cible AD, réutilise `WmiFleetProbeReader.ReadFrozenAsync`, respecte UseCim et le transport choisi, les exclusions DC AD + CIM, 2 000 instances, 12 s par projection et le budget CIM de 60 s. Aucun ICMP n’est imposé sur Poste. La qualification finale compare aussi UAC via `AdQueryAccess`.
- L’arrêt attend la fin physique du fournisseur. Seul le résultat déjà reçu est conservé localement avec état incomplet si la qualification finale n’a pas pu finir ; aucune nouvelle lecture LDAP/CIM après arrêt. Les baux d’accès et l’admission Poste restent détenus jusqu’à cette fin. La consommation normale d’un compte à usage unique est distinguée d’un changement de sélection, en coordination avec le correctif partagé OneShot108.
- L’UI réelle `probe-cards.js` et `personal-probe-reads.js` propose le contrat complet, droits, coût et sens de l’inconnu, puis une confirmation sur le poste et la version exacts. Fermer le contrat, retirer/mettre en pause la carte ou quitter l’écran avant confirmation n’envoie pas de relevé. Après réception, la carte relit uniquement son cache. Import, catalogue, ajout de carte et ouverture du cache ne lancent aucune collecte.
- Le consommateur de carte de requête Poste transmet également le catalogue du profil à `PosteQueryCards.Build`, pour le raccordement Query/4 réalisé dans le lot Atelier coordonné.

## Vérification et limites

`git diff --check` ne signale pas d’erreur de mise en forme. Aucune compilation ni suite de tests exécutée par cet agent pour ce lot.

Tests critiques **écrits, non exécutés** :

- `PostePersonalProbeTests` : cinq scénarios de catalogue/bridge réel, versions distinctes sans réemploi, absence de définition, refus des plans modifiés, contrôleurs, restauration et import conditionnel via `FilePreferenceStore`.
- `PostePersonalProbeNativeTests` : six scénarios du lecteur AD avec CIM injecté : qualification et stockage exact, refus avant contact, profil absent, changement de cible/rôle, arrêt physique et compte à usage unique pendant une interrogation passive UI.
- `poste-personal-probes.test.mjs` : cinq parcours des contrôleurs UI réels : ajout sans collecte, contrat/confirmation/reçu, retour tardif, arrêt et absence de définition.

La compilation Windows du commit de base ne valide pas ces changements. Les tests critiques après commit/push, la recette UI/native dans les deux VM et la réouverture réelle du profil doivent encore être exécutés et documentés. Aucune validation verte ni publication PROD/DEV v2.0.0 n’est revendiquée par ce rapport.

# TRV313 — versions restaurables des vrais tableaux

Lot Codex du 25 octobre 2026, après gel du lot placement de 22 fichiers. Aucun build ni test exécuté par cet agent. Compilation et recette réservées à la VM Windows, orchestrées par le parent ; aucune promotion du catalogue global.

## Contrats et sources

D1 conserve dix annulations de disposition dans `dev/wad/modules/Domenia-Widgets.UI.ps1`, fonctions `Sync-DomeniaBoardUndo`/`Set-DomeniaBoardLayout`, lignes 76–110. Un changement sans effet n’est ni enregistré ni empilé ; les nouveaux relevés n’effacent pas cette pile. Les cinq versions persistantes sont une amélioration D2 promise dans `v2/docs/FEATURES.md:10194`, déjà présente pour l’écran Interface (`web/js/shell/board.js:241`), pas une fonction D1 retrouvée dans les sources. Ce lot raccorde cette promesse aux trois vrais consommateurs Parc, Poste et Logiciels.

## Persistance effective

Les préférences `accueil.layout`, `poste.computerLayout` et `poste.softwareLayout` utilisent maintenant une enveloppe version 2 : disposition actuelle, date de sa sauvegarde et cinq versions précédentes au plus. Chaque version possède un identifiant, l’empreinte SHA-256 de ses cartes, ses cartes complètes et, lorsqu’elle était connue, la date de sauvegarde. Une ancienne version 1 sans date reste explicitement non datée. Le lecteur accepte la version 1 ; l’évolution du schéma se fait lors d’un changement effectif.

Choix et historique sont remplacés ensemble par `IAtomicPreferenceStore`, dans la même préférence et sous le même verrou. Le document est relu avant mutation, le jeton du choix affiché est comparé, puis les deux états sont écrits atomiquement. Une restauration archive à son tour le choix remplacé. Une sauvegarde sans effet n’écrit ni n’empile rien. `[]` reste distinct d’une absence et peut être sauvegardé, restauré puis relu après redémarrage.

Bornes : 64 cartes par état, cinq états précédents, 512 Kio de JSON compact pour disposition + historique, et plafond existant de 1 Mio pour le document de préférences entier. Champs inconnus, version future, doublons de champs, SHA historique altéré, historique trop long ou cartes non représentables sont refusés sans remplacer le document. Les valeurs futures ne sont pas nettoyées silencieusement pour permettre une écriture ; une disposition entière incompatible reste conservée. Les clés de provenance D1 restent intactes, ainsi que les sources historiques originales.

Les opérations réelles `poste.layout.restore` et `accueil.layout.restore` prennent l’identifiant de version et le jeton du choix examiné. Les boutons Versions précédentes ouvrent un aperçu contenant les cartes, leur pause, leur liaison et le SHA. Fermer l’aperçu n’écrit rien. La restauration ne recrée aucune recette retirée, ne modifie aucune révision de bibliothèque et ne déclenche aucune collecte. Les liaisons D1 restent épinglées ; les liens natifs suivent uniquement la liaison explicite de l’Atelier, selon le lot précédent.

## Interfaces et correction de liaison

Les trois vrais tableaux disposent de dix annulations/rétablissements en session, par boutons et Ctrl+Z/Ctrl+Y. Les changements sans effet n’effacent pas la pile de rétablissement. Une lecture de nouvelles données n’efface pas la pile ; en revanche, une étape dont le jeton appartient à une autre disposition est refusée. La pile locale n’est pas confondue avec les cinq versions persistantes.

Accueil n’installe plus une liste optimiste avant réussite de la sauvegarde. En cas d’échec ou de concurrence, il relit et affiche le choix actuel ; la pile d’annulation n’est modifiée qu’après succès. Les lectures de données sont séquencées après celle de la disposition, afin que le calcul utilise ses cartes actives. L’éditeur Poste/Logiciels conserve ses changements dans le dialogue jusqu’au geste Enregistrer.

Défaut de production confirmé et corrigé dans ce lot : `accueil/board.js` omettait `QueryBinding` dans `wire`, puis `AccueilOperations.LayoutItem` l’ignorait. Une pause ou un déplacement via l’interface pouvait donc perdre la révision D1, malgré la conservation dans le test C# direct. Le vrai chemin UI → Bridge → préférence → historique transmet maintenant cette liaison qualifiée. Le nouveau test utilise ce chemin et vérifie que la révision 1 reste calculée après apparition d’une révision 2 et restauration de la disposition.

## Vérifications préparées, non exécutées

Six tests C# sur les vrais handlers : cinq versions et restauration de `[]` pour les trois tableaux avec réouverture fichier ; jeton obsolète contre une autre instance ; liaison Query D1 et pause dans le vrai Accueil ; champs/version futurs, SHA altéré et dépassement d’historique conservés ; cartes inconnues et 65 cartes refusées sans perte ; échec de remplacement disque sans état optimiste. La fixture du lot placement simule désormais une réparation explicite d’un document de version future avant le réessai, car ce lot protège aussi l’historique futur contre le remplacement.

Trois tests navigateur emploient les vrais composants : aperçu sans écriture puis restauration Poste, annuler/rétablir et refus après changement extérieur ; Accueil transmet la liaison et attend l’écriture avant affichage, puis recharge le choix concurrent et restaure une version avec son jeton ; borne de dix annulations et sauvegarde sans effet. Les opérations et le module PosteLayoutOperations ont été ajoutés à la table de déclaration stricte, ainsi que les trois opérations Recherche du lot RCH précédent qui y manquaient.

`run.mjs` importe aussi les quatre suites adaptées au navigateur par le parent : Paramètres, format Assistance, Recherche et règles Comptes. Lecture statique de `test-api.mjs` et des imports : les assertions navigateur rejoignent le même harnais, les fixtures viennent du host local, les imports Node restent conditionnels. Aucun test supprimé ou lancé ici.

## Limites encore distinctes

Cette livraison n’annonce pas la parité globale TRV313 acquise : recette Windows non faite, adaptations de présentations D1 selon données disponibles encore à examiner, et critères historiques de remplacement automatique d’une ancienne disposition livrée inchangée restent à comparer au portage explicite. Les préréglages et import/export de documents de disposition des tableaux Poste/Logiciels relèvent aussi des autres parcours du catalogue, pas de la seule présence d’un historique. L’écran Interface conserve son format et son historique propres ; aucune migration arbitraire depuis cette clé vers les tableaux métier n’a été ajoutée.

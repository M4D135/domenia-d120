# RC1.17.21 — corrections des règles, géométrie et installation

Périmètre demandé : reprise des échecs KI-007 de RC20, sans campagne AD/WMI ni charge longue. Windows PowerShell 5.1 x64 STA sur CNAMTS-W11-01. Les décisions externes 134/146 et le certificat 141 restent ouverts.

## Corrections applicatives

- Les listes de composants DN, chemins, fils d’Ariane et vérifications d’absence sont maintenant émises à plat. Le périmètre, les déplacements et la limite de 200 objets retrouvent le comportement attendu.
- Un compte de la forme `CORP\a\b` est refusé par la bonne surcharge .NET 5.1 de `Split`.
- Le dictionnaire des cycles de batterie ne masque plus le paramètre `$Cycles` ; une valeur nulle reste inconnue.
- L’export `dossier` choisit son format par défaut ; la stratégie fine ne se mélange plus à une stratégie de domaine présentée en référence ; l’import vide rend zéro décision.
- Le format BoardLayout est enregistré ; les URL de documentation absentes restent une liste vide ; les limites déclarées des sondes correspondent au budget déjà appliqué par le lot.
- Le détecteur de classes MSI distingue une comparaison de garde d’une lecture WMI. Les noms de la liste d’interdiction restent identiques, représentés par leurs composants comme la liste MSI canonique ; aucun accès interdit n’est autorisé.
- Les actions/filtres secondaires de recherche défilent dans une hauteur bornée. L’Atelier récupère l’espace des marges imbriquées sur écran court. Les paramètres de l’opérateur restent conservés.

## Harnais corrigés

Chaque fichier de règles a sa portée de fonctions, avec ses dépendances explicites. Les références anciennes sont alignées sur les décisions déjà présentes : Santé en dernier, groupes d’OU complets, effets F01/D018, XAML séparé, schéma SQLite centralisé, résultats de parcours déclarant leur couverture. Le mot « expiration » ne déclenche plus un faux verdict « piratage ». Le DEV contient la fixture des parcours GUI sans les outils hôte du laboratoire.

Geometry ouvre les panneaux repliables et fait défiler les commandes avant de tester leur accessibilité ; dimensions minimales, bornes du viewport et stabilité restent contrôlées. Installer écrit sa progression et ne tente plus d’énumérer un dossier qui vient d’être supprimé. Le filtre de cas permet de rejouer seulement les scénarios utiles.

## Résultats

- **Règles :** 1 073/1 075 réussies dans la passe complète RC21, puis 149 cas ciblés réussis (Engine 72, Workstation 57, ProbeContract 8, Query 12). Les deux échecs restants de la passe complète sont couverts et résolus ; aucun échec restant. La synthèse rapproche les rapports, elle ne prétend pas être une nouvelle passe complète.
- **Géométrie : 79/79.**
- **Capture ciblée : 18/18.** À 1280×720, trois lignes entières au lieu d’une ; grille de 112 px, minimum demandé de deux lignes atteint. Image inspectée, commandes accessibles.
- **Installation :** la suite complète RC20 a terminé ses 26 cas, avec 24 succès et deux erreurs de diagnostic du harnais après suppression correcte. Les quatre cas RC21 rejoués passent : installation/mise à jour/retour, interruption/restauration, suppression explicite, variantes minuscules et conservation sans réponse. Les 26 cas distincts sont couverts, sans prétendre avoir rejoué toute la suite sur RC21. Le compte standard et la suppression du profil restent la preuve RC20 distincte (12 contrôles).
- **Démarrage :** contrôle natif `CheckOnly` réussi sur les 172 fichiers applicatifs vérifiés. Les parcours de connexion réelle, réouverture et sauvegarde automatique restent les preuves RC20 distinctes.

Rapports dans `raw/`, rapprochement dans `summary.json`. Les premières tentatives sont conservées dans `raw/initial` ; aucune n’est transformée en succès.

La première tentative simultanée RC21 a rencontré un gel VirtualBox avec 462 Mo de RAM libres dans une VM de 3 Go et une erreur Guest Control VERR_DUPLICATE. Une pause/reprise de la VM a rétabli l’accès ; les suites suivantes ont été séparées. Le dépassement d’installation de cette tentative ne qualifie pas le comportement applicatif.

## Portée

Les tailles et échelles WPF sont simulées sur une surface native hors écran. Elles ne valent pas une qualification DPI réel multimoniteur, RDP, clavier/Narrateur, endurance ou parc représentatif. Les parcours réels AD/WMI et sauvegarde déjà qualifiés restent leurs preuves historiques distinctes.

Les guides Word/PDF et leurs figures restent ceux de RC20 ; ce rapport décrit le delta RC21. Aucune nouvelle qualification générale ni autorisation de redistribution n’est déduite de ces tests. Publishable reste faux.

## Livraison et laboratoire

Les 172 fichiers applicatifs de la dernière passe sont reliés aux archives finales par leurs SHA-256 (voir `archive-binding.json`). Le contrôle final des archives extraites et le nettoyage du laboratoire sont consignés dans `raw/PackCheck.json`. Les changements postérieurs aux premières captures/règles concernent les classifications de référence, les métadonnées d’interdiction et les empreintes générées ; les fichiers XAML et UX de Geometry et des captures restent inchangés.

KI-007 est résolu pour le périmètre demandé. Après récupération des preuves et vérification du push, David peut effacer les VM pour ce périmètre. Aucune VM n’est supprimée par cette intervention.

Les rapports et journaux texte sont archivés avec des fins de ligne LF ; leurs valeurs et les détails des erreurs sont conservés.

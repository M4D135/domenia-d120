# Dispositions explicites : fichiers, préréglages et défaut d’équipe

Lot TRV-310–312, écrit le 25 octobre 2026. Aucun build ni test exécuté par cet agent ; compilation et tests critiques réservés à la VM Windows orchestrée par root. Ce rapport ne promeut aucun statut de catalogue.

## Contrat historique relu

`dev/wad/modules/Domenia-Boards.Model.ps1` : lignes 931–940, défaut d’équipe `Dashboard.DefaultLayout<Board>` puis catalogue lorsque la sélection d’équipe est absente ou vide ; 942–958, Assistance/Inventaire/Santé ajoutent les priorités absentes et réordonnent les groupes sans retirer les autres cartes ; 1099–1146, documents `Domenia.BoardLayout.1`, tableau et liste de widgets ; 1165, noms d’export datés. Les fichiers D1 restent en lecture seule.

## Comportement livré

Accueil, Poste et Logiciels proposent les fichiers de disposition, l’export exact du choix courant et le défaut d’équipe. Les préréglages des deux tableaux Poste sont des changements réels de disposition, selon leurs capacités : Logiciels n’affiche pas Santé puisque D1 n’y définit aucune priorité. Identifiants, groupes, pauses, titres et liaisons existants sont conservés. Les priorités absentes sont ajoutées ; dépasser 64 cartes refuse le geste entier.

Le fichier D2 `Domenia.BoardLayout.2` reprend la disposition sans données de parc, résultats ni autorisation réseau. L’import accepte aussi les documents et listes D1, sans reconnaissance implicite du catalogue livré historique : les lignes du fichier choisi font autorité. La liste vide explicite est un choix valable, importé et exporté. Un champ futur, une carte sans représentation, une présentation D2 altérée ou une ambiguïté JSON refuse le document entier. Borne : 64 Kio UTF-8.

L’aperçu précède toute application. Il montre l’origine, le SHA-256 du texte UTF-8, les pauses, les groupes et les révisions liées. Une nouvelle proposition de liaison requiert un consentement distinct. Les requêtes utilisent la bibliothèque locale réelle, le domaine et la session courants ; aucune recette ni permission d’exécution n’est créée. Domaine/compte/génération de session et révisions sont requalifiés après la prise du verrou des préférences.

Le défaut d’équipe provient du fichier local existant `Domenia.config.json`, qualifié sans lien de redirection et lu sous borne. En simulation, seul le défaut fictif livré est exposé avant toute lecture de configuration. Le SHA complet de la source est revalidé sous le verrou de destination ; un fichier existant est tenu jusqu’à la fin du commit. Une section illisible/ambiguë ou une carte non prise en charge refuse le remplacement.

Toutes les écritures passent par les véritables services de disposition, avec jeton du choix aperçu et historique des cinq versions dans le même document. Les choix concurrents, dont `[]`, restent intacts. Les écrans n’installent le nouveau choix qu’après succès. L’original importé n’est jamais réécrit. Le journal garde le SHA du texte importé ; l’historique conserve le choix remplacé. Aucun archivage durable des octets du fichier importé n’est annoncé. Les SHA texte ne sont pas présentés comme les SHA des octets d’un fichier avec BOM.

## Vérifications préparées

`BoardLayoutTransferTests.cs` : six tests comportementaux (trois catalogues, formats refusés, vrais handlers et concurrence, préréglages et dépassement, source d’équipe tenue/revalidée, révision de bibliothèque modifiée entre aperçu et commit). `board-transfer.test.mjs` : trois tests DOM des consommateurs réels, annulation/consentement, jeton conservé et callback tardif. Importés au harnais web existant ; aucune exécution effectuée.

Reste à vérifier sur VM : compilation, ces tests ciblés, sélection réelle d’un fichier et réouverture d’une disposition exportée. Les adaptations de cartes D1 déjà documentées restent inchangées ; ce lot ne crée pas de faux widgets Logiciels pour les sources Query/Probe qui n’y appartiennent pas.

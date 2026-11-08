# Recherche AD : attente fondée sur la progression — RC1.17.6

## Constat et décision

Les photos transmises montrent `GlobalSearch` interrompu à 45 secondes. Cette opération couvre aussi une OU choisie : son nom ne signifie pas que tout le domaine est interrogé. Le code imposait un délai total de 45 secondes, des attentes LDAP serveur/client de 8/12 secondes et des pages de 40 objets. Une recherche recevant encore des objets pouvait donc être arrêtée par le moteur.

La cause réelle de la latence de l’annuaire de l’utilisateur n’a pas été mesurée. Ce correctif retire la coupure fixe trop courte et rend l’attente sensible aux arrivées AD ; il ne constitue pas une mesure de performance sur ce domaine.

## Comportement livré

| Réglage | Défaut | Bornes appliquées |
|---|---:|---:|
| `Async.SearchTimeoutSeconds` : absence de nouvelle ligne AD | 120 s | 120–600 s |
| `Async.SearchMaxDurationSeconds` : durée totale | 900 s | au moins le délai d’inactivité, au plus 3 600 s |
| `Browser.SearchPageSize` | 250 objets | 100–1 000 objets |
| `Browser.SearchServerTimeLimitSeconds` | 60 s | 60–300 s demandées au fournisseur |
| `Browser.SearchClientTimeoutSeconds` | 90 s | au moins serveur + 30 s, au plus 600 s |

Les anciens réglages enregistrés 45/8/12 secondes sont relevés aux nouveaux minima. Les politiques du contrôleur de domaine et les contraintes du fournisseur LDAP restent applicables ; les bornes de configuration de l’application ne les remplacent pas. Un échec du fournisseur peut terminer une recherche avant le délai du moteur.

Un compteur synchronisé est créé par recherche et conservé sur la tâche après libération de son payload. Son horloge monotone démarre au dispatch, pas à l’entrée dans la file. Chaque résultat LDAP brut avance le compteur et la date avant conversion ; cache, rendu de la liste, files UI et essais infructueux ne prolongent pas l’attente. L’heure courante de production est prélevée après le snapshot verrouillé pour ne pas traiter une arrivée concurrente comme une date future.

Le plafond total reste effectif même si des lignes continuent d’arriver. Le journal distingue absence de progression et durée totale, et précise durée, inactivité et lignes AD reçues. Un compteur brut peut dépasser les lignes affichées à cause des filtres ou doublons. Les résultats conservés restent marqués partiels après interruption. Le badge de délai conserve la distinction introduite avec l’erreur réseau réelle.

## Revue et vérifications

- Lecture du diff runtime et revue indépendante du calcul des délais et de son câblage.
- Régression concurrence reproduite avant correction, couverte par un test déterministe d’arrivée pendant le snapshot.
- Corps réel du worker GlobalSearch et convertisseurs réels exécutés avec 5 000 objets synthétiques : conservation des lignes, dédoublonnage, objets ignorés, limites, annulation et erreur pendant l’énumération.
- Commandes et affectations AST réelles du demandeur : configuration, anciens réglages, bornes et taille de page.
- Dispatch réel dans un runspace local inerte : référence partagée, payload libéré et temps en file exclu.
- Tests existants des périmètres OU, profondeur et générations ; erreurs/retours tardifs conservés.
- La branche des écritures reste inchangée. Les lectures ordinaires conservent leur délai total ; le handle terminé est traité avant le délai.
- Contrat worker et registre recalculés après revue ; six composants binaires épinglés conservés.

Résultats chiffrés et empreintes : [qualification.json](qualification.json). Les échantillons sont synthétiques et ne contiennent aucune donnée du domaine transmis en photo.

## Limites et retour utile

Contrôles locaux sous PowerShell 7.4.20 et Python sur Mac. Aucune nouvelle exécution Windows PowerShell 5.1, WPF, SQLite natif ou AD réel. L’utilisateur effectue la recette sur son poste ; les packs restent des candidats avec qualification Windows `NOT_EVALUATED`.

Après extraction complète du nouveau pack et relance, refaire la même recherche dans la même OU avec les mêmes sous-OU et limite. Vérifier la version RC1.17.6 dans l’application. En cas de nouveau dépassement, transmettre la ligne `Budgets`, le message complet d’arrêt et le compteur de lignes, ainsi que le périmètre et l’heure. Une recherche terminée sans erreur et sans limite atteinte doit correspondre à ce périmètre ; une liste partielle ne doit pas être interprétée comme exhaustive.

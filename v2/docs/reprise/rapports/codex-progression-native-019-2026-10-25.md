# TRV129 — progression des lectures natives, lot 019

État : code et 12 tests écrits le 25 octobre 2026. Aucun build ni test exécuté dans ce lot ; compilation et suites réservées à la VM Windows pilotée par root. Ce lot ne déclare pas la parité globale TRV129 validée.

## Contrat raccordé

La règle D1 de `Get-DomeniaReadTimeoutState` (`dev/wad/modules/Domenia-Engine.Model.ps1`, référence en lecture seule) distingue travail achevé, inactivité et plafond total. Les notifications UI préalables à une étape et la restitution des lignes d’une réponse IPC déjà matérialisée ne sont pas des canaux de progression source.

`NativeReadProgress` consomme maintenant les réponses CIM terminées du parent via `CimSession.QueryCompleted`. Seules les réponses `Ok` et `Empty` créditent l’inactivité : refus, authentification refusée mémorisée, garde WQL, source désactivée, réponse partielle, timeout, IPC interrompue et cleanup ne créditent rien. Une réponse partielle reste conservée dans les modèles existants ; le choix conservateur inclut les troncatures dans les réponses qui ne prolongent pas le délai.

| Lecture | Inactivité | Plafond total conservé |
| --- | --- | --- |
| Survey | 15 s, bornée par le total | 15 s |
| SurveyComplete | 25 s | 30 s |
| Quick / Full | 25 s | 55 / 150 s |
| Sondes seules, fiche et parc | 20 s | 60 s |
| Faits d’inventaire | min(25 s, budget demandé borné) | budget demandé existant, au plus 150 s |
| Ping seul | min(20 s, total existant) | total existant, au plus 10 s ; écho Recherche 2 s |

Les sondes seules prennent 20 s car elles n’incluent pas la collecte d’inventaire. Services, événements et diagnostics autonomes conservent leurs budgets séparés. Le ping n’est crédité qu’après la fin de l’écho ; son plafond déjà inférieur à l’inactivité ne peut pas être prolongé. Aucun signal UI, cache, admission ou drain de file ne renouvelle le délai.

Le délai est créé dans le worker réellement admis. Pour un inventaire partagé, le jeton appartient au groupe et survit au départ d’un seul abonné. Annulation et expiration sont terminales. La session CIM est détruite avant le canal de progression ; aucun bail ni secret n’est rendu par ce canal. L’IPC et le propriétaire physique existants arrêtent le processus et attendent sa fin avant leur restitution ; leurs budgets, protocole et code de terminaison ne sont pas modifiés ici.

## Résultats et qualification

Les faits déjà reçus restent présents avec un état incomplet après une interruption. Les lecteurs de sondes déclarent toutes les sondes restantes non lues, y compris après l’expiration interne normale du worker. Une lecture d’inventaire expirée ne publie plus « Lecture terminée » en fin de boucle.

L’identité reste celle effectivement lue : le lecteur de parc exige la concordance avec le poste avant ses sondes, le lecteur détaillé confirme le nom, les faits exposent le nom reçu pour la qualification existante par l’appelant. Les règles de session/source des couches AD ne changent pas. Aucun nouvel accès LDAP, cache ou écran n’est ajouté.

## Preuves préparées et limites

`NativeReadProgressTests` contient 12 tests comportementaux avec horloge contrôlée et barrières : seuils 20/25 et total court, plafonds 15/30/55/60/150 indépendants, vrais retours CIM positif/vide, refus/cache/partiel sans crédit, arrêt/disposal terminal, collecte effective de faits sur 32 s, conservation après source bloquée, toutes les sondes restantes déclarées, notifications UI sans crédit, SurveyComplete réellement arrêté à 30 s, propriétaire collectif et six slots conservés jusqu’au retour effectif du worker.

Les barrières disposent d’une garde de 10 s pour détecter un blocage du test ; aucun sommeil de campagne et aucun contact AD/réseau ne sont employés. Ces tests restent non exécutés. Ils vérifient la retenue du slot du worker injecté ; les preuves de processus enfant/secret/quota physique relèvent des tests natifs déjà écrits dans le lot 015, non remplacés par une simulation ici. L’écho réseau réel et la campagne complète sur postes restent à valider dans la recette autorisée.

Les autres volets TRV129 (délais LDAP, recettes/recherche et UI) relèvent des lots de leurs propriétaires ; ce rapport décrit uniquement le raccord des lectures natives explicites.

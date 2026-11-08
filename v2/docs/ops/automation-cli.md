# Ligne de commande locale — Domenia.Automation/1

Implémentation raccordée à `Domenia.exe`. Compilation et recette Windows du présent lot **non vérifiées** ; les tests critiques restent à exécuter après commit/push dans les deux VM Windows, avec preuve UI/native.

## Commandes

```text
Domenia.exe version
Domenia.exe etat --base C:\Domenia\Domenia.db
Domenia.exe postes --base C:\Domenia\Domenia.db --ou OU=Postes,DC=exemple,DC=local
Domenia.exe observations --base C:\Domenia\Domenia.db --postes PC-01,PC-02 --famille Inventory
Domenia.exe associations --base C:\Domenia\Domenia.db --guids 3f2504e0-4f89-11d3-9a0c-0305e82c3301
Domenia.exe requetes --base C:\Domenia\Domenia.db --sortie C:\Exports\requetes.json
Domenia.exe postes --base C:\Domenia\Domenia.db --postes PC-01 --format Csv --sortie C:\Exports\postes.csv
```

`version` expose le contrat et l’identité compilée sans lire de base. Les autres commandes exigent un chemin `.db` local absolu explicite. `postes`, `observations` et `associations` exigent exactement un périmètre : `--ou`, `--postes` ou `--guids`. `etat` et `requetes` décrivent la base entière et refusent un filtre de postes qui serait ignoré.

Les noms historiques `-DatabasePath`, `-OutputPath`, `-OrganizationalUnit`, `-Computers`, `-Guids`, `-Limit`, `-Format` et `-Family` sont reconnus. `--limite` vaut 1 000 par défaut, au plus 5 000 ; une liste contient au plus 500 noms/GUID. Les options inconnues, répétées, de mutation, de serveur et de simulation sont refusées avant toute composition applicative. Les familles admises sont `Presence`, `Console`, `Inventory` et `Probe:<identifiant>`.

La commande `dossier` conserve sa grammaire distincte documentée dans [assistance.md](assistance.md#61-commande-en-ligne-domeniaexe-dossier).

## Lecture effective et bornes

Un seul instantané SQLite en lecture seule sert chaque réponse. Le schéma historique 11 est lisible sans projection v2, migration, sauvegarde ni création de profil. Lorsque les projections v2 existent, les observations sont fusionnées par GUID/famille avec les tables historiques, en conservant la tentative la plus récente ; la bibliothèque de requêtes courante est relue avec son empreinte. Aucune requête ni sonde n’est exécutée.

La base doit être fermée et cohérente. Les bases WAL, les journaux actifs et les fichiers annexes présents sont refusés : SQLite pourrait sinon créer ou modifier des fichiers annexes même lors d’une ouverture readonly. La CLI ne change aucun mode de journalisation. Le fichier est épinglé contre les écritures/remplacements pendant la lecture ; les tris temporaires SQLite restent en mémoire.

La sélection utilise des paramètres SQL liés ; les caractères génériques d’une OU sont littéraux et sa casse Unicode est respectée. La limite est vérifiée avec une ligne sentinelle. `Truncated` et les notes qualifient le résultat partiel ; le détail borné de `etat` porte également `DetailsTronques`. Une lecture dure au plus 30 secondes. Les données SQL retenues sont bornées à 32 Mio et la réponse écrite à 64 Mio. Les observations et définitions JSON illisibles/trop volumineuses sont signalées comme non reprises ; les champs secrets sont retirés avec leurs noms d’exclusion. Une donnée manquante ne devient pas une réussite.

`DOMENIA_SIMULATION=1` ou `Auth.DemoProvider=true` refuse toute lecture de base réelle et toute sortie fichier réelle avant l’ouverture de ces chemins. `DOMENIA_SIMULATION=0` possède la priorité du sélecteur de mode existant. `version` sur la sortie standard reste disponible sans lecture de configuration en démonstration. `--demo-session` ne peut pas être combiné avec une commande réelle.

## Sorties et codes

JSON conserve l’enveloppe `Domenia.Automation/1` : commande, source, périmètre, date, limite, nombre de lignes, troncature, éléments, exclusions et notes. CSV est réservé à `postes`/`associations`, neutralise les formules et utilise UTF-8 BOM. Une troncature CSV sur stdout est signalée sur stderr.

`--sortie` exige un nouveau fichier `.json` ou `.csv` dans un dossier local existant. UNC, lecteur réseau, périphérique, flux alternatif et lien sont refusés. La CLI écrit un temporaire adjacent, force sa sauvegarde, relit SHA256 puis renomme sans remplacement. Une destination déjà présente est conservée. La confirmation JSON sur stdout contient le chemin, SHA256, le nombre de lignes, la troncature et les notes. Si stdout se rompt après finalisation du fichier, le code vaut 5 et le fichier finalisé reste complet.

| Code | Signification |
|---|---|
| 0 | Réponse complète écrite, éventuelle troncature explicitement signalée |
| 2 | Commande, option ou valeur refusée |
| 3 | Base/configuration locale absente, occupée, incohérente, hors limites ou lecture expirée |
| 4 | Périmètre obligatoire absent, démonstration ou contrôle du paquet refusé |
| 5 | Destination ou sortie impossible à écrire entièrement |

`Domenia.exe` est une application fenêtrée. Pour attendre sa fin et récupérer le code dans PowerShell, utiliser `Start-Process -Wait -PassThru` avec `-RedirectStandardOutput`/`-RedirectStandardError`, ou `start /wait` dans cmd. Aucune fenêtre, WebView, connexion AD ni minuterie applicative ne doit apparaître. Les erreurs du paquet vont sur stderr et ne doivent pas créer de journal de profil.

## Recette critique à faire dans chacune des deux VM

Exécuter les sélections `AutomationCommandTests`, `AutomationLocalStoreTests` et `QueueTimingTests` depuis le commit livré. Vérifier aussi l’exécutable réel : six commandes, base D1 sans projection, base v2 avec relevés et requêtes, filtre familial, limite atteinte, CSV, refus en démonstration, refus d’un fichier existant, base absente/occupée/WAL et pipeline rompu. Comparer les empreintes et l’inventaire des fichiers/profil avant/après les lectures ; constater l’absence de transport natif, de fenêtre et de journal créé.

Pour 124/125, modifier `Async.BackgroundAgingSeconds`, `Async.MaxQueueWaitSeconds` et `Async.TickBudgetMs` dans `Domenia.config.json`, relancer, puis confronter Paramètres → Configuration aux attentes de la file. Les valeurs affichées et appliquées proviennent du même instantané de démarrage. Une modification externe du fichier exige un nouveau lancement ; elle ne modifie pas les demandes déjà admises.

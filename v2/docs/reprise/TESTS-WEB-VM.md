# Tests des modules web dans la VM

À lancer après la fin du développement et les commits/push, avec le bureau Windows ouvert :

```sh
bash v2/tools/vm.sh nom-du-lot web-test --config Release --out /chemin/absolu/preuves-web
```

La commande prend le verrou VM habituel, synchronise et compile, puis lance `Domenia.WebTests` dans la session interactive. Le harnais utilise l’unique runtime WebView2 fixe déjà présent dans le cache. Il ne télécharge rien, n’installe aucun composant, ne lance aucun serveur HTTP et n’expose aucun bridge applicatif.

Le harnais charge `tests/web/run.html` depuis un hôte virtuel local. Il refuse les requêtes et navigations externes. Chaque lancement conserve un dossier unique avec le rapport structuré, le texte et une capture PNG ; une erreur de chargement ou d’infrastructure échoue explicitement. Une page sans test ne peut pas réussir. Le délai global est de dix minutes.

Cette commande couvre les modules importés par `tests/web/run.mjs`. Elle ne remplace ni les tests C#, ni les scénarios E2E, ni les scripts de tests qui nécessitent Node, ni la recette native des deux VM. Le projet de harnais reste sous `tests/` et n’entre pas dans les paquets livrés.

Les suites Paramètres, Recherche, Assistance et règles Comptes utilisent désormais le même adaptateur d’assertions dans le navigateur et dans leur ancien point d’entrée Node. Le pilote lit les vecteurs communs de recherche et toutes les sources Paramètres dans l’arbre local de la VM, avec des bornes explicites, puis les fournit à la seule page de tests. Une source manquante provoque un échec ; aucun accès réseau ni assouplissement de `connect-src 'none'`. Leur import dans `run.mjs` est livré avec le lot d’historique des dispositions.

État à l’écriture : harnais écrit ; aucune suite exécutée.

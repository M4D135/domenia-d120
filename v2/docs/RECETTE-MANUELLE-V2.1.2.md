# Domenia 2.1.2 — clôture de la parité et garanties de lecture

Version du 9 novembre 2026. La qualification CI est distincte de la recette utilisateur sur un domaine réel.

Un seul ZIP est prévu : `Domenia_2.1.2_PROD-LIGHT_Windows-x64.zip`. L’extraire dans un dossier distinct et vérifier
son SHA256 avec `SHA256SUMS.txt`. Le runtime .NET est embarqué ; WebView2 est fourni par Evergreen installé ou
par le pack du Socle extrait dans `wad/runtime/webview2`. Aucun téléchargement automatique.

Le format des données reste le schéma 11, révision native 2. Une base de 2.0.5 à 2.1.1 s’ouvre telle quelle.

## Contenu

- Comparaison des relevés : une population non décrite reste inconnue ; un même compteur ne prouve pas que les
  postes sont les mêmes. Un score absent puis disponible, ou l’inverse, donne une comparaison limitée avec sa raison.
- Contrat des sondes : contrôles des comptes/groupes insensibles à la casse, filtre local réellement restrictif,
  sous-espaces interdits refusés. Lecture CIM seule, aucune méthode ni écriture, collecte lourde explicite.
- PAR-046 : clôture documentaire sur les raccordements existants L16/L02 et leurs tests. Le délai des commandes
  distantes est appliqué par appel natif, de 1 à 300 secondes, défaut 10 ; il ne promet pas de terminer un appel COM
  bloqué. La place reste occupée jusqu’au retour physique, sans second envoi.

## À observer sur ce ZIP

- Connexion, affichage et fermeture habituels ; les observations de la [recette 2.1.1](RECETTE-MANUELLE-V2.1.1.md)
  restent à vérifier avec l’identité de la session Windows hors Domain Admins.
- Comparer deux relevés depuis l’Accueil : les différences de périmètre, couverture et règles sont nommées.
  Si l’un des relevés ne contient pas de score, aucun gain ou état stable n’est déduit de sa seule disponibilité.
- Dans l’atelier de requêtes, vérifier la ligne de population : domaine ou OU, profondeur, type d’objet, recette,
  empreinte, source et instant du calcul correspondent à l’aperçu affiché.
- Consulter le contrat d’une sonde : droits, coût, sources et limites sont lisibles ; consulter ou afficher un
  contrat ne lance aucune collecte. Une collecte lourde exige le geste de confirmation de l’opérateur.
- Dans le rapport de configuration, vérifier le délai des commandes distantes et les valeurs réellement bornées.
  Ce contrôle ne demande de lancer aucune commande distante.

Pour chaque observation, conserver le résultat réel, la version et l’empreinte du ZIP ; noter « non exécuté »
si le cas n’a pas été exercé. Aucun succès n’est prérempli. Cette recette ne demande aucune écriture AD,
modification de service, stratégie, pare-feu, antivirus ou redémarrage.

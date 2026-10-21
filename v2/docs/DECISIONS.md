# Décisions de David pour Domenia 2

Chaque décision est datée. Une décision plus récente remplace une décision antérieure sur le même sujet.

| Date | Sujet | Décision | Mise en œuvre |
|---|---|---|---|
| 21/10 | Interface | WebView2 seule, « master site » très animé, « web 4.0 », propre et soigné ; rien perdu, tout amélioré | `web/`, animations riches par défaut, réglage riches / réduites / suivre Windows |
| 21/10 | Langage | Réécriture complète en C# (.NET 10 LTS autonome) | `src/` |
| 21/10 | Portabilité | Pack PROD autonome : dézipper et lancer, rien à installer (runtime .NET et WebView2 fixe embarqués) | `tools/build-vm.ps1 -Publish` |
| 21/10 | Tests | Écrits au fil du code, exécutés à la toute fin ; compilation permise à tout moment | `tests/` |
| 21/10 | Poste de travail | Développement et compilation dans la VM Windows ; en cas d'échec de la VM, lancement en simulation sans AD autorisé directement sur le PC de test | `docs/SIMULATION.md` |
| 21/10 | Mesure active | « Fais au plus intelligent » : l'état de chaque widget est mémorisé dans les préférences locales de l'application (nouvelle classe d'opération `LocalWrite`, jamais d'écriture AD), avec un fichier de préférences séparé en simulation | à faire |
| 21/10 | Auth.DemoProvider | « Ok, fais au mieux » : `Auth.DemoProvider=true` dans `Domenia.config.json` démarre aussi en simulation (raison « configuration ») | à faire |
| 21/10 | Fin de support Windows | Non retenue (« balec ») | — |
| 21/10 | OU de travail | « Au plus pratique et logique » : OU de travail globale, choisie dans un panneau d'arborescence avec recherche, mémorisée ; elle sert de défaut aux sections sans choix propre (comme Domenia 1) ; surcharge par section prévue ensuite | à faire |
| 21/10 | Catalogue | Construire `docs/FEATURES.md` à partir de tout Domenia 1 | en cours |
| 21/10 | Livraison | Une fois tout terminé : pack Windows prêt à l'emploi (ZIP à dézipper et lancer, simulation incluse), publié en release GitHub | à faire en fin de chantier |

# Contrôle court Windows de Domenia 1.0

`Invoke-DomeniaQuickUi.ps1` exécute les contrôles dans des processus Windows PowerShell 5.1 x64 STA distincts. Les données sont fictives et aucun annuaire réel n'est interrogé ou modifié.

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Invoke-DomeniaQuickUi.ps1 `
  -DevRoot C:\DomeniaTest\dev -OutDir C:\DomeniaTest\preuves
```

Le contrôle fabrique aussi un PROD ordinaire dans le dossier de preuves, compare ses composants au DEV figé et exécute son lanceur en `-CheckOnly`. Aucun lancement interactif ni accès AD ne suit cette fabrication.

Le contrôle couvre la compatibilité Windows PowerShell 5.1, le parseur natif, le tri global de la base, le lanceur (`-CheckOnly`), les fonctions et le chargement WPF, les tableaux de bord, le cycle d’affichage de la connexion, le câblage de l'interface, la détection du parc, la résilience des files et le moteur de requêtes. `-Extended` ajoute les règles, le moteur natif et la persistance SQLite sur des données jetables.

Depuis PowerShell, `-Suites @('Ps51Compat','NativeParser','StartupCheckOnly','Test-DomeniaBoards','Test-DomeniaQuery','Test-DomeniaIndexSorting')` permet une reprise ciblée des contrôles affectés. Ajouter `-Extended` rend aussi les trois suites étendues sélectionnables.

Chaque processus écrit son stdout, son stderr et, lorsque disponible, son rapport JSON. `_quick-ui.json` distingue les sorties non nulles, les délais dépassés et les rapports absents. Le lanceur laisse au test WPF interne son propre délai de 90 secondes et lui accorde une enveloppe de 150 secondes, portable compris. Les autres étapes disposent de 90 secondes par défaut. Les empreintes du runtime sont comparées avant et après les tests.

Pour les illustrations des guides, `-CaptureScript` accepte `guides\captures\capture-guides.ps1`. Ce script charge les vrais contrôles WPF mais injecte des données de démonstration (`example.local`). Les PNG sont produits hors écran par `RenderTargetBitmap`; une exécution en session 0 ne prouve pas une interaction humaine dans une session Windows ouverte. Le moteur local de l'atelier est exécuté; les transports réseau restent inertes. Les compteurs de la page Base montrent le scénario de démonstration et sa progression, sans représenter une collecte AD réelle. La virtualisation des colonnes de cette grille est désactivée uniquement pour le rendu hors écran.

Une validation réussie de ces fixtures ne remplace pas une recette avec les droits, transports, données et volumes du domaine cible. Les erreurs ou délais dépassés doivent rester visibles et être résolus avant qualification du paquet.

Le test `Test-DomeniaLoginForeground.ps1` ouvre les vrais dialogues standard/debug et le panneau de reconnexion intégré. Il vérifie le premier plan temporaire du login autonome, sa libération après succès fictif, annulation ou erreur, et l’absence de promotion de la fenêtre principale ou du moniteur. En session 0, cette preuve porte sur les propriétés WPF et leur cycle de vie ; elle ne prouve pas une interaction Alt-Tab entre applications d’une session utilisateur. Aucune authentification réseau n’est tentée.

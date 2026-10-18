# RC1.17.22 — correction de l’arbre UI Automation

Le modèle `UxWorkspaceHost` affichait la page sans réaliser les conteneurs des onglets : UI Automation voyait `WorkspaceTabs` sans enfants. Un `ItemsPresenter` de hauteur nulle réalise maintenant ces conteneurs, sans ajouter une barre d’onglets ni une cible de clic ou de tabulation. Les sélecteurs du banc utilisent aussi les `Uid` réellement exposés par les boutons de navigation.

## Preuves exécutées

- Avant correction du modèle : 23/28 étapes natives réussies ; grille `DgObjects` introuvable, quatre étapes suivantes non exécutées. Le relevé UIA montre 134 éléments et aucun enfant du `WorkspaceTabs` pourtant visible.
- Après correction du modèle, avant estampillage de version : **7/7 étapes du parcours de défilement**, grille trouvée et activée, défilement de 0 % à 100 %, puis de 100 % à 0 %, capture 1920×1080 valide. Cible Preview, données fictives, aucune connexion AD. Le rapport reste « Partiel » car seuls ces sept contrôles sont exécutés.
- Nouveau pack RC1.17.22 : **démarrage CheckOnly réussi sous Windows PowerShell 5.1 x64 STA**, 172 fichiers runtime vérifiés ; les empreintes des deux ZIP sont relues dans la VM. **Huit règles du banc réussies**. `native/proof/Startup.json` et `RC22-build.json` donnent les empreintes et les contrôles de fabrication.
- Relecture Spark du correctif sans défaut concret retenu ; son hypothèse initiale d’un `Uid` manquant sur la grille a été rejetée grâce au relevé UIA et à la reprise ciblée réussie.

## Dernier contrôle restant

Le passage complet des quatre parcours natifs sur le pack RC1.17.22 attend une session Windows interactive après redémarrage. Il n’est pas déclaré réussi. Aucun relevé humain complet n’a été produit. Les limites personnelles déjà acceptées (plusieurs écrans/DPI, écoute Narrateur, variantes LAPS, grande échelle et matrice cible) restent documentées dans le [complément RC21](../rc21-completion/README.md).

À la demande de David, le verrouillage automatique et la mise en veille ont été désactivés seulement dans la VM jetable (`PreventLock.json`). L’arrêt à 12:45 UTC est expliqué par l’événement Windows : `wlms.exe` a éteint le système car sa période d’évaluation est expirée (`LastShutdown.json`). Il ne s’agit pas du verrouillage ni d’un plantage de Domenia. Aucun contournement d’activation appliqué. La VM a été redémarrée et le pack a passé son contrôle de démarrage ; sa session reste à ouvrir.

`DOMENIA-RC21-FINAL` est conservée pour ce dernier passage ; `CNAMTS-DC01` et les autres projets sont préservés. Les archives restent candidates, autonomes, avec leurs composants embarqués. Qualification générale et publication restent fausses.

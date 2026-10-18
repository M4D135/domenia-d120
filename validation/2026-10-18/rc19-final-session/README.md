# RC1.17.19 — dernier contrôle applicatif ciblé

18/10/2026, CNAMTS-W11-01, Windows PowerShell 5.1 x64 STA. ZIP PROD exact extrait dans `C:\DomeniaLab\d120-rc11719-final`, données portables isolées et aucun profil opérateur copié. RC18 a échoué au contrôle applicatif : les réglages existaient sur disque, mais la politique de stockage était initialisée avant leur chargement dans la présentation. La case restait décochée et la minuterie arrêtée. Le dossier `rc18-failure` conserve ce résultat. RC19 déplace cette seule étape après la présentation ; nouvelle identité et nouveaux ZIP. Le runtime RC19 testé reste inchangé pendant les essais.

- Deux lancements réels du lanceur, connexion Windows et fenêtre principale atteintes.
- Première session : déplacement/redimensionnement par UI Automation, puis maximisation ; sauvegarde automatique activée et réglée sur 48 h / 5 copies via les contrôles. Fermeture normale avant toute sauvegarde. Réglages vérifiés sur disque.
- Réouverture : maximisation retrouvée ; rétablir la fenêtre restitue la taille et la position normales (tolérance 2 pixels). Case automatique toujours cochée, champs 48 h et 5 copies conservés à l'écran.
- La minuterie réelle de 60 s déclenche la première sauvegarde après réouverture, sans appel manuel du worker ni changement de son délai. Reçu `Scheduled`, SHA-256, intégrité SQLite et marqueur synthétique vérifiés. Après fermeture normale, politique et reçu restent enregistrés.
- Les 172 fichiers runtime restent identiques au manifeste. Application et contrôleur arrêtés normalement, tâche de test retirée. Rapports, captures et copie SQLite récupérés sur le Mac ; intégrité et contenu revérifiés hors VM.

`Final-Result.json` et `Cleanup.json` sont les résultats terminaux. `Qualification.json` lie les preuves au PROD réellement exécuté et au DEV partageant exactement le même runtime (identité vérifiée lors de la construction ; DEV non lancé dans ce dernier essai).

Les trois parcours demandés passent. La capture et le journal ont cependant révélé une erreur LDAP à la recherche initiale : page de 250 résultats supérieure au quota de 101. Une lecture native ciblée reproduit le défaut et sa correction ; la décision d’effacer les VM est reportée à la preuve RC20. Les échéances longues, rotations répétées, grands volumes, autres parcours et décisions externes 134/146 restent distincts de cette validation ciblée. Pas de qualification générale ni de publication déclarée. La restauration via interface après corruption reste qualifiée sur RC17 dans la preuve précédente.

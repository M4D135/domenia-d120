# RC1.17.20 — dernier contrôle critique avant effacement du labo

18/10/2026, CNAMTS-W11-01, Windows PowerShell 5.1 x64 STA. PROD exact, données portables isolées, aucun profil opérateur copié ni écriture dans AD. Pas de campagne générale.

Deux défauts ont été corrigés pendant le dernier contrôle demandé de RC18 :

- RC18 gardait la politique de sauvegarde sur disque mais initialisait ses contrôles/minuterie avant de charger les préférences. RC19 inverse ces deux étapes ; la réouverture et le cycle automatique passent. [Échec RC18 et étape RC19](../rc19-final-session/README.md).
- La capture RC19 révèle une recherche LDAP en échec. La lecture asynchrone avec une page de 250 pour un quota de 101 renvoie zéro objet et une erreur de taille. RC20 borne la page sous le quota, sans supprimer les limites ni l’élément supplémentaire servant à détecter une liste tronquée. Le banc natif relit l’expression exacte du Core livré : ancien cas reproduit, puis 101/101, 2/2 et 234 objets sous un quota de 501 sans erreur. Seules la fonction GlobalSearch et ses empreintes générées ont été re-épinglées après vérification du diff ; les autres fonctions critiques restent protégées.

Le premier dispatch du banc RC20 a été arrêté avant lancement car son empreinte attendue pointait encore sur RC19. Le résultat et le banc initial sont conservés ; seule cette référence a été corrigée avant le contrôle effectif.

Le pack RC20 passe le parcours applicatif réel : deux lancements et connexions Windows, taille/position normales 1320 × 820 à (120,80), fermeture maximisée, réouverture maximisée puis rétablissement du même rectangle. L’activation automatique et les réglages 48 h / 5 copies sont retrouvés à l’écran et sur disque. La minuterie réelle de 60 s produit la première sauvegarde après réouverture ; reçu Scheduled, SHA-256, SQLite quick_check et marqueur synthétique vérifiés. Politique et reçu persistent à la fermeture. Aucune erreur LDAP de dépassement de taille dans les deux sessions.

Les 172 fichiers runtime sont inchangés et identiques dans PROD, DEV et les sources. Les contrôles obligatoires de fabrication passent. DEV partage le runtime vérifié mais n’est pas lancé séparément. Les ZIP testés sont conservés octet pour octet ; seuls les trois documents de suivi dans les sources DEV sont actualisés après fabrication. La base sauvegardée et les preuves sont récupérées sur le Mac ; intégrité et marqueur sont revérifiés hors VM. Application et contrôleur terminés normalement, tâche temporaire retirée. Les VM ne sont pas supprimées par l’assistant.

**David peut effacer les VM pour le périmètre critique demandé.** Les échéances longues, rotations répétées, autres transports, volumes et parcours restent hors qualification ciblée ; les décisions externes 134/146 restent ouvertes. Aucun acceptance_passed global ni caractère publiable déclaré. La restauration via interface après corruption reste qualifiée sur RC17, dans la preuve historique correspondante.

`Qualification.json` lie les archives et toutes les preuves ; `raw/Final-Result.json`, `raw/Ldap-Page-Limit.json` et `raw/Cleanup.json` portent les résultats. Les journaux de session sont conservés, y compris leurs avertissements non bloquants ; ils ne sont pas présentés comme exempts de toute anomalie.

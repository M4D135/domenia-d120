# Lot cache, restes : décisions de David du 2026-10-04

Décisions validées en bloc (« Oui, toutes ») sur proposition argumentée, après cartographie du code (workflow de
lecture, 7 points + synthèse vérifiée sur la source à `9455a78`).

| Point | Décision |
|---|---|
| D028 | Après un conflit entre deux consoles sur une même association : état « modifiée ailleurs, rechargez les associations » (`Get-DomeniaPersistenceLabel -Conflicts`) ; le chemin silencieux ne renvoie plus les clés en conflit avant `Reset-DomeniaLinkBaseline` ; le chemin explicite soumet et avertit. |
| D113 | Geste de migration explicite : bouton à côté de « Reprendre les sauvegardes » (Outils > Fiabilité) ; simulation affichée puis Oui/Non. |
| D113 | Anciens magasins sans DN (`parc.tsv`, `recherches.tsv`, `secrets-etat.tsv` sans `objets.tsv`) : bloqués (le plan porte un blocage), aucune supposition de domaine. |
| D113 | Lien retenu par poste : règle Relations actuelle (affectation déclarée d'abord, sinon la plus récente, liens canonisés avant la règle) ; les fichiers de configuration ADCC restent du ressort de l'installeur. |
| D113 | Base déjà utilisée avant la migration : n'ajouter que les postes absents de la base, sans jamais écraser (une clé existante devient un conflit) ; règle et tests ajustés, idempotence conservée. |
| D023 | Politique explicite actuelle acceptée à la place d'une pagination : 500 lignes au plus par liste (limite saisie ou `Browser.GlobalSearchLimit`, « Charger la suite » jusqu'à 500, puis « affinez la recherche »), virtualisation WPF de `DgObjects`. `New-DomeniaPageBuffer` reste inutilisée ; son retrait sera décidé à part. |
| D024 | Fraîcheur par nature affichée dans les infobulles des colonnes existantes (SessionDetail, PresenceDetail) et la ligne d'état de la fiche. |
| D024 | Observations déjà stockées sans dates par nature : complétées prudemment au chargement, sans jamais rajeunir une date. |
| D030 | « Réessayer la lecture » reste actif hors ligne (lecture explicite) ; `CanRetry` documenté comme réessai automatique seulement. |
| D030 | Fiche en cache ou en échec hors ligne : visible mais grisée pour ce lot. |
| D030 | Explorateur de cache non requis pour clore D030 (éventuel, mémoire seule). |
| D118 | Journaux et sauvegardes : sous-zones déclarées de la catégorie Cache à leur emplacement actuel (contrat à 4 catégories et preuves D115 conservés). |
| D118 | Dossier de données refusé au démarrage : journal de secours `%LOCALAPPDATA%\DOMENIA\Logs` puis `%TEMP%`, toujours nommé dans le message fatal. |
| D118 | Dossier Préférences non inscriptible : démarrage avec avertissement visible, rien n'est écrit ailleurs. |
| D029 | Purge : vidage complet pour les données reconstructibles (Observations, Instantanés, Index), âge borné pour l'historique ; nombres trompeurs retirés de `Get-DomeniaRetentionPolicy`. Associations protégées : Manual, Saisie manuelle et Import CSV, avec leur historique (le plafond automatique de LocalStore et `Start-PruneOrphanLinks` les excluent). Journal d'audit `Domenia.log` jamais supprimé (Logs hors première version). Reçus jamais purgés ni archivés dans D029 ; archivage des reçus résolus suivi à part. |

Défaut relevé par la cartographie et à corriger (D024, étape I1) : `Complete-DomeniaLiveProbe` teste
`$observation.Outcome`, jamais `PresenceOnly`, si bien qu'un simple ping rajeunit la session console quand le résultat
précédent était Observed ou NoConsole ; le test existant le masque en doublant `ConvertTo-DomeniaLiveObservation`.

## Precision D113, reprise Codex du 2026-10-04

David confirme dans cette session : refuser l import si une des quatre tables
`ad_objects`, `park_state`, `user_scan_history` ou `secret_state` contient deja
des donnees. Les associations existantes restent protegees ; seuls les postes
absents de `user_machine_links` sont ajoutes. Le controle a lieu dans la
transaction du worker, apres le controle du marqueur d idempotence.

## Precision G2/G3 et nom du produit, 2026-10-04

David choisit de proteger les associations reprises sous Import CSV, en conservant leur source d origine dans le detail. La regle Relations choisit d abord la ligne a retenir ; le changement de source vient ensuite. Le produit est Domenia : les libelles utilisateur parlent de « Reprendre les anciennes donnees ». Les noms historiques de fichiers et de tables restent uniquement des identifiants de compatibilite.

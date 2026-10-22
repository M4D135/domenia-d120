# Suivi du Spark autonome (Domenia 2)

Mis à jour automatiquement par `_pilotage/spark/auto.py` le 22/10 23:13. Ce fichier sert à la relève si Claude Code n'est plus disponible.

- Chaque tâche (`_pilotage/spark/tasks/<id>.md`) tourne dans OpenCode avec le modèle local du Spark :
  - arbre `../Domenia-D120-team/sp-<id>`, branche `spark/<id>`, poussée sur GitHub ;
  - suivi détaillé de la tâche dans `v2/docs/reprise/spark/<id>.md`, sur sa branche.
- Vérification automatique (`verify.sh`) :
  - portée limitée à `v2/` ;
  - motifs interdits ;
  - compilation Debug et Release ;
  - suite C# complète dans la VM.
- Une tâche validée est fusionnée dans **`v2-spark`** (branche d'intégration), recompilée et retestée, puis poussée. La branche `v2` n'est jamais touchée.
- **Pour la relève** :
  - relire `v2-spark` (`git log origin/v2..origin/v2-spark`), puis la fusionner dans `v2` ;
  - traiter les tâches en échec ou en conflit avec leur rapport `verify-<id>.txt` et leur suivi.

| Tâche | État | Essais | Vérification | Note |
|---|---|---|---|---|
| 01-e2e | merged | 1 | PASS | fusionnée dans v2-spark |
| 02-ad-accueil-rechercher | merged | 1 | PASS | fusionnée dans v2-spark |
| 03-ad-fiche-comptes | pending | 1 | FAIL | relance après échec de vérification |
| 04-ad-relations-poste | pending | 1 | FAIL | relance après échec de vérification |
| 05-ad-requetes-audit-schema | running | 1 |  |  |
| 06-store-synchro | pending | 0 |  |  |
| 07-ops-assist-param | pending | 0 |  |  |

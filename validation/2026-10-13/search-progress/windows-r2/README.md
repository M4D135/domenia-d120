# Campagne Windows ciblée — deuxième tentative

Même runtime RC1.17.6 et mêmes ZIP que `../windows-r1`. Seul le runner est corrigé : `File.Replace` reçoit un vrai paramètre nul compatible avec Windows PowerShell 5.1. Le lancement capture les erreurs précoces dans `launcher.txt` et limite `ExecutionPolicy Bypass` au processus de test. Les stratégies Windows persistantes restent inchangées.

Les onze étapes sont séquentielles : dix suites synthétiques locales (SQLite et WPF natifs), puis `PROD -CheckOnly`. Aucun accès à un AD réel, ping/WMI distant, écriture d’annuaire ou parcours utilisateur n’est réalisé. Les preuves de cette campagne sont distinctes de celles de la première tentative.

## Résultat

Les onze étapes sont exécutées, les 492 fichiers source sont identiques avant/après, et les 61 empreintes invitées ont été vérifiées à la récupération. Huit étapes réussissent, trois suites échouent :

- Freshness : assertion erronée incluant un marqueur technique SQLite parmi les checkpoints de fraîcheur.
- LiveSearchView : deux attentes fixes trop courtes dans la VM ; le test de 5 002 objets passe. Le libellé attendu du compteur était également périmé.
- Geometry : huit échecs réels de hauteur de l’arbre OU sur les petites surfaces.

Aucun de ces échecs n’est masqué par un statut global PASS. La révision suivante corrige le panneau OU et les assertions concernées, puis rejoue les onze étapes sur les deux nouveaux packs.

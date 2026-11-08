# Vérifications de reprise

Rapports de construction et de tests locaux, sans qualification Windows :

- `build-report.json` et `SHA256SUMS` : packs candidats RC1.17.8, intégrité vérifiée, non qualifiés sous Windows.
- `worker-composition-pwsh7.json` : douze fabriques pures, aucun worker exécuté.
- `support-pwsh7.json` : 53 cas locaux, sans WPF ni domaine.
- `dead-functions-preexisting.json` : treize écarts au cliquet déjà présents dans `553fe9e`.

Les essais VM et les captures restent à effectuer. Le suivi détaillé est dans `dev/engineering/d120/programme-2026-10-13/SUIVI-2026-10-16.md`.

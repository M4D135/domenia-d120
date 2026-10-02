# Audits Python historiques (archivés le 2026-10-02, lot D120 « suites »)

Ces scripts viennent de `tools/`. Chacun contrôlait une livraison passée (RC1 à RC1.9) par rapport à une archive ZIP
ou à une référence figée : nombre d'opérations, de modules ou de fonctions, fonctions du cœur modifiées par cette
livraison précise. Ces faits ne décrivent plus RC1.11.0. Aucun n'est lancé par `tools/build_packages.py`.

Ils sont conservés à l'identique pour l'historique et ne s'exécutent plus depuis ce dossier.
Le motif de chaque archivage est dans `../ARCHIVE-SUITES-RC1.11.md` (§5).

Portes actuelles du build : `tools/release_contract.py`, `tools/audit_function_names.py`,
`tools/validate_powershell_static.py`, `tools/audit_preload.py`, `tools/update_worker_contracts.py`,
`engineering/d120/release_guard.py`, puis les suites Windows PowerShell 5.1 de `wad/tests`.

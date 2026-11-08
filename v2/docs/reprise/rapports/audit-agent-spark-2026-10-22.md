# Rapport OC — écran Audit AD (v2-page/audit)

Date : 2026-10-22. Relève du travail en cours de l'agent précédent (CRITIQUE-1.md traité).

## État du dépôt

- Branche `v2-page/audit`, commits : `0f43490` (écran Audit AD, AUD-001 à AUD-023),
  `3916953` (WIP sauvegardé de l'agent précédent, 30 fichiers, +2 304/−528),
  `5250fc2` (fix de la relève : teinte du critique câblée dans le JS, statut et captures à jour).
- Aucun push (conforme à la consigne). `CRITIQUE-1.md` et ce rapport sont hors Git (ignorés).

## Travail de la relève

1. **Relecture complète du WIP** (C# et web) : garde des lectures restreinte à l'objet courant (AUD-003),
   suggestions et sélection vérifiées par RID et non par nom écrit en dur (AUD-010), contrôleurs limités à la
   liste du domaine avec `audit.controllersInvalid` (aucun hôte arbitraire, jamais plus de 10), estimation et
   groupes de jetons refusées pour un bénéficiaire absent des entrées lues, historique et relations en mémoire
   locale avec limite dite, identité de poste à trois faits repérés par identifiant stable (`adName`,
   `dnsForward`, `dnsReverse`, `reported`), objet hors domaine refusé avant lecture (`audit.outsideDomain`),
   contrôleur injoignable « Non lu » et jamais « en panne ».
2. **Correction appliquée par la relève** : la teinte `crit` du niveau critique était définie en CSS
   (`--aud-crit`, `[data-tone="crit"]`) et attendue par le scénario E2E `analyse-domaine.json`, mais le JS
   émettait `alert` (identique aux élevés). Corrigé dans `v2/web/js/pages/audit/shared.js`
   (`SEVERITIES.critical.tone = 'crit'`, icône d'alerte pour `crit` dans `statusMarkup`) et
   `v2/web/js/pages/audit/overview.js` (bandeau de synthèse en `crit` quand il y a des constats critiques).
3. **Vérifications hors VM** : signatures des tests (records de sonde, `EngineContext`,
   `ScreenReaders.Discover`, `SimulatedBridge.Source/Decision`) et sélecteurs des scénarios E2E
   (`.aud-rel-lines`, `.aud-hist-card`, `.aud-ladder .aud-rung`, `.aud-graph .gnode`, `.aud-path`,
   `.aud-why`, boutons `data-act`) tous présents et câblés.

## Preuves VM

- `bash v2/tools/vm.sh audit build` : **Debug réussi, 0 erreur, 0 avertissement** (tous projets,
  `TreatWarningsAsErrors` actif). Le Release de capture compile également (0/0).
- `bash v2/tools/vm.sh audit capture --routes audit --themes dark,light` : **12 images sur 12**,
  code de sortie 0, dans `_pilotage/oc-v2/shots/audit` (audit sombre, clair, défilés bas).

## Non fait (assumé, déclaré)

- **Tests C# et scénarios E2E écrits, non exécutés** (décision du 22/10 : la VM ne sert qu'à compiler).
  Ils ne sont donc pas une preuve ; l'exécution reste à programmer.
- **Mode annuaire réel** : décrit dans `docs/ops/audit.md` § 11, renvoyé à la vague 3 ; le lecteur réel
  `AdAuditReader` n'est pas branché. Rien d'audit n'a été exécuté contre un vrai domaine.
- Le score de synthèse reste indicatif (formule affichée dans le détail de la tuile).

## Statuts

`v2/docs/status/audit.json` : 14 points `fait`, 9 `ameliore`, 0 `partiel` ; note complétée par la compilation
0/0 et les captures 12/12.

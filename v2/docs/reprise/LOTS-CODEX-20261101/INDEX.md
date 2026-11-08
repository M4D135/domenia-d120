# Reprise Codex des 22 lots — 01/11/2026

Codex poursuit sans Claude ni Spark. Aucun test produit sur Mac, aucune VM ni domaine réel. Master reste `cf93a6aa`, production 2.0.8 ; aucun nouveau pack publié.

| Lot | État | Branche |
| --- | --- | --- |
| L07 | Code et revue terminés ; qualification Windows cumulative requise | `codex/lot-L07-claude-20261101` |
| L22 | Code et revue terminés ; qualification Windows cumulative requise | `codex/lot-L22-claude-20261101` |
| L21 | Code et revue terminés ; qualification Windows cumulative requise | `codex/lot-L21-claude-20261101` |
| L13 | Code et revue terminés ; qualification Windows cumulative requise | `codex/lot-L13-codex-20261101` |
| L14 | Code et revue terminés ; qualification Windows cumulative requise | `codex/lot-L14-codex-20261101` |
| L17 | Code et revue terminés ; qualification Windows cumulative requise | `codex/lot-L17-codex-20261101` |
| L18 | Code et revue terminés ; qualification Windows cumulative requise | `codex/lot-L18-codex-20261101` |
| L19 | Code et revue terminés ; qualification Windows cumulative requise | `codex/lot-L19-codex-20261101` |
| L09 | Code et revue terminés ; qualification Windows cumulative requise | `codex/lot-L09-codex-20261101` |
| L08 | Code et revue terminés ; qualification Windows cumulative requise | `codex/lot-L08-codex-20261101` |
| L10 | Code et revue terminés ; qualification Windows cumulative requise | `codex/lot-L10-codex-20261101` |
| L11 | Code et revue terminés ; qualification Windows cumulative requise | `codex/lot-L11-codex-20261101` |
| L12 | Code et revue terminés ; qualification Windows cumulative requise | `codex/lot-L12-codex-20261101` |
| L05 | Code et revue terminés ; qualification Windows cumulative requise | `codex/lot-L05-codex-20261101` |
| L06 | Code et revue terminés ; qualification Windows cumulative requise | `codex/lot-L06-codex-20261101` |
| L15 | Code et revue terminés ; qualification Windows cumulative requise | `codex/lot-L15-codex-20261101` |
| L16 | Code et revue terminés ; qualification Windows cumulative requise | `codex/lot-L16-codex-20261101` |
| L20 | Code et revue terminés ; qualification Windows cumulative requise | `codex/lot-L20-codex-20261101` |
| L03 | Code et revue terminés ; qualification Windows cumulative requise | `codex/lot-L03-codex-20261101` |
| L04 | Code et revue terminés ; qualification Windows cumulative requise | `codex/lot-L04-codex-20261101` |
| L02 | Code et revue terminés ; qualification Windows requise | `codex/lot-L02-codex-20261101` |
| L01 | Code et revue terminés. Qualification Windows requise | `codex/lot-L01-codex-20261101` |

La compilation de push seule n’autorise aucune intégration. Revue indépendante puis CI Windows complète du contenu exact comprenant master sont requises pour chaque intégration. Les rapports par lot conservent les résultats et corrections précédents. Au 2 novembre, le code des vingt-deux lots a été relu. Leur intégration à master attend la qualification Windows complète du candidat.

L03 : [Windows 41295099688](https://github.com/M4D135/domenia-d120/actions/runs/41295099688), critiques verts, suite complète 2937/2943. Contradictions d’identité mieux propagées et deux fixtures corrigées, revue indépendante accordée ; inclus dans L04.

L20 : [Windows 41293266800](https://github.com/M4D135/domenia-d120/actions/runs/41293266800), C# critique et complet verts, préparation arrêtée par ancien dossier WebView2 absent. Sélection préinstallée signée et copie inventoriée corrigées/revues `a911f10a` ; [nouvelle qualification 41295657172](https://github.com/M4D135/domenia-d120/actions/runs/41295657172) en cours.

Le quota GitHub refuse encore le transfert des preuves. Nettoyage autorisé par David le 1er novembre : 16 anciens packs temporaires avant le 29 octobre, 14 835 126 342 octets supprimés ; 219 autres artefacts conservés. Releases, runs et journaux préservés. Aucun passage forcé au vert ni suppression supplémentaire.

Source du périmètre : `../audit-parite-20261031/lots.json`. Les audits historiques restent inchangés.

## Candidat Windows du 2 novembre

La branche `codex/candidat-22-lots-20261102` réunit le lot L01 `dfe078af` et les correctifs collectifs `1ec67385`. Elle conserve les corrections du profil Windows, du fournisseur WMI et de la copie de compte en test. Les archives PROD et PROD-LIGHT et leurs empreintes sont conservées comme artefacts temporaires avec les preuves de tests. Le workflow de qualification a accès au contenu du dépôt en lecture seule.

Le contrôle attendu sur ce candidat comprend les tests critiques et complets, les contrôles web et la préparation des deux packs. Les résultats rapportés pour une branche antérieure ne qualifient pas ce candidat. Le test du mutex utilise deux instances du magasin dans le même processus Windows avec un autre thread propriétaire du verrou.

La variante légère utilise le même EXE et les mêmes composants applicatifs que PROD. Le moteur WebView2 fixe est absent de son inventaire. La sélection critique Windows doit aussi lancer l’interface du ZIP LIGHT extrait avec le runtime Microsoft préinstallé. Les sources se trouvent au commit de livraison dans Git.

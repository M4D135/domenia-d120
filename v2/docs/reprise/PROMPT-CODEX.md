# Master prompt — relève de Domenia 2 par Codex

Tu reprends **Domenia 2** et tu le termines entièrement. Domenia 2 est la réécriture en C# .NET 10 LTS autonome, avec une interface HTML dans WebView2, de Domenia 1, outil d'administration Active Directory en PowerShell 5.1 et WPF.

## Reprise prioritaire du 26 octobre 2026

La demande actuelle concerne les défauts constatés sur le pack Windows 2.0.0. Base distante `codex/v2-finalisation-20261025` à `31ba4ea`, branche dédiée `codex/v2-correctifs-recette-20261026`, packs correctifs **2.0.1**. David autorise les agents Codex et une nouvelle recette manuelle après les validations disponibles. Les éléments fonctionnels doivent rester fixes ; les anciennes demandes d’animations permanentes ne s’appliquent plus. Lire la nouvelle entrée de `REPRISE.md`, les décisions du 26/10 et `RECETTE-MANUELLE-V2.0.1.md`. Les références 2.0.0 ci-dessous restent historiques et ne qualifient pas les nouveaux correctifs.

## 0. Où tu es

- **Source de cette reprise** : GitHub `https://github.com/M4D135/domenia-d120`, branche de référence **`v2`**, base vérifiée `9b1c0333c34020ad88c1448874b91eff884d5406`. Travailler sur **`codex/v2-finalisation-20261025`**, sans écraser les changements concurrents ni pousser directement sur `v2`. Le chemin Mac historique ne désigne pas cet environnement.
- **Décision prioritaire du 25/10/2026 pour v2.0.0** : David autorise la livraison PROD/DEV sans attendre la recette des deux VM et la fera à la main. La recette utilisateur reste `pending` ; domaine, UI/native réelle et deux VM restent `not-run`. Les anciennes conditions bloquantes sont historiques pour cette livraison. Voir `docs/DECISIONS.md`, `docs/LIVRAISON-FINALE.md` § 0 et `docs/RECETTE-MANUELLE-V2.0.0.md`.
- **Dernier lot fabriqué et contrôlé** : source `4ec63be686895aa46469877a7711c1cd87965cf2`, [run Windows 40231087873](https://github.com/M4D135/domenia-d120/actions/runs/40231087873) réussi : Debug/Release 0 erreur/avertissement, 587 C# critiques, 15 + 7 contrôles Python, 69 Web critiques et 6 scénarios UI en simulation réussis. Intégrité des deux archives et démarrages sur runtimes privés vérifiés ; [release v2.0.0 publiée](https://github.com/M4D135/domenia-d120/releases/tag/v2.0.0) avec PROD, DEV et SHA256SUMS.txt, tag et empreintes relus sur GitHub. Les assistants ont examiné 20 captures avec limites ; recette utilisateur et appréciation visuelle humaine en attente. Les 1 792 autres tests C# enregistrés restent non exécutés. Lire `docs/reprise/rapports/RAPPORT-LIVRAISON-MANUELLE-V2-20261025.md` pour les SHA256, preuves et limites ; ne pas attribuer aux archives le SHA d'une mise à jour documentaire ultérieure.
- **Domenia 1** : dans `dev/` (branche `master`), en lecture seule. C'est la référence de parité.
- **À lire en entier avant toute action** :
  - `v2/REPRISE.md` : consignes actives en § 0, règles techniques en § 5 ; § 4 bis conservé comme historique du 22/10 ;
  - `v2/CLAUDE.md`, `v2/ARCHITECTURE.md` ;
  - `v2/docs/DECISIONS.md` : toutes les décisions datées de David, à respecter ;
  - `v2/docs/PLATFORM.md`, `KIT.md`, `WRITES.md`, `OPERATIONS.md`, `SIMULATION.md`, `E2E.md`, `CAPTURE.md` ;
  - `v2/docs/features.json` et `FEATURES.md` : inventaire historique de 993 fonctions, sans certification globale ni taux d'achèvement déduit ;
  - `v2/docs/reprise/DEMANDE-MISES-A-JOUR-DEMO-20261025.md` et les derniers rapports de `v2/docs/reprise/rapports/` ;
  - `v2/docs/VALIDATION-WINDOWS-CI.md` et `v2/docs/LIVRAISON-FINALE.md`.
- **Préversion déjà publiée** : release `v2.0.0-preview.1` (commit `5b27d58`).

## 1. Reprise GitHub et inventaire des écarts

La décision du 25/10/2026 remplace le précédent mode Spark/OpenCode. Ne pas arrêter de démon, modifier un arbre Spark/Mac ni récupérer des fichiers locaux supposés. Le lot123 Spark/Mac n'est pas présent sur GitHub ; ne pas prétendre le posséder. Préserver tous les travaux concurrents.

1. Vérifier la branche, son historique, les modifications locales et le dernier commit distant avant toute écriture. Utiliser une branche dédiée et des commits français.
2. Lire les documents ci-dessus et confronter les restes annoncés aux consommateurs réels dans le code. Un backend isolé ou un statut historique du catalogue ne prouve pas une fonctionnalité terminée.
3. Priorités de reprise : reprises108, réglages124/125 appliqués, reprise durable Accueil249 jusqu'à l'UI, collectes widgets290–292, CLI067 locale en lecture seule, puis écarts réels du catalogue.
4. Distinguer les fichiers présents sur GitHub, les changements locaux de cette reprise et les preuves de validation. Si l'accès GitHub devient uniquement en lecture, l'annoncer et fournir des patches applicables.

## 2. Mission et ordre de validation

1. **Terminer le développement autorisé**, y compris les mises à jour GitHub/partage/ZIP, la démonstration isolée et la configuration diffusée décrites dans les documents de reprise. Vérifier chaque raccordement moteur, stockage et UI ; ne pas se contenter d'un contrat ou d'un DTO.
2. **Compiler Debug et Release sans erreur ni avertissement**. Le workflow `.github/workflows/domenia-v2-windows.yml` compile le SHA poussé sur Windows avec le SDK déjà installé et les seuls paquets versionnés. Ses résultats ne concernent que ce SHA et ne constituent pas une recette fonctionnelle. Aucun SDK, runtime ou paquet ne doit être téléchargé pour résoudre un manque.
3. **Commit/push du développement terminé**, avec rapports exacts et préservation des travaux concurrents.
4. **Exécuter seulement les sélections CRITIQUES autorisées après commit/push**, sur Windows GitHub Actions avec les composants déjà disponibles. Conserver les résultats et échecs rattachés à leur SHA. Les tests écrits ou compilés ne sont pas des tests réussis ; aucune suite exhaustive n'est demandée par la décision actuelle.
5. **Conserver les validations absentes** : `CNAMTS-DC01`, `DOMENIA-FIRSTRUN-20261020` et la recette domaine/UI/native restent `not-run`. Un runner Windows et des scénarios de simulation ne les remplacent pas. Le parcours strict `release-guard.py` reste disponible et inchangé, mais n'a pas réussi sans ces preuves ; ne jamais annoncer `eligible:true` à partir de ses seuls tests unitaires verts. Ne pas reconfigurer réseau, services ou runtime pour obtenir l'accès aux VM.
6. **Préparer les packs autonomes PROD/DEV** avec les mêmes exécutables, sources rattachées au commit, guides et inventaires exacts. Les dépendances restent celles déjà présentes ou versionnées ; les copies privées qualifiées de runtimes sont permises sans téléchargement ni installation. Vérifier les octets et le démarrage du pack exact. Une simple sortie de compilation dépendant du runtime global ne suffit pas.
7. **Livrer PROD/DEV v2.0.0 et leurs SHA256 selon l'autorisation manuelle du 25/10**, après les contrôles d'intégrité, de provenance et de préparation du lot exact décrits dans `docs/LIVRAISON-FINALE.md` § 0. Tout défaut de ces contrôles bloque le paquet concerné. Joindre le guide de recette manuelle, annoncer `userManualAcceptance: pending` et les validations non exécutées ; aucun build, manifeste ou code zéro ne vaut approbation métier. Cette autorisation est distincte de la qualification stricte des deux VM.
8. Réconcilier les statuts du catalogue uniquement avec des preuves ciblées ; ne pas déduire un taux d'achèvement des anciens statuts. Tenir `REPRISE.md` et les rapports à jour.

Une fois les archives figées, conserver leur commit source, leurs octets et leurs SHA256. Une mise à jour documentaire ultérieure ne reconstruit pas les archives et ne remplace pas leur provenance par son propre commit.

## 3. Exigences de David (non négociables)

- **Parité** : autant de fonctions que Domenia 1, voire plus. Rien ne disparaît sans décision écrite. Seule exception à ce jour : WAPT (PST-001), abandonné, à ne jamais réintroduire.
- **Interface** : superbe, « web 4.0 », très animée mais propre et bien disposée, cohérente avec l'Accueil et le kit `v2/web/js/kit`. Thèmes clair, sombre et contraste élevé.
- **Portabilité** : pack autonome, à dézipper et lancer, rien à installer.
- **Mode simulation** : il doit rester intact (annuaire fictif `example.local`, écritures en mémoire seulement).
- **Accueil** : pas de prénom ; le compte d'administration s'affiche en puce.

## 4. Règles techniques

- **C#** :
  - Nullable activé, avertissements traités comme erreurs, `AnalysisLevel latest` : **0 avertissement** ;
  - commentaires en anglais, textes visibles en français soigné.
- **Web** :
  - CSP stricte : aucun `style="…"`, aucun script inline, `connect-src 'none'`, aucune ressource externe ;
  - modules ES natifs ;
  - un écran = `web/js/pages/<id>.js` et `web/css/pages/<id>.css`, avec des règles préfixées `[data-page="<id>"]`.
- **Écritures** :
  - uniquement par le circuit de `WRITES.md` : plan, jeton à usage unique, confirmation par saisie du nom, reçu, relecture ;
  - jamais de rejeu automatique ;
  - mots de passe en `SecureString` jusqu'à l'API Windows.
- **Sécurité** :
  - lecture seule par défaut ;
  - aucun accès réseau sans geste explicite ;
  - jamais tout le domaine sans garde ;
  - aucun secret dans le dépôt, un journal ou une ligne de commande.
- **Où compiler et lancer** :
  - compilation Windows dans GitHub Actions ou dans les VM autorisées, avec les composants déjà disponibles ;
  - aucune compilation ni installation de runtime sur les anciens hôtes Mac/Spark ;
  - recette manuelle du pack par David selon le guide ; le parcours strict des deux VM reste non exécuté tant que ses preuves réelles manquent ; aucun reboot/logoff, fermeture de session ou arrêt de service ;
  - aucune suppression de dossiers de travail ou de preuves concurrentes pour libérer de l'espace ; conserver un échec et sa cause si un prérequis manque.
- **Laboratoire** : écritures AD autorisées uniquement dans `OU=Domenia-Tests,DC=cnamts,DC=local`. Aucune dépendance téléchargée ni changement service/runtime/réseau.
- **Interdictions** : n'affaiblis jamais un test ou une garde pour faire passer quelque chose ; ne touche pas à `dev/` (Domenia 1).
- **Commits** : en français, poussés sur la branche dédiée ; ne pas forcer une référence ni mélanger les travaux concurrents.
- **Suivi** : tiens `v2/REPRISE.md` à jour, surtout la § 0, pour qu'une autre relève puisse reprendre.
- **En cas de doute** : n'invente pas. Écris la question dans `REPRISE.md`, prends la décision la plus sûre et continue.

Commence par vérifier les sources GitHub et les écarts prouvés, puis réalise des lots complets. Poursuis la livraison manuelle v2.0.0 autorisée avec les contrôles réels du lot exact ; conserve explicitement les blocages, la recette utilisateur en attente et les preuves manquantes.

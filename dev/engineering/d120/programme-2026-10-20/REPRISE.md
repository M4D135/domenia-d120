# Reprise RC1.17.39 et programme des 60 points

## État réel au troisième checkpoint du 20 octobre 2026

**Code intégré, qualification critique en cours, livraison non terminée.** Master reste `4987773325c0849129960c35b50790396ac1fc2b`. Premier checkpoint vérifié : `7a3376a98c60e2c04926f775761a92dce77c7b77`, branche `codex/rc39-60points-checkpoint`. Les ZIP publiés sur master restent RC38 ; les candidats RC39 sont dans `../../rc39-local-first/packs` (174 fichiers applicatifs identiques DEV/PROD).

Dernière instruction : OpenCode/Spark, contrôle indépendant, puis tests Windows **critiques seulement**, corrections, packs DEV/PROD, intégration master et push. Garder la VM. Pousser le suivi aux étapes importantes. Le runner `Verify-Critical.ps1` vient d’être lancé sur une copie fraîche `RC39-critical` ; résultats `rc39-critical-tests`. Ne pas lancer un second runner. Première passe terminée : démarrage/import natif réussi, compatibilité PS5.1 sans erreur, 7 suites critiques réussies sur 10. Trois fixtures ont oublié un import réel (LocalPreview, LiveSearchView, un cas WiringCache) : corrigées, relances ciblées en cours. Dernier checkpoint distant vérifié avant cette mise à jour : 50bf14a4878206868bbf0074d51cfba0d19a07a4.

Spark puis GLM gratuit ont épuisé leur génération sans patch (GLM : 32 000 tokens de raisonnement, aucun texte de sortie, coût déclaré nul). Le passage OpenCode GLM gratuit en variante low, avec fonctions complètes ciblées et prompt transmis par stdin, a produit les correctifs. Spark/OpenCode reste utilisé pour les guides puis la revue ; aucune écriture du runtime pendant les tests.

## Code réalisé

- Collectes 18–29 : délais bornés par sonde, sondes rapides avant lentes, réutilisation de cache correctement désactivable, budgets CIM incluant l’identité, reprise après défaut SQL, clôture par familles réellement observées, suppression AD fondée sur preuves. Voir `Lot-collectes.md`.
- Interface 30–48 : Premiers pas interrompus/hors connexion, pertinence mail/jokers, absence contextualisée, dispositions Support/Inventaire/Santé, réutilisation ciblée des cartes simples, historique et santé avec provenance/date, accès à la collecte manquante. Voir `Lot-parcours.md`.
- Stockage 49–54 : rotation bornée, contrôle de copie SQLite, restauration de préférences par annexe `.db.preferences.json` liée au SHA256, conservation des chemins actifs et identités, retour des préférences en cas d’échec, diagnostic expurgé. Voir `Lot-stockage.md`.
- Recherche et affichage : aperçu mémoire/SQLite avant AD, données connues conservées sur échec, identité/époque vérifiées, projection des lignes accélérée et présentation inconnue partagée par recherche, réutilisation de fiche identique. Gains de performance **non validés** sur ce code.
- Extraction de `Set-RowAssociationMetadata` dans un module dédié intégrée au registre ; corps conservé, nouveau banc non exécuté.

## Correctifs et contrôles encore ouverts

1. Course aperçu local **corrigée** : le tick détache CacheProgress uniquement après Ended sans Error, avant le choix de cadence. Le callback reste autorisé pendant SQL pending et après échec. Test causal avec 201 lignes ajouté ; sa preuve Windows reste à obtenir.
2. Python : les 8 échecs/1 erreur initiaux sont corrigés ; les 35 contrôles ciblés relancés passent (13 sur fixtures/langue/traces, 22 sur briques/workers/documents). BOM du JSON retiré, déclaration CommonLibrary alignée sur DLL inchangée déjà approuvée, fixtures d’incidents/opérations rendues indépendantes des données historiques, messages accentués, catch tracé. Pas de nouvelle campagne complète relancée.
3. Registre, migration, 97 contrats workers, manifeste et version régénérés. L’audit du build a trouvé une erreur d’intégration : refresh avait absorbé l’entrée Live.UI après extraction AssociationRows. Entrée restaurée, audit fermé PASS (132 modules, 3740 fonctions), build DEV/PROD réussi. Preload rebaseliné après revue explicite ; ce contrôle statique ne remplace pas Windows.
4. Compléter la revue des points 1–17 et 55–60, relire le diff de tous les lots ; mettre Suivi_60 à jour à partir des preuves, pas des intentions.
5. Guides et métadonnées : textes RC39 mis à jour et guides DOCX/PDF régénérés, contrôle visuel en cours ; captures anciennes RC20 à conserver comme historiques, sans leur attribuer une nouvelle provenance. Refaire les documents si sources modifiées.
6. Après fin du code : tests critiques seulement, puis corrections ciblées, packs DEV/PROD exacts et preuves liées aux SHA256. Qualification étendue, endurance longue et observation humaine restent distinctes.

## Orchestration et commandes

Dépôt : `work/opencode-supervision-rc14/isolated-checkout`. Remote de livraison : `https://github.com/M4D135/domenia-d120.git`. **origin désigne un ancien bundle local, ne pas pousser origin.** Ne pas effacer les modifications concurrentes.

File locale OpenCode : `../stockage-20261020/run-opencode.py --prompt-file CHEMIN`. Session race : `ses_ea518d676ffeLFsGBFFH7tsgWV`, log `turn-20261020T200100Z.jsonl`. Un seul appel Spark pour ce projet. Jeton lu uniquement en mémoire depuis la configuration privée ; jamais dans Git ou dans les sorties. Ancien tour backup interrompu sans fichier produit : ne pas attendre Test-DomeniaBackupQualification.ps1.

Contrôles et construction depuis le dépôt :

```sh
python3 dev/tools/integrate_lots.py --refresh-functions --apply
python3 dev/tools/update_migration_worker.py --apply
python3 dev/tools/update_worker_contracts.py --apply
python3 dev/tools/release_contract.py --stamp
python3 dev/tools/validate_powershell_static.py
python3 dev/tools/build_packages.py --output ../../rc39-local-first/packs
```

Le contrôle lexical a passé sur 347 fichiers avant les dernières modifications. Ce n’est pas une preuve PowerShell 5.1.

## Labo à conserver

VM `DOMENIA-FIRSTRUN-20261020`, UUID `bc2f1ac0-9545-49bd-a0f5-cb89d352cf61`, 1 vCPU / 4 Go, hôte `degun@192.168.1.173`. Dernier état observé : running. Aucun mot de passe à lire ni à consigner. Accès guestcontrol par fichier opaque existant. Ne pas modifier AD, réseau, sécurité ni configuration VM.

Harnais locaux prêts : `../../rc39-local-first/Verify-Critical.ps1`, `Critical-UI.ps1`, `Live-Timeout.ps1`. Le premier runner critique est terminé ; relances ciblées des trois fixtures en cours. Critical-UI et Live-Timeout restent à exécuter après lui. Le runner critique couvre démarrage/import natif, recherche/aperçu, stockage/restauration, WMI et santé. Le vieux Verify-60 de 34 suites est abandonné : ne pas le lancer. Candidats déployés dans les dossiers neufs RC39-critical et RC39-critical-ui ; régénérer les archives finales après documentation, puis vérifier leur identité applicative. Helper de transfert `../../rc38-final/lab.py` ; pour récupérer les résultats, utiliser les dossiers hôte uniques de `../../rc35-qualification/pull.py`, pas un fichier ancien susceptible d’être réutilisé.

Aucune mesure avant/après RC39 concluante ; ne pas annoncer de qualification complète ni de commit final de livraison avant les reçus correspondants.

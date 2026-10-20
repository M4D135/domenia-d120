# Reprise RC1.17.39 et programme des 60 points

## État réel au checkpoint du 20 octobre 2026

**Travail en cours, pas de nouvelle livraison qualifiée.** Base master : `4987773325c0849129960c35b50790396ac1fc2b`. Les packs publiés restent RC1.17.38. La branche `codex/rc39-60points-checkpoint` sauvegarde le code courant et ce suivi, même si les contrats et manifestes doivent encore être régénérés. Ne pas distribuer ses anciens ZIP comme RC39.

Dernière instruction : OpenCode/Spark pour économiser Codex ; contrôle indépendant ; code d’abord, puis tests Windows **critiques seulement**, correction des échecs, packs DEV/PROD, intégration master et push. Garder la VM. Pousser le suivi aux étapes importantes. Aucun test Windows de cette nouvelle passe n’a démarré.

## Code réalisé

- Collectes 18–29 : délais bornés par sonde, sondes rapides avant lentes, réutilisation de cache correctement désactivable, budgets CIM incluant l’identité, reprise après défaut SQL, clôture par familles réellement observées, suppression AD fondée sur preuves. Voir `Lot-collectes.md`.
- Interface 30–48 : Premiers pas interrompus/hors connexion, pertinence mail/jokers, absence contextualisée, dispositions Support/Inventaire/Santé, réutilisation ciblée des cartes simples, historique et santé avec provenance/date, accès à la collecte manquante. Voir `Lot-parcours.md`.
- Stockage 49–54 : rotation bornée, contrôle de copie SQLite, restauration de préférences par annexe `.db.preferences.json` liée au SHA256, conservation des chemins actifs et identités, retour des préférences en cas d’échec, diagnostic expurgé. Voir `Lot-stockage.md`.
- Recherche et affichage : aperçu mémoire/SQLite avant AD, données connues conservées sur échec, identité/époque vérifiées, projection des lignes accélérée et présentation inconnue partagée par recherche, réutilisation de fiche identique. Gains de performance **non validés** sur ce code.
- Extraction de `Set-RowAssociationMetadata` dans un module dédié intégrée au registre ; corps conservé, nouveau banc non exécuté.

## Correctifs et contrôles encore ouverts

1. Course aperçu local : après succès LDAP, pendant dernier commit SQL, un callback tardif peut remplir CacheProgress ; une recherche terminée garde alors le timer actif. OpenCode/Spark prépare le patch et le cas 201 lignes dans Live.UI / LocalPreview.UI / Test-DomeniaLiveSearchView. **Aucun patch reçu à ce checkpoint.** Préserver l’aperçu quand AD échoue.
2. Python : 184 tests exécutés, 8 échecs et 1 erreur avant régénération. BOM du JSON d’aide corrigé ; ancienne empreinte de CommonLibrary.json alignée sur DLL inchangée déjà épinglée dans Modules et release-contract. Restent fixtures delivery_recipe (quota périmé de cinq incidents), operation_table (StorageRetention n’est plus fictif), deux textes Storage.UI sans accents, catch vide Widgets.UI, contrats workers à régénérer. Relancer les modules échoués après correction, pas toute la campagne sans raison.
3. Régénérer registre des fonctions, migration, contrats workers et manifestes. Rebaseliner preload après revue explicite : extraction AssociationRows, conservation de fiche et cache Live changés volontairement. Ne pas masquer un échec fonctionnel par une baseline.
4. Compléter la revue des points 1–17 et 55–60, relire le diff de tous les lots ; mettre Suivi_60 à jour à partir des preuves, pas des intentions.
5. Guides et métadonnées : textes RC39 à mettre à jour ; captures anciennes RC20 à conserver comme historiques, sans leur attribuer une nouvelle provenance. Refaire les documents si sources modifiées.
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

Harnais locaux prêts : `../../rc39-local-first/Verify-Critical.ps1`, `Critical-UI.ps1`, `Live-Timeout.ps1`. Ils sont copiés dans la VM mais **non exécutés**. Le runner critique couvre démarrage/import natif, recherche/aperçu, stockage/restauration, WMI et santé. Le vieux Verify-60 de 34 suites est abandonné : ne pas le lancer. Déployer le pack final avant tout test. Helper de transfert `../../rc38-final/lab.py` ; pour récupérer les résultats, utiliser les dossiers hôte uniques de `../../rc35-qualification/pull.py`, pas un fichier ancien susceptible d’être réutilisé.

Aucune mesure avant/après RC39 concluante, aucune réussite Windows de cette passe ni commit final de livraison ne doivent être annoncés avant les reçus correspondants.

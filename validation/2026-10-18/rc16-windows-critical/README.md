# RC1.17.16 — qualification Windows des quatre parcours critiques

**Résultat : contrôles ciblés réussis, 96 cas natifs sans échec.** Qualification exécutée le 18 octobre 2026 dans CNAMTS-W11-01 (nom invité W11-01), Windows PowerShell **5.1.26100.6584 x64 STA**. La fenêtre de connexion du pack PROD a aussi été réellement affichée et contrôlée en session interactive 1. Aucun test ni application exécuté sur l’hôte relais.

Demande : démarrage, lot WMI, santé et sauvegarde seulement, sans grande campagne VM. Sources testées : commit `1a8cd5a2875dbec1488bf31ab77d715d53918f5a`. Les ZIP existants ont été copiés et extraits dans `C:\DomeniaLab\d120-rc11716-critical`, sans modification du runtime.

| Archive | SHA-256 |
|---|---|
| PROD | `fdfd170c74823f318731e581fec7504dd47a0363933d10aa5fc0366361e95f2a` |
| DEV | `1c0c97ce8f51c5ebfff005277c6a26d72824efc46d360727358b6df920662f64` |

Les 172 fichiers PROD et 642 fichiers DEV sont vérifiés contre leurs manifestes avant **et après** les essais. Les 172 fichiers du runtime sont identiques entre éditions. Les tests fournis dans le ZIP DEV exercent donc le runtime livré dans PROD. `Environment.json` et `FinalIntegrity.json` portent ces contrôles ; `Qualification.json` lie les rapports et la capture par leurs empreintes.

## Résultats

| Parcours | Vérification exécutée | Résultat / preuve |
|---|---|---|
| Démarrage | `Domenia-Start.ps1 -CheckOnly` des deux éditions : intégrité, syntaxe et imports réels des 130 modules | 2 retours zéro, `Runs.json` et journaux `Startup-*` |
| Démarrage interactif | Lancement normal du véritable `prod\Domenia.exe` ; fenêtre « Domenia · Connexion », bouton de connexion et champ mot de passe présents ; fermeture ensuite | Réussi en session 1, `InteractiveStartup.json`, `login.png` |
| Initialisation / connexion | Banc natif Windows `Test-DomeniaStartupLogin.ps1` | **48/48**, aucun cas ignoré, `StartupLogin.json` |
| Lot WMI | Deux cas RC11711 de ParkDetection : échec par délai injecté, enregistrement, attente pendant le nettoyage/saturation puis traitement du poste suivant ; variantes avec/sans ordonnanceur et inventaire | **2/2**, `WmiTimeoutHandoff.json` ; réseau simulé explicitement |
| Progression du lot | Lot visible entre deux workers, avant les workers, préparation OU, exclusion des lots obsolètes et lots simultanés indépendants | **5/5**, `BatchActivity.json` |
| Santé | Règles, couverture/inconnus, séparation AD/ping/WMI, populations exactes, recettes à révision figée, héritage OU, suspensions UTC et comparaisons | **20/20 + 17/17**, `HealthRules.json`, `HealthAdvanced.json` |
| Sauvegarde | Export SQLite autonome lisible sans fichiers WAL ; restauration vers cible distincte ; conservation sélective ; refus/rollback d’une confirmation périmée | **4/4, 22 assertions**, `StorageMaintenance.json`, véritable `winsqlite3.dll`, bases temporaires |
| WMI local | Lecture réelle `Get-CimInstance Win32_OperatingSystem` sur W11-01 | Réussie, `LiveLocalWmi.json` ; contrôle du fournisseur local, pas du worker distant de Domenia |

Les neuf commandes automatisées retenues passent, sans dépassement de leur délai ; durée cumulée d’exécution d’environ 131 secondes, hors transfert et préparation. Les calculs de santé utilisent des données synthétiques ; ils ne constituent pas une vérification visuelle du tableau de bord. Le libellé historique RC1.6 contenu dans le banc StartupLogin est celui du test : le code exécuté est bien celui du ZIP RC1.17.16 dont l’empreinte est donnée ci-dessus.

## Incidents du banc, puis vérification finale

La première tentative n’est pas une preuve de qualification : le pilote PowerShell ne conservait pas le handle du processus et enregistrait un code retour nul malgré la réussite du contrôle de démarrage. De plus, `Domenia.exe --check` lancé en session 0 est resté en attente et a été interrompu. `HarnessAttempt1.json` conserve ces résultats non retenus. Aucun succès du mode EXE `--check` n’est revendiqué.

Le pilote a été corrigé pour conserver le handle avant l’attente. Les contrôles script PROD/DEV et les suites ciblées ont ensuite été exécutés avec leurs vrais codes retour et rapports. Le lancement EXE normal a été vérifié séparément, dans la session ouverte par l’utilisateur, sans soumettre d’identifiant ni de mot de passe. Les scripts de reproduction sont dans `harness/` ; le relais `dev/engineering/d120/lab/lab.sh file` utilise uniquement le chemin du fichier de mot de passe déjà configuré, jamais sa lecture.

La tâche planifiée interactive temporaire a été supprimée et l’application de test fermée. La VM reste démarrée. Les archives et les 814 fichiers suivis par leurs manifestes sont inchangés ; aucune correction produit ni reconstruction de pack n’a été nécessaire.

## Limites maintenues

- **Aucune connexion AD ni collecte WMI distante réelle** : le timeout du lot est injecté aux frontières réseau, puis les vrais callbacks et décisions de reprise sont exercés. La lecture CIM locale ne remplace pas cette qualification distante.
- Sauvegarde/restauration/conservation vérifiées par les workers sur bases temporaires ; cycle automatique complet, restauration via l’interface après corruption et volume de 400 000 lignes restent à qualifier.
- Aucun parc représentatif de 10 000–20 000 postes, aucune grande campagne UI/VM, aucune désinstallation de profil et aucun renouvellement des 56 captures historiques.
- **Aucun `acceptance_passed` global ajouté.** Les décisions externes **134** (coordination Pesto/FilPro et dépôt amont) et **146** (droits de redistribution) restent ouvertes. Les ZIP conservent leur statut de candidats ; `Publishable` reste faux.

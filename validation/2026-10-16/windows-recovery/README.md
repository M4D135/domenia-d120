# Reprise Windows — candidat RC1.17.10

**Incident signalé après livraison : RC1.17.9 échoue à l’initialisation sur le poste
de l’utilisateur (capture reçue, incident INC-FA6D). Ce code est un identifiant
aléatoire, pas une cause. Le défaut a été reproduit avec le ZIP exact dans la VM,
puis corrigé en RC1.17.10.**

La boucle exécutée avant le login convertissait une `List[object]` en tableau
avec `@(...)`, ce qui provoque `Argument types do not match` sous PowerShell 5.1.
Elle énumère désormais directement la liste. Le test ciblé extrait la vraie boucle
du cœur : les cas liste vide et avertissements échouent tous deux sur RC1.17.9,
puis passent tous deux sur RC1.17.10. Le self-test existant retournait avant cette
boucle ; il ne couvrait pas ce chemin de démarrage.

Le ZIP PROD RC1.17.10 exact a ensuite été lancé par `Domenia.exe` dans la session
interactive de CNAMTS-W11-01. UI Automation confirme le titre « Connexion », le
bouton de connexion et le champ de mot de passe visible après « Utiliser un autre
compte ». Aucun identifiant n’a été soumis et aucune connexion AD n’a été effectuée.
La console était verrouillée : la capture GDI a échoué ; ce contrôle n’est donc
pas une qualification visuelle. Les preuves et le SHA-256 du ZIP sont dans
`startup-fix/`. La revue ciblée Spark n’a signalé aucun défaut du correctif.

Les corrections rétablissent le chargement WPF de Support, la préférence de thème,
les sections d’Automate, la validation de fraîcheur et les lectures de dictionnaires
génériques sous Windows PowerShell 5.1. Une propriété dont le getter échoue remonte
désormais l’erreur ; la protection en lecture seule conserve ainsi son refus.
Le lanceur natif est inchangé.

La construction RC1.17.9 passe tous ses contrôles : manifestes, empreintes,
chargement fermé, compatibilité statique, contrats, documentation, licences et
code compilé. Les 50 tests du garde de release passent. Les deux ZIP contiennent
les mêmes 172 fichiers d’exécution ; DEV contient 633 fichiers hors son manifeste.
Le contrôle de l’inventaire des licences vérifie sa cohérence : il ne lève pas
ses réserves existantes sur M4D.Admin.Common, les DLL RSAT et PsExec.
La construction RC1.17.10 repasse ces mêmes contrôles et contient 634 fichiers
DEV hors manifeste, avec le nouveau test de démarrage. Les rapports des deux
constructions restent conservés ; `build-report.json` désigne RC1.17.10.

Les contrats composés **LocalStore** et **LegacyMigration**, ainsi que l’empreinte
du registre des opérations, ont été régénérés après revue. Les fixtures suivent le
schéma SQLite produit par le code et le contrat actuel des projections CIM.
Les assertions de comptage complet, de tableaux typés, de budget et de chaîne
maximale sont conservées ; aucun seuil de production n’a été abaissé.

## Preuves ciblées

Exécutions dans CNAMTS-W11-01, Windows PowerShell 5.1 x64 STA. Les rapports copiés
ici sont indexés avec SHA-256 dans `proof-index.json`. Ils précèdent l’estampillage
de version RC1.17.9 : ils ne constituent pas une qualification des ZIP finaux.

| Contrôle | Résultat observé |
|---|---|
| Interface | 52 réussites, 0 échec |
| Tri de l’index | 545 réussites, 0 échec |
| Persistance de l’index | code de sortie 0, sans timeout |
| Régressions Common | 2 réussites, 0 échec |
| HealthRules | 10 réussites, 0 échec |
| Règles P-CD-09 | 10 réussites, 0 échec |
| Composition des workers | code de sortie 0, sans timeout |
| EngineResilience, dernier lot | 52 réussites, 0 échec, 4,74 s |
| LoadStability, dernier lot | limite de 3 600 s atteinte, aucun rapport final ; non validé |
| Parseur Windows natif | PASS ; workers, WPF et domaine non qualifiés par ce contrôle |

Les essais antérieurs ont également validé Support (54/0), Theme (32/0),
Automate (7/0), Main (388/0), Freshness et DnScopes. Leurs originaux restent dans
le dossier local `Domenia-lab/runs/` ; ils ne sont pas présentés comme des essais
du ZIP final. La revue Spark du diff n’a déclaré aucun défaut ; elle ne remplace
pas les résultats exécutés.

## Limites et suite

La campagne générale a été interrompue par l’incident VM. Son relevé partiel
`interrupted-baseline-suites.json` reste historique : plusieurs suites ont depuis
été corrigées, d’autres échecs demeurent, notamment Geometry, SearchPresence,
SearchCounter, Navigation, LastUser, OperationTrace et Boards. Installer avait
atteint son délai. Aucune nouvelle campagne générale n’est lancée, conformément
à la demande de David de limiter les dépenses pour les essais VM.

La résolution visible de la console reste 1710 × 948. Aucun parcours interactif
≥ 1080p n’est revendiqué. Les illustrations documentaires WPF hors écran et les
données fictives ne prouvent pas un parcours humain ni un accès à AD réel.

Les qualifications 41, 43, 106, 114, 116, 125, 126, 129 et 130 du registre
EXECUTION restent ouvertes. Aucun `acceptance_passed` n’est changé. Les packs
DEV/PROD classiques restent des candidats avec `Publishable=false` tant que la
preuve Windows liée aux deux ZIP et les autres conditions du garde manquent.

## Incident VM

Après le nettoyage du disque plein par David, un ancien backend VirtualBox
conservait le journal verrouillé alors que la VM était arrêtée. Ce seul processus
orphelin a été fermé, le journal préservé, puis CNAMTS-W11-01 a redémarré à 09:41.
David a ouvert sa session. Aucune autre VM ni règle de sécurité Windows n’a changé.

Les résultats du dernier lot sont conservés dans `Resilience-recovered/` et
`LoadStability-recovered/`. Le test de charge n’est pas relancé. La correction du
démarrage RC1.17.10 dispose de ses preuves distinctes dans `startup-fix/`.

La reprise des captures a révélé deux dépendances manquantes du harnais :
`Write-DomeniaSwallowed` et `Domenia-HealthRules.Model.ps1`, désormais chargées.
L’essai sur le PROD RC1.17.10 produit Accueil et Actualisation OU en haute
résolution, puis s’arrête à l’Atelier, faute de `Get-DomeniaSavedQueryRecipes`.
Il reste non validé ; ses images partielles ne remplacent pas les 28 illustrations
existantes des guides. Le correctif de cette dépendance et la série complète sont
différés pour respecter la demande de limiter les essais VM. Les guides DOCX/PDF
1.0 (30 et 80 pages) et leurs empreintes sont décrits dans `documentation-qa.json`.

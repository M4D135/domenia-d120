# RC1.17.15 — suspensions de santé et échéances UTC

Correction directe autorisée par David le 18 octobre 2026, sans test VM.
Base : `4a4fb4122f3b358565ce92c97b02004ec7512472` (RC1.17.14 livré).

## Défaut reproduit et correction

Le cas `Suspension validates UTC expiry, reason, uniqueness and domain inheritance`
échouait lors de la copie JSON effectuée par `Set-DomeniaHealthScopePolicy`.
PowerShell 7.4.6 matérialise la chaîne ISO UTC en `System.DateTime` (`Kind=Utc`).
Le cast `[string]` produisait `10/14/2026 12:00:00`, sans marqueur UTC : le validateur
rejetait alors une échéance initialement valide. Ce défaut de conversion ne dépend pas de Linux.

`ConvertTo-DomeniaHealthSuspensions` conserve désormais la représentation ISO invariante
pour `DateTime` UTC et `DateTimeOffset` à décalage zéro. Les dates locales, sans fuseau
ou à décalage non nul restent refusées. Les limites, le motif et l’unicité restent vérifiés.
Le cas historique reçoit une horloge explicite pour ne pas dépendre de la date de lancement.

Deux cas ajoutés couvrent les chaînes et objets typés, les cultures fr-FR/en-US, la relecture
JSON, l’expiration exacte et les rejets stricts/non stricts des dates ambiguës.

## Vérifications exécutées

Moteur : PowerShell **7.4.6 arm64 natif sur macOS**, archive Microsoft officielle dont
le SHA-256 a été vérifié. Aucun appel AD, WPF ni VM.

| Suite | Cas réussis | Échecs | Rapport |
|---|---:|---:|---|
| HealthAdvanced | 16 | 0 | [JSON](HealthAdvanced.json) |
| HealthPolicies | 9 | 0 | [JSON](HealthPolicies.json) |
| HealthRules | 20 | 0 | [JSON](HealthRules.json) |
| **Total** | **45** | **0** | |

Le cas RC14 du point 78 est inclus dans HealthAdvanced. Les points 9 et 10 ne sont pas modifiés.
Le garde-fou de compatibilité 5.1 passe sans erreur ([rapport](ps51-compat.json)).
L’analyse lexicale passe sur 337 fichiers PowerShell ; le parseur natif Windows n’est pas exécuté.
Le contrat `LocalStore` et l’empreinte du registre worker ont été ré-épinglés après revue
car la charge inclut le modèle santé ; aucune autre opération n’est modifiée.
Le contrôle preload passe après ce ré-épinglage ([rapport](preload.json)).

Les packs RC1.17.15 sont reconstruits depuis ces sources avec les manifestes de démarrage
actualisés. Les vérifications d’archives couvrent l’intégrité ZIP, chaque SHA-256 interne,
la liste des fichiers et l’identité du runtime DEV/PROD ; voir `build-report.json`.

## Portée

Ces résultats valident les règles pures et la cohérence des sources et archives.
**La qualification Windows PowerShell 5.1/WPF sur AD reste ouverte.**
Aucun `acceptance_passed` n’est relevé ; `Publishable` reste faux sans cette preuve
et sans clôture des conditions de redistribution déjà suivies.

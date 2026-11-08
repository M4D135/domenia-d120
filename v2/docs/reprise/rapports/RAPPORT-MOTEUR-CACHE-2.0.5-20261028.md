# Domenia 2.0.5 — connexion, moteur et cache, 28 octobre 2026

Connexion avec nom simple et identifiant mémorisé facultatif, Atelier guidé et bibliothèque enrichie, Accueil personnalisable, campagnes par sous-OU avec reprise durable, moteur de lecture temporisé, cache par nature de donnée, comptes protégés et quatre méthodes optionnelles de collecte temporaire. Le look et les animations sont conservés.

Source compilée : `003fc51e6440f0dbab972910159bf0ddaabfb7a8`. [Release v2.0.5](https://github.com/M4D135/domenia-d120/releases/tag/v2.0.5), publiée à `2026-10-28T16:16:57Z`, identifiant `426902668`.

## Vérifications

[Compilation Windows Debug/Release](https://github.com/M4D135/domenia-d120/actions/runs/40719585287) et [fabrication des packs](https://github.com/M4D135/domenia-d120/actions/runs/40719585149) réussies sur le commit indiqué. Résultats exacts : {"csharp_full_passed": 2578, "csharp_critical_passed": 931, "harness_self_tests": 25, "release_guard_tests": 15, "manual_package_verifier_tests": 11, "browser_evidence_verifier_tests": 10, "web_critical": 103, "simulation_scenarios": 7}. La suite C# complète est contrôlée en plus de la sélection critique ; les preuves sont conservées avec les logs de livraison.

Intégrité des ZIP et manifestes vérifiée localement ; sources DEV comparées aux blobs Git du commit. PROD et DEV partagent le même exécutable : `96e7459ed75fc3b085952fb18c193adae015a278869c6a19dca4e5e0c402034d`. SHA256 GitHub concordants avec les fichiers locaux, sans reconstruction pour publier. 6 releases antérieures et 18 assets conservés.

| Pack | Archive | Octets | SHA256 |
| --- | --- | ---: | --- |
| **PROD** | [Domenia_2.0.5_PROD_Windows-x64.zip](https://github.com/M4D135/domenia-d120/releases/download/v2.0.5/Domenia_2.0.5_PROD_Windows-x64.zip) | 485719887 | `730345aa4699c0ee751347387f44b6a19595fe274589f172d3d0b7edbc9412d4` |
| **DEV** | [Domenia_2.0.5_DEV_Windows-x64.zip](https://github.com/M4D135/domenia-d120/releases/download/v2.0.5/Domenia_2.0.5_DEV_Windows-x64.zip) | 507317601 | `7ff895d2c9c036bc9cf0b3cd4ff6a72ce2c096eff259973f9e687412e8d78561` |

## Comportements couverts

- Login avant connexion AD : nom simple, domaine joint en mode annuaire forcé, préférence facultative sans mot de passe, changement de compte et erreurs de persistance. La fenêtre principale reste masquée pendant le login.
- Identité : logo Domenia V2 sur fond rouge pastel avec arbre de domaine, icône Windows incorporée (16 à 256 px), ressources natives de connexion et variante monochrome pour contraste élevé. Famille visuelle coordonnée avec GLPI, Pesto et FILPRO.
- Interface : Mises à jour visible pendant le chargement, une erreur et un nouveau rendu ; menu Information de l’Atelier au-dessus des champs Condition et Valeur. Tests avec les feuilles CSS réelles et contrôle de la cible des clics.
- Réseau : IPv4 préféré, un seul écho, attente locale distincte du délai réseau, annulation et baux jusqu’à la sortie physique des lecteurs natifs. Suspension adaptative et essai de reprise unique ; réglages effectifs des réessais, jamais après refus de compte. Option explicite pour tenter une lecture directe après ICMP sans réponse, sans contourner DNS ni les identités.
- Collecte : cache initial vide et identités enrichies par AD, résultats progressifs conservés, périmètre après reçu AD confirmé. Une étape AD préalable échouée reste un arrêt explicite ; aucune collecte silencieuse sur un autre périmètre.
- Cache : fabricant, modèle et numéro de série connus réutilisables sous identité qualifiée ; durées propres aux données variables. Valeur vide, erreur, identité différente et relecture forcée restent à traiter. Les anciens résultats sans preuve d’identité ne deviennent pas permanents.
- Stockage : inspection sans gros contenus, compteurs fidèles, refus de purge sans suppression partielle, cache décodé seulement si les octets persistés concordent, invalidation d’un poste remplacé. Le cache passe atomiquement du document monolithique à des lignes par poste, après sauvegarde vérifiée. Les changements ordinaires ne réécrivent que les postes concernés. Les générations, empreintes et gardes du schéma invalident les instantanés en mémoire après une modification extérieure. Schéma historique 11 conservé, révision native 2 ; les anciens exécutables refusent la base migrée. Un retour à 2.0.4 exige une sauvegarde antérieure à la migration.

- Atelier et Accueil : modèles opérationnels supplémentaires, critères d’instances guidés, BitLocker C: et répartition des méthodes ; taille, hauteur, position, section et visibilité des cartes.
- Campagnes : sélection par sous-OU, objectifs séparés et budget commun, identités persistées par pages immuables de 256, reprise explicite et checkpoints compacts. Un changement de cible ou de compte bloque les prochains contacts.
- Comptes : rôle administratif vérifié distinctement des droits AD. Compte standard en lecture AD uniquement. Validation explicite des administrateurs locaux délégués du domaine par preuve temporaire liée au SID, au secret, à la session et à l’identité de la cible ; aucune autorisation globale de campagne. Authentifications LDAP sérialisées pour une même sélection ; un refus suspend la file.
- Collecteurs optionnels : tâche planifiée, PsExec, processus WMI, script WinRM, tous désactivés par défaut. Programme fermé, autorisation bornée, journal et nettoyage suivis. Aucun remplacement après une réponse de lancement perdue. WMI/WinRM temporaires nécessitent ADMIN$ ; après crash sans preuve d’arrêt, intervention requise. Les requêtes arbitraires de l’Atelier restent directes. La validation explicite d’un compte local utilise DCOM et refuse le mode WinRM exclusif avant contact ; une identité administrative du domaine permet les collectes WinRM.
- Temps : total monotone, attente et exécution cumulées par méthode, cache séparé. Aucun essai supplémentaire pour comparer ; historique détaillé limité à la session.

## Installation et portée

Extraire dans un nouveau dossier : seulement `Domenia.exe` et `wad` à la racine. Le profil utilisateur est conservé. La configuration portable est dans `wad/Domenia.config.json` et les sources DEV dans `wad/developer`. Les anciens packs et leurs moyens de reprise restent disponibles.

Aucune VM ni authentification AD réelle exécutée pour ces octets. Les tests de 3 500 et 100 000 postes utilisent des transports simulés ; ils vérifient les bornes et les contrats, sans qualifier le débit d’un domaine réel. La recette utilisateur et la revue visuelle native restent en attente. [Recette à effectuer](../../RECETTE-MANUELLE-V2.0.5.md).

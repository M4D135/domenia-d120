# Domenia 2.0.8 — relevé de présence : nom absent du DNS, 30 octobre 2026

Retour terrain sur 2.0.7 (OU ADCC-Lab du domaine de test) : un poste sans enregistrement DNS faisait passer le relevé de présence en « Échec », l’actualisation en « partielle » et proposait « Reprendre », qui ne pouvait que reposer la même question. Un nom absent du DNS est désormais un résultat : l’étape est terminée et le compte rendu le nomme (« 1 nom absent du DNS »), sans reprise. Seules les causes passagères (DNS indisponible ou trop lent, adresse ou réseau indisponible, erreur ICMP, délai dépassé) laissent l’étape « Incomplète » et reprenable, avec leur cause écrite ; quand aucun nom de l’OU n’est résolu, l’étape ajoute « aucun nom résolu : vérifiez le DNS de ce poste ». Même format de données que 2.0.5 à 2.0.7.

Source compilée : `5f4ed1ce8ead97b01e44653bba21e83d5b5f894c`. [Release v2.0.8](https://github.com/M4D135/domenia-d120/releases/tag/v2.0.8), publiée à `2026-10-30T10:44:07Z`, identifiant `428912895`.

## Vérifications

[Compilation Windows Debug/Release](https://github.com/M4D135/domenia-d120/actions/runs/41029725831) et [fabrication des packs](https://github.com/M4D135/domenia-d120/actions/runs/41029725871) réussies sur le commit indiqué. Résultats exacts : {"csharp_full_passed": 2593, "csharp_critical_passed": 942, "harness_self_tests": 26, "release_guard_tests": 15, "manual_package_verifier_tests": 11, "browser_evidence_verifier_tests": 12, "web_critical": 111, "simulation_scenarios": 7}.

Recette sur la VM `DOMENIA-FIRSTRUN-20261020` (domaine de test, session de bureau), avec le ZIP PROD publié (SHA256 `c0f6da6f52f6c1a5416b1cc80a250363d04d23936a3e17faa5f73586492f0a06`) : annuaire : 6 réussis, 0 en échec, 132 ignorés (réservés à la simulation) ; simulation : 136 réussis, 0 en échec, 2 ignorés (réservés au mode annuaire).

Intégrité des ZIP et manifestes vérifiée localement ; sources DEV comparées aux blobs Git du commit. PROD et DEV partagent le même exécutable : `2acd7b56b08521a9a757c562e6918f47b4341e0c9ee8c344ab5fe1b51750afb1`. SHA256 GitHub concordants avec les fichiers locaux, sans reconstruction pour publier. 9 releases antérieures et 27 assets conservés.

| Pack | Archive | Octets | SHA256 |
| --- | --- | ---: | --- |
| **PROD** | [Domenia_2.0.8_PROD_Windows-x64.zip](https://github.com/M4D135/domenia-d120/releases/download/v2.0.8/Domenia_2.0.8_PROD_Windows-x64.zip) | 485740238 | `c0f6da6f52f6c1a5416b1cc80a250363d04d23936a3e17faa5f73586492f0a06` |
| **DEV** | [Domenia_2.0.8_DEV_Windows-x64.zip](https://github.com/M4D135/domenia-d120/releases/download/v2.0.8/Domenia_2.0.8_DEV_Windows-x64.zip) | 507390741 | `599ef4a02c2693dbd50b2db53afa1752bfd51440cfc3a3ce50d6ecd05383c4bf` |

## Corrections

- Relevé de présence (ping) : une réponse DNS « nom inconnu » (11001) ou « nom sans adresse » (11004), comme un nom de poste invalide, est une réponse définitive sur le nom. Aucun écho ICMP n’est envoyé et la présence reste inconnue, mais il n’y a rien à reprendre : le poste est réglé pour l’actualisation, sa reprise, la collecte des widgets et les compteurs d’Opérations, et n’est plus compté comme lecture non confirmée ni erreur de ping.
- Nouvel état d’étape « Incomplète » : l’étape a tourné mais des postes restent à lire pour une cause passagère, ou après une lecture WMI incomplète ou refusée ; « Échec » est réservé à une étape qui n’a pas pu s’exécuter. Le compte rendu nomme les réponses définitives et les postes encore à mesurer avec leur cause.
- Garde-fou : quand aucun nom de l’OU n’est résolu (au moins deux réponses « nom absent », aucun poste joint), l’étape et le compte rendu ajoutent « aucun nom résolu : vérifiez le DNS de ce poste » ; une nouvelle actualisation repose la question à tous les postes.
- Provenance des mesures, tableau du parc, Rechercher et journal de l’annuaire nomment la réponse (« nom absent du DNS », « nom sans adresse dans le DNS », « nom de poste invalide ») au lieu de « en erreur » ou « sonde en erreur ».
- Relevés par OU : une reprise ne qualifie plus de « non confirmées » les lectures de l’actualisation interrompue.

## Portée

Recette exécutée sur une VM Windows 11 jointe au domaine de test (identité intégrée de la session, aucun mot de passe saisi par l’outil) ; ce n’est pas une recette utilisateur ni une validation sur le domaine de production. Le cas réel est vérifié sur l’OU ADCC-Lab : « Tout actualiser » se termine avec « 0 poste en ligne sur 5 · 4 sans réponse · 1 nom absent du DNS ». La reprise de l’actualisation laissée par 2.0.7 dans le profil de l’opérateur n’est vérifiée que par les tests C# (le harnais E2E utilise son propre profil), de même que les causes DNS passagères et le cas « aucun nom résolu », sans panne provoquée. Les tests de 3 500 et 100 000 postes restent simulés. La revue visuelle native et la recette utilisateur restent en attente. [Recette à effectuer](../../RECETTE-MANUELLE-V2.0.8.md).

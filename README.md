# Domenia 2

Application Windows d’administration Active Directory : connexion, lecture des OU,
base locale, inventaire, tableaux de bord et opérations contrôlées.

**La version active est Domenia v2, dans [`v2/`](v2/), sur la branche principale `master`.**
La v1 est conservée comme historique sous le tag
[`v1-historique-20261026`](https://github.com/M4D135/domenia-d120/tree/v1-historique-20261026).

## Packs Windows

Dernière version : **2.0.8**, construite depuis [`5f4ed1ce`](https://github.com/M4D135/domenia-d120/commit/5f4ed1ce8ead97b01e44653bba21e83d5b5f894c). Retour terrain sur 2.0.7 (OU ADCC-Lab du domaine de test) : un poste sans enregistrement DNS faisait passer le relevé de présence en « Échec », l’actualisation en « partielle » et proposait « Reprendre », qui ne pouvait que reposer la même question. Un nom absent du DNS est désormais un résultat : l’étape est terminée et le compte rendu le nomme (« 1 nom absent du DNS »), sans reprise. Seules les causes passagères (DNS indisponible ou trop lent, adresse ou réseau indisponible, erreur ICMP, délai dépassé) laissent l’étape « Incomplète » et reprenable, avec leur cause écrite ; quand aucun nom de l’OU n’est résolu, l’étape ajoute « aucun nom résolu : vérifiez le DNS de ce poste ». Même format de données que 2.0.5 à 2.0.7.

| Pack | Téléchargement direct |
| --- | --- |
| **PROD** | [Domenia_2.0.8_PROD_Windows-x64.zip](https://github.com/M4D135/domenia-d120/releases/download/v2.0.8/Domenia_2.0.8_PROD_Windows-x64.zip) |
| **PROD-LIGHT** | En préparation. Utilise WebView2 Evergreen Microsoft x64 déjà installé sur le poste. |
| **Sources** | [Télécharger les sources exactes de 2.0.8](https://github.com/M4D135/domenia-d120/archive/5f4ed1ce8ead97b01e44653bba21e83d5b5f894c.zip) |
| Empreintes | [SHA256SUMS.txt](https://github.com/M4D135/domenia-d120/releases/download/v2.0.8/SHA256SUMS.txt) |

[Release v2.0.8](https://github.com/M4D135/domenia-d120/releases/tag/v2.0.8) · [provenance des packs](packs/README.md) · [rapport](v2/docs/reprise/rapports/RAPPORT-PRESENCE-DNS-2.0.8-20261030.md) · [recette manuelle](v2/docs/RECETTE-MANUELLE-V2.0.8.md).

Extraire le ZIP dans un nouveau dossier, garder `wad` à côté de `Domenia.exe` et lancer l’application. Le candidat **PROD-LIGHT** cible WebView2 Evergreen Microsoft x64 à partir de **140.0.3485.54**. La recette du login sur cette version reste à exécuter. **PROD** fournit son moteur. Les deux éditions incluent .NET. Les sources se récupèrent directement dans le dépôt, au commit indiqué dans `wad/package-release.json`.

## Recette VM 2.0.8

Compilation Windows, suite C# complète, tests de navigateur et fabrication des packs CI réussis ; recette du pack publié sur la VM du domaine de test : annuaire : 6 réussis, 0 en échec, 132 ignorés (réservés à la simulation) ; simulation : 136 réussis, 0 en échec, 2 ignorés (réservés au mode annuaire). Recette exécutée sur une VM Windows 11 jointe au domaine de test (identité intégrée de la session, aucun mot de passe saisi par l’outil) ; ce n’est pas une recette utilisateur ni une validation sur le domaine de production. Le cas réel est vérifié sur l’OU ADCC-Lab : « Tout actualiser » se termine avec « 0 poste en ligne sur 5 · 4 sans réponse · 1 nom absent du DNS ». La reprise de l’actualisation laissée par 2.0.7 dans le profil de l’opérateur n’est vérifiée que par les tests C# (le harnais E2E utilise son propre profil), de même que les causes DNS passagères et le cas « aucun nom résolu », sans panne provoquée. Les tests de 3 500 et 100 000 postes restent simulés. La revue visuelle native et la recette utilisateur restent en attente.

## Recette VM 2.0.7

Compilation Windows, suite C# complète, tests de navigateur et fabrication des packs CI réussis ; recette du pack publié sur la VM du domaine de test : annuaire : 5 réussis, 0 en échec, 132 ignorés (réservés à la simulation) ; simulation : 135 réussis, 1 en échec, 1 ignoré (réservé au mode annuaire) ; relance ciblée de parametres/copie-destination : 3 réussis, 0 en échec, 0 ignoré ; 113 captures en thèmes clair, sombre et contraste élevé, 0 en échec. Recette exécutée sur une VM Windows 11 jointe au domaine de test (identité intégrée de la session, aucun mot de passe saisi par l’outil) ; ce n’est pas une recette utilisateur ni une validation sur le domaine de production. Les tests de 3 500 et 100 000 postes restent simulés. La revue visuelle native et la recette utilisateur restent en attente. L’échec intermittent de parametres/copie-destination (clic perdu, réussi 3 fois sur 3 en relance ciblée, écran non modifié par 2.0.7) reste à analyser.

## Recette VM 2.0.6

Compilation Windows, suite C# complète, tests de navigateur et fabrication des packs CI réussis ; recette du pack publié sur la VM du domaine de test : annuaire : 5 réussis, 0 en échec, 132 ignorés (réservés à la simulation) ; simulation : 136 réussis, 0 en échec, 1 ignoré (réservé au mode annuaire) ; 113 captures en thèmes clair, sombre et contraste élevé, sans échec. Recette exécutée sur une VM Windows 11 jointe au domaine de test (identité intégrée de la session, aucun mot de passe saisi par l’outil) ; ce n’est pas une recette utilisateur ni une validation sur le domaine de production. Les tests de 3 500 et 100 000 postes restent simulés. La revue visuelle native et la recette utilisateur restent en attente.

## Validation du moteur et du cache 2.0.5

Compilation Windows, suite C# complète, tests de navigateur et fabrication des packs CI réussis. ZIP, sources DEV et empreintes GitHub vérifiés. Aucune VM ni authentification AD réelle exécutée pour ces octets. Les tests de 3 500 et 100 000 postes utilisent des transports simulés ; ils vérifient les bornes et les contrats, sans qualifier le débit d’un domaine réel. La recette utilisateur et la revue visuelle native restent en attente.

## Validation du login 2.0.4

Compilations Windows Debug/Release et contrôles de livraison CI réussis. Intégrité des ZIP, sources DEV et empreintes GitHub vérifiées. Aucune VM, authentification AD réelle ou revue visuelle native exécutée pour cette version. La recette utilisateur reste en attente ; les validations des packs précédents ne sont pas réattribuées à ces octets.

## Validation de la carte 2.0.3

[Compilation Windows](https://github.com/M4D135/domenia-d120/actions/runs/40398683415) et [livraison du commit exact](https://github.com/M4D135/domenia-d120/actions/runs/40398683357) :
Debug et Release réussis, **751 tests C# critiques réussis**, 25 autocontrôles du pilote,
15 contrôles de la garde, 93 tests Web critiques et 7 scénarios de simulation.

Sur ces octets, 36 captures natives à 96 DPI ont été revues dans la VM du domaine, avec des identités fictives.
La carte longue mesure 96 px en grand format et 84 px en compact ; l’icône est centrée avec la légende et l’identité.
Aucune authentification n’a été tentée. La collecte AD et le ping du 2.0.2 n’ont pas été relancés et ne couvrent pas ce paquet.
Le [rapport 2.0.3](v2/docs/reprise/rapports/RAPPORT-CARTE-CONNEXION-2.0.3-20261026.md) détaille le périmètre.

## Validation du correctif 2.0.2

[Compilation Windows](https://github.com/M4D135/domenia-d120/actions/runs/40368684954) et [livraison du commit exact](https://github.com/M4D135/domenia-d120/actions/runs/40368684978) :
Debug/Release sans erreur ni avertissement, **751 tests C# ciblés sur 2 436 enregistrés**,
25 autocontrôles du pilote, 34 tests Python, les mêmes 93 tests Web dans deux passages,
puis 7 scénarios en simulation représentant 90 étapes. Les 1 685 autres tests C# n’ont pas été exécutés.

La connexion Windows native est validée à **96 DPI**, avec 18 captures de fixtures de présentation
et 7 captures du parcours réel. L’ouverture du formulaire d’un autre compte puis son annulation
ont été vérifiées ; son authentification reste non qualifiée.

Le scénario réel de lecture dans un domaine réussit **76 actions, soit 77 étapes avec le démarrage**,
avec fermeture normale et code 0. Le nombre de comptes affiché, la mesure récente SQLite et le
comptage AD indépendant concordent. Aucune écriture AD n’a été exécutée.

Le ping produit sur une seule cible a reçu une réponse ICMP, datée et persistée dans SQLite.
Aucun inventaire antérieur n’était présent sur la cible testée ; son état reste non mesuré. Les faits et autres mesures comparés sont inchangés.
La conservation d’un inventaire antérieur rempli est également couverte par les tests ciblés du code.
Une erreur de conversion horaire du préflight privé a nécessité une relecture LDAP indépendante de la date de création, normalisée en UTC après le ping. Les preuves initiales, dont le reçu d’échec, sont conservées ; aucun second ping n’a été exécuté.
Aucun inventaire WMI n’est demandé ;
le contrat et les traces contrôlées ne constituent pas une observation exhaustive du réseau.

La recette humaine de David, les DPI 125/150 %, le parcours strict sur deux postes VM et les
performances de démarrage restent non qualifiés. Le [rapport](v2/docs/reprise/rapports/RAPPORT-CORRECTIFS-COLLECTE-LOGIN-20261026.md) détaille le périmètre
et les limites ; ces preuves portent sur le commit et les archives exacts.

## Sources et documentation actives

- [État de reprise et validations restantes](v2/REPRISE.md).
- [Consignes v2](v2/CLAUDE.md), [architecture](v2/ARCHITECTURE.md) et [décisions](v2/docs/DECISIONS.md).
- [Validation Windows CI](v2/docs/VALIDATION-WINDOWS-CI.md) et [préparation de livraison](v2/docs/LIVRAISON-FINALE.md).

Le code et les outils v2 restent dans leur arborescence actuelle. Le workflow de compilation Windows
suit désormais aussi les changements de `master`. La préparation des packs reste un parcours
distinct ; aucune release n’est publiée par ces workflows.

## Historique v1

L’état de l’ancienne branche principale, au commit `c9898f61`, est conservé sous le
[tag `v1-historique-20261026`](https://github.com/M4D135/domenia-d120/tree/v1-historique-20261026),
avec ses sources, packs, guides et validations.
Les derniers commits v1 ont été conservés dans la fusion, sans réécriture d’historique.

Les dossiers racine `dev/`, `DOC/`, `guides/` et `validation/` concernent cet historique.
Le dossier [`packs/`](packs/README.md) décrit les téléchargements v2 actuels et leurs empreintes ;
les archives v1 restent disponibles dans le tag historique.

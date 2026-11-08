# Packs Windows Domenia 2.0.8

Retour terrain sur 2.0.7 (OU ADCC-Lab du domaine de test) : un poste sans enregistrement DNS faisait passer le relevé de présence en « Échec », l’actualisation en « partielle » et proposait « Reprendre », qui ne pouvait que reposer la même question. Un nom absent du DNS est désormais un résultat : l’étape est terminée et le compte rendu le nomme (« 1 nom absent du DNS »), sans reprise. Seules les causes passagères (DNS indisponible ou trop lent, adresse ou réseau indisponible, erreur ICMP, délai dépassé) laissent l’étape « Incomplète » et reprenable, avec leur cause écrite ; quand aucun nom de l’OU n’est résolu, l’étape ajoute « aucun nom résolu : vérifiez le DNS de ce poste ». Même format de données que 2.0.5 à 2.0.7.

Source : [`5f4ed1ce`](https://github.com/M4D135/domenia-d120/commit/5f4ed1ce8ead97b01e44653bba21e83d5b5f894c). [Release](https://github.com/M4D135/domenia-d120/releases/tag/v2.0.8).

| Pack | Archive | Octets | SHA256 |
| --- | --- | ---: | --- |
| **PROD** | [Domenia_2.0.8_PROD_Windows-x64.zip](https://github.com/M4D135/domenia-d120/releases/download/v2.0.8/Domenia_2.0.8_PROD_Windows-x64.zip) | 485740238 | `c0f6da6f52f6c1a5416b1cc80a250363d04d23936a3e17faa5f73586492f0a06` |

Pour les prochaines livraisons, choisir PROD-LIGHT sur un poste équipé de WebView2 Evergreen x64, et PROD pour un déploiement autonome. Les sources sont disponibles dans le [dépôt Domenia](https://github.com/M4D135/domenia-d120). Le fichier de sommes de la release 2.0.8 décrit les archives publiées à cette date.

[SHA256SUMS.txt](https://github.com/M4D135/domenia-d120/releases/download/v2.0.8/SHA256SUMS.txt) — copie identique dans `packs/SHA256SUMS`.

[Rapport exact](../v2/docs/reprise/rapports/RAPPORT-PRESENCE-DNS-2.0.8-20261030.md) · [recette manuelle](../v2/docs/RECETTE-MANUELLE-V2.0.8.md). Recette exécutée sur une VM Windows 11 jointe au domaine de test (identité intégrée de la session, aucun mot de passe saisi par l’outil) ; ce n’est pas une recette utilisateur ni une validation sur le domaine de production. Le cas réel est vérifié sur l’OU ADCC-Lab : « Tout actualiser » se termine avec « 0 poste en ligne sur 5 · 4 sans réponse · 1 nom absent du DNS ». La reprise de l’actualisation laissée par 2.0.7 dans le profil de l’opérateur n’est vérifiée que par les tests C# (le harnais E2E utilise son propre profil), de même que les causes DNS passagères et le cas « aucun nom résolu », sans panne provoquée. Les tests de 3 500 et 100 000 postes restent simulés. La revue visuelle native et la recette utilisateur restent en attente.

Les releases 2.0.0 à 2.0.7 restent conservées avec leurs packs et leurs rapports propres.

## Historique v1

Les sources, packs, guides et preuves v1 restent accessibles sous le
[tag `v1-historique-20261026`](https://github.com/M4D135/domenia-d120/tree/v1-historique-20261026).
Les téléchargements ci-dessus concernent exclusivement Domenia v2.

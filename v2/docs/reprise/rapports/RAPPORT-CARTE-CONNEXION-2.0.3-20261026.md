# Domenia 2.0.3 — carte de connexion

Rapport du 26 octobre 2026. Les archives exactes viennent du commit `66192551ac4950031d09d08340b3f75917094f7f`, build `2.0.3+961119ac0597920aae9d57eafd226c38622af437675f3a8d0606675ec6e485f6`. La [compilation 40398683415](https://github.com/M4D135/domenia-d120/actions/runs/40398683415) et la [préparation 40398683357](https://github.com/M4D135/domenia-d120/actions/runs/40398683357) ont réussi. La [release v2.0.3](https://github.com/M4D135/domenia-d120/releases/tag/v2.0.3) est publiée le 26 octobre 2026 à 21:18:30 UTC (`424779339`). Le tag désigne ce commit construit. Les commits documentaires ne sont pas réattribués au paquet.

| Archive | Octets | SHA-256 |
| --- | ---: | --- |
| `Domenia_2.0.3_PROD_Windows-x64.zip` | 483 435 434 | `0bb68597395e417d28cc1cdbcf573d9a7d844cc11baf97d6a9a351bd4293f7b4` |
| `Domenia_2.0.3_DEV_Windows-x64.zip` | 503 207 902 | `7687eaf0b5e857ca172bbe402ec649fdddb80f350bc1d9faeae09fe29303cbd1` |
| `SHA256SUMS.txt` | 201 | `665efab4c310b2a9ae59ae2683318c5794c2ffb76ae691d17125a0acf80504c8` |

Les trois assets GitHub ont la même taille et le même digest que les fichiers locaux. L’exécutable commun aux deux archives a le SHA-256 `df2b87809bfb418e2a5def94e7895b5572085d4b5a9442c1e4d6c1b46071fc02`. Les releases 2.0.2, 2.0.1, 2.0.0 et l’aperçu 2.0.0 sont restées identiques.

La CI a exécuté 751 tests C# critiques, tous réussis, 25 autocontrôles E2E, 15 contrôles de la garde de publication, 93 tests Web critiques et 7 scénarios de simulation. Le domaine réel, l’interface réelle et les deux VM ne font pas partie de ce passage.

Sur ces octets, la fenêtre native a été capturée dans la VM du domaine `cnamts.local`, session bureau 1, 96 DPI, sans authentification. 36 cas : identité fictive courte `LABO-FICTIF\Ada` et longue `DOMAINE-DE-RECETTE-FICTIF\Administrateur-de-la-plateforme-de-qualification`, thèmes clair, sombre et contraste, grand format et compact, message vide, annulé ou fictif. Géométrie acceptée dans les 36 cas. La légende mesure 16 px. L’écart de centrage est 0 px, sauf −0,5 px d’arrondi quand la fenêtre compacte dense réduit l’icône à 40 px.

Carte du compte long, largeur 440 px : 96 px en grand format, 84 px en compact, 75 px en compact avec le message fictif. Compte court : 84 px et 72 px. Les trois choix restent visibles, sans ascenseur. Les captures du grand format, du compact et du message fictif ont été revues. Le message orange est une fixture.

La collecte AD et le ping qualifiés pour le 2.0.2 n’ont pas été relancés. Ils ne couvrent pas ces archives. Les DPI élevés, l’authentification avec un autre compte, les écritures AD, WMI, la recette humaine et le parcours strict des deux postes restent non qualifiés. Le [guide 2.0.3](../../RECETTE-MANUELLE-V2.0.3.md) décrit les observations encore attendues.

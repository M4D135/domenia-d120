# Domenia 2.0.1 — correctifs Windows et nouvelle recette manuelle

Date : 26 octobre 2026. Les packs correctifs sont préparés et vérifiés. La recette du domaine réel et la recette utilisateur restent à effectuer ; ce rapport ne certifie pas l’ensemble du catalogue.

## Provenance et livraison

Branche poussée : [`codex/v2-correctifs-recette-20261026`](https://github.com/M4D135/domenia-d120/tree/codex/v2-correctifs-recette-20261026), issue du distant vérifié `31ba4eaadffc44b1de88380b523bce99655c3411`. **Commit source des deux packs : `fbe5caab6808619e727fdb8be597c8fde8270614`.** Le commit documentaire suivant ne change pas leurs octets ni leur provenance.

Les dix commits de code et de qualification, en ordre chronologique :

| Commit | Lot |
| --- | --- |
| `1dc6f64e` | Démarrage visible, connexion et politique d’écriture |
| `7187463d` | Plages LDAP valides et arrêt après échec du prérequis |
| `8855cf0d` | Maintien des opérations locales hors connexion |
| `dcad84a6` | Parcours connexion/OU et états visuels |
| `9ee99a0c` | Packs 2.0.1 et recette Windows instrumentée |
| `89dc7c7d` | Annulation finale, pictogrammes et assertion BER |
| `760798bf` | Qualification des preuves navigateur |
| `d4d4aa24` | Mesure de la fenêtre malgré son changement de titre |
| `ff515eeb` | Chargement CSS relatif au module et contrôle Web préalable |
| `fbe5caab` | Corrections issues de l’examen des premières captures |

La [release v2.0.0](https://github.com/M4D135/domenia-d120/releases/tag/v2.0.0), ses trois fichiers et son tag `4ec63be686895aa46469877a7711c1cd87965cf2` sont conservés, revérifiés sur GitHub le 26/10. Aucun remplacement ni nouvelle release publiée pendant ce lot. Les nouveaux fichiers sont fournis dans les livrables de la conversation et dans les [artefacts du passage Windows](https://github.com/M4D135/domenia-d120/actions/runs/40303383351). Les artefacts GitHub expirent le 9 novembre ; conserver les fichiers livrés localement.

| Archive exacte | Octets | SHA256 |
| --- | ---: | --- |
| `Domenia_2.0.1_PROD_Windows-x64.zip` | 483 379 653 | `cd9798df69dac59cfc3c37e5c7830aad8c68b41e7717d6b878bcd0a1cc6d623f` |
| `Domenia_2.0.1_DEV_Windows-x64.zip` | 503 077 910 | `a1fecea4e6502238308228101b78becc69148e7b501faf7ca15456b7e1900420` |
| `Preuves-Windows-2.0.1-fbe5caab.zip` | 18 917 411 | `c729f2160ed6006068ba2f1eeb62cffbbca4cefd032fa6b5caf678a935dcf717` |

`SHA256SUMS.txt` a pour empreinte `fa39da96c4812ffc2955c9f2fd96089ddd53fce0e86e50f15151393b5cb899b6`. L’artefact de transport GitHub contenant les deux packs et leurs reçus est `12641569662`, SHA256 `ea5b1075ee057d075abdedd19ced6f3e8a37d8c77a4455814cf21dad034b0364`, 988 142 994 octets. Ce SHA n’est celui d’aucun ZIP applicatif.

Le vérificateur des packs est passé avant extraction, après les tests Windows, puis localement après téléchargement. Manifestes, tous les octets déclarés et identité des binaires PROD/DEV sont conformes. Les **1 658 fichiers sources DEV**, 35 719 990 octets, ont aussi été comparés localement, octet par octet, aux blobs Git du commit source ; aucun écart. Les reçus `verification-paquets.json`, `verification-locale-paquets.json` et `verification-sources-git.json` sont livrés séparément. L’exécutable commun porte le SHA256 `f9f0e94dd5a4351f4a10386ab2c1d05fa81a30dd02fc2828b9024b64cf26e3ff`. Ces empreintes établissent la cohérence, sans signature d’éditeur.

## Causes établies et corrections

**Démarrage.** L’intégrité et la composition précédaient tout retour visible. Les flux conservés pour protéger les composants multipliaient les tampons de 64 Kio. Une fenêtre native indépendante affiche maintenant la phase, le temps écoulé et la demande d’annulation avant le travail long. Le hachage intégral conserve les protections et les handles ; un tampon partagé de 1 Mio remplace les tampons par fichier. Le thread des messages reste disponible. Le dernier clic d’annulation avant la fenêtre principale est traité. Cela corrige l’attente silencieuse et un coût évitable, sans démontrer la cause des trois minutes rapportées par David.

**Connexion et OU.** Le démarrage web lisait `session.info`, qui ne connecte pas l’annuaire. Le parcours explicite et sa présentation native existaient dans Comptes, sans entrée assez évidente depuis l’Accueil. Le bouton « Se connecter » est maintenant visible dans le haut de l’Accueil et le shell, raccordé à `session.connect`, avec un seul essai suivi. L’identité Windows et la saisie d’un autre compte restent distinctes ; aucun secret ne transite dans JavaScript. Annulation, identité tardive, focus/propriétaire et traces par phase sont traités. L’Accueil distingue déconnexion, attente, OU à choisir, première lecture, données et erreur. Le sélecteur attend une session valide et une demande explicite ; un résultat d’un ancien contexte n’est pas appliqué. Les gardes de session restent actives.

**LDAP.** La matérialisation rejetait une réponse valide contenant un attribut simple vide et sa plage, par exemple `member` vide et `member;range=0-1499`, à cause d’un double ajout sous le même nom. Seul ce compagnon vide est maintenant ignoré. Trous, chevauchements, doublons, ambiguïtés, changements GUID/USN et limites sans terminal restent refusés ; même connexion pour les continuations, aucune limite relevée ni boucle ajoutée. Les diagnostics bornés donnent référence, étape, attribut, catégorie, bornes, comptes, présence des marqueurs et nombre réel de requêtes, sans valeur AD, DN, compte ou serveur. Voir le [rapport LDAP](correctifs-ldap-recette-20261026.md). Le rôle exact de ce défaut dans l’incident sur l’OU réelle reste à confirmer.

**Actualisation.** Le repli poursuivait ping/WMI après échec ou résultat partiel du préalable AD. Il s’arrête maintenant en conservant sauvegarde et résultats acquis ; aucun stockage de snapshot incomplet. La consultation du statut conserve la cause connue au lieu de la remplacer par une annulation supposée. Après réouverture, un checkpoint sans cause historique indique honnêtement une interruption à vérifier. La reprise exige une nouvelle confirmation et les préconditions du contexte courant.

**Écritures.** La source AD fixait `ReadOnly=false` même déconnectée. Aucun argument, préférence persistée ou différence PROD/DEV ne pilotait ce booléen. Le libellé ne démontrait aucune écriture. La lecture par défaut et la disponibilité d’un plan confirmé sont maintenant distinctes. Le moteur refuse les mutations AD sans session connectée avant le plan et autour des préconditions ; confirmations, jetons, identité/génération, périmètre et reçus restent obligatoires. Les sauvegardes et maintenances locales restent utilisables hors connexion.

**Affichage et notifications.** Les animations décoratives déplaçaient des icônes fonctionnelles, dont Accueil et Fiche. Leurs déplacements permanents sont supprimés, en conservant les indicateurs d’opération réellement active. SHA256, DN, chemins et autres chaînes longues se replient dans leurs conteneurs ; le SHA entier est copiable. Le double signalement possible après un rapport suivi d’une erreur de rendu est séparé ; cela ne prouve pas l’origine du « ×2 » des photos absentes. Les durées explicites des notifications sont respectées. Les avertissements de collecte partielle ont une durée de six secondes et une identité par plan ; leur résultat reste au journal.

La première revue de captures, pourtant issue d’un passage vert, a révélé une connexion trop bas dans la page et un débordement horizontal réel de 4 px dans une fenêtre de faible hauteur (`data-low`, moins de 700 px). Le CTA a été ajouté au haut de l’Accueil et la gouttière ajustée au padding effectif, sans masquer globalement le débordement. Des assertions géométriques et les captures manquantes ont été ajoutées. Le harnais corrige aussi une URL CSS relative à la page de test, le cadrage après défilement et l’enregistrement des dimensions réellement obtenues.

## Mesures du pack extrait

Source `fbe5caab`, archive PROD ci-dessus, runner `runnervmdaln5`, image `win25-vs2026 / 20261021.278.1`, SDK 10.0.402, session 2. Exécution du vrai `Domenia.exe` extrait avec `--simulation --no-auto-connect`. Premier profil absent, puis même profil présent. Le cache du système n’a pas été purgé : ce sont un premier et un second lancement, sans preuve d’un cache OS froid.

| Mesure, millisecondes | Premier lancement | Second lancement |
| --- | ---: | ---: |
| Première fenêtre visible, observation externe | 141 | 123 |
| Fenêtre principale visible, observation externe | 1 946 | 1 904 |
| Interface prête, observation externe | 4 070 | 3 054 |
| Intégrité, durée interne | 1 398 | 1 386 |
| Composition, durée interne | 257 | 252 |
| Environnement WebView2, durée interne | 16 | 13 |
| Contrôle WebView2, durée interne | 777 | 423 |
| Session locale, durée interne | 52 | 27 |
| Signal InterfaceReady, depuis début managé | 3 449 | 2 602 |

Les jalons internes et l’observation externe n’ont pas le même point de départ ni la même granularité. `InterfaceReady` signifie shell rendu et disponible, pas données AD chargées. Le tableau ne doit pas être additionné : Composition englobe ses sous-phases. Les reçus contiennent aussi source locale, assemblages, préférences, lecteurs, configuration, registre et navigation.

Sur les deux passes : zéro échantillon non réactif observé, zéro timeout ou erreur de sonde/nettoyage, fenêtre principale réactive après disponibilité et fermeture gracieuse. DPI natif **96 (100 %)** uniquement. La sonde vérifie classe, HWND, propriétaire et réactivité via messages Windows ; elle ne remplace pas une recette clavier/focus. Les modules `hostfxr.dll` et `coreclr.dll` chargés viennent de la copie privée .NET 10.0.13 ; les six processus WebView2 viennent du pack privé 155.0.4283.62. Sept processus sont suivis par passe.

L’ancien passage `4ec63be6` avait enregistré 6 967 ms avant disponibilité en scénario E2E et 1 525 ms d’intégrité, dans une autre exécution et un autre mode. Ce n’est **pas** un avant/après comparable. Aucune amélioration chiffrée sur le poste de David ni sur sa connexion AD n’est revendiquée. Les traces de connexion séparent attente, préparation, bind, RootDSE et qualification pour sa nouvelle recette.

## Tests réellement exécutés

[Préparation et contrôle Windows 40303383351](https://github.com/M4D135/domenia-d120/actions/runs/40303383351), job `121506438407`, terminé avec succès. La [compilation indépendante 40303383384](https://github.com/M4D135/domenia-d120/actions/runs/40303383384) est également réussie au même SHA.

| Contrôle | Résultat final |
| --- | --- |
| Debug et Release | Réussis, zéro erreur et zéro avertissement |
| C# critique ciblé | **679/679 réussis**, 1 718 autres tests enregistrés non exécutés |
| Python garde stricte | 15/15 réussis ; teste la garde, ne qualifie pas les deux VM |
| Python packs manuels | 8/8 réussis |
| Python preuves navigateur | 8/8 réussis |
| Web critique | **79/79 réussis**, en précontrôle puis avec les runtimes privés extraits |
| E2E application en simulation | **6/6 scénarios**, 71 étapes et 71 captures |
| Captures ciblées | 16 par passe Web, plus une page par passe : **105 PNG au total** avec les E2E |
| PROD/DEV extraits | `--check-only` réussi ; lancement interactif mesuré deux fois pour PROD |
| Runtime privé absent | Refus attendu malgré le runtime global présent |
| Archives finales | Vérifiées et rehachées après contrôles, puis à réception locale |

Le passage Web emploie les sources UI du même commit et un hôte de test utilisant les runtimes extraits ; les six E2E emploient le vrai exécutable PROD extrait. Le lancement interactif normal de DEV n’a pas été mesuré ; ses binaires communs sont identiques et son contrôle natif est passé. Les tests LDAP utilisent des réponses représentatives et des objets de transport construits localement, pas `cnamts.local`.

Le ZIP de preuves conserve notamment `domenia-v2-ci/logs/critical-csharp.log`, les compilations, puis `domenia-v2-delivery/logs/delivery-result.json`, `startup-*.json`, `browser-evidence.json`, `manual-package-verification.json`, `web/`, `web-preflight/` et `ui-simulation/`. Aucune dépendance téléchargée, aucun runtime installé ou modifié, aucune configuration de service ou réseau modifiée. `dev/` et la garde stricte `release-guard.py` sont inchangés ; WAPT est exclu. Aucun appel ni écriture au domaine réel.

## Examen visuel et portée

Les assistants ont examiné séparément les 34 PNG Web/précontrôle, les 35 PNG Accueil/Opérations et les 36 PNG Fiche/Paramètres/Synchro, avec planches comparatives et agrandissements des vues utiles. Aucun nouveau défaut bloquant constaté sur ces captures ; les réserves restent décrites ci-dessous. Le reçu distinct `REVUE-VISUELLE-V2.0.1.json` énumère les images examinées et leurs empreintes ; il ne modifie pas les preuves CI ni leur `visualReview: pending`, qui ne constatait qu’une production automatisée. La recette humaine reste en attente.

Les états ciblés couvrent déconnexion, attente de connexion, connexion sans OU, sélecteur, première lecture nécessaire, actualisation avec SHA, interruption, confirmation de reprise, fin de traitement et Fiche sans historique. Les positions sont également testées sur une observation de **18 secondes**, avec rectangles et débordements, thèmes et animations normaux/réduits. Le test de dimensions utilise 800, 1 024 et 1 028 px effectifs ; la demande de 1 280 px était bornée par le viewport Windows de 1 028 × 749. Les vues de fenêtre E2E font 1 008 × 681 ; les clichés ciblés de blocs ont leurs propres dimensions, sans constituer d’autres tailles de fenêtre. Les contrôles géométriques complémentaires dans Chrome local ont exercé 1 008 × 681 et 1 495 × 900 ; ils ne constituent pas des mesures DPI natives Windows.

Limites visibles conservées : certains toasts transitoires couvrent une partie du texte de reçu, sans cacher les commandes finales ; l’action Échap du scénario Fiche n’a pas d’assertion de fermeture du panneau, donc cette fermeture n’est pas déclarée vérifiée ; un titre Synchro est partiellement cadré après le défilement forcé du harnais. Dans `accueil/actualiser-ou/13-journal.png`, le début du résumé et le badge sont rognés à gauche, tandis que la ligne récapitulative complète, les étapes et les actions restent accessibles. Un défilement horizontal interne provoqué par le centrage du harnais est une hypothèse, non une cause mesurée : aucune absence totale de rognage n’est revendiquée. Les six photos mentionnées dans la demande n’étaient pas jointes : les descriptions et les défauts reproductibles dans le code ont guidé le travail.

## Échecs intermédiaires conservés

| Source / run | Résultat et suite |
| --- | --- |
| `9ee99a0c` / 40290246637 | 678/679 C#. Une assertion imposait à tort un encodage BER court ; corrigée pour contrôler indépendamment structure, flags et absence d’octets supplémentaires. |
| `89dc7c7d` / 40291924402 | 679 C# et contrôles Python passés ; mesure arrêtée par un filtre de titre de fenêtre incorrect. Sonde corrigée pour suivre la fenêtre réelle. |
| `760798bf` / 40292637282 | Passage annulé explicitement car la correction de sonde était nécessaire ; aucun succès déduit. |
| `d4d4aa24` / 40293872341 | Mesures natives passées ; échec Web sur l’URL relative du CSS des widgets. Correction du chargement et ajout du précontrôle. |
| `ff515eeb` / 40296197015 | Passage intégral réussi, puis examen des 99 PNG : CTA, débordement de 4 px et notifications corrigés avant le passage final. Ces packs ne sont pas livrés. |

## Nouvelle recette de David et validations absentes

Suivre la [recette 2.0.1](../../RECETTE-MANUELLE-V2.0.1.md), fournie aussi avec les packs :

1. Vérifier le SHA256, extraire dans un dossier neuf ; chronométrer premier et second lancement, puis connexion séparément.
2. Utiliser « Se connecter » ; pour un autre compte, ouvrir Comptes et vérifier la fenêtre native, Tab, Échap, annulation et réessai.
3. Vérifier l’invitation sans OU, le sélecteur avant/après connexion et la mémorisation de l’OU autorisée.
4. Lancer « Mettre à jour la base locale de l’OU », lire le plan, confirmer ; vérifier sauvegarde/SHA complet, lecture, stockage et reçu.
5. En cas d’erreur, conserver le diagnostic expurgé ; vérifier ancienne base, arrêt des nouvelles collectes et reprise explicitement confirmée.
6. Observer Accueil/Fiche au moins 18 secondes, varier tailles, thèmes et animations ; essayer les DPI disponibles, notamment 125/150 %.
7. Changer d’OU puis de compte et vérifier qu’aucun résultat ancien ni nouvelle écriture implicite n’est appliqué.

Restent **non exécutés** : reproduction sur l’OU réelle, lecture/authentification/droits du domaine, recette native clavier/focus/Échap et clic précis d’annulation, les deux VM, les DPI Windows 125/150 %, une mesure comparable avant/après sur le poste de David et sa recette manuelle. Les éventuelles écritures de recette restent limitées à `OU=Domenia-Tests,DC=cnamts,DC=local`, avec toutes les confirmations ; aucune écriture réelle n’a été faite ici.

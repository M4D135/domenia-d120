# RC1.17.38 — contrôle visuel et chronométrage externe

Complément du 20 octobre 2026 sur le pack PROD RC38 exact, source `37fb757`.
Aucune modification du runtime ; packs DEV et PROD inchangés, empreintes vérifiées.

## Résultat ciblé

Le sélecteur UI Automation du menu Outils était indisponible dans le banc ; cette
tentative est archivée et ne compte pas comme réussite. Le contrôle a été terminé
par clics réels dans la console, puis lecture des captures.

Connexion Windows réelle, accueil, navigation Outils → Accueil, agrandissement et
rétablissement réussis. Captures relues à 1140 × 852 : connexion lisible et entièrement
visible ; accueil et Premiers pas rendus, lecture seule visible ; navigation et barre
inférieure accessibles, contenu long dans sa zone défilante. Fermetures normales
confirmées. Aucun verrouillage pendant les passages retenus. Il s'agit d'une revue
des captures et des actions effectuées, pas d'une recette humaine exhaustive.

## Mesures au repos

Même VM conservée (1 vCPU, 4 Go), même profil isolé réinitialisé avant chaque passage,
lanceur natif, authentification Compte Windows. Aucun inventaire de parc volumineux.
Avant chaque départ : trois échantillons de deux secondes, CPU moyen < 15 %, pic
< 25 %, mémoire disponible > 600 Mo. Les attentes et échantillons sont conservés.
Aucun service, antivirus, réglage de sécurité ou configuration de la VM modifié.
Une touche Ctrl relâchée périodiquement maintient la console active pendant l'essai.

Le chronomètre **Stopwatch de l'hôte**, hors VM, observe à 100 ms les marqueurs
VirtualBox émis juste avant le lancement, à la connexion et à l'accueil initialisé.
L'intervalle maximal observé entre lectures figure dans Comparison.json. Ces bornes
comprennent le coût des marqueurs, du lancement et de l'authentification automatisée.
Une capture de connexion est prise de la même façon dans chaque passage. La revue
visuelle et les interactions finales sont faites après le marqueur d'accueil.
Les durées Stopwatch internes au guest restent archivées mais ne servent pas à cette
comparaison : elles divergeaient de l'horloge lors de la première série.

| Passage | Connexion (s) | Accueil (s) | CPU moyen avant départ |
|---|---:|---:|---:|
| BeforeIdle1 | 32.36 | 131.82 | 12.73 % |
| BeforeIdle2 | 30.29 | 128.31 | 14.54 % |
| AfterIdle2 | 23.72 | 111.87 | 13.25 % |
| AfterIdle3 | 21.33 | 108.80 | 13.54 % |

Médianes (2 passages par version) : **connexion 31.32 → 22.52 s ; accueil 130.07 → 110.34 s**.
**Gain global non démontré** : petit échantillon et dispersion ; ces relevés ne
constituent ni un engagement de performance ni un gain reproductible sur un autre poste.
Le bénéfice isolé du validateur d'exports (7,56 → 0,13 s) reste établi par le banc précédent.

L'ordre initial était RC38 / RC37 / RC37 / RC38. Le premier RC38 a reçu une lecture
diagnostique des processus dans le guest pendant le démarrage : il est exclu de la
comparaison et conservé seulement comme preuve fonctionnelle. Un unique RC38 de
remplacement a été exécuté, sans inspection supplémentaire ni autre test dans le guest.
La comparaison retenue est donc RC37 / RC37 / RC38 / RC38, avec caches déjà sollicités ;
ce n'est pas un essai randomisé ni un démarrage à froid. Aucun autre passage n'a été
sélectionné selon sa vitesse. Les cinq fermetures normales et les preuves sont conservées.

## Portée et nettoyage

Contrôle demandé terminé ; aucun nouveau correctif bloquant identifié. Les validations
AD/WMI, santé et sauvegarde précédentes restent datées de leur version. Pas de nouvelle
campagne, ni qualification multiécran/DPI physique, Narrateur ou endurance. Qualification
générale et publication formelle toujours non déclarées acquises.

Tâches temporaires et propriété de chronométrage supprimées ; runtime de mesure remis
en RC38 ; VM **DOMENIA-FIRSTRUN-20261020 conservée**, serveur AD intact.

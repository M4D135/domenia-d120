# RC1.17.38 — démarrage mesuré

Deux suppressions de travail répété : les 3 059 exports sont vérifiés dans un
instantané des fonctions visibles, au lieu de 3 059 appels au fournisseur Function.
Chaque fonction doit toujours exister et provenir du fichier exact du plan fermé.
Le XAML principal reste prévalidé dans ConvertFrom-DomeniaXaml, puis construit
par le chargeur WPF ; son appel de prévalidation préalable en doublon est retiré.
Aucun contrôle d'intégrité, de sécurité ou de disponibilité n'est supprimé.

## Mesures dans le labo

Windows PowerShell 5.1.26100.6584 x64 STA, DOMENIA-FIRSTRUN-20261020, 1 vCPU / 4 Go.
Lanceur PROD natif, session Windows ouverte, authentification réelle par le bouton
Compte Windows. Copie isolée et même profil local restauré avant chaque lancement :
base du domaine initialisée, sans inventaire de parc volumineux. Aucun autre test
n'est exécuté dans la VM pendant ces mesures.

Repos préalable : trois échantillons CPU de deux secondes, moyenne < 25 %, maximum
< 35 %, mémoire disponible > 600 Mo. Les valeurs effectives figurent dans les JSON.
La VM conserve une activité système de fond (environ 15–20 % lors de la préparation),
y compris sans application. « Au repos » signifie ici sans autre travail lancé,
avec ce seuil commun aux deux versions ; pas un processeur à 0 %. Le seuil initial
plus strict a refusé deux départs et aucun de ces départs n'entre dans les mesures.
Le cache disque et l'antivirus ne sont pas
neutralisés. Aucun service ni stratégie Windows n'est modifié.

| Passage | Connexion visible (s) | Fenêtre principale détectée (s) | CPU avant lancement (moyenne) |
|---|---:|---:|---:|
| Before5 | 36.98 | 149.57 | 17.97 % |
| After5 | 27.99 | 132.71 | 16.89 % |
| After6 | 24.22 | 114.46 | 22.53 % |
| Before6 | 29.37 | 122.03 | 15.84 % |

**Gain global non concluant.** Les lancements sont dispersés et les horodatages
Windows divergent du chronomètre Stopwatch. Les nombres ci-dessous restent des
relevés du labo ; ils ne démontrent pas une accélération globale reproductible.

Médianes de deux passages par version : **connexion 33.18 → 26.11 s ; fenêtre principale 135.80 → 123.59 s**.
Ordre avant/après/après/avant. Les temps partent du lancement de Domenia.exe et
incluent PowerShell, les contrôles du pack et, pour l'accueil, l'authentification.
Après le clic de connexion par UI Automation, le banc lit la trace et observe
la fenêtre par les API natives (titre Accueil, handle visible). Il ne parcourt pas
l'arbre UI Automation du dashboard pendant le chronométrage. La clôture normale
est vérifiée. La présence de la fenêtre et la fin d'initialisation ne constituent
pas une validation visuelle humaine ou de toute son interactivité. La session
reste ouverte mais peut être verrouillée (SessionLocked dans chaque JSON).
Les valeurs LoggedSeconds donnent aussi les horodatages des traces ; les compteurs
Stopwatch de la VM et son horloge murale ne sont pas confondus. Ces observations
de labo ne garantissent pas les temps d'un autre poste. L'attente humaine n'entre
pas dans la mesure.

Les premiers essais du banc sont exclus. Le premier : création du profil et sélecteur trop strict
sur le début du titre de fenêtre (l'application le remplace par « Accueil … — Domenia »).
Il ne constitue ni une mesure retenue ni un échec applicatif. Le sélecteur corrigé
et le même profil initialisé sont utilisés pour les quatre passages ci-dessus.
Les essais de parcours UI Automation complet sont également exclus : référence
périmée pendant une transition, puis appel de parcours qui bloque le pilote.
Le pilote a été arrêté, l'application fermée normalement. Le banc final observe
la trace et la fenêtre native, selon la même méthode pour les quatre passages.
Aucun passage échoué ni mesure de l'ancien pilote n'entre dans les médianes.

## Contrôle isolé des exports

Même processus Windows 5.1, les 3 059 fonctions réelles déjà importées du pack,
ordre avant/après/après/avant : **7562 → 128 ms**
(médianes). La référence reprend le corps du contrôle avant modification ; le
résultat complet de validation est identique. Ce coût isolé ne prédit pas le gain
total de démarrage. Voir `pack/ImportBenchmark.json` et son harness.

## Vérification ciblée

- 10 cas natifs : exports valides, alias, origine incorrecte, disparition d'un export,
  portée enfant, chargement WPF réel, contenu de bouton double, membre WPF invalide,
  contrôle critique absent. Les cas erronés restent refusés.
- Parseur et compatibilité 5.1 des trois fichiers PowerShell modifiés ; CheckOnly
  du pack PROD complet réussi. Empreintes liées dans SourceBindings.json.
- Packs DEV et PROD régénérés, 172 fichiers applicatifs identiques, gardes de
  construction réussis. Contrats workers inchangés.

Pas de nouvelle campagne AD/WMI, santé, sauvegarde, endurance, matériel multi-écrans
ou Narrateur. Les preuves précédentes restent datées de leur version ; la qualification
générale et la publication formelle ne sont pas déclarées acquises. VM conservée.

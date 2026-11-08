# TRV313 — placement réel des requêtes Poste et réorganisation des tableaux

Lot Codex du 25 octobre 2026. Sources D1 lues seulement. Aucun build, test C# ou test navigateur lancé sur le Mac ; compilation et recette réservées à la VM Windows, orchestrées par le parent. Aucun statut global de parité promu.

## Chemins réellement reliés

`requetes.widget.save` conserve l’écriture de bibliothèque et place maintenant le widget Computer dans `poste.computerLayout`, consommé par `overview.js` puis `poste.layout.query`. L’ajout prend la dernière préférence disque sous le verrou du document ; une disposition existante, même `[]`, reçoit seulement la carte demandée. Un premier passage depuis la page livrée conserve ses cartes par défaut et les liens Computer explicites déjà affichés par son ancien montage. Une simple recette de bibliothèque ne crée aucune carte. Quota de 64, ordre, titres, sections, tailles, pauses et preuve de migration existants conservés.

La carte native conserve le domaine, l’ID de recette, la révision et l’empreinte d’origine, et l’ID exact du lien de widget. Son calcul suit ensuite uniquement les révisions explicitement liées par l’Atelier, après qualification du domaine, de la recette, de la révision disponible et du hash. Les liaisons D1 sans cet ID restent épinglées à leur révision importée. Retrait ou archive ne choisissent jamais une recette de remplacement.

Bibliothèque et préférences restent deux écritures distinctes. Le reçu précise si le widget est enregistré mais son placement refusé (document inconnu, quota, choix local en attente, concurrence, accès refusé). `requetes.widget.place` permet un réessai explicite avec ID, révision et empreinte affichés, sans créer une autre recette. Le retrait enlève aussi sa carte native ; si la préférence refuse, le message signale la carte résiduelle sans calcul. Aucun droit ni collecte distante n’est accordé par ces gestes.

Le montage Poste antérieur sans disposition évalue lui aussi un seul poste, sans calcul de toute la population. Deux évaluations au plus sont lancées simultanément par ce montage. Les seuls visuels proposés aux nouveaux widgets Computer sont verdict et explication ; les graphiques de population restent réservés au parc. Logiciels garde ses vrais widgets logiciels : D1 ne lui donnait pas de widgets Query ou Probe.

## Éditeur et concurrence

L’éditeur partagé Poste/Logiciels permet le glisser-déposer par poignée, avec boutons Monter/Descendre conservés pour le clavier. Les champs saisis, les sections, la pause, la présentation et la liaison de recette suivent la carte. Un texte ou fichier déposé de l’extérieur ne crée rien.

Un jeton SHA du choix montré à l’ouverture accompagne la sauvegarde. Il est comparé au dernier choix disque sous verrou ; un ancien dialogue ne peut donc effacer une carte ajoutée entre-temps. Après refus, l’éditeur recharge une lecture locale bornée du choix actuel. Le jeton distingue l’absence et `[]`, reste stable après indentation du JSON, et protège aussi les dispositions Logiciels.

`IAtomicPreferenceStore` fournit cette mutation ciblée et une lecture actualisée bornée. FilePreferenceStore réutilise le lecteur strict de migration (1 Mio), refuse les formats/champs racine inconnus, garde les autres clés et les choix locaux en attente, n’installe aucun état mémoire optimiste sur échec. Les champs futurs ou doublons d’une disposition sont refusés avant un ajout ciblé. Le remplacement volontaire d’une disposition incompatible reste possible depuis l’éditeur avec son jeton courant.

## Vérification préparée

Huit nouveaux tests C# couvrent : `[]` contre absence, conservation des liens déjà affichés, réessai sans modifier pause/titre, deux instances obsolètes et ajouts concurrents, ancien éditeur refusé puis relecture et choix explicite, vrai geste Bridge vers le calcul Poste, révision épinglée puis migration explicite, pause/retrait, reçu partiel et reprise, quota et champs futurs, revalidation de bibliothèque au callback verrouillé, source racine inconnue, choix en attente et annulation. La table des opérations déclare le nouveau geste LocalWrite.

Deux tests navigateur supplémentaires utilisent les vrais composants : déplacement Poste/Logiciels avec conservation de la liaison et du jeton, puis Atelier avec visuels adaptés, reçu partiel, absence de plan distant après échec et réessai sans deuxième enregistrement. Ils sont enregistrés pour la future recette Windows, non exécutés.

## Limites et suite

L’atomicité couvre un document de préférences, pas une transaction distribuée bibliothèque/préférences ; les deux résultats sont affichés séparément. La lecture d’un résultat local reste datée, et une bibliothèque modifiée après cette lecture sera requalifiée au prochain calcul. Les cartes D1 importées ne suivent pas automatiquement les nouveaux liens natifs.

Ce lot ferme le raccordement des nouveaux widgets Query au tableau Poste et la réorganisation manuelle des vrais tableaux Poste/Logiciels. Les cinq versions restaurables de disposition utilisées par l’écran Interface ne sont pas encore raccordées à ces tableaux ; cela reste un manque de parité distinct à traiter. Les présentations D1 exigeant une série chronologique ou une topologie absente des données locales restent des adaptations annoncées, pas des graphiques inventés. L’audit et la recette des parcours réels restent nécessaires avant toute promotion de TRV313.

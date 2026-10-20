# Qualification ciblée RC1.17.35 et correctifs RC1.17.36

**Qualifications fonctionnelles ciblées terminées le 20 octobre à 13:35 UTC.**
Le dernier parcours valide la réouverture de la base restaurée, la lecture réelle
de l’OU Domain Controllers (DC01 seul), la préparation locale du dashboard et la
persistance de la fin de Premiers pas.

Travail direct, sans Spark, dans **DOMENIA-FIRSTRUN-20261020** (Windows PowerShell
5.1.26100.6584, x64 STA). VM conservée, UUID
`bc2f1ac0-9545-49bd-a0f5-cb89d352cf61`. Aucun objet AD modifié ; le contrôleur DC01
sert uniquement aux lectures. Les autres VM sont hors périmètre.

## Corrections livrées

- Au démarrage, les préférences sont chargées avant l’ouverture de SQLite. Une base
  restaurée est ainsi reprise dès le lancement suivant, même si l’original est corrompu.
- La grille de résultats garde une hauteur utile à 1280 × 800 : les actions du
  relevé rejoignent le panneau repliable existant, au lieu de prendre toute la hauteur.
- L’analyse locale du domaine utilise le délai SQLite du contexte, sans imposer 250 ms.
- Un relevé avec ping préalable repart à zéro pour la phase WMI : **1/1**, et non
  **3/1**, pour deux postes dont un seul répond. Son bilan conserve les deux pings.
  Un ping positif ne valide plus prématurément le poste dans le plan de reprise ;
  les indices du plan restent corrects après filtrage. Un lot entièrement muet se clôture.
  Un poste muet n’est pas décrit comme un refus WMI mémorisé.
- WiringCache utilise les dépendances et contrats actuels, dont les reçus SQLite
  réels. Son extraction AST est mise en cache sans changer la sélection des fonctions.
  Le filtre optionnel ne prétend jamais constituer une exécution complète.

La référence de préchargement est régénérée. Elle rattrape aussi les empreintes de
`Complete-DomeniaIndexScopeUi` et `Fail-DomeniaInventoryUi`, déjà modifiées dans
le commit de départ ; leurs corps ne sont pas changés ici.

## Preuves Windows

| Contrôle | Résultat |
|---|---|
| Boards complet | **66/66**, rapport `final-suites/Boards.json`. |
| WiringCache | **190 cas couverts** : passe complète 188/190, puis les deux échecs corrigés et rejoués seuls, 2/2. Voir `WiringCoverage.json` ; ce n’est pas une nouvelle passe complète unique. |
| Santé | **20/20 + 17/17**, règles, couverture inconnue, dates, seuils hérités, suspensions et comparaisons. |
| Stockage ciblé | **10/10**, 61 assertions, vraies bases SQLite temporaires. |
| Phases ping/WMI | Deux scénarios de régression : mélange en ligne/muet et lot entièrement muet ; compteurs et reprise durable vérifiés. |
| AD et WMI réels | Lecture de DC01, endpoint muet `10.77.0.254` puis DC01. Le délai WMI du premier ne bloque pas le second ; reçus SQLite vérifiés. |
| Démarrage, fenêtre et réglages RC35 | Deux lancements du vrai PROD ; taille/position/état maximisé et réglages sauvegarde 48 h / 5 copies conservés. |
| Sauvegarde automatique RC35 | Déclencheur réel de 60 s conservé ; sauvegarde après réouverture, marqueur relu et `quick_check=ok`, 172 fichiers applicatifs inchangés. |
| Restauration par l’interface | Complément final dans `ui-out/RestoreVerified-Result.json`. Base corrompue volontairement dans un profil jetable, restauration vers une nouvelle base, original et sauvegarde source conservés. |
| Premiers pas RC36 | Complément final dans `ui-out/FirstStepsReopen-Result.json` : OU Domain Controllers, lecture AD bornée puis première vue. |
| Pack RC36 final | `rc36-reopen-targeted/` : parseur PS5.1 sur les deux fichiers du dernier correctif, préférences **7/7** et CheckOnly. SHA-256 des ZIP enregistrés ; 172 fichiers applicatifs identiques DEV/PROD. |

Pour la restauration, la destination réellement confirmée est le nouveau fichier proposé
par l’assistant, pas le chemin personnalisé initialement tenté par le pilote. L’écran
« étape 3/3 » et la relecture indépendante confirment la copie, son marqueur et le
choix durable. `UiAction.Passed=false` dans le rapport final décrit une seconde
tentative de clic effectuée après la fermeture de la confirmation ; ce clic n’est
pas compté comme une preuve positive. Le relancement a ensuite révélé le chargement
trop tardif de la préférence : le correctif et son contrôle sont séparés dans
`FirstStepsReopen-Result.json`.

Le timeout WMI est un véritable appel vers une adresse non joignable : seul le délai
sans progrès de ce premier endpoint a été réduit à 2 s ; DC01 conserve son délai
normal de 25 s. Aucun transport, callback ou stockage n’est simulé dans ce parcours.
Les suites de règles et d’intégration utilisent, elles, des données synthétiques et
des doubles de réseau : elles ne sont pas présentées comme des lectures AD réelles.

Le banc historique de 5 000 postes imposait 120 ms au modèle exécuté dans le
Dispatcher. Le calcul est désormais dans `LocalIndexRead`, avec un budget de
production de 120 s et la couverture individuelle de santé. Le test exécute
maintenant cette branche `ComputeBoard`, vérifie qu’elle est demandée au worker et
absente du callback WPF : **43 582 ms pour 5 000 postes / 46 groupes** dans cette VM.
L’ancienne assertion échouée reste conservée. Aucun gain de vitesse ni qualification
à grande échelle n’est revendiqué.

## Traçabilité et limites

Les rapports RC35 portent les octets RC35 ; les corrections ont nécessité RC36.
`SourceBindings.json` décrit les fichiers modifiés et les packs finaux. Les preuves
antérieures ne sont pas réétiquetées comme des exécutions intégrales de RC36.
Le contrôle natif complet dans `rc36-final-native/` précède le dernier correctif
de démarrage : les workers et les modules n’ont plus changé ensuite. Seuls le cœur
et le test de préférences ont été reparsés dans la dernière passe ciblée. La
repasse globale commencée pendant les lenteurs de Windows a été interrompue, sans
être comptée comme un succès.
Les tentatives intermédiaires sont conservées ; une console verrouillée et la faible
priorité des tâches de test ont retardé l’automatisation graphique. Windows a
également installé une mise à jour au redémarrage. Le premier pilote RC36 a
atteint sa borne de 300 s ; la même application, ensuite arrivée à l’accueil,
a été reprise pour les contrôles fonctionnels. Aucun temps de démarrage nominal
ni gain de performance n’est qualifié par ce parcours. Le contrôle final
s’appuie sur les états de l’interface et la relecture indépendante de SQLite.
Aucun mot de passe n’est enregistré dans ces preuves.

Limites personnelles déjà acceptées : endurance/grand parc, multi-écrans et DPI
matériels, écoute humaine Narrateur, variantes LAPS et matrice de matériels réels.
Aucune nouvelle campagne générale n’a été lancée. Les décisions externes et le
certificat restent séparés : `acceptance_passed` général et `Publishable=false`
ne sont pas transformés en succès par cette recette ciblée.

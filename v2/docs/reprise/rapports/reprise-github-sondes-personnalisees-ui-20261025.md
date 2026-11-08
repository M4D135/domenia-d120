# Reprise GitHub — interface des sondes personnalisées TRV-191

Date : 25/10/2026. Base GitHub du lot interface : `fea4c18117d07145d669859f16140739dde03329` (Accueil durable et collectes de widgets ; même arbre que le commit local initial). Branche de travail : `codex/v2-finalisation-20261025`.

## Écart constaté

Le tiroir « Ajouter un widget », onglet « Sondes WMI », affichait uniquement le catalogue et ses contrats. Aucun parcours de préparation, d’import ou d’édition des sondes personnalisées ne consommait les nouvelles opérations du profil. Les messages d’ajout annonçaient encore une collecte reportée à l’actualisation globale alors que les widgets disposent désormais de leur collecte ciblée.

## Changements de ce lot

- `web/js/pages/accueil/personal-probes.js` : module intégré dans l’onglet Sondes ; document JSON éditable, exemple à adapter, chargement par le sélecteur de fichiers existant, versions déjà enregistrées et reprise d’une version dans l’éditeur.
- L’aperçu appelle seulement `accueil.probes.preview`. Il montre les candidats, leurs droits, leur coût, les limites et le sens de l’inconnu, ainsi que les anciennes versions conservées.
- Le bouton de confirmation transmet à `accueil.probes.apply` le texte exact, le jeton du catalogue consulté et l’empreinte du document retournée par l’aperçu. Une modification, une fermeture ou une réponse tardive ne peut pas confirmer un autre document.
- Refus de validation ou conflit de profil : document conservé. Un conflit exige une actualisation locale puis un nouvel aperçu volontaire ; aucune nouvelle tentative d’écriture automatique.
- Limite locale avant l’appel : 262 144 caractères et 262 144 octets UTF-8. Aucun document trop grand n’est tronqué.
- Après réponse, le reçu du moteur distingue persistance confirmée et mémoire seule. Le vrai catalogue est rechargé. L’import ne crée aucun widget et ne demande aucune collecte ; le bouton « Ajouter » utilise ensuite le parcours normal du tableau.
- `tools.js` : fermeture/destruction du module, protection des réponses tardives, texte d’ajout corrigé et absence de succès « Affiché » si la disposition n’a pas enregistré le widget.
- `css/pages/accueil.css` : présentation du document, des versions et de l’aperçu avec les composants et variables existants.
- `mock-accueil.js` : catalogue personnel vide et non persistant ; prévisualisation/application refusées explicitement sans le moteur. L’aperçu navigateur ne simule pas une validation stricte réussie.

Le moteur TRV-191, ses clés immuables `custom.<SHA256>`, le stockage et les lecteurs sont un lot coordonné séparé. L’interface n’étend pas leurs classes autorisées ni les transports.

## Vérification et tests préparés

Relecture des changements et contrôle des espaces par `git diff --check`. Aucun test lancé, aucune preuve UI/native produite dans cette session pour ce lot.

`tests/web/personal-probes.test.mjs` contient sept scénarios critiques écrits :

1. Aperçu réel des droits/coût/inconnu, puis annulation sans écriture ni collecte.
2. Confirmation liée au texte exact, au choix et à l’empreinte ; nouvelle version distincte.
3. Conflit du profil, conservation du document et nouvel aperçu requis.
4. Déclaration refusée et reçu mémoire signalés sans faux succès disque.
5. Modification ou destruction pendant un aperçu en attente.
6. Chargement de fichier sans application et borne UTF-8 sans troncature.
7. Vrai tiroir Accueil : catalogue rechargé après import, aucun widget ajouté à l’import, puis ajout explicite par clé immuable.

Ces scénarios et les tests natifs associés doivent être exécutés après commit/push, seulement dans la sélection critique des deux VM Windows. La recette UI/native doit confirmer sur les deux VM : import sans lecture réseau, relecture du profil après redémarrage de l’application, ancienne version conservée après édition, ajout/confirmation du widget, collecte sous la clé exacte, refus de déclaration invalide et exclusion des contrôleurs. Aucun reboot ou logoff n’est requis.

## État de livraison

Implémentation de l’interface écrite ; compilation de ce lot, tests critiques et recette UI/native non vérifiés à la rédaction. Aucun changement de statut fondé sur une compilation. Publication PROD/DEV v2.0.0 toujours conditionnée aux deux VM et aux preuves UI/native vertes.

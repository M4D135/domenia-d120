# KIT-GUIDES : fabriquer un guide Word et PDF à partir d'un texte

Une seule source (un texte en Markdown simplifié et une fiche JSON) donne le `.docx` et le `.pdf` : page de garde,
sommaire cliquable, titres de chapitres, étapes numérotées, tableaux, encadrés, figures légendées,
blocs de commandes, en-tête et « Page n sur N ». Outil tiré des guides de Pesto 1.0.

Prérequis : Node.js 18 ou plus ; pour le PDF, Google Chrome, Chromium ou Microsoft Edge (détecté sous macOS,
Windows et Linux ; sinon variable `CHROME`). Images PNG ou JPEG.

    npm ci
    node build_guide.js exemple/exemple.json          # essai : exemple/build/*.docx, *.html, *.pdf
    node build_guide.js guides/mon-guide.json         # ajouter --no-pdf sans navigateur

Pour livrer un PDF avec exactement la mise en page du Word, générez le DOCX avec `--no-pdf`,
puis exportez ce DOCX en PDF depuis Word ou LibreOffice et vérifiez chaque page. Le PDF produit
directement par le navigateur est un rendu HTML indépendant, dont la pagination peut différer.

Une figure JSON accepte aussi `"crop": {"x": 240, "y": 140, "w": 1000, "h": 500}` :
coordonnées en pixels de la capture originale. Le cadrage est appliqué dans Word et HTML ; le PNG
complet reste intact dans le DOCX. Gardez les panoramas comme repères et cadrez les commandes
utiles aux étapes pour une lecture sur papier. Les dimensions hors image sont refusées.

Recadrage exact d'une capture (macOS) : `swift crop_image.swift entrée.png sortie.png x y largeur hauteur`.
Texte lu dans les captures (macOS) : `swift ocr_image.swift images/*.png` (repérer « SIMULATION », « démo »… avant livraison).
Relecture des pages : `swift pdf_pages.swift fichier.pdf dossier 900` (macOS) ou `pdftoppm -png -r 80 fichier.pdf page`.
Texte et fiche en UTF-8 ; le programme refuse les écarts de syntaxe courants avec le numéro de ligne.

La syntaxe du texte, les champs de la fiche et la méthode complète sont dans `PROMPT_GUIDES_AUTRE_LOGICIEL.md`
(version à coller : `PROMPT_GUIDES_AUTRE_LOGICIEL.txt`). `exemple/` montre chaque élément de syntaxe.

## Guides Domenia

Les sources `technicien.md` et `administrateur.md` décrivent Domenia **1.0**. Leur fiche JSON associe
les figures à des PNG natifs ; les livrables finaux sont copiés dans `../DOC/`. La référence interne
de la passe est RC1.17.10, datée du 16 octobre 2026 ; les guides destinés aux utilisateurs conservent
la version produit 1.0, sans journal des changements.

    node build_guide.js technicien.json --no-pdf
    node build_guide.js administrateur.json --no-pdf

Le harnais `captures/capture-guides.ps1` se lance avec Windows PowerShell 5.1 x64 en STA, sur la
copie de validation du pack DEV. Il charge le vrai XAML et les fonctions de présentation, puis
emploie des données explicitement fictives. Il ne se connecte pas à l’annuaire et ne relève aucun
poste. Les captures documentaires sont rendues à au moins 1920 × 1080, sans agrandissement d’image
ni infobulles. Les images `*-viewport-*` de 720 pixels servent au contrôle de disposition et sont
exclues des guides. Ces rendus WPF ne constituent pas une validation d’un parcours humain à la
souris ; cette vérification doit rester décrite séparément.

Les figures conservées couvrent notamment Outils → Atelier de requêtes, la barre Requêtes de Rechercher avec
ses sources et favoris, les résultats inconnus, la Base autonome et le panneau existant État du
moteur. Les valeurs de performance de ce dernier sont illustratives, pas un benchmark.

Avant livraison : conserver `capture-provenance.json`, `capture-layouts.json` et `capture-checks.json`,
vérifier les empreintes des PNG, ajuster les cadrages JSON aux contrôles réellement capturés,
produire le PDF depuis le DOCX et inspecter chaque page. Recalculer ensuite les empreintes des
quatre fichiers finaux et le rapport de contrôle documentaire. Une compilation réussie seule
ne remplace pas la relecture du rendu.

La logique d’actualisation de l’OU est décrite par des tableaux natifs dans les guides. Les vues
générales montrant un ancien parcours de boutons ou de dates sont exclues de cette édition.
Les captures conservées illustrent uniquement les contrôles encore applicables ; leurs PNG
originaux et leur provenance sont préservés. Aucun nouveau rendu Windows n’est revendiqué pour
cette édition tant que les nouveaux rendus ne sont pas retenus. Le résultat de la tentative
Windows et le contrôle des quatre documents sont décrits dans
`../validation/2026-10-16/windows-recovery/` ; les anciens originaux et leur provenance restent conservés.

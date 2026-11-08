# Identité visuelle Domenia V2

Décision de David du 28 octobre 2026 : Domenia V2 est la référence d’interface des outils ; les icônes suivent la famille GLPI. Les jeux sont exclus. Coordination avec GLPI, PESTO2 et FILPRO2 : symbole métier blanc épais avec relief léger, petit accent turquoise. Chaque produit garde son motif. Dernier choix explicite de David : le fond Domenia est rouge pastel, en remplacement du bleu / indigo initial. Domenia utilise un D et un arbre de domaine à trois nœuds.

## Fichiers livrés

- `web/assets/brand/domenia-master.png` : image originale générée, conservée sans modification.
- `web/assets/brand/domenia.png` : déclinaison 512 px pour le shell, la connexion et le navigateur.
- `web/assets/brand/domenia.svg` : variante monochrome simplifiée pour le contraste élevé ; pas une vectorisation du master.
- `src/Domenia.App/Branding/Domenia.ico` : neuf images PNG 32 bits, 16 / 20 / 24 / 32 / 40 / 48 / 64 / 128 / 256 px.

L’icône est incorporée à l’exécutable et aux fenêtres natives ; le logo de connexion est une ressource embarquée. Les composants de l’interface découpent le carré selon leurs coins arrondis existants. Le contraste élevé remplace l’image par le symbole monochrome ; les animations du shell sont conservées.

## Production de l’asset

Outil intégré ImageGen, mode référence de style, fond opaque. Référence : master GLPI fourni par son chat de développement, représentant un ticket plié et une flèche. Ce motif n’est pas repris. Les réductions et l’encapsulation ICO sont des exports du master, sans nouvelle génération ni modification de son dessin.

Prompt initial de création du motif :

> Use case: logo-brand. Create a production app icon for Domenia V2, a Windows Active Directory administration application, as a sibling of the provided GLPI icon. The reference is STYLE AND MATERIAL ONLY: do not copy its ticket, folded document, arrow or exact symbol. Keep its luminous royal blue #066DDB to indigo #6658F5 full-bleed square opaque background, gently dimensional thick white symbol, tiny turquoise #19C3B2 accent, soft restrained highlights and clean edges. Subject: a highly legible bold capital D monogram, whose open counter contains an extremely simple three-node directory tree: one round node linked to two others, crisp and balanced. Make the D geometric, rounded, white ceramic-like with very subtle volume, front facing, not tilted. One small turquoise node provides the accent. Symbol centered, occupying about 66–70% of canvas, enough calm breathing space to remain recognizable at 16/32 pixels. Minimal details, solid silhouette, professional elegant playful finish matching GLPI. No lettering besides the D symbol, no product name, no slogan, no watermark, no border, no outer rounded-square container, no transparent area. The whole square canvas is the smooth blue/indigo background. Single final icon, not a mockup or presentation board.

Prompt final d’édition, appliqué au master bleu initial avec ImageGen, fond opaque :

> Edit the supplied Domenia application icon. Preserve the exact existing white D monogram, its shape and placement, the three-node directory tree, the turquoise top node, all highlights, proportions and restrained ceramic-like dimensional finish. Change ONLY the entire blue/indigo square background, including the background visible inside the D and behind the tree, to a soft pastel red / dusty coral-red gradient: warm light coral red #EFA3A1 at the top left blending gently to muted pastel red #D97880 at the bottom right. The result should read red pastel, softly saturated and calm, not hot pink, orange, burgundy or saturated scarlet. Adjust reflected background tint and shadow color subtly to harmonize with the red background, but keep the symbol white and turquoise accent unchanged. Full-bleed opaque square, no outer margin, no border, no rounded-square container, no text, no slogan. Preserve the original design and geometry. Single production icon, not a presentation board.

La provenance et les empreintes des images font partie de l’inventaire Git du DEV et du manifeste du pack. Le générateur d’images n’est pas utilisé à l’exécution de l’application.

# Domenia 2.1.6 — configuration par défaut écrite sur place

Version qualifiée sur banc et publiée le 12 novembre 2026 après le go de David (« Essai VM puis publier »). Jusqu’en
2.1.5, « Définir comme configuration par défaut » assemblait une copie complète du pack (nouveau ZIP, nouveau
manifeste, nouvelles empreintes) dans un dossier `Domenia-diffusion-*`. 2.1.6
suit le modèle de GLPI Pilot : un seul fichier, `wad/Domenia.settings.seed.json`, est écrit dans le dossier du Domenia
ouvert, hors manifeste. Le ZIP officiel, le manifeste et les binaires restent intacts ; le démarrage admet ce fichier à
cet endroit et une mise à jour le conserve. Aucun changement de lecture des postes, d’inventaire ou d’AD.
[Bilan et limites](../REPRISE.md).
Pack attendu : `Domenia_2.1.6_PROD-LIGHT_Windows-x64.zip`, avec `SHA256SUMS.txt`.
Extraire dans un nouveau dossier, vérifier l’empreinte puis lancer Domenia.exe. Schéma 11, révision 2 inchangés.

## Points à vérifier

- Paramètres → Configuration à diffuser → « Définir comme configuration par défaut » : la fenêtre annonce l’écriture
  dans `wad/Domenia.settings.seed.json`, à côté du logiciel ouvert, et rappelle que le ZIP officiel, le manifeste et les
  binaires restent intacts. Après « Écrire la configuration par défaut », le fichier est présent avec l’empreinte
  affichée ; aucun fichier `*.part`, aucun dossier `Domenia-diffusion-*` ; `Domenia.exe` et
  `wad/package-manifest.json` gardent leurs empreintes.
- Même action avec les mêmes choix, sans relire la page : la fenêtre s’ouvre (l’empreinte affichée change avec l’heure
  d’export), puis « Cette configuration par défaut est déjà en place … ; aucun fichier modifié. » Fichier conservé à
  l’octet, aucune sauvegarde créée.
- Choix modifiés : l’ancien fichier est d’abord sauvegardé dans les exports
  (`Domenia.settings.seed.avant-remplacement.json`, ou nom suffixé), avec l’empreinte de l’ancien fichier, puis remplacé.
- Redémarrage du même dossier : démarrage normal, aucun refus « Composant hors manifeste » ; le profil qui a écrit la
  configuration ne se la voit pas reproposer. « Revoir la proposition du pack » affiche « Une décision a déjà été
  enregistrée pour cette version et ce fichier. L’import manuel reste disponible. »
- Profil vierge (profil local renommé, jamais effacé) : la configuration livrée est appliquée sans question ; chaque
  valeur du fichier se retrouve dans les préférences du nouveau profil, avec la décision « appliquée ».
- Copie préparée avant 2.1.6 (configuration listée dans son manifeste) : l’écriture sur place est refusée avec la
  consigne d’extraire le ZIP officiel dans un nouveau dossier ; une mise à jour de cette copie conserve sa configuration.
- Dossier du logiciel en lecture seule : message clair, aucun fichier écrit.

Banc administrateur du 12/11/2026 (poste de banc de test, profil local existant), en deux passages :

- Kit `e46237d5` (source `e46237d`) : écriture sur place, profil vierge et redémarrage conformes ; trois défauts
  relevés. Le second clic était refusé « Préférences modifiées depuis la sélection », car la page gardait l’empreinte
  lue avant l’écriture, alors que l’écriture enregistre la décision du profil. Les mêmes choix étaient réécrits avec
  sauvegarde, car chaque export porte son heure (`exportedAt`). « Revoir la proposition » n’affichait rien après une
  décision. Profil vierge (profil renommé puis restauré, rien d’effacé) : les quatre valeurs et l’interface du fichier
  appliquées sans question, décision « applied » tracée.
- Kit `50f66624` (source `50f6662`, ZIP `0b6f1f78…`), avec les trois correctifs : écriture (fichier seul nouveau,
  `Domenia.exe` et manifeste inchangés, aucun `.part`), puis quatre réécritures de suite sans relire la page : mêmes
  choix « déjà en place » à l’octet, « Interface » décochée remplacée avec sauvegarde `-2`, recochée remplacée avec
  sauvegarde `-3` (seule `exportedAt` diffère de la première écriture), mêmes choix de nouveau « déjà en place ».
  Redémarrage : aucun refus, aucune proposition, décision enregistrée annoncée. Aucune ligne ATTENTION ou ERREUR.

Le profil vierge n’a pas été rejoué sur le second kit : son code n’a pas changé. La copie préparée avant 2.1.6 et le
dossier en lecture seule n’ont pas été observés sur banc ; ils sont couverts par les tests C#. Le ZIP publié est
reconstruit depuis le commit de publication ; son empreinte figure dans `SHA256SUMS.txt` de la release.

Noter chaque résultat avec l’empreinte du ZIP ; ne déclarer aucun succès sans observation. Ne modifier ni AD,
ni services, pare-feu, WinRM ou stratégies pour cette recette. Le banc de qualification passe par David.

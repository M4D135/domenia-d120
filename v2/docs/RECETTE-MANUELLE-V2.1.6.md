# Domenia 2.1.6 — configuration par défaut écrite sur place

Version candidate, non publiée. Jusqu’en 2.1.5, « Définir comme configuration par défaut » assemblait une copie
complète du pack (nouveau ZIP, nouveau manifeste, nouvelles empreintes) dans un dossier `Domenia-diffusion-*`. 2.1.6
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
- Même action avec les mêmes choix : « Cette configuration par défaut est déjà en place … ; aucun fichier modifié. »
  Aucune sauvegarde créée.
- Choix modifiés : l’ancien fichier est d’abord sauvegardé dans les exports
  (`Domenia.settings.seed.avant-remplacement.json`, ou nom suffixé), avec l’empreinte de l’ancien fichier, puis remplacé.
- Redémarrage du même dossier : démarrage normal, aucun refus « Composant hors manifeste » ; le profil qui a écrit la
  configuration ne se la voit pas reproposer (« Revoir la proposition du pack » indique une décision enregistrée).
- Profil vierge (profil local renommé, jamais effacé) : la configuration livrée est appliquée sans question ; chaque
  valeur du fichier se retrouve dans les préférences du nouveau profil, avec la décision « appliquée ».
- Copie préparée avant 2.1.6 (configuration listée dans son manifeste) : l’écriture sur place est refusée avec la
  consigne d’extraire le ZIP officiel dans un nouveau dossier ; une mise à jour de cette copie conserve sa configuration.
- Dossier du logiciel en lecture seule : message clair, aucun fichier écrit.

Noter chaque résultat avec l’empreinte du ZIP ; ne déclarer aucun succès sans observation. Ne modifier ni AD,
ni services, pare-feu, WinRM ou stratégies pour cette recette. Le banc de qualification passe par David.

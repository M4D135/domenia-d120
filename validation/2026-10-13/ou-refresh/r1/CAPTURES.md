# Captures documentaires — Domenia 1.0 / RC1.17.4

## État

Le harnais est préparé et sa syntaxe a été vérifiée sur macOS. L’exécution WPF sous Windows reste à effectuer. Aucun nouveau PNG Windows n’a été produit pour cette passe. Sur décision de l’utilisateur, les guides sont finalisés avec les captures encore pertinentes et des tableaux explicatifs natifs. Les captures préparées ne prouvent ni une connexion AD, ni une collecte distante, ni un parcours humain à la souris.

Le script versionné est `guides/captures/capture-guides.ps1`. Son empreinte et le plan de contrôle sont dans `capture-plan.json`. Vérifier cette empreinte avant le transfert. L’agent de validation possède seul la session VM ; aucune exécution concurrente n’est prévue.

## Exécution sous Windows

Extraire le pack DEV exact de RC1.17.4 dans un dossier de test, puis copier le harnais gelé à côté. Remplacer les trois chemins ci-dessous par les chemins de staging du validateur :

```powershell
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File C:\DomeniaLab\capture-guides.ps1 -Dev C:\DomeniaLab\dev -Out C:\DomeniaLab\captures-ou-refresh -Width 1920 -Height 1080 -CaptureSet All
```

Conserver le code de sortie, stdout/stderr, le SHA du ZIP DEV, le SHA du harnais et tous les fichiers de sortie. Ne pas considérer une série partielle comme livrable. Le code doit être nul, tous les contrôles vrais, les empreintes PNG conformes à `capture-provenance.json` et les captures documentaires natives d’au moins 1920 × 1080 pixels. Les deux images `atelier-viewport-*` sont des diagnostics de disposition, hors guides.

## Scénarios

- **Accueil et actualisation-ou** : OU Postes/Lyon sélectionnée, trois actions et bouton Recalculer la vue ; AD relu il y a 35 minutes, présence relevée il y a 10 à 20 minutes, inventaire WMI vieux de 2 à 3 jours. Le calcul local laisse ces dates de source inchangées.
- **Recherche** : résultats et contexte de requête cohérents ; nouvelles commandes dans le bas du panneau OU.
- **recherche-actualisation-ou** : OU longue explicitement sélectionnée. La recherche globale conserve ses sept résultats. Les actualisations portent sur l’OU et ses sous-OU, sans dépendre de cette liste. Les quatre boutons doivent être entiers et l’arbre conserver au moins 80 pixels visibles.
- **Base autonome** : la date AD provient du même formateur et d’une couverture complète Subtree fictive.
- **Toutes les vues** : même runtime exact, aucun accès AD/SQLite/poste, infobulles désactivées, aucune mise à l’échelle des images après capture.

La date associée au ping est celle du relevé de présence qui comprend le ping, pas l’instant exact de la réponse ICMP.

## Remplacement éventuel des captures après réception

Comparer chaque figure et son cadrage avec `capture-layouts.json`. Mettre à jour les sources et les deux métadonnées JSON, puis reconstruire les DOCX et PDF avec le runtime documentaire fourni. Contrôler visuellement chaque page modifiée et conserver les empreintes par page ainsi que les reçus des relecteurs. Toute nouvelle version des quatre fichiers dans `DOC` devra passer cette vérification ; la documentation reste présentée comme Domenia 1.0, sans récit des versions internes.

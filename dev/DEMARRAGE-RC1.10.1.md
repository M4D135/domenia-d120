# Domenia 1.0 RC1.10.1 — correctif démarrage

Le démarrage ne dépend plus de `Get-SuitePalette` avant le chargement des modules de présentation. `Get-DomeniaBootThemePalette` contient une palette minimale autonome, strictement alignée sur les couleurs Light/Dark de `SupportSuite.UI.json`.

Le thème partagé reste utilisé par la fenêtre principale après chargement des modules. Aucun moteur AD, relation, cache ou opération distante n’est modifié.

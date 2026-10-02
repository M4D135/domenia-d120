# Domenia RC1.10.5 - Détection utilisateur/poste

- Le bouton **Détecter les postes** est désormais l'action explicite qui autorise la vérification réseau bornée. Il n'existe plus une seconde case à cocher qui pouvait laisser le bouton terminer avec zéro poste interrogé.
- Périmètre par défaut : OU sélectionnée. Aucun balayage implicite du domaine entier.
- Si aucun candidat connu n'existe, Domenia utilise l'OU sélectionnée, ou la liste chargée en repli. Sans périmètre utile, il explique quoi choisir au lieu de simuler une détection vide.
- Maximum 1 à 50 postes, 20 par défaut. Les résultats arrivent progressivement.
- La recherche manuelle reste séparée et ne sonde pas le réseau.
- Aucun script distant, tâche planifiée ou PsExec n'est utilisé par cette détection : CIM/DCOM uniquement.

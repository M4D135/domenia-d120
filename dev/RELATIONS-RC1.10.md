# Domenia 1.0 RC1.10 : relations utilisateur / poste simplifiées

## Objectif

La page Relations est recentrée sur le contexte déjà sélectionné dans la recherche globale. Elle ne demande plus de choisir une seconde fois l'utilisateur et ne lance plus de popup pour associer un poste.

## Parcours

1. Rechercher un utilisateur avec la barre globale en haut de Domenia.
2. Sélectionner sa ligne, puis ouvrir **Relations**.
3. L'onglet **Associations** affiche uniquement ses liens mémorisés.
4. L'onglet **Associer** propose deux méthodes :
   - **Détecter** : associations connues, indices AD et, uniquement si l'option est cochée, vérification CIM/DCOM bornée ;
   - **Rechercher** : recherche explicite d'un poste sur tout le domaine, sans filtre OU.
5. Sélectionner un poste puis cliquer **Associer ce poste**.
6. La confirmation apparaît dans la page Relations. Le poste est relu dans AD et son GUID est contrôlé avant l'enregistrement local.

Aucune fenêtre séparée n'est utilisée par ce parcours.

## Vues

- **Associations** : uniquement l'utilisateur ou le poste sélectionné.
- **Associer** : Détecter ou Rechercher.
- **Toutes les associations** : vue globale volontaire.
- **Détail** : erreurs, refus et limites de la dernière détection.

Une association mémorisée reste différente d'une session actuellement ouverte. Les observations réseau et les liens manuels conservent leur source.

## Réseau

Une simple recherche manuelle de poste utilise Active Directory uniquement. La vérification des consoles est désactivée par défaut. L'activer explicitement lance la lecture CIM/DCOM dans le périmètre et la limite affichés. Aucun script n'est déposé par cette détection.

## Limites de validation

La préparation de RC1.10 a vérifié statiquement les sources, le XAML et les archives. Windows PowerShell 5.1, le rendu WPF et le domaine réel n'ont pas été exécutés dans l'environnement de construction. La recette sur Windows reste nécessaire avant diffusion large.

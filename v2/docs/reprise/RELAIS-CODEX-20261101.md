# Relais vers Codex — 01/11/2026

Décision de David (01/11/2026) : « oublie ça sur le Spark, on passe en Codex ». La chaîne de lots sur le Spark est arrêtée (fichier `STOP`, aucun worker Domenia actif) ; rien n’a été intégré à master depuis `d5abbe71`.

## État de départ

- **master `d5abbe71`** : Domenia 2.0.8 publiée (release v2.0.8), catalogue de parité mis à jour par l’audit du 31/10.
- **Audit de parité** : `docs/reprise/audit-parite-20261031/` — une fiche `<ID>.json` par fonction encore ouverte (verdict, preuves `fichier:ligne`, manque exact, effort, risque) et `SYNTHESE.md` (22 lots proposés). Le catalogue compte 556 faites, 216 améliorées, 201 partielles, 19 à faire ; chaque « Reste à faire » de `docs/FEATURES.md` cite le manque relevé.
- **Lots** : `docs/reprise/audit-parite-20261031/lots.json` (titre, objectif, fonctions de chaque lot). Ordre conseillé, du moins risqué au plus engageant : L07, L22, L21, L13, L14, L17, L18, L19, L09, L08, L10, L11, L12, L05, L06, L15, L16, L20, L03, L04, L02, L01 (L01 = écritures AD, en dernier).
- **Brouillon L07 du Spark** : branche `codex/lot-L07-spark-brouillon` (8 commits, 7 fonctions, jamais compilé). **Défaut bloquant connu** : le commit `119a80da` applique `AdText.Flat` (une ligne, 240 caractères) aux valeurs lues par `AdDirectoryMapper` (description, mail, titre…), donc à la donnée stockée et réécrite : perte de donnée. À corriger avant toute intégration (valeur exacte dans le mappeur, mise en forme seulement à l’affichage, test d’une description de 300 caractères sur deux lignes). Le reste du brouillon est à relire puis à passer en CI.
- **Arbitrage de cadrage** (« tout corriger au mieux », 01/11/2026) : TRV-034, TRV-041 et TRV-042 décrivaient du XAML/PowerShell de Domenia 1 ; à reformuler pour Domenia 2 plutôt qu’abandonner — TRV-034 : bibliothèques livrées épinglées et vérifiées au démarrage ; TRV-041 : contrôle préalable des pages web ; TRV-042 : inventaire au démarrage des éléments et fonctions critiques de la coque.

## Règles rappelées

Un lot n’arrive sur master qu’après CI Windows verte (`domenia-v2-windows.yml` se lance sur `codex/**`) et relecture ; une lecture ne modifie jamais une donnée ; aucune écriture AD, sonde réseau ou rejeu nouveau sans geste de l’opérateur ; tests réels dans la VM du labo, jamais sur l’hôte ; aucun mot de passe lu ni saisi par les outils.

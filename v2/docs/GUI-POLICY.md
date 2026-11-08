# Politique des contrôles d’interface

La section `GuiElementPolicy` de `Domenia.config.json` applique des restrictions de présentation au shell, à Paramètres et à la fenêtre native de saisie des identifiants. Elle ne remplace aucun contrôle de droit, de lecture seule, de confirmation ou d’identité du moteur.

```json
{
  "GuiElementPolicy": {
    "BtnThemeToggle": "Disabled",
    "BtnIndexBackup": "Hidden",
    "BtnLoginVaultUse": "Disabled"
  }
}
```

`Disabled` grise le contrôle et bloque son activation. `Hidden` le masque et le désactive. `Default`, ainsi que l’alias `Visible`, n’active ni ne montre un contrôle rendu indisponible par sa propre règle métier. Les noms sont insensibles à la casse. Une valeur inconnue, un nom non pris en charge ou une ambiguïté est signalé, sans exécuter de sélecteur ni de commande fournis par le fichier. Le tableau est borné à 512 entrées et le fichier à 1 Mio.

Les noms raccordés sont décrits dans la table fermée de `web/js/shell/gui-policy.js`, partagée par Paramètres et le shell. Elle couvre notamment les contrôles de stockage déjà présents dans Paramètres, le thème, le profil, le menu latéral, la recherche globale, l’aide, le compte et le journal. Les commandes équivalentes de la palette et les raccourcis du shell utilisent la même décision ; les menus directs du thème et du profil la respectent aussi. Un nouveau nom sans correspondance est ignoré explicitement, et ne constitue pas une fonction appliquée.

La fenêtre native prend en charge `TxtLogin`, `PwdLogin`, `BtnRevealLogin`, `ChkRemember`, `BtnLoginVaultUse`, `LblLoginError` et `BtnLogin`. `BtnCancel` et les commandes d’arrêt d’une tâche restent utilisables, même si leur nom est déclaré masqué. Échap et la fermeture de la fenêtre restent disponibles. La politique n’autorise pas la lecture d’un secret ni l’envoi d’identifiants.

Le shell charge la politique à son ouverture ; la fenêtre native la relit à son ouverture. Revenir à `Default` après une restriction déjà chargée demande de rouvrir l’interface concernée. Il n’y a pas de levée automatique des restrictions d’une instance ouverte. La simulation utilise la politique fictive de sa composition.

Les politiques de zoom de Paramètres concernent ses boutons ; elles ne modifient pas le zoom natif de WebView2. Les contrôles sans équivalent dans Domenia 2 restent signalés comme non raccordés. Le chargement et les règles ont des tests dédiés ; la présentation effective de la fenêtre native reste à observer lors de la recette Windows.

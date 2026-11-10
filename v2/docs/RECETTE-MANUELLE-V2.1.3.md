# Domenia 2.1.3 — correctifs des retours de production

Version préparée le 10 novembre 2026. La qualification CI et la publication sont consignées séparément dans REPRISE.md.

Pack attendu : `Domenia_2.1.3_PROD-LIGHT_Windows-x64.zip`, accompagné de `SHA256SUMS.txt`.
Extraire dans un dossier distinct, contrôler l’empreinte et lancer Domenia.exe. .NET est embarqué ; WebView2
vient d’Evergreen ou du pack du Socle. Le format reste le schéma 11, révision native 2.

## Points à vérifier

- Pendant une actualisation explicitement demandée de l’OU de travail, les cartes « Sauvegarde » et « Lecture AD »
  restent lisibles à chaque seconde. Le spinner signale l’étape en cours ; la preuve et le focus restent stables.
- Ouvrir Paramètres → Données et cache avec la base existante. Les comptes s’affichent même en présence de données
  volumineuses. Un problème propre à la reprise historique est signalé dans cette section. Cette consultation
  ne purge rien et ne lance aucune lecture réseau. Les protections avant modification restent actives.
- Ouvrir Paramètres → Mises à jour. Le texte bleu utilise la largeur de sa carte à différentes tailles de fenêtre,
  en annuaire comme en démonstration. L’ouverture de cette page ne cherche aucun paquet.
- La barre de titre, les Paramètres, À propos et la version installée affichent **2.1.3**, sans suffixe de compilation.
  « Copier ces informations » conserve l’identité technique complète pour le diagnostic.

Conserver chaque observation avec l’empreinte du ZIP ; noter « non exécuté » lorsqu’un point n’a pas été exercé.
Aucun succès réel n’est prérempli. Aucun changement AD, système, service ou stratégie n’est demandé par cette recette.

# Domenia 2.1.10 — lecture d’une branche affichée dans l’arbre

Correctif préparé le 18 novembre 2026 après un retour terrain : une OU visible et sélectionnée dans
Rechercher produit « OU introuvable : rien n’a été lu ». La capture montre un client 2.1.8 ; le défaut de
raccordement décrit ci-dessous existe aussi dans 2.1.9. Le DN complet et la réponse du contrôleur ne figurent
pas dans cette capture, donc le résultat sur le domaine réel reste à vérifier.

Pack attendu : `Domenia_2.1.10_PROD-LIGHT_Windows-x64.zip`, avec `SHA256SUMS.txt` dans le même dossier.
Les résultats automatiques, la source et les empreintes sont consignés dans [REPRISE.md](../REPRISE.md).
Aucun succès de recette utilisateur n’est prérempli.

## Défaut corrigé

L’arbre de Rechercher charge les branches demandées et les conserve dans le cache de navigation. La lecture
du contenu vérifiait ensuite l’OU dans un autre index, celui du sélecteur global d’OU. Sur un cache d’objets
vide ou incomplet, une branche effectivement lue et affichée pouvait donc être refusée avant la demande de
ses objets. Les conteneurs imbriqués proposés par l’arbre étaient concernés par la même séparation.

La lecture reconnaît désormais une branche enregistrée dans le cache de navigation du domaine, avec son
DN exact. Elle conserve le périmètre choisi, les contrôles de domaine et de session, ainsi que les règles
propres aux opérations qui n’acceptent que des OU. Le cache de navigation reste distinct de l’inventaire des
objets ; ouvrir une branche ne vaut pas collecte de tous ses objets.

Les correctifs 2.1.9 sont inclus : poursuite de recherche après une passe LDAP vide sans contrôle de tri,
historique au premier plan et conservation de la sélection lors d’un suivi de session inchangé.

## Installer le correctif

Placer le ZIP et son `SHA256SUMS.txt` dans le même dossier. Dans **Paramètres → Mises à jour**, choisir
**Sélectionner un ZIP PROD**, sélectionner l’archive 2.1.10, puis **Copier et vérifier**. Vérifier la version
proposée avant **Fermer et installer**. Au lancement suivant, vérifier **2.1.10** dans le titre ou **À propos**
pour s’assurer que le raccourci a ouvert le paquet corrigé.

## Vérifications sur le poste

1. Dans Rechercher, développer l’arbre jusqu’à l’OU qui échouait, la sélectionner puis demander
   **Afficher le contenu**. Vérifier que le tableau présente les objets de cette OU.
2. Désactiver puis réactiver **Inclure les sous-OU** et relire. Contrôler le périmètre des lignes, sans
   élargissement silencieux à tout le domaine.
3. Dans cette même OU, rechercher le préfixe connu d’un compte ou d’un poste. Contrôler la liste, sélectionner
   un objet et attendre quelques secondes : sa sélection et son aperçu doivent rester présents.
4. Si l’arbre propose un conteneur imbriqué, vérifier également son contenu. Pour une branche sans objet,
   vérifier le résultat vide explicite ; pour une branche réellement supprimée ou devenue inaccessible,
   conserver l’erreur détaillée pour le diagnostic.
5. Vérifier l’historique du champ, ses clics et sa fermeture par Échap, en barre large puis compacte.

La recette automatique reproduit la composition réelle du cache avec un transport LDAP enregistré, y
compris un index d’OU vide alors que la branche est déjà connue. Elle ne remplace pas cette vérification
sur le contrôleur de domaine de l’utilisateur. Ne pas publier les DN ni les identifiants du domaine dans
le dépôt ; conserver le journal détaillé localement en cas d’échec.

## Livraison

Le schéma de données reste 11, révision 2. Le paquet conserve `Domenia.exe` et `wad/`, avec .NET privé et
WebView2 du poste. La référence publique de la recette binaire reste 2.1.8. La remise manuelle du correctif
est demandée ; la publication d’une nouvelle release dépend du statut effectivement consigné dans REPRISE.md.

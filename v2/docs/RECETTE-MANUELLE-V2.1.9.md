# Domenia 2.1.9 — recherche d’objets et historique

Correctif préparé le 18 novembre 2026 à la demande de l’utilisateur après un retour terrain : la recherche
échoue avec « Le contrôleur n’a pas confirmé le tri » et son historique passe derrière les options.
La capture fournie montre l’échec `search.run`, mais ni le texte recherché ni la réponse LDAP brute.
La cause dans le code est identifiée ; sa correspondance exacte avec ce contrôleur reste à vérifier sur place.

Pack attendu : `Domenia_2.1.9_PROD-LIGHT_Windows-x64.zip`, accompagné de `SHA256SUMS.txt`.
Les résultats automatiques, le commit source et les empreintes sont consignés dans
[le document de reprise](../REPRISE.md). Aucun succès de recette utilisateur n’est prérempli.

## Résultat attendu de la recherche

Une saisie doit produire la liste des objets correspondants. Une passe interne sans correspondance exacte
ne doit pas interrompre les passes suivantes : préfixe puis recherche ANR selon le mode sélectionné.
Les résultats sont réunis sans doublon, avec les limites et la pagination existantes.

La RFC 2891, section 2, cas 6, prévoit l’absence du contrôle de réponse de tri lorsque la réponse ne contient
aucune entrée. Domenia admet désormais ce seul cas. Une réponse non vide sans confirmation de tri et un
refus explicite de tri, même sur une réponse vide, restent des erreurs. Les erreurs de droits, de connexion
et de transport conservent leur traitement. Aucun échec n’est transformé en résultat vide.

Références : [RFC 2891](https://www.rfc-editor.org/rfc/rfc2891.html#section-2) et
[documentation Microsoft AD](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-adts/6b7b93f1-7c1a-45c2-9544-c067b94bba20).

## Installer le correctif

Placer le ZIP et son `SHA256SUMS.txt` dans le même dossier. Dans **Paramètres → Mises à jour**, choisir
**Sélectionner un ZIP PROD**, sélectionner l’archive 2.1.9, puis **Copier et vérifier**. Vérifier la version
proposée avant **Fermer et installer**. Au lancement suivant, contrôler que **À propos** affiche bien 2.1.9,
puis reprendre la recherche qui avait échoué.

## Vérifications sur le poste

1. Ouvrir la recherche dans le domaine et le périmètre habituels. Reprendre le texte qui avait déclenché
   l’erreur, puis un préfixe connu de plusieurs comptes. Vérifier que les objets attendus apparaissent
   dans le tableau, que la sélection et son aperçu restent présents après plusieurs secondes, et qu’une fiche
   s’ouvre sur l’objet sélectionné.
2. Rechercher un nom exact connu, puis un texte sans correspondance. Le premier doit renvoyer l’objet ;
   le second doit annoncer zéro résultat sans incident de tri. Si la liste dépasse la limite choisie,
   charger la suite et vérifier la continuité des objets.
3. Cliquer dans le champ pour ouvrir l’historique avant et après une recherche, en barre large puis compacte.
   Vérifier que la liste passe devant les options et les résultats, reste lisible et reçoit les clics.
   Un choix recopie le texte ; Entrée lance la recherche. Tester les flèches et Échap : une réponse locale
   tardive ne doit pas rouvrir la liste fermée.

Noter la version, l’empreinte du ZIP et le résultat de chaque point. Si l’erreur persiste, conserver le texte
recherché et le journal détaillé localement pour le diagnostic, sans publier d’identifiants du domaine.

## Livraison et portée

Le schéma de données reste 11, révision 2. Le paquet conserve la disposition `Domenia.exe` et `wad`,
avec runtime .NET privé et utilisation du WebView2 déjà disponible.
La CI prépare le paquet et vérifie la mise à jour réelle depuis 2.1.8 puis la restauration de 2.1.8.
Ses tests utilisent des réponses LDAP construites et l’interface en simulation ; ils ne valident pas un
contrôleur de domaine de production. Aucun changement AD ni réglage de poste n’est requis pour cette recette.

La préparation du correctif et sa remise manuelle sont demandées. La publication d’une nouvelle release
n’est pas attestée par ce document ; se reporter au statut réel et aux liens du document de reprise.

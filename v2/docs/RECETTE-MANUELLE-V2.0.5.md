# Domenia 2.0.5 — connexion, collecte et cache

Correctif du 28 octobre 2026. La préparation et les contrôles CI ne constituent pas une recette sur le domaine réel. Aucun essai VM n’est demandé pour cette livraison ; la validation visuelle native et la recette utilisateur restent en attente.

Extraire le nouveau pack dans un dossier distinct et vérifier son SHA256 avec `SHA256SUMS.txt`. Conserver les versions précédentes. `wad/package-release.json` donne le commit source et l’empreinte de l’exécutable exact.

## Disposition du pack

La racine extraite contient seulement `Domenia.exe` et le dossier `wad`. Lancer l’EXE à la racine ; conserver `wad` à côté. Les DLL, ressources, runtimes privés, guides et manifestes vivent dans `wad`. Le DEV ajoute ses sources dans `wad/developer` ; les deux packs ont le même exécutable.

Ne pas recopier cette version par-dessus les anciens packs plats. Extraire dans un nouveau dossier et adapter le raccourci vers le nouvel EXE. Le profil utilisateur reste dans son emplacement habituel. Si une configuration portable locale est utilisée, elle se place désormais dans `wad/Domenia.config.json`. Les réglages par défaut distribués restent dans `wad/Domenia.settings.seed.json`.

L’assistant refuse explicitement une mise à jour en place entre deux dispositions différentes. Les sauvegardes et transactions des anciens packs se reprennent avec leur ancien pack ; elles restent conservées. Les mises à jour et reprises entre packs utilisant la même disposition restent prises en charge. Les guides MISES-A-JOUR et CONFIGURATION-DIFFUSABLE livrés dans `wad/guides` décrivent ces mêmes emplacements.

## Migration du cache

La première écriture du cache par poste utilise une sauvegarde vérifiée puis une transaction atomique (schéma 11, révision native 2). Les anciens exécutables refusent la révision 2. Pour revenir à 2.0.4, conserver et restaurer explicitement une sauvegarde antérieure à la migration ; remplacer seulement l’EXE ne restaure pas le format des données.

## À observer lors de la prochaine utilisation

- Au démarrage normal sur un poste du domaine, seule la fenêtre de connexion doit être visible. La fenêtre principale ne doit apparaître qu’après le parcours de connexion ou le choix hors connexion, lorsque son document local est chargé. Une erreur d’affichage doit rester visible.
- Choisir un autre compte : le domaine détecté est indiqué sous le champ. Un nom simple suffit ; le bouton Valider devient disponible avec un mot de passe masqué. Les formats `DOMAINE\compte` et `compte@domaine` restent acceptés. Le mot de passe ne quitte pas la saisie native pour la page web.
- Vérifier l’identité affichée après connexion. Un nom simple utilise exclusivement le domaine de la session, sans repli sur un compte local et sans fabriquer de suffixe UPN. Si aucun domaine n’est connu, le texte le signale et demande un compte qualifié.
- Cocher « Se souvenir de cet identifiant », puis valider une connexion : au prochain lancement, ce compte est proposé à la place du compte Windows. Le mot de passe reste vide. Décocher l’option ou oublier l’identifiant dans Paramètres retire cette proposition. Un essai refusé ne remplace pas l’identifiant valide mémorisé.
- Dans Paramètres, Mises à jour doit afficher la version, les sources et les actions avec les animations habituelles. Ouvrir cette section ne consulte aucune source distante ; un échec de lecture locale doit afficher un message et Réessayer.
- Dans l’Atelier, ouvrir Information : la liste doit couvrir les lignes Condition et Valeur, recevoir les clics et se fermer avec Échap. Les animations d’entrée restent inchangées.
- Après annulation ou refus, conserver la possibilité d’un nouvel essai explicite ou de continuer hors connexion. Aucune tentative supplémentaire n’est automatique.
- En format réduit, thèmes clair et sombre, vérifier le champ, son aide, Valider, Annuler et l’absence d’ascenseur. Les dialogues du login doivent rester accessibles dans la barre des tâches pendant que la fenêtre principale est invisible.

## Atelier, BitLocker et widgets

- Dans Informations, sélectionner une propriété BitLocker : le formulaire doit afficher cette propriété, les méthodes lisibles et la portée du volume. Ajouter un critère ne doit pas laisser le précédent champ OS sélectionné.
- Pour la répartition demandée : choisir « Méthode BitLocker du volume C: », puis « Créer une répartition ». Vérifier XTS-AES 128, XTS-AES 256 et les autres méthodes réellement relevées. Les inconnus restent séparés de « Non chiffré ».
- Depuis le résumé, l’aperçu ou un modèle de la Bibliothèque, choisir « Créer un widget », renseigner son titre et son tableau, puis « Enregistrer et créer le widget ». Vérifier le reçu et l’affichage après réouverture.
- Sur l’Accueil, le crayon de chaque widget doit proposer titre, taille, représentation et, pour une requête, « Modifier la requête ». Ce dernier ouvre sa recette liée, sans remplacer le brouillon par une clé de widget.
- Comparer chaque part d’une répartition à sa liste de postes : les catégories ne se recouvrent pas et le total reste exact, y compris « Autres valeurs » et « Valeur inconnue ».

## Collecte et cache à observer

- Sur l’OU de travail, une collecte après relecture AD doit utiliser les cibles enregistrées, même si le cache était vide. Un changement réel de compte, de base ou de périmètre doit rester signalé.
- Les résultats de ping et de sondes doivent apparaître par lots. Arrêter conserve les résultats déjà enregistrés ; les postes non interrogés restent inconnus.
- Une file occupée ne doit pas être confondue avec un échec DNS ou une absence de réponse. Chaque ping envoie au plus un écho, en IPv4 de préférence lorsque DNS fournit les deux familles.
- Relancer une collecte avec des données fraîches doit réutiliser le cache. Fabricant, modèle et numéro de série qualifiés restent conservés ; disque, sessions, état système et sécurité ne deviennent pas permanents. Une valeur absente ou erronée reste à relire. « Tout relire » doit contourner le cache.
- Changer la durée de fraîcheur ou le plafond de réutilisation dans Paramètres doit se retrouver dans le prochain plan de relevé. Zéro force une nouvelle lecture.
- Données locales doit afficher les comptes et dates d’une base volumineuse. Une limite rencontrée lors d’une préparation de purge doit laisser la base intacte et ne pas être présentée comme une corruption.

## Collecte d’entreprise : vérifications complémentaires

- Conserver les scripts ponctuels désactivés dans un profil neuf. Vérifier que le choix des transports et le mode automatique ou manuel sont visibles dans Paramètres. Une option désactivée ne doit jamais servir de repli.
- Avec un compte non administrateur, vérifier que les lectures AD restent utilisables et que les fonctions de collecte distante expliquent le blocage et proposent un autre compte. Les droits AD sur chaque objet restent vérifiés séparément.
- Avec un compte de domaine administrateur local délégué, utiliser la validation explicite du compte sur le poste choisi. L’appartenance au groupe Administrateurs de cette cible doit permettre sa collecte sans exiger Domain Admins. Cette preuve temporaire reste liée au poste, au compte, au secret et à la session ; elle ne vaut pas pour les autres machines d’une campagne. Après expiration ou changement de compte, une nouvelle validation explicite est nécessaire. La validation utilise DCOM ; le mode WinRM exclusif doit expliquer son refus avant tout contact.
- Après un refus d’identifiants, aucun autre poste ou transport ne doit réessayer automatiquement le même compte. Un refus d’autorisation sur une ressource reste distinct d’un mot de passe rejeté. Ne pas provoquer volontairement plusieurs échecs sur un compte de production.
- Sur une sous-OU choisie, suivre le total et les mini-objectifs par branche. Un arrêt conserve les reçus des postes terminés ; la reprise garde la sélection de branches.
- Observer la durée totale, le temps d’attente, les tentatives et le temps cumulé par méthode. Le cumul des opérations parallèles peut dépasser la durée réelle de la campagne. Un résultat du cache n’est pas une nouvelle mesure réseau.
- Une suspension réseau doit mettre en attente les travaux non envoyés, puis reprendre avec une seule tentative de contrôle. Annuler pendant cette attente doit rester possible. Un refus d’identifiants ne se résout pas par ce mécanisme.
- La cible de 100 000 postes exige aussi une qualification dans l’environnement réel : les tests synthétiques Windows vérifient les limites, files, reçus et reprises, sans mesurer le débit d’un réseau d’entreprise.

## Références officielles utilisées pour la révision

Consultées le 28 octobre 2026. Elles guident les choix du moteur ; elles ne prouvent pas les performances du pack.

- [Microsoft : considérations LDAP](https://learn.microsoft.com/en-us/windows-server/administration/performance-tuning/role/active-directory-server/ldap-considerations) : garder des pages raisonnables et examiner les requêtes coûteuses avant de changer le serveur. Domenia conserve des pages de 1 000 objets au plus et un attributage explicite.
- [Microsoft : analyser les requêtes LDAP](https://learn.microsoft.com/en-us/troubleshoot/windows-server/active-directory/event1644reader-analyze-ldap-query-performance) : réduire fréquence, attributs retournés et périmètre, et utiliser le cache. Domenia ne modifie ni index ni journalisation des contrôleurs.
- [Microsoft : améliorer les énumérations WMI](https://learn.microsoft.com/en-us/windows/win32/wmisdk/improving-enumeration-performance) : préférer les projections ciblées et libérer les résultats au fil de la lecture.
- [Microsoft : options des sessions CIM](https://learn.microsoft.com/en-us/powershell/module/cimcmdlets/new-cimsessionoption) et [quotas WinRM](https://learn.microsoft.com/en-us/windows/win32/winrm/quotas) : DCOM et WSMan sont des transports distincts ; les limites du serveur restent applicables. Domenia ne relève pas les quotas ni ne configure WinRM.
- [Microsoft : seuil de verrouillage des comptes](https://learn.microsoft.com/windows/security/threat-protection/security-policy-settings/account-lockout-threshold) : les authentifications rejetées, y compris certaines renégociations Windows, peuvent compter vers le seuil. L’arrêt des tentatives de Domenia réduit ce risque ; il ne modifie pas la stratégie du domaine et ne garantit pas l’absence de verrouillage causé par d’autres processus.
- [Microsoft : tokenGroups](https://learn.microsoft.com/en-us/windows/win32/adschema/a-tokengroups) : la liste transitive des SID de groupes exige une requête BASE coûteuse. La validation réutilise les groupes déjà lus pour l’identité authentifiée ; aucune expansion LDAP n’est relancée automatiquement pour chaque poste.
- [Microsoft : Win32_Group](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-group) : le SID identifie le groupe indépendamment de sa traduction. La preuve locale compare les membres du groupe `S-1-5-32-544` aux SID du compte et de ses groupes confirmés, sans déduire les droits d’une simple lecture WMI réussie.

Ne noter comme réussies que les étapes effectivement exercées sur ce pack. Conserver les journaux et identités réelles en privé. Ce guide ne demande aucune écriture AD, modification du système, installation de runtime ou redémarrage.

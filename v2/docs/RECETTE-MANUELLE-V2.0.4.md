# Domenia 2.0.4 — connexion et pack portable

Correctif du 28 octobre 2026. La préparation et les contrôles CI ne constituent pas une recette sur le domaine réel. Aucun essai VM n’est demandé pour cette livraison ; la validation visuelle native et la recette utilisateur restent en attente.

Extraire le nouveau pack dans un dossier distinct et vérifier son SHA256 avec `SHA256SUMS.txt`. Conserver les versions précédentes. `wad/package-release.json` donne le commit source et l’empreinte de l’exécutable exact.

## Disposition du pack

La racine extraite contient seulement `Domenia.exe` et le dossier `wad`. Lancer l’EXE à la racine ; conserver `wad` à côté. Les DLL, ressources, runtimes privés, guides et manifestes vivent dans `wad`. Le DEV ajoute ses sources dans `wad/developer` ; les deux packs ont le même exécutable.

Ne pas recopier cette version par-dessus les anciens packs plats. Extraire dans un nouveau dossier et adapter le raccourci vers le nouvel EXE. Le profil utilisateur reste dans son emplacement habituel. Si une configuration portable locale est utilisée, elle se place désormais dans `wad/Domenia.config.json`. Les réglages par défaut distribués restent dans `wad/Domenia.settings.seed.json`.

L’assistant refuse explicitement une mise à jour en place entre deux dispositions différentes. Les sauvegardes et transactions des anciens packs se reprennent avec leur ancien pack ; elles restent conservées. Les mises à jour et reprises entre packs utilisant la même disposition restent prises en charge. Les guides MISES-A-JOUR et CONFIGURATION-DIFFUSABLE livrés dans `wad/guides` décrivent ces mêmes emplacements.

## À observer lors de la prochaine utilisation

- Au démarrage normal sur un poste du domaine, seule la fenêtre de connexion doit être visible. La fenêtre principale ne doit apparaître qu’après le parcours de connexion ou le choix hors connexion, lorsque son document local est chargé. Une erreur d’affichage doit rester visible.
- Choisir un autre compte : le domaine détecté est indiqué sous le champ. Un nom simple suffit ; le bouton Valider devient disponible avec un mot de passe masqué. Les formats `DOMAINE\compte` et `compte@domaine` restent acceptés. Le mot de passe ne quitte pas la saisie native pour la page web.
- Vérifier l’identité affichée après connexion. Un nom simple utilise exclusivement le domaine de la session, sans repli sur un compte local et sans fabriquer de suffixe UPN. Si aucun domaine n’est connu, le texte le signale et demande un compte qualifié.
- Après annulation ou refus, conserver la possibilité d’un nouvel essai explicite ou de continuer hors connexion. Aucune tentative supplémentaire n’est automatique.
- En format réduit, thèmes clair et sombre, vérifier le champ, son aide, Valider, Annuler et l’absence d’ascenseur. Les dialogues du login doivent rester accessibles dans la barre des tâches pendant que la fenêtre principale est invisible.

Ne noter comme réussies que les étapes effectivement exercées sur ce pack. Conserver les journaux et identités réelles en privé. Ce guide ne demande aucune écriture AD, modification du système, installation de runtime ou redémarrage.

# Démonstration isolée de Domenia 2

État du 25 octobre 2026 : code et tests écrits, recette Windows ciblée à effectuer après la fin du développement. Ce document ne constitue pas une preuve d’exécution.

Dans Paramètres → Démonstration, « Ouvrir la démonstration » prépare un espace fictif neuf dans un enfant du **même Domenia.exe**. Il n’existe aucune variante Admin. La fenêtre précédente reste vivante avec son contexte ; elle est suspendue et masquée seulement après contrôle des opérations. Une écriture active ou un reçu réel incertain empêche la bascule. Les lectures arrêtables sont retirées ou annulées, puis leur fin effective, les travaux physiques et les écritures locales sont contrôlés. La fin ou l’échec de l’enfant réaffiche le même parent. Les secrets temporairement affichés sont effacés avant la bascule.

Depuis la décision du 26 octobre 2026, les commandes de démonstration sont accessibles **uniquement dans Paramètres → Démonstration**. L’ancien onglet d’**Aide et interface** est retiré ; son adresse `#/shell?onglet=demonstration` redirige vers cette section sans lancer de mode. La couverture de l’annuaire fictif et les explications de son comportement y sont conservées. Les indicateurs passifs de mode restent visibles pour distinguer les données fictives de l’annuaire réel. Le réglage des animations se trouve, séparément, dans **Paramètres → Apparence → Animations**.

La nouvelle entrée fermée `--demo-session` ne prend aucun autre argument et ne peut pas être combinée avec une commande d’installation, de santé, de lecture native ou de dossier. Le mode historique `--simulation` conserve ses fixtures `example.local`. La démonstration isolée utilise `example.invalid`, des DN, UPN, contrôleurs et références de sondes cohérents. Elle ne récupère ni le domaine, ni les identifiants, ni la configuration d’équipe, ni les préférences du contexte réel.

## Un parcours de cinq minutes

1. Dans le contexte habituel, ouvrir un écran et choisir un périmètre identifiable. Ouvrir Paramètres → Démonstration, puis « Ouvrir la démonstration ». Le bandeau permanent « Démonstration — données fictives » et `example.invalid` identifient l’espace.
2. Dans Accueil, examiner le parc, les comptes verrouillés, les dates de collecte et les cartes. Dans Poste, ouvrir un poste fictif et demander son inventaire ; consulter logiciels, services et relevés. Les tableaux et calculs sont ceux de Domenia, alimentés par les lecteurs simulés.
3. Dans Comptes, rechercher Camille Bernard. Préparer le déverrouillage, lire le plan, confirmer puis examiner le reçu marqué « simulé » et sa relecture. La carte des comptes verrouillés diminue. L’annuaire généré initial reste immuable ; seule sa surcouche en mémoire a changé.
4. Modifier une disposition, enregistrer une note ou utiliser les scénarios de Données et cache. Un export explicite est conservé dans le dossier privé de cette session, avec le préfixe `DEMONSTRATION-`. Le sélecteur hôte d’import n’expose que cet espace ; les pickers navigateur et dépôts de fichiers locaux des pages sont bloqués avant leur lecture dans la session isolée. Un texte collé explicitement reste une saisie en mémoire ; les destinations de stockage et leurs contrôles sont fictifs. Les outils distants et sources réseau réelles sont refusés avant acquisition.
5. Dans Paramètres → Démonstration, « Réinitialiser » demande confirmation puis recrée la composition, la surcouche, les préférences, les reçus et un profil d’affichage neuf. Les exports demandés sont conservés. « Quitter » ferme l’enfant et retrouve le parent, son écran, ses choix et sa mémoire. La croix de la fenêtre permet également de quitter.

Les parcours de mise à jour et de référentiels utilisent leurs propres adaptateurs fictifs ; cette session ne leur donne aucun droit supplémentaire sur les sources ou paquets réels. Les gardes et recettes correspondantes sont documentées dans leurs lots dédiés.

## Données et stockage

Le générateur existant fournit 1 258 utilisateurs, 454 ordinateurs, 75 groupes et 39 OU, leurs relations, inventaires et historiques. Les dates se rapportent à l’instant d’ouverture ; le fuseau et la graine sont explicitement injectables. L’horloge de session avance pour conserver les règles d’expiration, et peut être contrôlée dans les tests. Aucune donnée de tickets ou de calendrier étrangère au métier AD n’est inventée.

Les préférences et reçus restent en mémoire. Le journal technique, les profils WebView2 et les exports vont sous `%LOCALAPPDATA%\Domenia\Demonstrations\<session>` ; chaque reset emploie une nouvelle génération de profil. Les anciens profils fictifs ne sont pas réutilisés et restent conservés sur disque dans ce premier lot, afin de ne pas supprimer un profil encore tenu par WebView2. Aucun nettoyage du profil normal n’est effectué. Les binaires, moteurs et ressources statiques restent ceux du pack ouvert.

## Recette critique à exécuter uniquement dans la VM

- `DemonstrationSessionTests` : sept tests du CLI fermé, monde réservé complet et daté, vrai déverrouillage/recalcul/reçu isolé, nouvelle composition propre, audit cohérent, refus réseau avant handler, destinations fictives et horloge.
- `WriteClosingTests` : refus d’une écriture active sans annulation ; clôture conditionnée aux reçus ; reprise sans consommer une confirmation.
- `SimulationIsolationTests` : dépendances sans accès réseau et lecteurs exclusivement construits sur la source simulée.
- WebView2 : `demo-files.test.mjs` vérifie les gardes capture avant picker et handler FileReader ; `demonstration-session.test.mjs`, trois tests de la vraie page (confirmation/annulation du reset, double clic, sortie, destruction et réponse tardive). Aucune action n’est annoncée réussie sur une simple acceptation de la commande.
- `settings-entrypoints.test.mjs` couvre l’absence des anciens contrôles dans Aide, la redirection de l’ancienne adresse et la conservation des trois choix d’animations dans Paramètres, avec clavier et persistance. Le scénario `shell/apparence-clavier.json` exerce désormais ces choix dans Paramètres avant de vérifier les contrôles conservés dans Aide. Leur présence dans le dépôt ne constitue pas un reçu de validation Windows.
- Recette native ciblée, pack réel de la VM : empreintes des préférences/base/reçus normaux avant entrée, tentative pendant une écriture suspendue, retour après échec de lancement enfant, reset après mutation, sortie après lecture lente, même écran/périmètre/choix au retour et empreintes normales inchangées hors activité normale déjà terminée. Observer les appels réseau : aucun appel métier réel de l’enfant. Une simple compilation ne prouve pas cette recette interprocessus.

# Domenia 2.1.4 — lectures, périmètre et unités

Candidat qualifié automatiquement par le run 42786153794, non publié. Recette manuelle sur domaine réel non exécutée.
Pack attendu : `Domenia_2.1.4_PROD-LIGHT_Windows-x64.zip`, avec `SHA256SUMS.txt`.
Extraire dans un nouveau dossier, vérifier l’empreinte puis lancer Domenia.exe. Schéma 11, révision 2 inchangés.

## Points à vérifier

- Paramètres → Budgets réseau : âge des observations en jours (dont 1 jour), campagne en minutes ; automatique reste
  « au plus 24 h ». Enregistrer un choix et rouvrir : la valeur et son unité restent cohérentes.
- Avec une OU déjà enregistrée dans la base, fermer et rouvrir : l’OU de travail est restaurée sans lecture AD automatique.
  Sans OU connue, l’Accueil s’ouvre sans erreur `scope.tooWide` ; lancer une collecte exige toujours une OU.
- Après correction du mot de passe du même compte, ouvrir Synchronisation : l’OU persistée reste consultable.
  Une OU absente d’un arbre fraîchement lu ne doit pas être réintroduite depuis l’ancien cache.
- Sur une petite OU choisie explicitement, lancer l’inventaire avec un compte saisi autorisé sur les postes : aucun
  refus préalable demandant Domain Admins ou une validation par poste. Chaque poste décide de l’accès effectif.
- Sur un poste qui refuse la lecture, vérifier le refus qualifié et le compte utilisé ; aucun autre compte essayé.
  Ne pas provoquer d’échecs de mot de passe répétés. Les écritures continuent d’exiger leur validation et confirmation.
- Une campagne interrompue est seulement proposée à la reprise : aucun lancement automatique à l’ouverture.

Noter chaque résultat avec l’empreinte du ZIP ; ne déclarer aucun succès sans observation. Ne modifier ni AD,
ni services, pare-feu ou stratégies pour cette recette. Le banc de qualification passe par David.

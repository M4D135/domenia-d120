# Domenia 2.1.7 — commandes de maintenance du paquet

Version candidate, non publiée. La recette des binaires publiés de 2.1.6 sur un runner Windows hébergé a relevé deux
défauts de ligne de commande et un risque de restauration. 2.1.7 les corrige ; l’interface, la lecture des postes,
l’inventaire et l’AD ne changent pas.
[Bilan et limites](../REPRISE.md).
Pack attendu : `Domenia_2.1.7_PROD-LIGHT_Windows-x64.zip`, avec `SHA256SUMS.txt`.
Extraire dans un nouveau dossier, vérifier l’empreinte puis lancer Domenia.exe. Schéma 11, révision 2 inchangés.

## Points à vérifier

- Mise à jour d’une installation 2.1.5 ou 2.1.6 par `livraison appliquer`, puis depuis Paramètres : action `updated`,
  contrôle de santé confirmé (`HealthConfirmed` vrai), démarrage de la nouvelle version. Jusqu’en 2.1.6, le contrôle de
  santé annulait sa page de vérification et chaque mise à jour revenait aux anciens binaires (code 3), sans cause.
  Un retour automatique donne maintenant sa cause (`Failure`, et « Cause : » dans la fenêtre de mise à jour).
- `Domenia.exe livraison apercu <installation>` depuis un pack extrait à part rend un plan JSON avec sa valeur
  `Confirmation`. De 2.0.8 à 2.1.6, cette commande répondait « Commande inconnue », comme toutes les commandes
  `livraison` de reprise, restauration et désinstallation.
- `livraison appliquer <installation> <Confirmation>` met à jour l’installation ; un fichier
  `wad/Domenia.settings.seed.json` écrit sur place est conservé à l’octet et le démarrage l’admet.
- `livraison apercu-restauration` vers une version antérieure à 2.1.6, alors qu’une configuration par défaut est écrite
  sur place : refus avant toute modification, avec le nom du fichier et la consigne de le déplacer. Une fois le fichier
  déplacé, la restauration aboutit et la version restaurée démarre. Vers 2.1.6, le fichier est conservé et admis.
- `Domenia.exe --check-settings-seed <fichier>` : code 0 pour un fichier valide, code 2 pour un fichier invalide, une
  clé interdite, un JSON tronqué ou un fichier absent. En 2.1.6, une clé interdite faisait planter la commande.

Noter chaque résultat avec l’empreinte du ZIP ; ne déclarer aucun succès sans observation. Ne modifier ni AD,
ni services, pare-feu, WinRM ou stratégies pour cette recette. Le banc de qualification passe par David.

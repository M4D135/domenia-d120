# Domenia 2.1.7 — commandes de maintenance du paquet

Version publiée le 12 novembre 2026, sur la consigne de David d’aller au bout sans attendre (« go publish etc ne
l’attend pas va au bout »). La recette des binaires publiés de 2.1.6 sur un runner Windows hébergé a relevé un défaut
de mise à jour, deux défauts de ligne de commande et un risque de restauration. 2.1.7 les corrige. L’interface, la
lecture des postes, l’inventaire et l’AD ne changent pas.
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

Recette des binaires du 12/11/2026 sur un runner Windows hébergé jetable (run 43230764136), candidat `a08a3e3`
(ZIP `029fcded…`), avec les ZIP 2.1.5 et 2.1.6 téléchargés depuis leurs releases et vérifiés : 21 étapes, aucun échec.

- Admission : 2.1.7 démarre (`--check-only` 0) sans fichier et avec `wad/Domenia.settings.seed.json` ; refus du fichier
  à la racine et d’un `.part` laissé, avec consigne ; `--check-settings-seed` 0 pour un fichier valide, 2 pour une clé
  interdite.
- Mise à jour 2.1.5 → 2.1.7 par `livraison apercu` puis `appliquer` : action `update`, santé confirmée par le vrai
  contrôle WebView2, fichier conservé, démarrage admis.
- Restauration vers 2.1.5 avec le fichier sur place : aperçu refusé, code 2, fichier nommé, installation intacte. Après
  déplacement du fichier : restauration en 2.1.5, qui démarre (code 0).
- 2.1.6 avec un fichier écrit sur place → 2.1.7 : santé confirmée, fichier gardé à l’octet ; restauration vers 2.1.6 :
  fichier conservé, 2.1.6 démarre avec lui (code 0).

Deux passages précédents ont fait corriger les défauts : run 43219420270 sur les binaires publiés seuls, puis run
43225208232 sur le candidat `f33f651`. Ce dernier a atteint les commandes `livraison`, mais toute mise à jour revenait en
arrière. Non observés : la mise à jour lancée depuis Paramètres, qui partage le même contrôle de santé, et tout geste
d’interface ; aucun banc administrateur pour cette version. Le ZIP publié vient de la CI du commit de publication.

Noter chaque résultat avec l’empreinte du ZIP ; ne déclarer aucun succès sans observation. Ne modifier ni AD,
ni services, pare-feu, WinRM ou stratégies pour cette recette. Le banc de qualification passe par David.

# Domenia 2.1.5 — lectures WinRM

Candidat qualifié automatiquement, non publié. En 2.1.4, le choix « CIM / WinRM » échouait sur chaque source en
0x80070057 : la session WinRM était refusée à l’ouverture avec l’identité de la session Windows. 2.1.5 ouvre la session
correctement, lit les réponses WinRM comme les lectures DCOM et ne retente pas la connexion d’un poste sans WinRM.
[Bilan et limites](../REPRISE.md).
Pack attendu : `Domenia_2.1.5_PROD-LIGHT_Windows-x64.zip`, avec `SHA256SUMS.txt`.
Extraire dans un nouveau dossier, vérifier l’empreinte puis lancer Domenia.exe. Schéma 11, révision 2 inchangés.

## Points à vérifier

- Paramètres → Lectures distantes : « Transport CIM » affiche « Automatique : DCOM, puis WinRM si DCOM est
  injoignable ». Inventaire rapide d’un poste joignable en DCOM : transport DCOM et sources lues, comme en 2.1.4.
- Avec « CIM / WinRM », sur un poste où WinRM est actif : inventaire rapide avec l’identité de la session Windows.
  Les sources sont lues par WinRM ; aucun 0x80070057, aucun repli DCOM caché, aucun arrêt du processus de lecture.
  Les dates (démarrage, installation), les tableaux (adresses IP) et les sessions ouvertes sont renseignés.
- Avec « CIM / WinRM » et un compte saisi autorisé sur le poste : même lecture ; un poste qui refuse affiche son code
  et le compte utilisé, sans essai d’un autre compte.
- Sur un poste sans WinRM (Windows 11 sans écouteur, cas par défaut) : chaque source « Injoignable » avec
  0x80338012, la première en quelques secondes, les suivantes aussitôt ; aucune source « Interrompu » par le délai
  sans nouvelle donnée, aucun 0x80070057.
- Un poste éteint ou injoignable en DCOM affiche lui aussi son code (par exemple 0x800706BA).
- Remettre « Automatique » après l’essai et relire la valeur.

Noter chaque résultat avec l’empreinte du ZIP ; ne déclarer aucun succès sans observation. Ne modifier ni AD,
ni services, pare-feu, WinRM ou stratégies pour cette recette. Le banc de qualification passe par David.

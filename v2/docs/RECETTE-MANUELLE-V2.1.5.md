# Domenia 2.1.5 — lectures WinRM

Version qualifiée automatiquement et publiée le 12 novembre 2026 après le go de David. En 2.1.4, le choix « CIM / WinRM »
échouait sur chaque source en 0x80070057 : la session WinRM était refusée à l’ouverture avec l’identité de la session
Windows. 2.1.5 ouvre la session correctement, lit les réponses WinRM comme les lectures DCOM et ne retente pas la
connexion d’un poste sans WinRM. Elle lit aussi les logiciels installés dont les valeurs facultatives sont absentes, et
arrête les animations en boucle quand l’affichage se fait sans accélération graphique.
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
- Sur un poste sans WinRM (Windows 11 sans écouteur, cas par défaut) : la première source « Injoignable » avec
  0x80338012 quelques secondes après le démarrage du processus de lecture (5,4 s sur le poste de banc, dont 1,1 s de
  démarrage), les suivantes aussitôt, « Injoignable » ou « Non tenté » (« Non relu : protocole CIM inaccessible… ») ;
  aucune source « Interrompu », aucun 0x80070057.
- Un poste éteint ou injoignable en DCOM affiche lui aussi son code (par exemple 0x800706BA).
- En Automatique, « Logiciels installés » liste les programmes du poste, sans « code 1 » dans son détail ; « Site AD et
  proxy » lit ses deux valeurs.
- Sur une machine sans accélération graphique : Paramètres → Apparence indique « Affichage sans accélération
  graphique : les animations en boucle s’arrêtent après un passage pour ne pas occuper le processeur. » ; au repos,
  Domenia n’occupe presque plus le processeur.
- Remettre « Automatique » après l’essai et relire la valeur.

Banc administrateur du 11/11/2026 (poste de banc à 2 vCPU sans écouteur WinRM ni carte graphique, ZIP `287fd2b8…`,
source `af201b1`) : les points 1, 4, 6 et 7 sont observés. En Automatique, 27/27 sources par DCOM en 26,4 s, dont
4 logiciels pour 31 clés et « Site AD » 2 requêtes sur 2. En « CIM / WinRM », 0/27 en 5,6 s, sans aucune source
« Interrompu ». La phrase d’Apparence est affichée, et au repos Domenia consomme 0,7 à 1,1 s de processeur par 5 s
(7 à 8,6 s avant le correctif). Les lectures WinRM réussies (points 2 et 3) n’ont pas pu y être observées : elles
restent à vérifier sur un poste où WinRM est actif. Le ZIP publié est reconstruit depuis le commit de publication ; son
empreinte figure dans `SHA256SUMS.txt` de la release.

Noter chaque résultat avec l’empreinte du ZIP ; ne déclarer aucun succès sans observation. Ne modifier ni AD,
ni services, pare-feu, WinRM ou stratégies pour cette recette. Le banc de qualification passe par David.

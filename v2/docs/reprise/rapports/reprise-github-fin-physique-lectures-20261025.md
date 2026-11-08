# Reprise GitHub — fin physique des lectures Accueil

Date : 25 octobre 2026. Branche de reprise GitHub : `codex/v2-finalisation-20261025`.

## Écart prouvé

`WmiWorkstationProbe.ReadFactsAsync`, `WmiFleetProbeReader.ReadAsync` et
`WmiWorkstationReader.ReadConsoleAccountAsync` pouvaient rendre ou lever une annulation dès
l’expiration de leur attente, alors que leur worker WMI continuait. Son quota natif restait
occupé, mais le consommateur Accueil pouvait libérer son admission de campagne avant cette
fin physique.

## Correctif

- `NativeReadCompletion` demande l’arrêt puis attend sans bloquer le thread UI le `Task`
  réel du worker, jusqu’à la fin de sa session et de ses ressources. Les fautes tardives
  sont observées ; aucune continuation abandonnée ne sert de preuve de fin.
- Les trois lecteurs concernés utilisent cette attente. `ReadSharedAsync`, qui possédait
  déjà cette propriété, reste inchangé.
- L’inventaire léger et les sondes proposent une capture explicite des résultats partiels
  à leur consommateur de campagne. Les appels habituels propagent l’annulation après la
  fin physique. Une expiration de l’enveloppe ne devient pas un incident transitoire
  justifiant un nouvel essai.
- `AdDirectorySource` conserve les mesures reçues, vérifie encore l’identité locale et les
  générations de compte/session, puis les enregistre avant de propager l’arrêt. Sans
  qualification LDAP finale, elles restent incomplètes ; aucune console n’est qualifiée.
  Les qualifications des essais utilisent maintenant le token incluant la deadline de
  reprise. La qualification finale déjà accomplie n’est pas répétée inutilement.
- `AdAccueilReader` applique la même règle aux valeurs de sondes : fin physique, contrôle
  local, conservation sous état incomplet, sauvegarde, puis annulation. Il ne commence pas
  de nouvelle qualification LDAP après l’arrêt.
- Une console expirée ne renvoie ni compte qualifié ni date d’observation exploitable.
  Les appelants Relations vérifiaient déjà le token et les statuts avant toute association.
- Le filtre de sonde natif appelle également `ProbeCatalog.ResolveFilter`, fourni par le
  lot de contrôle du catalogue, avant la construction de son SELECT.

## Vérifications préparées

Nouveau fichier `v2/tests/Domenia.Tests/NativePhysicalCompletionTests.cs`, six cas :

1. Deadline externe d’inventaire : worker bloqué, faute tardive observée et mesures déjà
   reçues conservées, sans classification transitoire artificielle.
2. Annulation des sondes : propagation seulement après la fin du worker.
3. Deadline console : attente physique, compte et date non qualifiés, aucune reprise.
4. Annulation console : attente physique puis annulation, malgré une faute native tardive.
5. Consommateur d’inventaire Accueil : admission de compte Remote fictif explicite,
   sauvegarde des partiels après fin physique, aucun LDAP après l’arrêt, puis annulation.
6. Consommateur de sondes Accueil : valeurs conservées incomplètes avant annulation,
   sondes jamais envoyées explicitement non lues.

Relecture statique et contrôle de présentation du diff effectués. **Tests non exécutés,
compilation de ce lot non vérifiée au moment de ce rapport.** Les validations critiques
dans les deux VM Windows et les preuves UI/native restent requises ; ce rapport ne les
remplace pas. Aucune publication PROD/DEV n’est autorisée par ce seul correctif.

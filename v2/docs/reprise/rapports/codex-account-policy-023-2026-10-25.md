# Unification ciblée Fiche / Comptes — lot 023

Deux divergences fermées dans les intentions historiques, sans renommer les `Kind` ni modifier les reçus : la désactivation d’un compte `adminCount = 1` est refusée dans les deux parcours ; imposer `pwdLastSet = 0` est refusé lorsque `DONT_EXPIRE_PASSWORD` rend cette obligation sans effet. `AccountWritePolicy` porte ces règles communes. Les projections des actions Comptes et Fiche affichent le refus avant le clic.

La requalification précède les raccourcis « déjà fait » et la mutation. Les exécutants LDAP relisent toujours l’objet et la session ; Comptes tient également compte de l’attribut `isCriticalSystemObject` déjà demandé à la lecture, comme Fiche. En simulation, Comptes requalifie la valeur dans `UpdateUser`, Fiche dans le verrou de mutation de l’overlay ; le callback ne prend pas le verrou de recherche Fiche. La désactivation simulée utilise l’identité effective de la session, jamais le DN opérateur fourni par le client. Les vérifications de mot de passe refusent un faux succès fondé sur le seul zéro lorsque le mot de passe n’expire pas.

Les confirmations plus fortes sont conservées : désactivation standard Fiche avec nom tapé, règles Comptes existantes, changement de mot de passe privilégié avec nom tapé ; la réactivation Fiche d’un compte privilégié demande maintenant le nom que son contrôle LDAP exigeait déjà. Aucun attribut supplémentaire n’est écrit. Les types `account.enable`, `account.disable`, `account.enabled`, `account.mustChangePassword` et `password.expire` restent distincts pour la compatibilité des plans/reçus.

## Vérification préparée

12 nouveaux tests : `AccountWritePolicyTests` (7, règles pures, projections et vraie mutation simulée par l’exécuteur d’options), `AdAccountWriteTests.Policy.cs` (3) et `AdFicheWriteTests.Policy.cs` (2), utilisant les doubles LDAP existants. Chaque scénario négatif prépare d’abord un plan admissible ou valide son témoin positif ; les assertions portent sur le code de refus, le compteur de modifications et les octets/valeurs préservés. Deux attentes historiques ont été corrigées dans `AccountsRulesTests` et `AccountsRefusalsTests` : un nom tapé n’autorise plus la désactivation protégée.

Aucun build ni test exécuté sur le Mac. `git diff --check` des fichiers du lot est passé. Compilation et recette critique Windows restent à réaliser par root. La recette ciblée demande les 7 tests `AccountWritePolicyTests`, les 5 méthodes ajoutées aux deux classes AD et les 2 attentes historiques modifiées.

## Limites

Ce lot unifie ces deux intentions ; il ne réécrit pas toutes les politiques des autres écritures ni le parcours Poste. L’annuaire reste autorité sur les droits. La relecture des protections avant LDAP ne prétend pas verrouiller toutes les modifications d’autres administrateurs sur le contrôleur ; l’UAC conserve sa comparaison/modification atomique déjà présente. La barrière de session globale reste celle du circuit d’écriture existant. Aucune écriture AD réelle, aucun secret ni service utilisé pendant ce travail.

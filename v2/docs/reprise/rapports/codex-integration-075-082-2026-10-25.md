# Intégration Codex 075–082 — 25 octobre 2026

Les huit captures ont été compilées dans la VM Domenia en Debug et Release, sans avertissement ni erreur. Aucune suite de tests n’a été exécutée : le développement reste actif. Les manifestes enregistrent les octets compilés ; les modifications ultérieures des autres acteurs restent conservées dans le répertoire de travail.

- 075/077 : lecteur, cache, exécuteur, simulation et interface du parc partagé ; pilote de recette native avec garde de session interactive et périmètre AD.
- 076 : dispositions réelles des 47 cartes Poste et 12 cartes Logiciels, battement des pages restantes.
- 078 : publication du parc avec base SQLite absente ou héritée, intention et sauvegardes vérifiées, issue inconnue conservée après tentative ambiguë.
- 079 : file visible et annulation par requestId avant admission, essai de credentials WMI isolé dans le processus natif.
- 080 : dispositions d’équipe D1 requalifiées sous verrou avant import, aperçu du parc préservé pendant sa propre maintenance, identités et traces du partage, spool plat sans répertoires orphelins.
- 081 : budget physique commun des appels LDAP, CIM/WinRM, WTS, événements, DNS, LAPS et lectures SMB ; conservation du bail jusqu’au retour réel et au nettoyage des secrets.
- 082 : 111 sondes disponibles dans les cartes Poste avec leurs valeurs mémorisées réelles, dates, transformations et pagination ; aucune sonde réseau lancée par l’affichage.

## Incident de VM pendant 079

La première compilation079 a été interrompue par le gel de la VM, sans diagnostic C#. SSH et l’horloge du bureau ne répondaient plus. David a explicitement autorisé le redémarrage de cette seule VM. Le reset est resté bloqué au démarrage EFI ; un arrêt/redémarrage à froid de la même VM a rétabli SSH. Aucun autre hôte, service, réseau ou VM n’a été modifié. Le journal interrompu et les diagnostics d’infrastructure restent dans le dossier de reprise local. Les sources ont été revérifiées par empreinte puis recompilées à l’identique avec succès, 56 s. David a rouvert sa session ; console Administrateur active vérifiée. Aucun secret n’est enregistré dans ce rapport.

## Validation restante

Compilations réussies ne valent pas exécution des tests ni recette. Restent les raccordements Query, la coalescence des lectures, Assistance native, la parité du transport optionnel PsExec, la revue ciblée du catalogue et toute la validation finale C#/E2E/UI/domaine/deux VM. Aucun pack final ni release v2.0.0 n’est publié.

# Isolation native 015 — complément essai de compte

La relecture des autres points physiques a révélé que `WmiMachineAccessProbe` utilisait encore System.Management directement, hors `CimSession`. Cet essai explicite passe désormais lui aussi par l’enfant portable privé. Le protocole ajoute uniquement l’action fermée AccessTrial et le nom attendu facultatif ; le DN, la sélection annuaire et le credential complet ne sont pas sérialisés dans une commande.

Le child conserve les distinctions d’origine : mauvais mot de passe, état du compte verrouillé/expiré, accès refusé, délai réseau et échec fournisseur. Le parent restitue l’observation seulement après destruction du client et fin physique de l’enfant. Une défaillance IPC locale n’est pas classée comme rejet du mot de passe distant. Aucun repli dans le parent, aucun rejeu. Une garde interdit l’entrée native depuis le processus principal.

Quatre tests écrits, aucun exécuté : projection du nom réellement confirmé et refus d’une autre cible ; conservation des catégories sur IPC ; véritable enfant avec action désactivée sans réseau ; entrée locale et identité malformée refusées. Fichiers : NativeReadProtocol.cs, NativeReadWorkerHost.cs, WmiMachineAccessProbe.cs, NativeAccessTrialTests.cs. Compilation Windows requise par le coordinateur ; aucun build local.

# Protocole de la campagne Windows distante

Préparer les scripts et archives avant de lancer la campagne. Utiliser un seul lancement GuestControl, puis récupérer les rapports après sa terminaison. Pendant les tests, consulter uniquement l’état du processus depuis l’hôte, sans nouvelle authentification dans l’invité ni copie de fichiers.

Cette précaution suit les erreurs intermittentes `E_UNEXPECTED` observées avant les cas, pendant un chargement DLL. Les [diagnostics](intermediate/profile-diagnostic/diagnostic-summary.json) ont constaté un chargement puis un retrait de la ruche utilisateur lors d’opérations GuestControl, mais **n’ont pas reproduit l’erreur DLL ni établi sa cause**.

L’option `--profile` acceptée par le CLI ne prouve pas qu’un profil Windows soit maintenu : les mesures locales ne l’ont pas démontré et la [documentation Oracle 7.2](https://docs.oracle.com/en/virtualization/virtualbox/7.2/user/vboxmanage.html) la décrit comme non implémentée. Conserver les observations effectives du contexte d’exécution.

Un échec avant les cas reste un échec de campagne. Conserver son rapport et ses empreintes ; toute nouvelle exécution utilise un dossier distinct et indique les changements de protocole. Une exécution suivante réussie ne suffit pas à déclarer la cause corrigée.

Ces contrôles WPF en session 0 utilisent des données fictives. La recette à la souris et les vérifications sur un annuaire réel ont leurs propres preuves ; elles ne sont pas déduites des résultats automatisés.

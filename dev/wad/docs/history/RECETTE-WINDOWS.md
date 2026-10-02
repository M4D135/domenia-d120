# Recette Windows et Active Directory

## Tests automatiques locaux fournis

`TESTER-ADCC.cmd` exécute `wad\tests\Test-ADCC.ps1 -WpfSmoke` sous Windows PowerShell 5.1 64 bits. L’outil extrait les définitions de fonctions avec l’AST Microsoft ; il ne charge pas le démarrage normal d’ADCC dans le processus de tests. Les bases de tests sont générées dans un répertoire temporaire. Aucun secret réel ni objet AD réel n’est nécessaire.

Les contrôles couvrent l’analyse native des scripts, l’écriture atomique et le repli JSON, les filtres de logs et de CSV, les recherches SQL, les limites WMI, le masque des secrets, le registre d’opérations, le nettoyage d’un vrai runspace local annulé, la sauvegarde par `winsqlite3.dll` et l’affectation des caches par périmètre. L’option WPF lance l’autotest interne préexistant dans un processus dédié, avec chargement des écrans et vérification du moteur. Cet autotest peut écrire des traces locales ; il ne correspond pas à une session AD de production.

Exécution sans le chargement WPF facultatif :

```powershell
powershell.exe -NoProfile -STA -File .\wad\tests\Test-ADCC.ps1
```

Exécution complète et rapport explicite :

```powershell
powershell.exe -NoProfile -STA -File .\wad\tests\Test-ADCC.ps1 -WpfSmoke -ReportPath 'C:\Temp\ADCC-tests.json'
```

Un code retour non nul indique un échec. Ne pas conclure que le moteur fonctionne si seul le contrôle lexical Python a réussi : le parseur Windows et les essais WPF sont distincts. Les tests Windows sont livrés mais n’ont pas été exécutés dans l’environnement de création Linux.

## Recette manuelle recommandée

| Cas | Résultat attendu / point à contrôler |
|---|---|
| Démarrage, clair/sombre, DPI 100/150/200 %, fenêtre réduite | Aucun contrôle inaccessible ; login puis fenêtre principale ; journal bas lisible. Les trois nouveaux contrôles du journal restent utilisables. |
| Authentification Windows puis compte explicite | Bon domaine/DC, identité correcte ; pas d’ancien résultat réaffiché après changement de compte. |
| Annulation répétée de recherches lentes | Contrôles rendus disponibles ; compteur des lectures détachées visible dans État moteur ; pas de nouvelle tâche au-delà de la limite physique. Un appel natif peut rester en attente. |
| Changement de compte en lecture active / écriture incertaine | Changement refusé avec explication ; aucune écriture rejouée. |
| Recherche locale `utilisateur@domaine`, nom avec `_`, `%`, apostrophe | Terme traité littéralement ; pas de troncature du suffixe UPN local. |
| Domaine A puis B avec noms courts identiques | Caches distincts ; grille, droits estimés et liens en mémoire rechargés ; comptes secondaires retirés lors du changement de Base DN. |
| LAPS / BitLocker autorisé et refusé | Résultat conforme aux droits du compte ; aucune valeur partiellement visible dans le masque ; copie de la bonne ligne ; remasquage/expiration ; refus non assimilé à un secret vide réussi. |
| Chargement secret puis Effacer avant réponse | Un ancien retour ne doit pas repeupler la vue. |
| Compte AD Windows + compte distant dédié | La requête distante utilise le compte explicitement choisi ; tester WinRM/CIM puis les replis autorisés par l’environnement. |
| WMI standard, `Win32_Product`, limite excessive | Classe standard lisible ; fournisseur MSI bloqué ; requêtes bornées. |
| CSV contenant `=1+1` dans un champ de test | Protection visible lors de l’import texte ; vérifier le comportement du tableur utilisé sans lancer une formule non fiable. |
| Mise à jour avec `-WhatIf` | Aucun fichier de destination modifié ; configuration et données annoncées comme conservées. |
| Installation puis retour arrière sur une copie du projet | Ancien code restauré ; base et réglages personnels inchangés ; refuser l’écrasement d’un fichier de code modifié indépendamment. |
| Écriture AD sur objets dédiés de test | Confirmation, relecture effective du résultat, gestion des refus et des délais ; aucun rejeu automatique d’une écriture incertaine. |

Ne pas lancer ces scénarios d’écriture sur un compte, un groupe ou une machine de production pour simplement vérifier l’interface. Une OU dédiée, un compte de test et une validation hors ADCC permettent de constater le vrai résultat.

## Audit multiplateforme du paquet neuf

L’audit Python ne remplace pas les tests Windows. Il utilise uniquement la bibliothèque standard et n’interroge pas AD :

```text
python wad/tests/audit_project.py --report audit.json
```

Il contrôle aussi que le **paquet neuf** ne contient pas de données personnelles. Ce contrôle est volontairement inadapté à une installation déjà utilisée, dont `wad\data` n’est plus vide. Le script lexical Python est un analyseur approximatif de délimiteurs et de chaînes, pas un parseur PowerShell complet.

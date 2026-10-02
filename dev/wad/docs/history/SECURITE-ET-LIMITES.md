# Ajout R1.5 : Atelier

L'Atelier ne lance aucune nouvelle sonde automatique. Captures, incidents et repères sont limités à la session. Seuls le partage manuel, le presse-papiers et l'export HTML sortent ces données de ce nouvel espace. Les noms et métadonnées internes ne sont pas anonymisés. Les informations dédiées aux secrets et les logs bruts ne font pas partie du rapport. Une information manquante est indéterminée, pas fausse ou supprimée.

Les limites de validation Windows et AD restent valables. Voir `ATELIER-SUPPORT-R1.5.md` à la racine pour les garanties exactes et les exclusions. L'ajout ne corrige pas les risques historiques de PsExec ni les droits réels sur les postes.

---

# Sécurité, compatibilité et limites

## Ce qui ne change pas

Le contrôleur de domaine et les autorisations Windows restent l’autorité réelle. Le mode lecture seule, les contrôles d’intégrité des 46 opérations de travail, les protections des objets et le canal d’écriture unique ne sont pas désactivés. Le code conserve les fonctions d’administration existantes ; cette révision n’ajoute pas de mécanisme pour contourner les GPO, l’UAC ou un antivirus.

Les DLL AD et les exécutables PsExec/ADCC sont identiques octet pour octet aux fichiers fournis. Leur identité avec la source n’atteste ni d’une signature valide ni de leur innocuité : appliquer les contrôles logiciels habituels de l’organisation. Le manifeste SHA-256 repère des différences accidentelles ; comme il accompagne le paquet sans signature indépendante, il ne prouve pas son authenticité face à une modification malveillante du paquet entier.

## Secrets et presse-papiers

Le masque de la grille n’affiche plus de préfixe ou suffixe du secret. La grille masquée ne porte pas de propriété brute `Value`. La révélation est temporaire ; la fermeture d’activation remasque. L’expiration retire les références conservées par ADCC et utilise le mécanisme de nettoyage du presse-papiers existant.

Cela **ne garantit pas une remise à zéro cryptographique de la mémoire managée**, ni la disparition d’un secret déjà copié dans une autre application, un historique de presse-papiers, un outil de capture ou un collecteur externe. Les mécanismes d’administration utilisent encore des mots de passe en clair à certains endroits transitoires. Le repli PsExec avec identifiants explicites conserve notamment l’utilisation de `-p` : le risque d’observation de la ligne de commande par un processus privilégié n’est pas résolu. Les traces ADCC sont filtrées, mais cela ne filtre pas les collecteurs EDR ou les journaux des autres programmes.

Le filtrage des logs couvre plusieurs formes de mots de passe, jetons, authentification Bearer/Basic, clés BitLocker et les valeurs connues au moment du filtrage. Ce n’est pas une garantie de détection de tous les secrets dans n’importe quel format. Les journaux historiques déjà existants ne sont pas réécrits ; ils sont exclus des nouveaux ZIP de diagnostic.

## CSV et diagnostic

Les valeurs textuelles ressemblant à des formules sont préfixées par une apostrophe ; les nombres et dates natifs ne sont pas transformés en texte par cette étape. Cette modification peut ajouter un caractère visible à un texte légitime commençant par `+`, `-`, `@` ou `=`. Elle concerne les rapports destinés à un tableur, pas un format de sauvegarde réversible.

Les tableurs ne traitent pas tous ces protections de la même façon et un réenregistrement peut les modifier. Ouvrir les données non fiables comme du texte ; ne pas considérer le CSV comme totalement inoffensif. Vérifier les exports avant diffusion.

Les diagnostics ne sont **pas anonymisés** : noms d’utilisateurs, machines, domaines, contrôleurs de domaine, chemins et informations de configuration peuvent y figurer. L’utilisateur décide explicitement de l’export et doit le relire avant partage.

## Cache et multi-domaines

L’ancien cache n’est adopté que si `sync_state` identifie le même Base DN. Sinon, un nouveau fichier est choisi dans un répertoire déterminé par le hachage du périmètre. Un ancien cache sans métadonnées peut donc paraître absent dans la nouvelle vue, tout en restant intact sur disque. Il faut resynchroniser le périmètre approprié ou effectuer une migration contrôlée, pas supprimer à l’aveugle les fichiers d’origine.

Cette séparation ne prouve pas que tous les historiques déjà présents dans une base ancienne étaient exempts de mélange ; elle ne réécrit pas rétroactivement les données historiques. La base locale contient des données de parc et doit rester dans un répertoire dont les ACL correspondent à l’usage souhaité. Aucune nouvelle fonction de chiffrement du cache n’est ajoutée.

## Arrêt et concurrence

`BeginStop` est asynchrone. Un appel natif ou distant peut ne pas s’interrompre immédiatement. ADCC retire les callbacks d’une lecture détachée puis libère ses objets lorsque les handles de fin sont terminés. La limite physique empêche une accumulation illimitée de nouveaux workers ; atteindre cette limite suspend les nouvelles demandes au lieu de prétendre que les anciennes sont arrêtées.

Un état d’écriture inconnu ne signifie pas un échec. Relire l’objet réel avant de répéter une action. L’installateur exige la fermeture de l’application et ne tue pas ADCC. Le programme de tests peut arrêter uniquement le sous-processus dédié à son autotest WPF s’il dépasse son délai.

## Sources techniques

Sources officielles utilisées pour les décisions de conception, consultées le 21 septembre 2026 :

- SQLite, Online Backup API : https://www.sqlite.org/backup.html
- Microsoft, PowerShell.BeginStop : https://learn.microsoft.com/en-us/dotnet/api/system.management.automation.powershell.beginstop
- Microsoft, WMI Tasks — Computer Software : https://learn.microsoft.com/en-us/windows/win32/wmisdk/wmi-tasks--computer-software
- Microsoft Sysinternals, PsExec : https://learn.microsoft.com/en-us/sysinternals/downloads/psexec
- OWASP, CSV Injection : https://community.owasp.org/attacks/CSV_Injection

Ces références expliquent les mécanismes et risques. Elles ne constituent pas une validation de ce paquet particulier sous Windows.

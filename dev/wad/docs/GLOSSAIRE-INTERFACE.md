# Glossaire dʼinterface Domenia

Piste P-UI-21 : remplacer le jargon visible par des termes de français courant. Ce document est la référence pour
toute nouvelle étiquette, infobulle, colonne ou message. **Il nʼest pas encore appliqué aux sources** : lʼapplication
se fait après la passe de langue P-UI-04 (`dev/tools/lang_pass.py`), une fois tous les lots fusionnés.

Les décomptes viennent de lʼinventaire des textes dʼinterface de lʼaudit TE-01 (`dev/tools/audit_wording.py`, lu
par `lang_pass.py`) au 15 octobre 2026 : textes distincts, hors textes dʼaccessibilité qui les recopient. Les exemples
donnent `fichier:ligne`, sauf pour lʼaide `Domenia-UX.help.json` : comme lʼaudit, le rapport de `lang_pass.py` y donne
le numéro dʼentrée, pas la ligne du fichier.

## 1. Portée

- **Profil Essentiel, fiches, tableaux, confirmations, barre dʼétat, aide courte** : termes de ce glossaire.
- **Profil Expert, journal, trace technique, aide détaillée** : les termes techniques restent permis (DN, ms, nom du
  serveur, transports, classes WMI). Le profil Expert les ajoute, il ne remplace pas la formulation courante.
- Noms propres et sigles connus des administrateurs : conservés tels quels (Active Directory ou AD, Windows,
  PowerShell, BitLocker, LAPS, DNS, VPN, CSV, OU, Kerberos).

## 2. Règles de rédaction

Ces règles valent pour tout texte dʼinterface, nouveau ou corrigé. La dernière colonne dit ce que `lang_pass.py`
vérifie lui-même : il refuse une correction qui laisse une faute de lʼaudit TE-01 (accent, élision, tutoiement), qui
contient `'` ou un guillemet typographique, ou qui change une variable, un paramètre, un `$` ou un `` ` ``. Les
autres règles ne se vérifient pas mécaniquement : la table sûre nʼaccepte que des corrections dʼaccents et
dʼapostrophes (toute autre différence part dans la table à relire), et la table à relire se relit avec ce tableau
avant toute application.

| Règle | Exemple à suivre | À éviter | Vérifiée par `lang_pass.py` |
|---|---|---|---|
| Accents, y compris sur les capitales | « État », « À la demande », « Élément » | « Etat », « A la demande » | mots suivis par lʼaudit |
| Apostrophe `ʼ` (U+02BC) uniquement | « lʼannuaire », « nʼest » | « l annuaire », « l'annuaire », « l’annuaire » | oui |
| Vouvoiement pour une consigne | « Sélectionnez un poste. », « Vérifiez le réseau. » | « Selectionne un poste. », « Verifie le reseau. » | formes de lʼaudit (tu, ton, Choisis…) ; pas les verbes en -er |
| Infobulle : verbe à la 3e personne qui décrit lʼaction | « Ouvre la fiche du poste associé. » | « Ouvrez la fiche… » dans une infobulle | non : relecture |
| Bouton : verbe à lʼinfinitif | « Ouvrir la fiche », « Vider la mémoire locale » | « Ouvre la fiche » sur un bouton | non : relecture |
| Étape, action proposée, question : infinitif conservé | « Vérifier lʼétat du compte… », « Abandonner ces saisies… ? » | « Abandonnez ces saisies… ? » | non : relecture |
| Participe passé devant une date ou un état | « Détecté le », « Démarré le », « Vérifié : … » | « Détecter le », « Démarrez le » | non : relecture |
| Titres et sections en casse normale | « Mode écriture AD actif », « Annuaire AD » | « MODE ECRITURE AD ACTIF », « ANNUAIRE AD » | non : relecture |
| Le nom du logiciel | « Domenia » | « DOMENIA » | non : relecture |
| Durées en secondes dans le profil Essentiel | « Durée : 1,2 s » | « Durée ms : 1200 » | non : relecture |
| Variables et paramètres intacts | « $count valeur(s) chargée(s) » | changer `$count`, `{0}` ou `${elapsed}` | oui |

Pourquoi `ʼ` : dans une chaîne PowerShell entre apostrophes, une apostrophe droite `'` ferme la chaîne et les
guillemets typographiques `‘ ’ “ ”` sont aussi des délimiteurs pour Windows PowerShell 5.1. Le caractère `ʼ` est une
lettre : il ne casse jamais une chaîne. Les `’` encore présents dans certaines infobulles XAML sont à remplacer par `ʼ`.
Étant une lettre, il compte aussi comme caractère de mot dans une expression régulière : `\bactive\b` reconnaît
« d Active » mais plus « dʼActive ». `lang_pass.py` évalue chaque motif sur lʼancien et le nouveau texte et signale ce cas.

## 3. Glossaire

| Terme visible aujourdʼhui | Terme à afficher (profil Essentiel) | Terme technique gardé pour | Exemples actuels | Textes |
|---|---|---|---|---|
| Ping, Pinger, « Pinger la liste » | « Tester la réponse », « Tester la réponse des postes » | Expert, journal : « ping (ICMP) » | `Domenia-Core.ps1:5467` bouton « Pinger la liste » | 46 |
| Console, « Compte console », « Utilisateur connecté (console) » | « Utilisateur connecté » | Expert : « session console » | `Domenia-Core.ps1:5515` colonne, `:6295` « Compte console » | 26 |
| managedBy | « Responsable indiqué dans lʼannuaire » | Expert (vue des attributs) | attribut managedBy de la vue Expert ; la fiche dit déjà « Responsable » | 0 |
| DN, « Base DN », « Racine LDAP », distinguishedName | « Emplacement », « Emplacement dans lʼannuaire » | Expert, journal, copie du chemin | `Domenia-Core.ps1:5193` « Base DN », `:8208` « Racine LDAP : » | 25 |
| ms, « Durée ms » | « Durée » en secondes | Expert, journal | `Domenia-Core.ps1:6676` colonne « Duree ms » | 3 |
| Serveur, DC, « Serveur / DC » | « Contrôleur de domaine » ou rien | Expert, journal : nom du serveur | `Domenia-Core.ps1:5175` « Serveur / DC » | 8 |
| Transports : WMI, CIM, DCOM, WinRM, SMB, RPC, ICMP, LDAP | Le but de lʼaccès : « lecture à distance du poste », « lecture de lʼutilisateur connecté », « accès aux fichiers du poste » | Expert, journal, page Transports du profil Expert | `Domenia-Park.UI.ps1:100` confirmation « (CIM/DCOM) » ; `Domenia-Core.ps1:6060` | 36 (WMI), 9 (CIM) |
| « Fraîcheur AD » | « Lu dans lʼannuaire le » | — | `Domenia-Core.ps1:5519` colonne | 2 |
| « Source lien » | « Origine de lʼassociation » | — | `Domenia-Core.ps1:5528` colonne | 1 |
| Sonde, sondes | « Vérification », « vérifications du poste » | Expert : « sonde » | `Domenia-Core.ps1:5148` « les sondes choisies » | 31 |
| Cache, « Cache visite », « Vider le cache » | « Mémoire locale », « Objets consultés », « Vider la mémoire locale » | Expert, journal | `Domenia-Core.ps1:5162`, `:5229` | 20 |
| Lots de cache | « Enregistrements en attente » | Journal | `Domenia-Core.ps1:7026` | 2 |
| Domenia.db, SQLite | « Base locale » | Expert, journal | `Domenia-Park.UI.ps1:213` « enregistrement SQLite non confirmé » | 8 |
| Dashboard | « Tableau de bord » | — | `Domenia-Core.ps1:21478` « Etat dashboard copie. » | 7 |
| Widget, widgets | « Vignette », « vignettes du tableau de bord » | — | `Domenia-Query.UI.ps1:692` « Détail du widget : » | 16 |
| Credential | « Identifiant », « compte et mot de passe » | Journal | `Domenia-Core.ps1:7327`, `:12818` « Credential poste » | 4 |
| Preflight | « Contrôle préalable » | Journal | `Domenia-Core.ps1:25545` | 3 |
| Fallback | « Repli », « solution de repli » | Journal | `Domenia-Core.ps1:7250` colonne « Fallback » | 2 |
| Relogin | « Reconnexion » | Journal | `Domenia-Core.ps1:21803` « Relogin annule. » | 2 |
| Scan | « Balayage » (déjà employé : « Aucun balayage ») | — | `Domenia-Core.ps1:7391` « Aucun scan nʼest lancé » | 7 |
| Cmdlet, cmdlets | « Commande PowerShell » | Expert (aide des commandes) | `Domenia-Core.ps1:19293` « Cmdlets : … » | 9 |
| Regex | « Motif » | Expert : « expression régulière » | `Domenia-Support.xaml:92` | 1 |
| Option UAC (userAccountControl) | « Option du compte » | Expert (vue des attributs) | `Domenia-Core.ps1:27101` « Aucune option UAC modifiée » | 2 |
| ACL, « estimation ACL » | « Droits », « estimation des droits » | Expert : « ACL » | `Domenia-Core.ps1:25543` | 5 |
| GUID | « Identifiant unique de lʼobjet » | Expert | `Domenia-Core.ps1:5620` | 6 |
| SID | « Identifiant de sécurité » | Expert, journal | aide `Domenia-UX.help.json`, entrée 464 (`ChkRelationEvents`) | 1 |
| UPN, « UPN / DNS » | « Nom de connexion (utilisateur@domaine) » | Expert | `Domenia-Core.ps1:5524` colonne | 2 |
| sAMAccountName | « Nom de connexion (ancien format) » | Expert | `Domenia-Core.ps1:8675` | 1 |
| PsExec, tâche planifiée | « Exécution de secours sur le poste » | Expert, journal | `Domenia-Core.ps1:7022` | 4 |
| RSAT, DLL | « Outils dʼadministration Windows » | Expert, journal | `Domenia-Core.ps1:27759` | 1 |
| Classes Win32_… | rien : vue réservée au profil Expert | Expert (explorateur WMI) | `Domenia-Query.xaml:217` | 3 |
| Mode DEBUG, « TRACE TECHNIQUE » | « Diagnostic de connexion », « Détail technique » | Journal | `Domenia-Core.ps1:28938`, `:28964` | 2 |

Remarques :

- Une colonne renommée ne doit jamais être retrouvée par son en-tête. Le code la repère par `x:Name` ou `Tag`
  (piste P-FI-16). En-têtes réellement comparés dans le code au 15 octobre 2026 : « Methode » et « Duree ms »
  (`Domenia-UX.UI.ps1:242`), « Derniere connexion » (`Domenia-Live.UI.ps1:150`). Ils doivent être découplés avant
  toute correction ou tout renommage.
- `lang_pass.py` repère les comparaisons par littéral, pas par flux de données : la section `Dependencies` du rapport
  liste chaque comparaison qui retient un texte, et marque « possible » une clé, un index ou un nom de propriété égal au
  texte. Une comparaison relue et sans rapport avec le texte est consignée, avec son motif et sa ligne exacte, dans
  `dev/engineering/d120/programme-2026-10-08/langue-dependances-ecartees.json` ; si la ligne change, le texte est de
  nouveau retenu. Cʼest le cas des en-têtes « Etat » (lignes dʼinventaire), « Detail » (clés, types et familles
  internes), « Operation » (nom de propriété) et « Parametres » (code de problème interne) : leur correction
  dʼaccents nʼattend pas P-FI-16.
- Les textes reconnus par le code doivent suivre le même chemin. Exemple : `Domenia-UX.UI.ps1:59` reconnaît les
  infobulles dʼactions désactivées par leur début (« Desactive… », « Droit indetermine… »). Il faut changer cette
  règle en même temps que les infobulles, ou mieux la remplacer par un état porté par lʼaction.
- Arbre de recherche : une icône « dossier » pour une OU et une icône « conteneur » pour un conteneur (Users,
  Computers…), pour que le type se voie sans le mot.

## 4. Application (après la fusion des lots)

1. Passe de langue P-UI-04, depuis `dev/` (intégrateur, après la fusion des lots) :
   1. `python3 tools/lang_pass.py --report <rapport.json>` (simulation) : lire `Manual`, `Dependencies`, `Tests` et
      `References`, et vérifier que `UnusedCleared` est vide.
   2. `python3 tools/lang_pass.py --apply` (table sûre), puis `--apply --include-review` une fois la table à relire
      validée. Les tests listés dans `Tests` (texte littéral ou motif) sont mis à jour à la main.
   3. `python3 tools/audit_wording.py --update` abaisse la référence TE-01.
   4. `python3 tools/audit_preload.py` échoue sur « Unchanged critical function » : la passe modifie des fonctions
      critiques épinglées du cœur. Au 15 octobre 2026, la table sûre touche `Start-DomeniaFastLoginAttempt`,
      `Update-DomeniaFastLoginAttempt` et `Start-DomeniaWriteTask` ; la table à relire ajoute `Invoke-GlobalSearch`.
      Lʼintégrateur relit ces fonctions puis enregistre sa décision :
      `python3 tools/audit_preload.py --rebaseline --decision "Passe de langue P-UI-04 relue" --source <commit>`.
   5. `python3 tools/update_worker_contracts.py` doit répondre `"ReviewedChangesRequired": []` (aucun worker épinglé
      nʼest touché au 15 octobre 2026). Sinon, relire chaque opération listée avant `--apply`.
   6. `python3 tools/build_packages.py --manifest-only --output <dossier hors de lʼarbre>` régénère
      `wad/package-manifest.json` et `tools/prod-manifest.json` ; sans cela `Domenia-Start.ps1` refuse le démarrage.
   7. `python3 tools/validate_powershell_static.py`, puis les suites Windows dans la VM, tests mis à jour compris.
2. Glossaire : chaque remplacement est une reformulation. Il entre dans la table à relire par
   `python3 tools/lang_pass.py --merge paires.json` (objet JSON `{"texte actuel": "texte corrigé"}`). Les mêmes
   garde-fous sʼappliquent : variables intactes, infobulle, texte dʼaccessibilité et aide modifiés ensemble,
   comparaisons du code et tests signalés.
3. Profil Expert : quand le terme technique reste utile (DN, ms, nom du serveur, transport), il est affiché par la vue
   Expert ou par lʼaide détaillée, pas ajouté à lʼétiquette courante.
4. Garde-fou durable : ajouter à `audit_wording.py` une règle « jargon » qui lit la première colonne de ce glossaire
   (hors profil Expert, journal et aide détaillée) avec une référence à cliquet, comme TE-01 : aucun nouveau texte
   jargonnant, et la référence ne peut que baisser.

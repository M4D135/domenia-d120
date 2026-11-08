# Domenia v2.0.0 — recette manuelle de David

Le 25 octobre 2026, David a autorisé la livraison PROD/DEV v2.0.0 sans attendre les tests des deux VM et a pris en charge la recette manuelle. **Ce guide n’est pas un compte rendu : tous les contrôles ci-dessous sont à effectuer.** La [CI Windows — run 40224745081, job 121263620296](https://github.com/M4D135/domenia-d120/actions/runs/40224745081/job/121263620296), au SHA `1e877d650df71b37716b0b0840726238f632db7d`, a réussi 587 tests C# critiques et 15 contrôles Python. Cette preuve reste liée à ce SHA ; elle ne remplace pas l’observation du pack livré. Les validations domaine/UI/deux VM restent non exécutées.

## Préparer le passage

Conserver les ZIP reçus et `SHA256SUMS.txt`. Comparer leurs empreintes avec `Get-FileHash -Algorithm SHA256`, puis extraire le PROD dans un dossier neuf sans remplacer l’installation habituelle. Noter version, commit source, SHA256 du ZIP, machine, date et mode utilisé. Garder les captures et observations hors du dossier du pack ; ne pas inclure de mot de passe, secret ou donnée sensible dans le retour.

Utiliser les profils et données de test disponibles sans supprimer le profil habituel. Commencer par la démonstration pour les gestes fictifs, puis choisir explicitement une petite OU pour les lectures réelles. Si un profil vierge ou un cas de panne n’est pas disponible, inscrire **non exécuté**, avec sa raison. Ne pas provoquer une panne en modifiant le réseau, les services, le runtime ou la stratégie de sécurité. Aucun téléchargement de dépendance, reboot ou logoff n’est nécessaire ni autorisé par cette recette.

Guides complémentaires joints dans ce même dossier : [mises à jour](MISES-A-JOUR.md), [démonstration](DEMONSTRATION.md), [référentiels](REFERENTIELS.md) et [configuration à diffuser](CONFIGURATION-DIFFUSABLE.md).

## Parcours prioritaires

Pour chaque ligne, renseigner **réussi**, **échec** ou **non exécuté** après observation, avec une courte note et la capture ou le journal correspondant. Une donnée inconnue, un refus ou un arrêt ne doivent pas être confondus avec une mesure réussie.

| Parcours | Geste et points à observer |
| --- | --- |
| Démarrage portable | Lancer le `Domenia.exe` du PROD extrait. Vérifier la fenêtre native, la version, le mode affiché et l’absence de demande d’installation. Un refus d’intégrité doit rester visible, sans contourner le contrôle. |
| Connexion native | Ouvrir la connexion explicite ; vérifier mot de passe masqué, indication Verr. Maj, annulation par Échap et suivi du même essai. Employer un compte de test autorisé, sans multiplier des essais invalides. Si le diagnostic est disponible, sa copie doit correspondre aux lignes affichées et ne contenir aucun secret. |
| Thèmes et confort | Passer clair/sombre, vérifier lisibilité et navigation clavier. Changer le thème de la saisie native, la fermer puis la rouvrir : choix mémorisé sans authentification supplémentaire. Contrôler également le zoom et les animations dans l’application. |
| Profil et démonstration | Retenir une OU et une disposition, fermer puis rouvrir seulement l’application : les choix attendus restent présents. Ouvrir la démonstration depuis Paramètres, effectuer une action fictive, réinitialiser, quitter : le contexte réel revient sans données fictives. Voir [DEMONSTRATION.md](DEMONSTRATION.md). |
| Configuration : export/import | Dans Paramètres → Configuration à diffuser, sélectionner des réglages et une OU seulement si souhaité. Exporter, importer, examiner l’aperçu puis annuler : rien ne doit être appliqué. Refaire et confirmer : sauvegarde préalable, reçu et clés attendues ; les réglages absents restent conservés. Relancer l’application pour vérifier les réglages métier. |
| Configuration : pack par défaut | « Définir comme configuration par défaut » doit préparer une nouvelle copie, sans modifier le pack ouvert. Sur un profil de test réellement vierge, vérifier l’application automatique du seed ; sur un profil existant, vérifier aperçu, sauvegarde et choix de conserver/remplacer. Aucun import ne doit déclencher une collecte. Si le profil vierge manque, noter ce cas non exécuté. Voir [CONFIGURATION-DIFFUSABLE.md](CONFIGURATION-DIFFUSABLE.md). |
| Rechercher | Choisir une petite OU, lancer une recherche, changer un filtre et ouvrir un résultat. Vérifier périmètre, identité, nombre de lignes et indication des résultats partiels. Les résultats précédents ne doivent pas être présentés comme ceux d’une nouvelle cible. |
| Fiche et Poste | Ouvrir une fiche et un poste de test ; lire les données locales puis demander explicitement un relevé. Vérifier cible, sources, dates et états inconnus/partiels. Fermer puis rouvrir la fiche : les valeurs conservées gardent leur provenance et leur date. Aucune écriture AD n’est requise pour ce contrôle. |
| Reprises de lecture et arrêt | Sur un relevé déjà lent ou un refus observable, demander « Arrêter » : progression cohérente, résultats acquis conservés, aucun faux succès. Vérifier qu’un refus de droits n’est pas réessayé en boucle. Si une interruption récupérable se produit, noter les tentatives réellement visibles et le résultat final ; ne pas inventer ce cas s’il ne survient pas. |
| Accueil : reprise durable | Dans une petite OU, demander une actualisation puis l’arrêter. Après fermeture/réouverture de l’application lorsque l’arrêt est terminé, examiner la proposition de reprise et la confirmer explicitement. Vérifier que les étapes déjà enregistrées restent acquises et qu’un changement de contexte impose un nouveau plan au lieu de réutiliser l’ancien. |
| Widgets et sondes personnelles | Ajouter une carte, examiner le plan de collecte, puis suivre file, progression, arrêt et résultat daté. Une ouverture du catalogue ou un import de sonde ne déclenche aucune collecte. Si une sonde personnelle est utilisée, vérifier son aperçu, droits/coût, confirmation puis valeurs dans Accueil/Poste ; une nouvelle version ne doit pas remplacer silencieusement les valeurs de l’ancienne. |
| CLI locale | Fermer l’application pour libérer la base de test, puis essayer les trois commandes décrites ci-dessous. Attendre la fin réelle du processus et noter sortie/code. Vérifier absence de fenêtre/connexion AD et empreintes de la base inchangées ; une base occupée ou WAL doit être refusée, sans conversion. |

Les contrôles de lecture n’autorisent aucune écriture implicite. Si David ajoute un essai d’écriture AD, il reste exclusivement dans `OU=Domenia-Tests,DC=cnamts,DC=local`, avec plan, confirmation, reçu, relecture et restauration contrôlée. Aucun reboot/logoff, changement de service ou écriture hors de cette OU ne fait partie de ce guide.

## CLI : trois lectures locales

Utiliser une base `.db` locale existante, fermée et cohérente. Les exemples supposent `C:\DomeniaRecette\cache.db` ; adapter ce chemin et remplacer `PC-TEST` par un nom présent dans la base. Aucun accès annuaire ni création/migration de base ne doit partir. Une base avec WAL, journal actif ou fichier annexe est refusée ; ne pas retirer ses journaux pour forcer la lecture.

| Arguments à donner à `Domenia.exe` | Résultat à examiner |
| --- | --- |
| `version` | Version et contrat `Domenia.Automation/1`, sans lecture de base. |
| `etat --base "C:\DomeniaRecette\cache.db"` | Identité, révision et état daté de la base locale ; aucun filtre de postes. |
| `postes --base "C:\DomeniaRecette\cache.db" --postes PC-TEST --limite 5` | Postes du seul périmètre demandé, dates, notes et éventuelle troncature. |

L’exécutable étant fenêtré, attendre sa fin avec `Start-Process`. Depuis la racine du PROD extrait, après création d’un dossier de résultats neuf hors du pack, par exemple `C:\DomeniaRecette\passage-01` :

```powershell
$domeniaCli = Start-Process -FilePath '.\Domenia.exe' -ArgumentList 'version' -Wait -PassThru `
    -RedirectStandardOutput 'C:\DomeniaRecette\passage-01\version.json' `
    -RedirectStandardError 'C:\DomeniaRecette\passage-01\version.err'
$domeniaCli.ExitCode
```

Reprendre cette invocation avec les deux autres arguments du tableau et des noms de sortie distincts. Code `0` : réponse produite, dont les notes et `Truncated` restent à lire ; `2` : commande/option refusée ; `3` : base ou configuration absente, occupée, incohérente, hors limites ou délai dépassé ; `4` : périmètre, démonstration ou intégrité du paquet refusés ; `5` : destination/sortie impossible. Conserver le JSON et le code réels, sans les préremplir.

## Retour utile

Pour une anomalie, fournir : version/commit et SHA256 du pack, parcours, mode réel ou démonstration, étapes exactes, résultat attendu, résultat observé, heure et capture/journal sans secret. Conserver les reçus incertains et ne pas répéter une écriture pour tenter de faire disparaître l’erreur. Une correction ou un nouveau pack demandera de retester le parcours concerné ; le passage précédent reste lié à ses octets.

Une recette manuelle ne doit être déclarée réussie que pour les lignes réellement observées. Elle ne crée pas rétroactivement la qualification automatisée et les preuves UI/native des deux VM.

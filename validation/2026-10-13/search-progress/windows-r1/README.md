# Recette Windows ciblée — RC1.17.6

## Périmètre

Reprise demandée le 13 octobre 2026 après remise à disposition du PC. Exécution dans la VM existante `CNAMTS-W11-01`, sur le relais du laboratoire, avec Windows PowerShell 5.1 x64 STA. Une extraction séparée reçoit les packs RC1.17.6 publiés ; aucune installation précédente n’est remplacée.

Les dix suites couvrent les délais et la progression, le périmètre OU, les compteurs, le statut AD, l’actualisation de l’OU, la fraîcheur, les contrôles WPF et la géométrie. Freshness utilise réellement SQLite natif avec une base jetable. Le démarrage PROD est contrôlé séparément avec `-CheckOnly`. Les objets et transports des tests sont fictifs : aucun AD réel, ping/WMI distant ni modification d’annuaire.

## Traçabilité

- `guest-runner.ps1` : onze étapes séquentielles, JSON et codes de sortie contrôlés, attente bornée par sous-processus ; arrêt uniquement des enfants créés par ce runner en cas de dépassement.
- `lab-control.py` : copie via les accès SSH/GuestControl préexistants. Aucun changement de configuration réseau, service ou politique persistante. Après constat du refus initial, `-ExecutionPolicy Bypass` est limité au processus du runner et hérité par ses enfants.
- Le statut utilise le nom de l’état VirtualBox, car les valeurs numériques des versions installées diffèrent. Le verrou COM est libéré seulement lorsqu’il a effectivement été acquis.
- Le runner refuse un dossier de preuves ou une extraction existante. Les ZIP sont vérifiés par taille/SHA, les 397 fichiers DEV et 95 fichiers PROD sont inventoriés avant et après exécution.
- Les originaux récupérés restent sous `/tmp/domenia-search-progress-windows-r1-originals`. Les copies versionnées indiquent toute normalisation du texte et ses empreintes.

Pendant l’exécution : `python3 validation/2026-10-13/search-progress/windows-r1/lab-control.py status`. Ne pas authentifier une nouvelle session invitée ni récupérer des fichiers tant que le processus de campagne est actif.

## Limites

La campagne ciblée ne suffit pas à qualifier toute la distribution. Elle ne remplace pas une recherche sur l’AD réel, une collecte distante ou un parcours interactif via les clics. Les captures et le parcours GUI restent une preuve séparée. Les résultats antérieurs de PowerShell 7 et des versions précédentes restent conservés avec leur périmètre d’origine.

## Résultat conservé — échec partiel

Le premier lancement effectif sous Windows PowerShell 5.1 a exécuté Freshness : **16 cas réussis sur 17**, dont le cas SQLite natif en échec (« Transactional provenance missing »). Un défaut du runner a ensuite interrompu la campagne : PowerShell 5.1 convertit `$null` en chaîne vide pour le paramètre de sauvegarde de `File.Replace`. Aucune autre suite n’est qualifiée par cette tentative.

`proof/` contient les octets reçus, sans normalisation. `retrieved-sha256.json` en donne les empreintes locales ; le runner n’a pas pu achever son manifeste invité. La tentative suivante, `../windows-r2`, corrige le runner avec `[System.Management.Automation.Language.NullString]::Value`, dans un nouveau dossier et sur les mêmes archives figées. Les preuves d’échec restent conservées.

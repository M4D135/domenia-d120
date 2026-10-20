# RC1.17.39 — contrôles critiques ciblés

Passe en cours ; aucune qualification générale ni livraison finale revendiquée. VM DOMENIA-FIRSTRUN-20261020 conservée, Windows PowerShell 5.1 x64 STA. Données de test isolées, pas d’écriture AD ni de changement de stratégie.

## Résultats acquis sur le premier candidat

- Démarrage avec contrôle du manifeste et chargeur fermé : réussi. Contrôle de compatibilité de source PS5.1 : 342 fichiers, zéro erreur.
- Aperçu local : 19/19 ; recherche WPF et Dispatcher réel : 16/16. Les premiers échecs provenaient d’imports manquants dans les fixtures ; rapports initiaux conservés. WiringCache : 190 cas réussis lors de la passe initiale, son cas D024 échoué passe après ajout des deux vrais helpers (rapport `WiringCache-final.json`). La suite complète n’a pas été rejouée.
- Préférences : 9/9 ; maintenance SQLite et sauvegardes : 33/33 ; pannes stockage : 8/8 ; RemoteStore : 34 cas réussis. Le disque plein est simulé par `max_page_count` et produit le vrai `SQLITE_FULL` ; aucun volume physique rempli, donc le rapport StorageFaults reste `Qualifying=false`.
- Santé : 23/23 règles ; 5 000 objets synthétiques en 1 437 ms. Aucun gain avant/après établi.
- Connexion/démarrage : 48/48 cas sans AD. CollectCircuit : 7 contrôles AST, pas des essais réseau.
- AD/WMI réel : premier poste en délai dépassé (budget de test réduit à 2 secondes), poste suivant DC01 lu avec succès puis résultat inscrit dans SQLite. Lot clôturé 2/2, un échec attendu, pas d’arrêt global. Réseau, callbacks et stockage non simulés.
- Parcours UIA réel : connexion Windows, Premiers pas, OU sans collecte implicite, collecte AD confirmée, préparation du dashboard, recherche, fiche, poste, santé, fermeture normale. Fiche : 300 ms ; première ligne de recherche : 12 959 ms sur ce passage. Ce ne sont pas des mesures comparatives sur une VM au repos. Les captures pixels étaient indisponibles pendant ce passage verrouillé ; la réussite UIA n’est pas une validation visuelle. Session déverrouillée ensuite, capture du bureau réussie.
- Guides DOCX/PDF régénérés et relus visuellement ; copies DOC identiques par SHA256. Captures intégrées RC20 conservées explicitement comme historiques. `doc_sync` réussi.

## Liaison aux sources et limites

`rc39-critical-tests/Environment.json` porte les empreintes de Core, du chargeur, de la release et du manifeste. Les rapports WMI et UIA portent également leurs empreintes. Le candidat DEV était B79F1B11821162F5D7CC0BFADCE44C0D4EE2B30D9DA834B789C29227E2E9BD65 ; PROD D82C17B915A3CA4CB9332E873970E2FF3AF50906D8169493D97CD4B953D3AF53. Leurs 174 fichiers applicatifs étaient identiques.

La dernière revue a trouvé trois optimisations partielles (6, 8, 38) : corrections complémentaires en cours, distinctes de ces preuves. Les archives finales seront liées à une passe delta ciblée et au contrôle visuel final. Aucun résultat ci-dessus ne certifie un code futur.

Endurance longue, gros parc réel, multi-écrans, Narrateur, variations DPI et qualification générale restent hors de cette passe critique demandée. Aucune clôture formelle D001–D120 par `acceptance_passed=true`.

Les JSON sont conservés en UTF-8/LF ; quelques journaux texte disponibles restent des pièces complémentaires. Les scripts reproduisent les appels du labo sans secret.

# RC1.17.17 — sauvegarde automatique et restauration via interface

Essais ciblés du 18/10/2026 dans CNAMTS-W11-01, Windows PowerShell 5.1 x64 STA, session interactive. Une copie isolée du PROD exact utilise son propre dossier de données portable ; aucun profil opérateur copié, aucune écriture AD, aucune VM supprimée.

- Activation des sauvegardes et enregistrement des réglages par les contrôles WPF. La minuterie réelle de 60 s, inchangée, déclenche le premier cycle ; aucun appel manuel au worker. Reçu `Automatic=true`, `Origin=Scheduled`, empreinte et taille concordantes, `quick_check=ok` et marqueur synthétique présent.
- Désactivation par interface, observation de 65 s sans autre copie. L'intervalle configuré reste 24 h : cette observation ne remplace pas la vérification d'une échéance de 24 h ni de plusieurs rotations.
- Après fermeture, checkpoint de la seule base isolée, conservation d'une copie saine puis corruption volontaire de son fichier. Le démarrage maintient l'interface disponible ; restauration autorisée et déplacement bloqué.
- Sélection de la sauvegarde automatique et d'un nouveau fichier par les deux dialogues natifs. Aperçu inspecté et confirmation par le bouton WPF. Le fichier restauré passe `quick_check`, contient le marqueur, devient la base préférée persistante et libère le mode récupération. Les SHA-256 de l'original corrompu et de la sauvegarde sont inchangés. Fermeture normale de l'application isolée.
- Contrôle final : 172 fichiers PROD, 642 DEV et 172 dans la copie isolée inchangés. Les archives RC17 restent identiques à celles des preuves précédentes. Rapports et copies de test récupérés sur le Mac avant tout effacement des VM.

## Traçabilité

`Qualification.json` lie les preuves aux ZIP RC17 : PROD `0393c1b7fd23e732209d3f96c4c91196afcb57ba26f02e86d79bbbc7eb4e908a`, DEV `001ae72db21059bda3ad5ac72e810d8c69e20b948e2fc18c224f5b070a2eb04b`. Le contrôle final révèle un défaut RC17 : la politique de sauvegarde et ses reçus sont perdus au rechargement des préférences. Quatre cas échouent sur RC17 (les trois rechargements et l’admission bornée des nouvelles clés), puis les cinq passent avec le correctif RC18. Le rejet des clés/types invalides passe dans les deux versions. Les ZIP courants deviennent ensuite RC18 pour ce correctif et la mémorisation de fenêtre ; ces essais de stockage ne sont pas réétiquetés RC18.

`Auto-Result.json` et `RestoreFinish-Result.json` sont les résultats terminaux. `Restore-Result.json` décrit l'étape intermédiaire avec le sélecteur ouvert, donc Passed=false. Les tentatives de pilotage antérieures ne qualifient pas le produit : fenêtre confondue avec une infobulle, en-têtes de l'espace de travail masqués, transition connexion/fenêtre principale et accès UIA aux dialogues natifs. Le contrôle final utilise le pair de l'onglet sélectionné ; le dialogue Enregistrer est piloté par ses contrôles Win32 après blocage du fournisseur UIA. Sa destination proposée, restée inchangée malgré la tentative de saisie du pilote, est relue dans l’aperçu et validée comme nouveau fichier isolé avant confirmation. Aucun contournement des workers ou de la confirmation applicative.

À la demande de David, le verrouillage automatique et les délais de veille secteur de cette VM de laboratoire ont été désactivés ; état précédent et réglages appliqués conservés. Pas de changement de l'hôte, du DC ni du verrouillage manuel. Les tâches de test sont retirées après vérification ; les VM restent disponibles pour leur propriétaire.

## Limites

Qualification ciblée par automatisation des contrôles et inspection des captures, pas une recette humaine complète. Restent les échéances longues et rotations répétées, migrations exhaustives, volumes représentatifs et autres parcours. Décisions externes 134/146 inchangées, publication générale non autorisée. La preuve distincte [RC18 fenêtre](../rc18-window-geometry/README.md) couvre le nouveau correctif.

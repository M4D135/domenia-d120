# Labo AD/WMI réel — RC1.17.16 puis correctif RC1.17.17

Essai limité demandé le 18 octobre 2026 : lecture AD et un lot de deux cibles, dont une en délai dépassé. Exécution Windows PowerShell 5.1 x64 STA dans **CNAMTS-W11-01**, domaine de laboratoire `cnamts.local`. L’hôte ne fait que relayer. CNAMTS-DC01, initialement arrêté, a été démarré ; son nom Windows publié par DNS est `dc01.cnamts.local`. Aucune écriture AD, aucun changement de pare-feu, de WinRM ou de stratégie, aucun secret lu ou saisi. Les deux VM restent démarrées.

## Constat RC1.17.16

- **AD réel réussi** : RootDSE puis lecture bornée de huit objets ordinateur avec la DLL AD livrée ; nouvelle lecture ciblée de DC01 dans le pilote de lot. Authentification Windows du compte de laboratoire, aucun mot de passe dans le pilote. Preuve : `rc16/AD-and-RemoteWmi.json`.
- **WMI distant réel réussi** : CIM/DCOM de W11-01 vers DC01, système Windows Server 2025, version 10.0.26100.
- **Timeout du transport natif** : un relevé vers `10.77.0.254`, adresse non répondante du réseau interne du labo, est suivi du relevé réel de DC01. Celui-ci démarre vers 6,7 secondes et sa mesure est enregistrée, pendant que la première cible reste soumise aux reprises espacées de 30 puis 120 secondes. Le lot finit à 2/2 en environ 162 secondes. `rc16/NativeTransport.json` conserve les réponses et leurs lignes SQLite.
- **Défaut reproduit lors du timeout du moteur** : pour provoquer cette autre branche sans attendre 25 secondes, seul le budget d’inactivité du premier travail est ramené à 2 secondes ; le vrai appel natif continue son nettoyage. Le deuxième travail garde 25 secondes. DC01 répond et sa mesure atteint SQLite, mais le lot finit « arrêté » à 1/2. `rc16/EngineTimeoutFailure.json` et son journal prouvent le défaut. La qualification du timeout moteur de RC16 est donc **en échec**, malgré les anciens tests à callbacks simulés.

Les requêtes réseau, ordonnanceur, callbacks et écritures SQLite sont ceux du produit. Seuls le choix des deux cibles, le budget de faute contrôlée et le chemin du profil temporaire sont fournis par le pilote. La première identité est synthétique, confinée à cette base de test : aucun objet « TimeoutEndpoint » n’est créé dans AD. La seconde identité et son GUID viennent réellement de DC01.

## Correction

`Save-DomeniaSupersededCollection` posait `SuppressPublish` sur l’état partagé lors de la fin tardive de l’appel natif. Le callback de timeout avait déjà soumis l’échec au stockage ; son reçu SQLite encore en attente héritait alors de ce marquage et était refusé, ce qui arrêtait le lot sans motif affiché.

RC1.17.17 ignore cette seconde livraison dès que `TimeoutErrorDelivered` est vrai, avant toute mutation de l’état partagé. L’échec déjà soumis conserve son reçu ; aucun résultat natif tardif ne le remplace. Les contrôles de session, compte et base restent appliqués lors de la publication. Les annulations/remplacements sans timeout déjà livré conservent leur chemin de protection existant.

Un cas de non-régression reproduit la séquence **timeout → fin native → reçu SQLite → poste suivant**, avec erreur native tardive puis réponse native tardive. Il vérifie l’absence de seconde sauvegarde, le reçu toujours publiable et la fin du lot à 2/2.

## Résultat RC1.17.17

Le même lot réel passe avec les ZIP RC17 exacts : **2/2 traités, 1 échec attendu, aucun arrêt**, aucune tâche ni écriture en attente. La cible non répondante démarre à 1,523 s avec le budget moteur de 2 s ; DC01 démarre à 4,484 s en gardant son budget de 25 s. Le lot termine en 6,224 s. SQLite conserve deux observations : l’erreur du premier poste (révision 1), puis le succès DC01 et son système réel (révision 2). Voir `rc17/LiveBatch.json` et `rc17/LiveBatch.log`.

- **AD réel** : l’identité de DC01 est relue avec la DLL AD livrée par RC17 ; elle correspond au GUID de l’observation enregistrée.
- **Non-régression Windows 5.1** : les trois cas filtrés `RC11711|RC11717` passent, dont les deux variantes de fin native tardive du nouveau cas. Les réseaux de cette seule suite sont simulés, distinctement du lot réel ci-dessus.
- **Intégrité/démarrage** : `Domenia-Start.ps1 -CheckOnly` réussit sur PROD. Les 172 fichiers PROD et 642 fichiers DEV correspondent aux manifestes avant et après l’essai ; le pilote temporaire est supprimé. Contrôle final sous Windows PowerShell 5.1.26100.6584 x64 STA.
- ZIP PROD : `0393c1b7fd23e732209d3f96c4c91196afcb57ba26f02e86d79bbbc7eb4e908a` ; ZIP DEV : `001ae72db21059bda3ad5ac72e810d8c69e20b948e2fc18c224f5b070a2eb04b`.

`Qualification.json` relie les rapports bruts et les deux archives par SHA-256. Les packs de `packs/` sont ces octets testés ; les documents de suivi actualisés après l’essai sont dans le dépôt, sans reconstruction des ZIP. Le manifeste du DEV de travail est régénéré pour ces trois documents de suivi ; les manifestes embarqués restent ceux des archives testées et tous les fichiers runtime restent identiques. Santé et sauvegarde n’ont pas été rejouées sur RC17 : leur qualification ciblée RC16 reste historique.

## Traçabilité et limites

Les ZIP RC16 reproduits sont ceux du dossier voisin `rc16-windows-critical` : PROD `fdfd170c74823f318731e581fec7504dd47a0363933d10aa5fc0366361e95f2a`, DEV `1c0c97ce8f51c5ebfff005277c6a26d72824efc46d360727358b6df920662f64`. Ils restent conservés dans les livraisons datées et dans l’ancien dossier invité. RC17 utilise un nouveau dossier invité `C:\DomeniaLab\d120-rc11717-live` et de nouveaux ZIP ; aucune preuve RC16 n’est réétiquetée RC17.

Le champ historique `FaultMethod` du rapport RC16 `NativeTransport.json` annonce un budget demandé de 2 s que cette version du pilote n’appliquait pas, car le moteur avait déjà libéré `Job.Payload`. Les quatre événements enregistrent **25 s**, valeur réellement appliquée ; cet essai ne prouve que le timeout du transport. Le pilote du timeout moteur identifie ensuite la cible par le nom du travail, et les événements confirment bien **2 s puis 25 s**. Une première préparation appelée trop tôt et un essai arrêté à 120 s avant les reprises complètes ont été exclus ; leurs traces intermédiaires restent dans le dossier de travail local.

Le pilote ne charge pas le tableau de bord complet : les messages DEBUG concernant des contrôles absents dans son journal ne constituent pas une qualification de l’interface.

Il s’agit d’un test programmatique de l’entrée de collecte du produit, avec persistance réelle ; aucun parcours complet de clics ni grand parc n’est certifié. Les autres contrôleurs, transports, droits métier, volumes, installations/désinstallations et campagnes Windows complètes restent à qualifier. Les décisions externes 134/146 restent ouvertes et les packs restent candidats, `Publishable=false`.

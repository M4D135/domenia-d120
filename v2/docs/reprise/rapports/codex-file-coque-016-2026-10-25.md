# File de lectures dans la coque — lot 016

État : implémentation relue statiquement, 5 tests C# et 5 tests web écrits ; aucun exécuté. Compilation Windows à effectuer par le coordinateur. Aucun build ou test sur Mac.

Le dispatcher remet au contexte de chaque requête deux capacités liées uniquement à sa propre file. Le module découvert `BridgeQueueOperations` expose `operations.queue.read` et `operations.queue.cancel`. Le snapshot contient au plus 32 requestId, noms d’opérations, libellés déclarés et anciennetés ; aucun argument, cible, compte ou empreinte de session. Les entrées expirées sont retirées avant le snapshot.

La consultation est pure mémoire ; elle et le retrait utilisent les quatre places de contrôle, pour rester accessibles lorsque les 48 places ordinaires sont occupées. Le retrait renvoie `removed=true/state=withdrawn` uniquement après retrait sous le verrou du véritable ordonnanceur. Une demande déjà admise, terminée ou absente renvoie `removed=false/state=notQueued` et « Aucun arrêt confirmé ». Le jeton et l’activité du handler restent responsables de l’arrêt après admission. Aucun rejeu n’est ajouté.

Le panneau Opérations de la coque affiche la file réelle, son plafond et un bouton Retirer par requestId. La notification d’admission actualise cette vue ; les relectures concurrentes du panneau sont regroupées et les abonnements sont retirés à sa fermeture. Un état indisponible est affiché « non lu », sans fabriquer une file vide. Les résultats de retrait sont présentés tels que confirmés par le moteur.

Le registre des promesses du client WebView2 est borné à 128 demandes et quatre contrôles supplémentaires. Il conserve uniquement les fonctions de résolution, l’opération et l’état d’admission, sans arguments ni secrets. Une notification queued retardée après admitted ne rétablit pas une attente ; une erreur globale termine les attentes sans les rejouer. Les noms et la taille des messages sont contrôlés avant envoi.

Les tests C# ciblent le snapshot plein, l’absence de données sensibles, l’appartenance au dispatcher, le retrait unique, le refus après admission, la réserve sous saturation et les arguments fermés. Les tests web utilisent une instance du véritable client sur un canal local en mémoire : notifications retardées, absence de faux arrêt après admission, plafond/réserve, erreur sans ID, refus avant émission. Ils ne simulent pas l’ordonnanceur.

Fichiers : BridgeAdmission.cs, BridgeContext.cs, BridgeDispatcher.cs, Operations/BridgeQueueOperations.cs ; BridgeQueueTests.cs ; web/js/bridge.js, web/js/shell/panels.js ; tests/web/shell/bridge-queue.test.mjs et son import dans tests/web/run.mjs. Aucun changement MainForm, app.js, Poste, Logiciels ou SharedPark. Cette file reste distincte du recensement des workers physiques ; le lot 015 borne les enfants natifs CIM/WinRM, pas tous les fournisseurs de l’application.

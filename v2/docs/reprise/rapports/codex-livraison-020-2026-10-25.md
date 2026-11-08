# Livraison portable — lot 020

Code et 19 tests écrits le 25 octobre 2026, zéro build/test/installation exécuté par cet agent. Le lot attend capture et
compilation Windows par root. Les sources concurrentes hors de la liste ci-dessous sont préservées.

Le parcours v2 ajoute aperçu/confirmation, copies préparées et sauvegarde de code relues, verrou exclusif, journal,
pending bloquant, manifeste dernier, relecture finale et activation. Reprise/restauration explicites survivent à un
changement d’instance. Le remplacement conserve toute entrée étrangère apparue entre contrôle et mutation. L’annulation
ou une erreur laisse les preuves et le blocage ; aucun retour automatique ni effacement de sauvegarde.

La désinstallation conserve données/configuration/profils/coffre, fichiers modifiés et dossiers. Comparaison et suppression
portent sur le même handle ; le verrou est conservé comme métadonnée, décision revue avec root pour éviter sa suppression
par un chemin devenu étranger après fermeture. La reprise ne réécrit un marqueur endommagé que sur le même handle
exclusif et avec l’empreinte de l’aperçu. Les temporaires à nettoyer sont annoncés et liés à leurs propres empreintes.

L’identité de publication provient des octets source, de la version SDK et du runtime WebView2 local unique. Elle est
injectée dans les assemblages, partagée par titre/journaux/À propos/rapports, liée aux métadonnées de schéma, au manifeste
format 1 et au rapport de ZIP. Le développement reste 2.0.0-dev. Les anciens paquets sans métadonnées restent compatibles
avec le contrôle d’intégrité et annoncent un schéma inconnu. Aucun store n’est modifié, aucun faux avis de migration.

Revue root : course de réécriture pending corrigée ; conservation du verrou ; noms COM/LPT avec exposants ¹²³ refusés.
Revue indépendante : InvalidDataException capturée au boundary de commande ; temporaires comparés aux références
confirmées ; casse de package-release.json qualifiée. Les tests exercent de vrais points de passage (copie créée par le
moteur, mutation après aperçu, garde positive de paquet valide), pas seulement des prédicats miroir.

Les 19 tests couvrent aperçu sans mutation, première installation et mise à jour, manifeste dernier, verrou du lanceur,
six interruptions de bascule et reprise, restauration et conservation de données, preuve corrompue/octet étranger,
annulation, remplacement du pending avant ouverture, marqueur vide, copie temporaire changée, désinstallation et verrou,
modification tardive de code, reprise de désinstallation, identités/schémas, noms DOS, casse des métadonnées, fichiers
réservés, DEV/liens/chevauchement et commande complète liée à une relecture finale. Aucun contact réseau dans les fixtures.

Limites réelles : confiance éditeur Authenticode non établie (aucun certificat épinglé fourni) ; pas de signature créée,
pas de purge de données/profil, pas d’installation système. Un nouveau paquet est exécuté depuis un dossier distinct ;
la cible doit déjà être un dossier local ordinaire. Les outils PsExec hors manifeste de la source ne sont pas transférés
implicitement. La reconstruction bit à bit, le ZIP publié et la recette Windows d’installation/interruption ne sont pas
prouvés par le code ni par sa compilation. Les volets TRV084–089 ne sont donc pas déclarés globalement validés ici.

Fichiers : Directory.Build.props ; Core/ProductInfo.cs ; App/Composition.cs, Program.cs, PackageIntegrity.cs,
PackageLifecycle.cs, PackageLifecycle.Files.cs, PackageLifecycle.Recovery.cs, PackageLifecycle.Uninstall.cs,
PackageLifecycleCommand.cs ; tools/build-vm.ps1 ; tests/Domenia.Tests/{Domenia.Tests.csproj,PackageLifecycleTests.cs} ;
docs/PLATFORM.md et ce rapport. Aucun commit/stage/push par cet agent.

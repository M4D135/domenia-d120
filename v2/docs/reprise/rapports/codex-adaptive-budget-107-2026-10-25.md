# TRV-107 — budgets adaptatifs des lectures

Lot de développement Codex du 25 octobre 2026. Aucune compilation ou exécution locale. Tests écrits, non exécutés ; compilation et sélection critique restent à effectuer par root dans la VM Windows. Aucun statut de catalogue promu.

## Contrat effectivement raccordé

`AdaptiveReadBudget` qualifie les noms sans DNS, mémorise les dernières adresses IPv4 observées par les pings (20 000 noms, éviction des observations anciennes) et regroupe par /24 présumé. Les contrôleurs utilisent une clé distincte. Les adresses IPv6, indéterminées, loopback et multicast ne constituent pas une preuve de site ; les inconnus partagent un budget qui ne suspend jamais. Les groupes sont bornés à 4096 ; aucune éviction d’un groupe actif ou suspendu pour admettre un autre nom.

Par défaut, quatre lectures simultanées par groupe, plafond d’instance de 1 à 32, en complément des plafonds physiques et des limites des consommateurs existants. Les réponses terminées alimentent une référence de latence ; après trois échantillons, une réponse dépassant deux fois la référence et 500 ms réduit le plafond de moitié, avec dix secondes entre deux réductions. Trois échecs consécutifs suspendent une source connue : 60 s, puis doublement lors d’un échec de reprise, au plus 900 s. Une seule lecture explicitement demandée peut essayer après expiration. Son succès reprend à une place, puis hausse additive jusqu’au plafond. L’horloge de ces durées est monotone.

La politique conserve les principes de `dev/wad/modules/Domenia-Collection.Model.ps1`, lignes 885–1102 (consulté en lecture seule). Une réponse tardive ne rouvre pas une suspension et ne prolonge pas sa durée ; aucune minuterie ne déclenche un envoi.

Les vrais raccordements sont :

- `NativeReadClient` : admission avant création du processus, retour de chaque requête CIM/registre/utilisateur/essai, refus de continuation d’un enfant conservé si son groupe s’est suspendu. Le bail est rendu après constat de fin du processus, comme la place physique et les copies de secrets.
- `AdConnection` : requêtes LDAP de lecture, clé contrôleur et retour du véritable `SendRequest`, en conservant la place jusqu’à sa fin physique. Les refus LDAP d’identification, droits, cible ou contraintes ne pénalisent pas le contrôleur. Deux scopes `AuthenticationTrace` demandés par root instrumentent liaison et RootDSE sans changer l’authentification ; ils dépendent du lot login concomitant.
- `WindowsSessionsReader` : admission WTS, retours réels et durée. Après expiration d’une attente, le worker garde son bail, ses handles et son secret jusqu’au retour effectif ; un retour après expiration demeure un délai, jamais un succès de reprise.
- `WmiWorkstationProbe.PingAsync` : admission avant ping, place physique réseau, observation de la véritable adresse de réponse. Un poste silencieux ou une résolution infructueuse reste neutre.

Les réponses `Ok`, `Empty` et `Partial` prouvent un chemin répondant. `Refused`, `Skipped`, `Unreachable`, `Unavailable` (capacité absente ou indisponibilité non qualifiée), compte rejeté et annulation restent neutres. Une erreur réseau remontée par l’essai CIM peut correspondre à un poste éteint : elle reste neutre ; un dépassement effectif du délai du processus demeure mesuré comme délai. Un résultat partiel ne devient pas une donnée complète du fait de cette classification technique. Les circuits d’écriture gardent leurs propres places et ne sont pas freinés ni utilisés comme mesure par ce budget de lectures.

L’attente d’une place simplement occupée dans les pings et les processus natifs est cancellable et bornée avant le premier envoi ; elle ne compte pas de place physique, ne détient aucun nouveau processus et ne produit aucune observation. Une source suspendue est refusée immédiatement. Ce mécanisme ne relance aucune requête. Les consommateurs WTS/LDAP peuvent refuser immédiatement l’admission ; leurs contrôles et délais existants restent applicables.

Le relevé de présence conserve les réponses déjà terminées si une autre cible n’est pas admise ; il enregistre cette dernière comme non lue, sans inventer un poste hors ligne ou une panne WMI, et explique les lectures non envoyées dans son journal.

## Vérifications écrites

Neuf tests purs `AdaptiveReadBudgetTests` : partage /24 et séparation DC, changement d’adresse pendant un bail, inconnus et non-unicast, seuils et horloge monotone, réponses tardives, doublement borné, reprise unique et additive, lenteur/cooldown, annulation/attente, classification, mémoire bornée.

Cinq nouveaux tests `NativeReadWorkerTests` emploient les vrais processus privés existants, avec lectures distantes désactivées : attente avant lancement, annulation avant admission, expiration avant admission, refus de continuation après suspension et exemption du circuit écritures. Deux tests existants renforcent la preuve de fin physique et la distinction annulation/délai. Les tests natifs et de quotas injectent chacun leur budget pour éviter tout cooldown partagé entre cas. Le test `AdAccueilTests.Presence_budget_refusal_preserves_completed_measures_without_inventing_an_offline_or_WMI_result` vérifie le consommateur réel avec faux transport positif puis refus de budget voisin.

## Limites et suite

Le groupe /24 reste présumé, sans découverte réseau ni inférence de site AD. Le plafond partagé de production est conservateur (4), complémentaire des limites choisies par les parcours ; ce lot n’ajoute pas un nouveau réglage utilisateur. Les rapports d’état sont disponibles par `Snapshot`, sans nouvelle vue graphique « sites lents ». Les classifications de répétition TRV-108 et les politiques de vieillissement/retrait TRV-124/125 sont distinctes et ne sont pas déclarées réalisées par ce lot. Une reprise après suspension nécessite toujours une demande de lecture existante ou explicite ; aucune nouvelle campagne n’est programmée.

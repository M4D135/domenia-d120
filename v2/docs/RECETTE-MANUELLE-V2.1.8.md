# Domenia 2.1.8 — relevé de présence avec des comptes ordinateur sans nom DNS cohérent

Version publiée le 12 novembre 2026 sur le go de David (« Oui, publier »), à la suite d’un relevé réel qu’il a signalé : sur une OU de production,
« Tout actualiser » s’arrêtait au relevé de présence avec « Actualisation interrompue : Identité du compte ordinateur
absente, modifiée ou incohérente ; lecture écartée. Aucune nouvelle collecte ne sera lancée. » Un seul compte
ordinateur sans cible Windows qualifiée suffisait à interrompre toute la campagne : compte pré-créé sans `dNSHostName`,
compte renommé dont le nom DNS n’a pas suivi, ou compte modifié entre le plan et le contact. 2.1.8 traite ces comptes
un par un. L’interface, l’inventaire, les écritures AD et le schéma de données (11, révision 2) ne changent pas.
[Bilan et limites](../REPRISE.md).
Pack attendu : `Domenia_2.1.8_PROD-LIGHT_Windows-x64.zip`, avec `SHA256SUMS.txt`.
Extraire dans un nouveau dossier, vérifier l’empreinte puis lancer Domenia.exe.

## Points à vérifier

- Accueil > « Tout actualiser » sur une OU qui contient au moins un compte ordinateur pré-créé (sans nom DNS) ou dont
  le nom DNS diffère du nom du compte : le relevé de présence va au bout, l’inventaire léger suit, aucun message
  « Actualisation interrompue ».
- Ces comptes reçoivent une réponse définitive, sans requête LDAP, DNS ni ICMP : « Nom de poste invalide », diagnostic
  « Nom DNS absent de l’annuaire ou différent du nom du compte ordinateur ; aucun test ICMP envoyé. » Le journal du
  relevé les nomme (« N noms de poste invalides : aucun test ICMP envoyé, présence inconnue. »).
- Un compte modifié dans l’annuaire depuis la préparation du relevé (nom DNS, création, désactivation) est écarté
  seul : aucune donnée ne lui est attribuée, ses voisins sont mesurés, et le journal indique « poste(s) écarté(s) :
  compte(s) ordinateur modifié(s) depuis le plan ; relisez l’annuaire », en orange.
- Si aucun poste du relevé ne peut être qualifié (tous écartés ou sans nom DNS cohérent, au moins un écarté), le
  relevé reste refusé avec le message d’identité, comme avant.
- Fiche et requêtes sur un tel poste : refus inchangé « Identité locale sans cible Windows valide ; aucun contact
  distant. »

Recette des binaires du 12/11/2026 sur un runner Windows hébergé jetable (run 43255444292), candidat `3741ca8`
(ZIP `596d0c3b…`), avec le ZIP 2.1.7 téléchargé depuis sa release et vérifié : 13 étapes, aucun échec.

- Admission : 2.1.8 démarre (`--check-only` 0) sans fichier et avec `wad/Domenia.settings.seed.json` ; refus du fichier
  à la racine et d’un `.part` laissé, avec consigne ; `--check-settings-seed` 0 pour un fichier valide, 2 pour une clé
  interdite.
- Mise à jour 2.1.7 → 2.1.8 par `livraison apercu` puis `appliquer`, avec un fichier écrit sur place : action `update`,
  santé confirmée par le vrai contrôle WebView2, fichier gardé à l’octet.
- Restauration vers 2.1.7 : fichier conservé, 2.1.7 démarre (code 0).

CI de livraison du candidat : 43250548146 (3 082 tests C#, 1 654 critiques, 227 contrôles navigateur, 7 simulations),
dont le test du relevé avec des comptes sans nom DNS cohérent. Non observés : le relevé corrigé sur un vrai domaine,
tout geste d’interface ; aucun banc administrateur pour cette version. Le ZIP publié vient de la CI du commit de
publication.

Noter chaque résultat avec l’empreinte du ZIP ; ne déclarer aucun succès sans observation. Ne modifier ni AD,
ni services, pare-feu, WinRM ou stratégies pour cette recette. Le banc de qualification passe par David.

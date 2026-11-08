# Matrice de validation Domenia

Page générée par `tools/validation_matrix.py --write` depuis `validation-matrix.json` : ne pas la modifier à la main.

Chaque cellule croise un système, un protocole et un droit. Son état est la preuve valide la plus forte :

- **C** : *Cible* — rapport dʼexécution produit sur le domaine réel, hors domaine et postes du laboratoire.
- **L** : *Laboratoire* — rapport produit dans le domaine du laboratoire (cnamts.local).
- **S** : *Synthétique* — suite de test dont le réseau, lʼannuaire ou le poste sont remplacés par des doubles. Une preuve synthétique ne prouve jamais le comportement du réseau cible.
- **·** : *Non couvert* — aucune preuve.
- **—** : combinaison sans objet.

Bilan : 0 cellule(s) prouvée(s) sur le domaine cible, 1 en laboratoire, 35 seulement synthétique(s), 5 non couverte(s).

## Poste dʼadministration Windows 11 (Windows PowerShell 5.1)

| Protocole | Utilisateur du domaine | Support délégué sur une OU | Lecteur LAPS et BitLocker délégué | Administrateur local des postes | Admin du domaine (laboratoire seulement) |
|---|---|---|---|---|---|
| LDAP 389 signé et scellé | S | — | — | — | — |

## Poste dʼadministration Windows 10 22H2 (Windows PowerShell 5.1)

| Protocole | Utilisateur du domaine | Support délégué sur une OU | Lecteur LAPS et BitLocker délégué | Administrateur local des postes | Admin du domaine (laboratoire seulement) |
|---|---|---|---|---|---|
| LDAP 389 signé et scellé | S | — | — | — | — |

## Contrôleur de domaine Windows Server 2019

| Protocole | Utilisateur du domaine | Support délégué sur une OU | Lecteur LAPS et BitLocker délégué | Administrateur local des postes | Admin du domaine (laboratoire seulement) |
|---|---|---|---|---|---|
| LDAP 389 signé et scellé | S | S | S | — | · |
| LDAPS 636 | S | — | — | — | — |
| Catalogue global 3268 | · | — | — | — | — |
| Kerberos | S | — | — | — | — |
| NTLM (repli) | S | — | — | — | — |
| Journal de sécurité distant | — | S | — | — | — |

## Contrôleur de domaine Windows Server 2022

| Protocole | Utilisateur du domaine | Support délégué sur une OU | Lecteur LAPS et BitLocker délégué | Administrateur local des postes | Admin du domaine (laboratoire seulement) |
|---|---|---|---|---|---|
| LDAP 389 signé et scellé | S | S | S | — | · |
| LDAPS 636 | S | — | — | — | — |
| Catalogue global 3268 | · | — | — | — | — |
| Kerberos | S | — | — | — | — |
| NTLM (repli) | S | — | — | — | — |
| Journal de sécurité distant | — | S | — | — | — |

## Contrôleur de domaine Windows Server 2025

| Protocole | Utilisateur du domaine | Support délégué sur une OU | Lecteur LAPS et BitLocker délégué | Administrateur local des postes | Admin du domaine (laboratoire seulement) |
|---|---|---|---|---|---|
| LDAP 389 signé et scellé | S | S | S | — | L |
| LDAPS 636 | S | — | — | — | — |
| Catalogue global 3268 | · | — | — | — | — |
| Kerberos | S | — | — | — | — |
| NTLM (repli) | S | — | — | — | — |
| Journal de sécurité distant | — | S | — | — | — |

## Poste cible Windows 10

| Protocole | Utilisateur du domaine | Support délégué sur une OU | Lecteur LAPS et BitLocker délégué | Administrateur local des postes | Admin du domaine (laboratoire seulement) |
|---|---|---|---|---|---|
| CIM sur DCOM (RPC) | — | S | — | S | — |
| CIM sur WS-Management | — | — | — | S | — |
| SMB 445 (partage dʼadministration) | — | — | — | S | — |
| ICMP (présence) | S | — | — | — | — |
| DNS (résolution des postes) | S | — | — | — | — |

## Poste cible Windows 11

| Protocole | Utilisateur du domaine | Support délégué sur une OU | Lecteur LAPS et BitLocker délégué | Administrateur local des postes | Admin du domaine (laboratoire seulement) |
|---|---|---|---|---|---|
| CIM sur DCOM (RPC) | — | S | — | S | — |
| CIM sur WS-Management | — | — | — | S | — |
| SMB 445 (partage dʼadministration) | — | — | — | S | — |
| ICMP (présence) | S | — | — | — | — |
| DNS (résolution des postes) | S | — | — | — | — |

## Détail des cellules

- **Contrôleur de domaine Windows Server 2019 · LDAP 389 signé et scellé · Utilisateur du domaine** — Recherche, fiche, relations et index local en lecture. État : Synthétique.
  - Synthétique : `wad/tests/Test-DomeniaWiringRecherche.ps1` — réseau doublé
  - Synthétique : `wad/tests/Test-DomeniaSearchTimeout.ps1` — délais de lecture
- **Contrôleur de domaine Windows Server 2019 · LDAPS 636 · Utilisateur du domaine** — Connexion et lecture en LDAPS avec vérification du certificat. État : Synthétique.
  - Synthétique : `wad/tests/Test-DomeniaLogin.ps1` — connexion doublée
- **Contrôleur de domaine Windows Server 2019 · Catalogue global 3268 · Utilisateur du domaine** — Recherche dans le catalogue global. État : Non couvert.
- **Contrôleur de domaine Windows Server 2019 · Kerberos · Utilisateur du domaine** — Ouverture de session et liaison LDAP avec le compte Windows. État : Synthétique.
  - Synthétique : `wad/tests/Test-DomeniaLogin.ps1` — authentification doublée
- **Contrôleur de domaine Windows Server 2019 · NTLM (repli) · Utilisateur du domaine** — Repli NTLM refusé ou accepté selon la stratégie du domaine. État : Synthétique.
  - Synthétique : `wad/tests/Test-DomeniaCredentialGuard.ps1` — comptes synthétiques
- **Contrôleur de domaine Windows Server 2019 · LDAP 389 signé et scellé · Support délégué sur une OU** — Écritures déléguées avec reçu, résultat confirmé par relecture. État : Synthétique.
  - Synthétique : `wad/tests/Test-DomeniaWiringEcritures.ps1` — annuaire doublé
  - Synthétique : `wad/tests/Test-DomeniaFaults.ps1` — refus et coupure après envoi
- **Contrôleur de domaine Windows Server 2019 · LDAP 389 signé et scellé · Lecteur LAPS et BitLocker délégué** — Lecture LAPS et BitLocker, refus de déchiffrement distingué. État : Synthétique.
  - Synthétique : `wad/tests/Test-DomeniaFaults.ps1` — déchiffrement LAPS refusé
  - Synthétique : `wad/tests/Test-DomeniaWiringAcces.ps1` — comptes par ressource
- **Contrôleur de domaine Windows Server 2019 · Journal de sécurité distant · Support délégué sur une OU** — Lecture des verrouillages 4740 sur lʼémulateur PDC. État : Synthétique.
  - Synthétique : `wad/tests/rules/Directory.Tests.ps1` — règles pures
- **Contrôleur de domaine Windows Server 2019 · LDAP 389 signé et scellé · Admin du domaine (laboratoire seulement)** — Validation des écritures de contrôle sur lʼOU du laboratoire. État : Non couvert.
- **Contrôleur de domaine Windows Server 2022 · LDAP 389 signé et scellé · Utilisateur du domaine** — Recherche, fiche, relations et index local en lecture. État : Synthétique.
  - Synthétique : `wad/tests/Test-DomeniaWiringRecherche.ps1` — réseau doublé
  - Synthétique : `wad/tests/Test-DomeniaSearchTimeout.ps1` — délais de lecture
- **Contrôleur de domaine Windows Server 2022 · LDAPS 636 · Utilisateur du domaine** — Connexion et lecture en LDAPS avec vérification du certificat. État : Synthétique.
  - Synthétique : `wad/tests/Test-DomeniaLogin.ps1` — connexion doublée
- **Contrôleur de domaine Windows Server 2022 · Catalogue global 3268 · Utilisateur du domaine** — Recherche dans le catalogue global. État : Non couvert.
- **Contrôleur de domaine Windows Server 2022 · Kerberos · Utilisateur du domaine** — Ouverture de session et liaison LDAP avec le compte Windows. État : Synthétique.
  - Synthétique : `wad/tests/Test-DomeniaLogin.ps1` — authentification doublée
- **Contrôleur de domaine Windows Server 2022 · NTLM (repli) · Utilisateur du domaine** — Repli NTLM refusé ou accepté selon la stratégie du domaine. État : Synthétique.
  - Synthétique : `wad/tests/Test-DomeniaCredentialGuard.ps1` — comptes synthétiques
- **Contrôleur de domaine Windows Server 2022 · LDAP 389 signé et scellé · Support délégué sur une OU** — Écritures déléguées avec reçu, résultat confirmé par relecture. État : Synthétique.
  - Synthétique : `wad/tests/Test-DomeniaWiringEcritures.ps1` — annuaire doublé
  - Synthétique : `wad/tests/Test-DomeniaFaults.ps1` — refus et coupure après envoi
  - Remarque : Validation D096 du 04/10/2026 sur le contrôleur du laboratoire consignée dans lʼen-tête de Validate-D096-Controller.ps1, sans rapport lié : non comptée.
- **Contrôleur de domaine Windows Server 2022 · LDAP 389 signé et scellé · Lecteur LAPS et BitLocker délégué** — Lecture LAPS et BitLocker, refus de déchiffrement distingué. État : Synthétique.
  - Synthétique : `wad/tests/Test-DomeniaFaults.ps1` — déchiffrement LAPS refusé
  - Synthétique : `wad/tests/Test-DomeniaWiringAcces.ps1` — comptes par ressource
- **Contrôleur de domaine Windows Server 2022 · Journal de sécurité distant · Support délégué sur une OU** — Lecture des verrouillages 4740 sur lʼémulateur PDC. État : Synthétique.
  - Synthétique : `wad/tests/rules/Directory.Tests.ps1` — règles pures
- **Contrôleur de domaine Windows Server 2022 · LDAP 389 signé et scellé · Admin du domaine (laboratoire seulement)** — Validation des écritures de contrôle sur lʼOU du laboratoire. État : Non couvert.
- **Contrôleur de domaine Windows Server 2025 · LDAP 389 signé et scellé · Utilisateur du domaine** — Recherche, fiche, relations et index local en lecture. État : Synthétique.
  - Synthétique : `wad/tests/Test-DomeniaWiringRecherche.ps1` — réseau doublé
  - Synthétique : `wad/tests/Test-DomeniaSearchTimeout.ps1` — délais de lecture
- **Contrôleur de domaine Windows Server 2025 · LDAPS 636 · Utilisateur du domaine** — Connexion et lecture en LDAPS avec vérification du certificat. État : Synthétique.
  - Synthétique : `wad/tests/Test-DomeniaLogin.ps1` — connexion doublée
- **Contrôleur de domaine Windows Server 2025 · Catalogue global 3268 · Utilisateur du domaine** — Recherche dans le catalogue global. État : Non couvert.
- **Contrôleur de domaine Windows Server 2025 · Kerberos · Utilisateur du domaine** — Ouverture de session et liaison LDAP avec le compte Windows. État : Synthétique.
  - Synthétique : `wad/tests/Test-DomeniaLogin.ps1` — authentification doublée
- **Contrôleur de domaine Windows Server 2025 · NTLM (repli) · Utilisateur du domaine** — Repli NTLM refusé ou accepté selon la stratégie du domaine. État : Synthétique.
  - Synthétique : `wad/tests/Test-DomeniaCredentialGuard.ps1` — comptes synthétiques
- **Contrôleur de domaine Windows Server 2025 · LDAP 389 signé et scellé · Support délégué sur une OU** — Écritures déléguées avec reçu, résultat confirmé par relecture. État : Synthétique.
  - Synthétique : `wad/tests/Test-DomeniaWiringEcritures.ps1` — annuaire doublé
  - Synthétique : `wad/tests/Test-DomeniaFaults.ps1` — refus et coupure après envoi
- **Contrôleur de domaine Windows Server 2025 · LDAP 389 signé et scellé · Lecteur LAPS et BitLocker délégué** — Lecture LAPS et BitLocker, refus de déchiffrement distingué. État : Synthétique.
  - Synthétique : `wad/tests/Test-DomeniaFaults.ps1` — déchiffrement LAPS refusé
  - Synthétique : `wad/tests/Test-DomeniaWiringAcces.ps1` — comptes par ressource
- **Contrôleur de domaine Windows Server 2025 · Journal de sécurité distant · Support délégué sur une OU** — Lecture des verrouillages 4740 sur lʼémulateur PDC. État : Synthétique.
  - Synthétique : `wad/tests/rules/Directory.Tests.ps1` — règles pures
- **Contrôleur de domaine Windows Server 2025 · LDAP 389 signé et scellé · Admin du domaine (laboratoire seulement)** — Validation des écritures de contrôle sur lʼOU du laboratoire. État : Laboratoire.
  - Laboratoire : `../validation/2026-10-18/rc21-completion/LabLDAP.json` (SHA-256 ab82749649e2, 2026-10-18, DC01 sur cnamts.local) — Lecture LDAP réelle de RootDSE et de l’objet du DC, 18/10/2026 ; aucun secret ni écriture. Couverture limitée du labo personnel, pas une qualification générale LDAP.
- **Poste cible Windows 10 · CIM sur DCOM (RPC) · Administrateur local des postes** — Compte console, inventaire et sondes, identité du poste vérifiée. État : Synthétique.
  - Synthétique : `wad/tests/Test-DomeniaNetworkFaults.ps1` — transport doublé
  - Synthétique : `wad/tests/Test-DomeniaStreaming.ps1` — transport doublé
  - Synthétique : `wad/tests/Test-DomeniaRemoteStore.ps1` — transport doublé
- **Poste cible Windows 10 · CIM sur WS-Management · Administrateur local des postes** — Lecture CIM par WinRM quand le poste lʼexpose. État : Synthétique.
  - Synthétique : `wad/tests/Test-DomeniaRemote.ps1` — transport doublé
- **Poste cible Windows 10 · SMB 445 (partage dʼadministration) · Administrateur local des postes** — Contrôle du partage dʼadministration. État : Synthétique.
  - Synthétique : `wad/tests/Test-DomeniaRemote.ps1` — transport doublé
- **Poste cible Windows 10 · ICMP (présence) · Utilisateur du domaine** — Présence réseau par ICMP, distincte de la réponse WMI. État : Synthétique.
  - Synthétique : `wad/tests/Test-DomeniaNetworkFaults.ps1` — ping doublé
  - Synthétique : `wad/tests/Test-DomeniaSearchPresence.ps1` — ping doublé
- **Poste cible Windows 10 · DNS (résolution des postes) · Utilisateur du domaine** — Résolution du poste, DNS périmé détecté avant attribution. État : Synthétique.
  - Synthétique : `wad/tests/Test-DomeniaNetworkFaults.ps1` — résolution doublée
  - Synthétique : `wad/tests/rules/Workstation.Tests.ps1` — règle de cohérence dʼidentité
- **Poste cible Windows 10 · CIM sur DCOM (RPC) · Support délégué sur une OU** — Lecture refusée sans droit dʼadministration locale : refus conservé, aucun autre compte imposé. État : Synthétique.
  - Synthétique : `wad/tests/Test-DomeniaNetworkFaults.ps1` — refus doublé
- **Poste cible Windows 11 · CIM sur DCOM (RPC) · Administrateur local des postes** — Compte console, inventaire et sondes, identité du poste vérifiée. État : Synthétique.
  - Synthétique : `wad/tests/Test-DomeniaNetworkFaults.ps1` — transport doublé
  - Synthétique : `wad/tests/Test-DomeniaStreaming.ps1` — transport doublé
  - Synthétique : `wad/tests/Test-DomeniaRemoteStore.ps1` — transport doublé
- **Poste cible Windows 11 · CIM sur WS-Management · Administrateur local des postes** — Lecture CIM par WinRM quand le poste lʼexpose. État : Synthétique.
  - Synthétique : `wad/tests/Test-DomeniaRemote.ps1` — transport doublé
- **Poste cible Windows 11 · SMB 445 (partage dʼadministration) · Administrateur local des postes** — Contrôle du partage dʼadministration. État : Synthétique.
  - Synthétique : `wad/tests/Test-DomeniaRemote.ps1` — transport doublé
- **Poste cible Windows 11 · ICMP (présence) · Utilisateur du domaine** — Présence réseau par ICMP, distincte de la réponse WMI. État : Synthétique.
  - Synthétique : `wad/tests/Test-DomeniaNetworkFaults.ps1` — ping doublé
  - Synthétique : `wad/tests/Test-DomeniaSearchPresence.ps1` — ping doublé
- **Poste cible Windows 11 · DNS (résolution des postes) · Utilisateur du domaine** — Résolution du poste, DNS périmé détecté avant attribution. État : Synthétique.
  - Synthétique : `wad/tests/Test-DomeniaNetworkFaults.ps1` — résolution doublée
  - Synthétique : `wad/tests/rules/Workstation.Tests.ps1` — règle de cohérence dʼidentité
- **Poste cible Windows 11 · CIM sur DCOM (RPC) · Support délégué sur une OU** — Lecture refusée sans droit dʼadministration locale : refus conservé, aucun autre compte imposé. État : Synthétique.
  - Synthétique : `wad/tests/Test-DomeniaNetworkFaults.ps1` — refus doublé
- **Poste dʼadministration Windows 11 (Windows PowerShell 5.1) · LDAP 389 signé et scellé · Utilisateur du domaine** — Démarrage, connexion et interface sous Windows PowerShell 5.1 x64 STA. État : Synthétique.
  - Synthétique : `wad/tests/Test-DomeniaStartupLogin.ps1` — démarrage sans domaine
- **Poste dʼadministration Windows 10 22H2 (Windows PowerShell 5.1) · LDAP 389 signé et scellé · Utilisateur du domaine** — Démarrage, connexion et interface sous Windows PowerShell 5.1 x64 STA. État : Synthétique.
  - Synthétique : `wad/tests/Test-DomeniaStartupLogin.ps1` — démarrage sans domaine

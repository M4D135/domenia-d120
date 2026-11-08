DOSSIER DOMENIA-D120 — PASSATION 14/10/2026 (audit Qwen/Spark, lecture seule)

Redige par Qwen (Spark) sur demande de David. Perimetre de cet audit : lecture
seule. Codex garde la main sur le code (regle domenia-codex-only-2026-10-04
maintenue). Tout ce qui suit a ete verifie a la main le 14/10/2026 ; les
references file:ligne sont exactes a ce moment-la.

===========================================================================
0. CE QUI A CHANGE DEPUIS TON RELAIS
===========================================================================
Le travail non commité est desormais sauvegarde HORS MACHINE. Tu peux travailler
sans la peur de le perdre, mais ne change rien a ta facon de faire :

  branche  wip/domenia-sauvegarde-20261014
  commit   90af5995e1f70c1b5aec36370fb706aa46673407 (pousse, verifie par ls-remote)
  contenu  159 ajouts + 72 modifications vs master (les 25 nouveaux modules et
           les 26 nouveaux bancs sont dedans)

Construit par index temporaire + git commit-tree : master et ton arbre de
travail n'ont PAS ete touches. master est toujours a 42e87e6, l'arbre a 138
entrees. Ne supprime pas cette branche avant d'avoir integre.

Brief complet (120 l.) :
  dev/engineering/d120/programme-2026-10-13/BRIEF-CODEX-2026-10-14.md
  sha256 a28d7a30e4b4d21168af01e2f4814bf32962bb6bcd9adf89b337125ecab20483

===========================================================================
1. INTERDITS
===========================================================================
- Ne pas nettoyer, reinitialiser ou remplacer le clone. Les non-suivis sont le
  travail. Pas de git clean, pas de git reset --hard, pas de nouveau clone.
- Ne pas relancer une armee d'agents ni un LLM au seul motif de lire ce message
  (pause tokens demandee par David).
- Le pack publie (RC1.17.6, commit fb03e2b) porte en manifest :
  LOCAL_CHECKS_PASSED_WINDOWS_NOT_RUN. Ne le presente pas comme qualifie.
- Ne pas lancer l'application avant la phase 4 (gel + regeneration).

===========================================================================
2. TROIS CORRECTIONS A MON AVIS DE RELAI (verifiees dans le code)
===========================================================================
(a) GARDE DE COMPTE — ton relais etait imprecis, et la correction naive
    ferait pire.
    La garde n'est PAS ecrite au site d'appel :
      Domenia-Core.ps1:23908  expedie 8 fonctions dans le runspace (Get-Domenia-
        StructuredError, Get-DomeniaCredentialAccountKey, Set-WCredentialAttempt-
        Identity, Get-WCredentialGuardKeys, Assert-WCredentialAllowed,
        Enter-WCredentialAttempt, Exit-WCredentialAttempt, Register-WCredential-
        Failure) — toutes DEFINIES DANS Domenia-Guard.Model.ps1, aucune dans le Core.
      Domenia-Core.ps1:23914  enveloppe le metier :
        try { Assert-WCredentialAllowed -Context $Context ; <metier> }
        catch { Register-WCredentialFailure ... ; throw }
    Le defaut reel de Get-DomeniaLogonHarvestWorkerCode (Core:16718) est que son
    catch INTERNE (L16738-16743) fait `return` sur un statut REFUSE/ERREUR : il
    EMPECHE le catch du wrapper L23914 de s'executer. Register-WCredentialFailure
    n'est donc jamais appele sur ce chemin, et la protection anti-verrouillage
    n'apprend rien. C'est une EVASION DU WRAPPER, pas un appel manquant :
    corrige en relancant (throw) ou en appelant explicitement la garde avant le
    return — pas en ajoutant un Enter- decoratif.

(b) NE CORRIGE PAS LE SECOND SITE Get-WinEvent (Core:19053, journal Security
    4624). Il est correctement garde : son catch L19055 appelle bien
    Register-WCredentialFailure -Context $Context -ErrorValue $_ -Channel Remote.

(c) L'EXPORT COMPLE EXISTE DEJA dans l'arbre de travail. La FEUILLE-DE-ROUTE
    point 8 le dit "a ajouter" : c'est faux.
      Domenia-Query.UI.ps1:537  Start-DomeniaQueryExport
      Domenia-Query.UI.ps1:554  Start-UiTask -Name 'Exporter tous les resultats
                                de la requete' -OperationId 'QueryExport'
      Domenia-Query.UI.ps1:564  controle `if($null -eq $result -or -not $result.Complete)`
    L'operation est deja declaree dans les contrats. Ne pas la reecrire : la qualifier.

    A trancher par toi (non concluant en statique) : Enter-/Exit-WCredentialAttempt
    sont expediees aux workers mais JAMAIS appelees dans les ~1700 lignes de
    Get-DomeniaIndexWorkerCode ni dans le harvest. Leur role (Guard.Model:117-128)
    est de SERIALISER l'authentification (Monitor::Enter, WaitSeconds=120). Sans
    elles, rien n'empeche N workers de frapper le DC en parallele. Conception
    assumee ou oubli ?

===========================================================================
3. RACCORDEMENTS MANQUANTS — CONFIRMES
===========================================================================
- 8 modules non declares dans dev/wad/Domenia-Modules.ps1 (le registre est
  obligatoire, ajouter un fichier ne suffit pas) :
    Domenia-QueryDetails.UI     Domenia-QuerySchema.Model   Domenia-QuerySchema.UI
    Domenia-QuerySchema.Worker  Domenia-QueryTransfer.UI    Domenia-QueryTransfer.Worker
    Domenia-SearchWorkspace.Model  Domenia-SearchWorkspace.UI
  SearchWorkspace : 0 occurrence dans TOUT le XAML.
  (Domenia-CredentialVault.Native.cs absent du registre est NORMAL : les .cs n'y
   figurent pas, Clipboard.Native.cs et Sessions.Native.cs non plus. Ne pas "corriger".)
- Ancre d'integration des resultats (ton relais) :
  </Grid></StackPanel><Grid Grid.Row="1">, puis ligne vide, puis DgObjects.
- operation-contracts.json (74 entrees) :
    * StorageMaintenance -> Sha256 ENTIEREMENT A ZERO (placeholder)
    * aucune entree pour QuerySchema, QueryDetails, QueryTransfer, StoreRead, FleetStats
    * l'UI invoque -OperationId 'StorageRetention' (Domenia-Storage.UI.ps1) non declare
    * QueryExport et QueryLibrary sont declares : conserver tels quels
- DLL anterieures aux sources (rebuild obligatoire apres gel) :
    Domenia.Native.dll              13/10 20:50  < ObservationReader.cs 21:29
    M4D.Admin.Common.Query.dll      13/10 20:40  < QueryEngine.cs       21:27
- domenia_domain_metadata : CREATE TABLE a Core:23268 et UNE SEULE occurrence
  dans tout dev/wad — ni writer, ni reader, ni validation. Ton relais avait raison.
- Domenia-StorageContext.UI.ps1:18 fait un Invoke-DomeniaDbQuery 'SELECT store_id,
  domain_dn,revision FROM domenia_store_state WHERE id=1;' sur le fil appelant,
  et :54-55 rappelle Initialize-DomeniaDatabase + Initialize-DomeniaQueryLibraryStore
  -Force dans Resume-DomeniaDatabaseViews. A deplacer vers le worker Maintenance.
- Limites : CountBy 10 000 confirme (QueryEngine.cs:35, :122, :356). Les 100
  recettes et 1 Mio vivent desormais dans Domenia-QueryLibrary.Model.ps1
  (Limit=100, 1048576), plus dans Query.Model comme l'annoncait la doc.
  Dans Domenia-Live.Model.ps1:46 le 20 est MaxQueries (requetes), pas des
  elements de detail (MaxRows=20000) — reformuler la feuille de route.

===========================================================================
4. ORDRE DE REPRISE
===========================================================================
1. Garde de compte : (a) ci-dessus, puis exercer le chemin REEL depuis
   dev/wad/tests/Test-DomeniaCredentialGuard.ps1 (241 l., 14 references a la
   garde, NE REDEFINIT PAS les fonctions de garde — donc elles doivent venir du
   produit ; si elles manquent dans le runspace, le catch avale le "terme non
   reconnu" et ton test passe pour la mauvaise raison).
2. Raccordements : declarer les 8 orphelins, cabler SearchWorkspace au XAML et
   au registre, finir StorageContext.UI -> worker Maintenance, raccorder
   ObservationProjection=Summary a Fleet/Park, ecrire domenia_domain_metadata.
3. Geler les sources.
4. Regenerer dans l'ordre : contrats (update_worker_contracts.py --apply, y
   compris le SHA StorageMaintenance), migration, baselines de prechargement,
   manifests, limites de distribution ; RECONSTRUIRE Native et Query + empreintes.
5. Puis seulement : parsing, contrats, modeles purs, scenarios de panne,
   qualification native PS 5.1 / net472, charge 10 000 / 20 000, parcours
   graphiques (>= 1080p, sans infobulles).
6. Guides DOCX/PDF v1.0 alignes sur le pack, deux packs coherents, commit/push,
   verification distante.
Cible : 10 000 postes minimum, qualification recommandee 20 000. Les mesures a
5 000 ne valident pas ce seuil, et le work-ledger porte encore une cible 5 000 a
reconcilier.

===========================================================================
5. PIEGES (deja payes, ne les repaye pas)
===========================================================================
- Encodage : les .ps1 sont commites UTF-8 AVEC BOM. Lire en utf-8-sig, ecrire
  BOM + texte.encode('utf-8'), comparer a `git show HEAD:<fichier>`.
  BOM perdu -> "Unexpected token 'aucune'" ; BOM double -> "Unexpected attribute
  'CmdletBinding'". Deux campagnes perdues le 11/10 pour des octets.
- Ne JAMAIS delimiter une fonction de Domenia-Core.ps1 par regex ^function :
  les here-strings @' ... '@ contiennent des function en colonne 0. Mesure
  d'erreur relevee ce soir : "Get-DomeniaIndexWorkerCode : 8 lignes" alors qu'il
  en fait ~1700.
- Test-Domenia.ps1 n'injecte que les 30 noms de $wanted et ne definit que
  Assert-True (Assert-False leve un "not recognized"). Les 26 nouveaux bancs
  sont AUTONOMES (26/26 avec leur propre Assert/Case ou extraction AST) : ils ne
  passent pas par $wanted.
- Un banc qui construit un arbre synthetique doit y Copy-Item le script sous
  test avant de l'invoquer, sinon il valide l'arbre reel du labo.
- Lanceur de suite : powershell -STA -File <suite> -ReportPath <rapport>, UN
  PROCESSUS PAR SUITE (Invoke-LabRun.ps1:22). Plusieurs suites dans le meme
  processus inventent des echecs de resolution de noms par PushFrame.
- Verdict : PASS -> None = test disparu (renomme/supprime), PAS une regression ;
  seule PASS -> FAIL en est une. Rapports de suite en UTF-8 BOM, compteurs sous
  Tests ou Results, detail sous Detail OU Error.
- Arbre propre et committe AVANT de lancer une campagne, sinon "Campagne non
  liee a l'arbre local".
- acceptance_passed n'est jamais pose par une campagne : seul
  release_guard.py --require-windows le fait, sur le ZIP.
- build_packages.py --manifest-only se lance depuis dev/ avec --output ; reecrit
  en place dev/wad/package-manifest.json ET dev/tools/prod-manifest.json — a
  committer quand un fichier RUNTIME change, pas quand seul un test change.

===========================================================================
6. CE QUE L'AUDIT N'A PAS ETABLI (ne le prends pas pour du vert)
===========================================================================
- Analyse STATIQUE uniquement. Aucun build, aucun test, aucune ecriture dans le
  depot n'a ete fait par l'audit.
- 73 empreintes de contrats non verifiees : update_worker_contracts.py n'a PAS
  de mode --check (seulement --apply/--add/--remove/--file/--literal-index).
  A valider par un run dedie, pas au juge.
- Le comportement reel des workers en runspace n'est pas observe.
- Aucune qualification Windows : PC de test eteint, aucun socket de relais labo
  (/tmp/domenia-lab-*.sock absent). Le Mac est revenu sur 192.168.1.13 (son IP
  DHCP bouge, ne la code pas en dur) ; caffeinate relance pour 4 h.
- La disponibilite du Mac graphique et de VirtualBox n'a pas ete verifiee : ne
  reutilise pas un ancien resultat de disponibilite comme preuve.

NOTE KBZA pour la flotte : domenia-audit-statique-20261014
(commit 50ccd1820e8a289158beea74fa5c9c7ad374053f, etat pushed).

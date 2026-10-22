using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Tests;

/// <summary>Pure rules of « Synchronisation et base autonome » (docs/ops/synchro.md), the same with the simulation and the real base.</summary>
internal static class SyncRulesTests
{
    private const string Root = Fixtures.Root;
    private const string Postes = Fixtures.Postes;
    private const string Lyon = "OU=Lyon," + Postes;
    private const string Paris = "OU=Paris," + Postes;
    private static readonly DateTimeOffset Now = Fixtures.Now;
    private static TimeZoneInfo Zone => TestClock.Paris;

    private static IndexRecord Row(string name, string parent = Lyon, IndexObjectType type = IndexObjectType.Computer, DateTimeOffset? observed = null, string? description = null, bool enabled = true, long usn = 100) =>
        new(Fixtures.IdOf(name), type, name, type == IndexObjectType.Computer ? name + "$" : name.ToLowerInvariant(), type == IndexObjectType.Computer ? name.ToLowerInvariant() + ".test.local" : name.ToLowerInvariant() + "@test.local",
            null, description, null, enabled, "CN=" + name + "," + parent, Now - TimeSpan.FromDays(3), usn, Now - TimeSpan.FromDays(1), LapsKind.None, null, observed ?? Now - TimeSpan.FromHours(1));

    private static SyncScope Scope(string dn, bool domain = false) => new(dn, SyncLocations.Name(dn), SyncLocations.ScopePath(dn, "test.local"), true, domain, "chosen");

    private static SyncStateEntry Entry(string key, string dn, DateTimeOffset at, string? depth = "Subtree", bool partial = false) =>
        new(key, dn, at, depth, partial, 10, "DC1.test.local", 0, null, partial ? "temps" : null, partial ? 30_000 : 0);

    // ---------------------------------------------------------------- locations and moves (SYN-008)

    [Test]
    public static void Scope_membership_respects_rdn_boundaries_and_depths()
    {
        Check.True(SyncLocations.InScope("CN=PC1," + Lyon, Postes), "dans le sous-arbre");
        Check.False(SyncLocations.InScope("CN=PC1,OU=Lyon2," + Postes, Lyon), "OU=Lyon2 n’est pas dans OU=Lyon (frontière de RDN)");
        Check.True(SyncLocations.InScope(Postes, Postes, ScopeDepth.Base), "base : l’objet lui-même");
        Check.False(SyncLocations.InScope("CN=PC1," + Lyon, Postes, ScopeDepth.OneLevel), "niveau direct seulement");
        Check.True(SyncLocations.InScope(Lyon, Postes, ScopeDepth.OneLevel), "enfant direct");
        Check.True(SyncLocations.InScope("cn=pc1,ou=lyon,ou=postes,dc=test,dc=local", Lyon), "casse ignorée");
        Check.False(SyncLocations.InScope("pas un DN", Postes), "DN illisible : jamais membre");
    }

    [Test]
    public static void Locations_are_readable_paths()
    {
        Check.Equal("Postes › Lyon", SyncLocations.Location("CN=PC1," + Lyon), "emplacement lisible");
        Check.Equal(SyncLocations.RootLocation, SyncLocations.Location("CN=PC1," + Root), "directement sous la racine");
        Check.Equal("", SyncLocations.Location("CN=Seul"), "trop court");
        Check.Equal("Le Gall, Anne", SyncLocations.Name("CN=Le Gall\\, Anne," + Lyon), "valeur déséchappée");
    }

    [Test]
    public static void Moves_are_classified_without_making_a_second_object()
    {
        Check.Equal(MoveKind.Unchanged, SyncLocations.Move("CN=PC1," + Lyon, "cn=pc1," + Lyon.ToLowerInvariant(), Postes).Kind, "inchangé");
        var renamed = SyncLocations.Move("CN=PC1," + Lyon, "CN=PC2," + Lyon, Postes);
        Check.Equal(MoveKind.Renamed, renamed.Kind, "renommé");
        Check.Contains("PC1 → PC2", renamed.Text, "texte du renommage");
        Check.Equal(MoveKind.MovedWithin, SyncLocations.Move("CN=PC1," + Lyon, "CN=PC1," + Paris, Postes).Kind, "déplacé dans le périmètre");
        Check.Equal(MoveKind.MovedOut, SyncLocations.Move("CN=PC1," + Lyon, "CN=PC1,CN=Computers," + Root, Postes).Kind, "sorti");
        Check.Equal(MoveKind.MovedIn, SyncLocations.Move("CN=PC1,CN=Computers," + Root, "CN=PC1," + Lyon, Postes).Kind, "entré");
        Check.Equal(MoveKind.MovedOutside, SyncLocations.Move("CN=PC1,OU=A," + Root, "CN=PC1,OU=B," + Root, Postes).Kind, "hors périmètre");
        Check.Equal(MoveKind.Unknown, SyncLocations.Move("CN=PC1," + Lyon, null, Postes).Kind, "nouvel emplacement inconnu");
        Check.Equal("Sorti du périmètre" + FrenchText.Colon + "Computers", SyncLocations.MoveStateText(SyncLocations.Move("CN=PC1," + Lyon, "CN=PC1,CN=Computers," + Root, Postes)), "état court");
    }

    // ---------------------------------------------------------------- disappeared objects (SYN-006, SYN-007)

    private static AbsenceRecord Absent(string name, string parent = Lyon, AbsenceStatus status = AbsenceStatus.NotSeen, DateTimeOffset? noticed = null) =>
        new(Fixtures.IdOf(name), name, IndexObjectType.Computer, "CN=" + name + "," + parent, null, status, noticed ?? Now - TimeSpan.FromDays(1), null, "", Postes, "DC1");

    [Test]
    public static void Only_an_isDeleted_entry_read_by_guid_proves_a_deletion()
    {
        var absence = Absent("PC9");
        var refused = SyncAbsences.Resolve(absence, new AbsenceCheck(DomainRead.Refused, null, DeletedProbe.NotRequested, false, null, null, false, null), Zone);
        Check.Equal(AbsenceStatus.Unconfirmed, refused.Status, "domaine refusé : aucune conclusion");
        Check.Contains("refusée", refused.Detail, "motif");
        var found = Row("PC9", Lyon);
        var visible = SyncAbsences.Resolve(absence, new AbsenceCheck(DomainRead.Read, found.Dn, DeletedProbe.NotRequested, false, null, null, false, found), Zone);
        Check.Equal(AbsenceStatus.Visible, visible.Status, "retrouvé au même endroit");
        Check.NotNull(visible.Keep, "fiche remise dans la base sous le même GUID");
        var moved = Row("PC9", "CN=Computers," + Root);
        var elsewhere = SyncAbsences.Resolve(absence, new AbsenceCheck(DomainRead.Read, moved.Dn, DeletedProbe.NotRequested, false, null, null, false, moved), Zone);
        Check.Equal(AbsenceStatus.Moved, elsewhere.Status, "retrouvé ailleurs : déplacé, pas supprimé");
        Check.Contains("GUID", elsewhere.Detail, "identité conservée");
        var deleted = SyncAbsences.Resolve(absence, new AbsenceCheck(DomainRead.Read, null, DeletedProbe.Read, true, Now - TimeSpan.FromDays(2), Lyon, true, null), Zone);
        Check.Equal(AbsenceStatus.Deleted, deleted.Status, "isDeleted lu : suppression constatée");
        Check.Contains("Postes › Lyon", deleted.Detail, "dernier parent");
        Check.Contains("recyclé", deleted.Detail, "objet recyclé");
        Check.Equal(AbsenceStatus.NotFound, SyncAbsences.Resolve(absence, new AbsenceCheck(DomainRead.Read, null, DeletedProbe.Read, false, null, null, false, null), Zone).Status, "introuvable");
        Check.Equal(AbsenceStatus.Invisible, SyncAbsences.Resolve(absence, new AbsenceCheck(DomainRead.Read, null, DeletedProbe.Empty, false, null, null, false, null), Zone).Status, "objets supprimés invisibles");
        Check.Equal(AbsenceStatus.Unconfirmed, SyncAbsences.Resolve(absence, new AbsenceCheck(DomainRead.Read, null, DeletedProbe.NotRequested, true, null, null, false, null), Zone).Status, "isDeleted sans sonde lisible : pas de preuve");
        var stranger = Row("Autre", Lyon);
        Check.Null(SyncAbsences.Resolve(absence, new AbsenceCheck(DomainRead.Read, found.Dn, DeletedProbe.NotRequested, false, null, null, false, stranger), Zone).Keep, "une fiche d’un autre GUID n’est jamais gardée");
    }

    [Test]
    public static void Verifications_take_the_oldest_unverified_objects_first_and_stay_bounded()
    {
        var rows = new[]
        {
            Absent("B", noticed: Now - TimeSpan.FromDays(1)),
            Absent("A", noticed: Now - TimeSpan.FromDays(5)),
            Absent("C", status: AbsenceStatus.Deleted),
            Absent("D", status: AbsenceStatus.Unconfirmed, noticed: Now - TimeSpan.FromDays(3)),
        };
        var picked = SyncAbsences.SelectToCheck(rows);
        Check.Equal(3, picked.Length, "non revus et vérifications impossibles seulement");
        Check.Equal("A", picked[0].Name, "le plus ancien d’abord");
        Check.Equal(1, SyncAbsences.SelectToCheck(rows, 1).Length, "borné");
        var list = SyncAbsences.List(rows, Zone, canRead: true);
        Check.Equal(4, list.Total, "total exact");
        Check.Contains("4 objets non revus", list.Summary, "pluriel");
        Check.Contains("1 suppression constatée", list.Summary, "singulier");
        Check.True(list.CanCheck, "vérification possible");
        Check.Contains("au lieu d’être déclaré supprimé", SyncAbsences.Summary(0, [], 0, 0), "liste vide expliquée");
        Check.Contains("les 200 premiers des 250 objets", SyncAbsences.Summary(250, [], 250, 250), "vérification bornée");
        Check.Contains("par son GUID l’objet", SyncAbsences.Summary(1, [], 1, 1), "un seul objet à vérifier");
    }

    [Test]
    public static void Census_gaps_are_added_when_found_and_leave_without_conclusion_otherwise()
    {
        var gap = new CensusGapRecord(Fixtures.IdOf("U1"), "CN=U1," + Fixtures.People, Now);
        var record = Row("U1", Fixtures.People, IndexObjectType.User);
        var added = SyncAbsences.ResolveGap(gap, new GapCheck(DomainRead.Read, record.Dn, record));
        Check.True(added.LeavesList, "quitte la liste");
        Check.NotNull(added.Keep, "ajouté à la base");
        var gone = SyncAbsences.ResolveGap(gap, new GapCheck(DomainRead.Read, null, null));
        Check.True(gone.LeavesList && gone.Keep is null, "absent : retiré sans conclusion");
        var unread = SyncAbsences.ResolveGap(gap, new GapCheck(DomainRead.Unavailable, null, null));
        Check.False(unread.LeavesList, "non lu : reste à lire");
        Check.Equal("Aucun objet recensé ne manque dans la base locale.", SyncAbsences.GapSummary(0, 0), "aucun écart");
        Check.Contains("relit 200 à la fois", SyncAbsences.GapSummary(350, 200), "lecture bornée");
    }

    // ---------------------------------------------------------------- coverage and census (SYN-012, SYN-019)

    [Test]
    public static void Coverage_needs_a_complete_read_of_the_scope_or_of_an_ancestor_with_sub_OUs()
    {
        var entries = new[]
        {
            Entry(SyncStateEntry.DirectoryKey, Root, Now - TimeSpan.FromDays(3)),
            Entry(SyncStateEntry.OuKey(Postes), Postes, Now - TimeSpan.FromHours(2)),
        };
        var lyon = SyncCoverageRules.Coverage(Lyon, Root, entries, Now, Zone);
        Check.Equal(CoverageStatus.Complete, lyon.Status, "couvert par l’OU parente");
        Check.Equal(Now - TimeSpan.FromHours(2), lyon.At, "la plus récente des lectures qui couvrent");
        var oneLevel = SyncCoverageRules.Coverage(Lyon, Root, [Entry("ou:onelevel:" + Postes.ToLowerInvariant(), Postes, Now - TimeSpan.FromHours(1), "OneLevel")], Now, Zone);
        Check.Equal(CoverageStatus.Missing, oneLevel.Status, "un niveau direct ne couvre pas les sous-OU");
        var attempt = SyncCoverageRules.Coverage(Lyon, Root, [.. entries, Entry(SyncStateEntry.AttemptPrefix + SyncStateEntry.OuKey(Lyon), Lyon, Now - TimeSpan.FromMinutes(5), partial: true)], Now, Zone);
        Check.Equal(CoverageStatus.Partial, attempt.Status, "tentative plus récente incomplète");
        var future = SyncCoverageRules.Coverage(Lyon, Root, [Entry(SyncStateEntry.OuKey(Lyon), Lyon, Now + TimeSpan.FromDays(1))], Now, Zone);
        Check.True(future.ClockInvalid, "date future : horloge douteuse");
        Check.Equal(CoverageStatus.Missing, future.Status, "date future ignorée");
        var legacy = SyncCoverageRules.Coverage(Lyon, Root, [Entry(SyncStateEntry.OuKey(Lyon), Lyon, Now - TimeSpan.FromHours(1), null)], Now, Zone);
        Check.Equal(CoverageStatus.UnknownDepth, legacy.Status, "ancien repère sans profondeur");
        var otherDomain = SyncCoverageRules.Coverage(Lyon, Root, [Entry(SyncStateEntry.DirectoryKey, "DC=autre,DC=local", Now)], Now, Zone);
        Check.Equal(CoverageStatus.Missing, otherDomain.Status, "le repère d’un autre domaine ne compte pas");
    }

    [Test]
    public static void Census_advice_never_starts_anything_and_names_its_reason()
    {
        SyncCoverage Cov(CoverageStatus status, DateTimeOffset? at, bool partial = false, bool clock = false) => new(status, at, Postes, "Postes", "Subtree", null, partial, clock, "");
        Check.Equal(CensusState.Clock, SyncCoverageRules.Census(Cov(CoverageStatus.Missing, null, clock: true), 0, 7, Now, false).State, "horloge");
        Check.Equal(CensusState.Gap, SyncCoverageRules.Census(Cov(CoverageStatus.Complete, Now - TimeSpan.FromDays(1)), 5, 7, Now, true).State, "écarts du recensement pour le domaine");
        Check.Equal(CensusState.Partial, SyncCoverageRules.Census(Cov(CoverageStatus.Partial, Now, partial: true), 0, 7, Now, false).State, "incomplet");
        Check.Equal(CensusState.Absent, SyncCoverageRules.Census(Cov(CoverageStatus.Missing, null), 0, 7, Now, false).State, "jamais complet");
        var due = SyncCoverageRules.Census(Cov(CoverageStatus.Complete, Now - TimeSpan.FromDays(9)), 0, 7, Now, false);
        Check.Equal(CensusState.Due, due.State, "dû");
        Check.Contains("9 jours (seuil" + FrenchText.Colon + "7 jours)", due.Text, "âge et seuil");
        var recent = SyncCoverageRules.Census(Cov(CoverageStatus.Complete, Now - TimeSpan.FromDays(1)), 3, 7, Now, false);
        Check.Equal(CensusState.Recent, recent.State, "récent");
        Check.False(recent.Due, "rien de dû");
        Check.Contains("Lire les objets manquants", recent.Text, "les écarts du domaine sont ajoutés au conseil de l’OU");
        Check.Equal(90, SyncCoverageRules.Census(Cov(CoverageStatus.Missing, null), 0, 400, Now, false).MaxAgeDays, "seuil borné à 90 jours");
    }

    [Test]
    public static void A_checkpoint_is_reused_only_on_its_controller_instance_and_data()
    {
        var invocation = Guid.NewGuid().ToString("D");
        var ok = new SyncCheckpoint("DC1.test.local", invocation, 5000, Now - TimeSpan.FromDays(1), 1000, Root);
        string Code(SyncCheckpoint? c, string server = "DC1.test.local", long count = 900, long highest = 6000) =>
            SyncCoverageRules.CheckCheckpoint(c, server, Root, count, highest, Now).Code;
        Check.Equal("Usable", Code(ok), "utilisable");
        Check.Equal("Missing", Code(null), "absent");
        Check.Equal("NoUsn", Code(ok with { Usn = 0 }), "sans USN");
        Check.Equal("NoInstance", Code(ok with { InvocationId = "" }), "sans invocationID");
        Check.Equal("NoServer", Code(ok with { Controller = " " }), "sans contrôleur");
        Check.Equal("OtherController", Code(ok, "DC2.test.local"), "autre contrôleur");
        Check.Equal("OtherScope", Code(ok with { ScopeDn = Postes }), "autre périmètre");
        Check.Equal("UsnAhead", Code(ok, highest: 4000), "USN au-delà du validé");
        Check.Equal("EmptyBase", Code(ok, count: 0), "base vide");
        Check.Equal("BaseShrunk", Code(ok, count: 400), "base réduite");
        Check.Equal("FutureDate", Code(ok with { At = Now + TimeSpan.FromHours(1) }), "date future");
        Check.Contains("aucun USN reporté", SyncCoverageRules.CheckCheckpoint(ok, "DC2.test.local", Root, 900, 6000, Now).Reason, "explication");
    }

    [Test]
    public static void Pass_limits_and_cuts_are_named()
    {
        Check.Equal(1_200_000, SyncCoverageRules.Limits(null, 240_000).BudgetMs, "ancien défaut de 4 min relevé à 20 min");
        Check.Equal(30_000, SyncCoverageRules.Limits(null, 1000).BudgetMs, "30 s au moins");
        Check.Equal(0, SyncCoverageRules.Limits(-5, null).MaxObjects, "pas de quota négatif");
        Check.Equal(1320, SyncCoverageRules.Limits(null, null).TimeoutSeconds, "budget + 2 min");
        Check.Contains("Index.MaxObjects", SyncCoverageRules.Cut("volume", 500, 500).Text, "limite de volume nommée");
        Check.Contains("Index.BudgetMs", SyncCoverageRules.Cut("temps", 30_000, 12).Text, "limite de temps nommée");
        Check.Contains("ServerTimeLimit", SyncCoverageRules.Cut("serveur", 120, 9).Text, "coupure du contrôleur");
        Check.Contains("arrêtée à la demande", SyncCoverageRules.Cut("arret", 0, 3).Text, "arrêt");
        Check.Contains("9 objets relus dans la passe sur une limite de 120", SyncCoverageRules.PartialText(Now, 9, "serveur", 120, Zone), "avertissement de l’Accueil");
    }

    [Test]
    public static void Readiness_tiles_notices_and_backup()
    {
        Check.False(SyncCoverageRules.Readiness(true, false, null).Ready, "une passe à la fois");
        Check.False(SyncCoverageRules.Readiness(false, true, null).Ready, "pendant un enregistrement");
        Check.Equal("Disque presque plein.", SyncCoverageRules.Readiness(false, false, "Disque presque plein.").Reason, "refus du stockage");
        var unreadable = SyncCoverageRules.Tiles(0, 0, 0, 0, 0, null, Now, Zone, unreadable: true);
        Check.True(unreadable.All(t => t.Value == "—" && t.Number is null), "base illisible : jamais de zéros");
        var tiles = SyncCoverageRules.Tiles(1258, 454, 431, 23, 104, Now - TimeSpan.FromMinutes(12), Now, Zone);
        Check.Equal("1 258", tiles[0].Value, "milliers séparés par une espace fine insécable");
        Check.Contains("431 actifs · 23 désactivés", tiles[1].Detail, "postes actifs et désactivés");
        Check.Equal("il y a 12 min", tiles[3].Value, "âge de la dernière lecture");
        Check.Equal("Jamais", SyncCoverageRules.Tiles(1, 1, 1, 0, 0, null, Now, Zone)[3].Value, "jamais lu");
        Check.Contains("Aucune base locale", SyncCoverageRules.Notices(0, null, null, Now)[0].Text, "première construction à la main");
        var checkpoint = new SyncCheckpoint("DC1", Guid.NewGuid().ToString("D"), 10, Now - TimeSpan.FromDays(3), 10, Root);
        Check.Contains("jamais lancée automatiquement", SyncCoverageRules.Notices(10, checkpoint, null, Now)[0].Text, "âge de la base : conseil, jamais lancement");
        Check.True(SyncCoverageRules.Backup(null, Now).Due, "aucune sauvegarde : due");
        Check.Equal("InvalidClock", SyncCoverageRules.Backup(Now + TimeSpan.FromHours(1), Now).Reason, "date future");
        Check.False(SyncCoverageRules.Backup(Now - TimeSpan.FromMinutes(10), Now).Due, "récente : réutilisée");
        Check.Contains("aucune nouvelle copie", SyncCoverageRules.BackupNotice(SyncCoverageRules.Backup(Now - TimeSpan.FromMinutes(10), Now), Zone), "point de retour");
        Check.Equal("Une sauvegarde vérifiée de la base sera faite avant.", SyncCoverageRules.BackupNotice(SyncCoverageRules.Backup(Now - TimeSpan.FromHours(2), Now), Zone), "copie due");
    }

    // ---------------------------------------------------------------- local index (SYN-001 to SYN-004)

    [Test]
    public static void The_term_is_normalized_and_scored()
    {
        Check.Equal("j.martin", SyncIndex.Normalize(@"EXAMPLE\J.Martin"), "domaine retiré");
        Check.Equal("j.martin", SyncIndex.Normalize("j.martin@example.local"), "suffixe UPN retiré");
        Check.Equal("pc-01", SyncIndex.Normalize("PC-01$"), "dollar final retiré");
        var row = Row("PC-PAR-0042", description: "Poste de Hélène");
        Check.Equal(100, SyncIndex.Score(row, "pc-par-0042"), "exacte");
        Check.Equal(90, SyncIndex.Score(row, "pc-par"), "début du nom");
        Check.Equal(70, SyncIndex.Score(row, "helene"), "contenu, sans accent");
        Check.Equal(0, SyncIndex.Score(row, "zzz"), "aucune");
    }

    [Test]
    public static void The_sort_covers_the_whole_population_before_the_page()
    {
        var rows = Enumerable.Range(1, 9).Select(n => Row("PC-" + (10 - n).ToString(System.Globalization.CultureInfo.InvariantCulture), description: n % 3 == 0 ? null : "d" + n)).ToList();
        IndexQuery Query(IndexSort sort, bool desc = false, int offset = 0, int limit = 4, string term = "") => new(term, Scope(Postes), sort, desc, offset, limit);
        var page2 = SyncIndex.Page(rows, Query(IndexSort.Name, offset: 4), _ => null, 7);
        Check.Equal(9, page2.Total, "total de la population");
        Check.Equal(2, page2.Page, "page 2");
        Check.Equal("PC-5", page2.Rows[0].Name, "tri par nom avant la coupe");
        Check.True(page2.HasMore, "suite");
        var desc = SyncIndex.Page(rows, Query(IndexSort.Description, desc: true, limit: 9), _ => null, 7);
        Check.True(desc.Rows.TakeLast(3).All(r => r.Description is null), "vides en fin, même en ordre décroissant");
        var asc = SyncIndex.Page(rows, Query(IndexSort.Description, limit: 9), _ => null, 7);
        Check.True(asc.Rows.TakeLast(3).All(r => r.Description is null), "vides en fin en ordre croissant");
        Check.Equal(0, SyncIndex.Page(rows, Query(IndexSort.Name, offset: 99), _ => null, 7).Offset, "page hors population : retour au début");
        var one = SyncIndex.Page(rows, Query(IndexSort.Relevance, term: "p"), _ => null, 7);
        Check.Equal(0, one.Total, "un seul caractère : rien");
        Check.Contains("deux caractères", one.Message, "message");
        var outside = SyncIndex.Page([Row("PC-X", "OU=Serveurs," + Root)], Query(IndexSort.Relevance), _ => null, 7);
        Check.Equal(0, outside.Total, "hors du périmètre");
        Check.True(SyncIndex.Busy(Query(IndexSort.Name), 7).Busy, "base occupée : jamais un résultat vide");
        Check.Contains("nouvel essai", SyncIndex.Busy(Query(IndexSort.Name), 7).Message, "un essai de plus");
    }

    // ---------------------------------------------------------------- storage of a read (SYN-013 to SYN-015)

    [Test]
    public static void Reconciliation_keeps_identities_and_never_overwrites_a_newer_observation()
    {
        var kept = Row("PC-A");
        var moved = Row("PC-B");
        var renamed = Row("PC-C");
        var changed = Row("PC-D");
        var newer = Row("PC-E", observed: Now + TimeSpan.FromMinutes(1));
        var gone = Row("PC-F");
        var outside = Row("PC-G", "OU=Serveurs," + Root);
        var current = new[] { kept, moved, renamed, changed, newer, gone, outside }.ToDictionary(r => r.ObjectGuid);
        var read = new[]
        {
            kept with { ObservedAt = Now },
            moved with { Dn = "CN=PC-B," + Paris, ObservedAt = Now },
            renamed with { Name = "PC-C2", Dn = "CN=PC-C2," + Lyon, ObservedAt = Now },
            changed with { Description = "Nouveau", ObservedAt = Now },
            newer with { Description = "Ancien", ObservedAt = Now },
            Row("PC-H", observed: Now),
        };
        var r = SyncReconcile.Reconcile(current, read, Postes, assertAbsence: true);
        Check.Equal(1, r.Counts.Added, "ajout");
        Check.Equal(1, r.Counts.Moved, "déplacement");
        Check.Equal(1, r.Counts.Renamed, "renommage");
        Check.Equal(1, r.Counts.Changed, "valeur modifiée");
        Check.Equal(1, r.Counts.Unchanged, "inchangé");
        Check.Equal(1, r.Counts.Conflicts, "observation locale plus récente conservée");
        Check.Equal(1, r.Counts.Unseen, "non revu, dans le périmètre seulement");
        Check.Equal(gone.ObjectGuid, r.Unseen[0].ObjectGuid, "l’objet non revu");
        var (rows, absences) = SyncReconcile.Apply(current, r, Postes, Now, "DC1");
        Check.False(rows.ContainsKey(gone.ObjectGuid), "retiré de la copie");
        Check.Equal(AbsenceStatus.NotSeen, absences.Single().Status, "noté non revu, jamais supprimé");
        Check.Equal("Ancien" == rows[newer.ObjectGuid].Description, false, "la ligne plus récente n’est pas écrasée");
        Check.Equal("CN=PC-B," + Paris, rows[moved.ObjectGuid].Dn, "même GUID, nouvel emplacement");
        Check.Equal(7, rows.Count, "aucun doublon : 7 − 1 + 1");
        var partial = SyncReconcile.Reconcile(current, read, Postes, assertAbsence: false);
        Check.Equal(0, partial.Counts.Unseen, "lecture incomplète : aucune absence déduite");
    }

    [Test]
    public static void Batch_fingerprints_depend_on_the_data_only()
    {
        var a = Row("PC-A");
        var b = Row("PC-B");
        Check.Equal(SyncReconcile.Fingerprint([a, b]), SyncReconcile.Fingerprint([b with { ObservedAt = Now }, a]), "ordre et date d’observation sans effet");
        Check.False(SyncReconcile.Fingerprint([a]) == SyncReconcile.Fingerprint([a with { Description = "x" }]), "une valeur change l’empreinte");
        Check.Equal(64, SyncReconcile.IdentityFingerprint([a.ObjectGuid]).Length, "SHA-256 hexadécimal");
    }

    [Test]
    public static void The_checkpoint_moves_only_with_complete_data_of_a_known_instance()
    {
        var invocation = Guid.NewGuid().ToString("D");
        var checkpoint = new SyncCheckpoint("DC1", invocation, 100, Now - TimeSpan.FromDays(1), 10, Root);
        var same = SyncReconcile.Incremental(checkpoint, "DC1", invocation, 200, Root, false, false, true, 10, Now);
        Check.False(same.FullRescan, "même instance : incrémentiel");
        Check.True(same.Advances && same.Next!.Usn == 200, "le repère avance");
        var other = SyncReconcile.Incremental(checkpoint, "DC2", invocation, 200, Root, false, false, true, 10, Now);
        Check.True(other.FullRescan, "autre contrôleur : relecture complète");
        var partial = SyncReconcile.Incremental(checkpoint, "DC1", invocation, 200, Root, true, false, false, 10, Now);
        Check.False(partial.Advances, "réponse partielle : le repère reste");
        Check.False(partial.CanAssertAbsence, "aucune absence déduite");
        Check.Equal(checkpoint, partial.Next, "repère inchangé");
        Check.False(SyncReconcile.Incremental(checkpoint, "DC1", null, 200, Root, false, false, true, 10, Now).Advances, "instance inconnue : le repère reste");
    }

    // ---------------------------------------------------------------- snapshots (SYN-022 to SYN-026)

    private static SnapshotRecord Snapshot(string id, string label, DateTimeOffset at, IEnumerable<SnapshotLine> lines, string scope = Postes, SnapshotCoverageState coverage = SnapshotCoverageState.Complete)
    {
        var ordered = lines.ToImmutableArray();
        return new SnapshotRecord(id, label, Root, scope, true, at, coverage, at, "Postes", "Couverture", ordered, SyncSnapshots.Fingerprint(ordered));
    }

    [Test]
    public static void Snapshot_requests_stay_inside_the_domain()
    {
        var coverage = new SyncCoverage(CoverageStatus.Complete, Now, Postes, "Postes", "Subtree", null, false, false, "");
        var id = WritePlans.NewId();
        var request = SyncSnapshots.Request(Root, Postes, true, "  ", coverage, id, Now, Zone);
        Check.Equal("Relevé du 21/10/2026 18:26", request.Label, "nom par défaut, heure de Paris");
        Check.Equal(SnapshotCoverageState.Complete, request.Coverage.State, "preuve de couverture");
        var outside = Check.Throws<DomeniaOperationException>(() => SyncSnapshots.Request(Root, "OU=X,DC=autre,DC=local", true, null, coverage, id, Now, Zone), "hors domaine");
        Check.Equal(SyncErrors.OutsideDomain, outside.Code, "code");
        Check.Throws<ArgumentException>(() => SyncSnapshots.Request(Root, Postes, true, null, coverage, "court", Now, Zone), "identifiant invalide");
        Check.Equal(SnapshotCoverageState.Unknown, SyncSnapshots.Proof(coverage with { ClockInvalid = true }, Zone).State, "horloge douteuse");
        Check.Contains("ni mot de passe, ni droit, ni appartenance", SyncSnapshots.Notice, "notice");
    }

    [Test]
    public static void Snapshot_comparisons_are_exact_and_bounded()
    {
        var a = SnapshotLine.From(Row("PC-A"));
        var b = SnapshotLine.From(Row("PC-B"));
        var c = SnapshotLine.From(Row("PC-C"));
        var before = Snapshot(new string('a', 32), "Avant", Now - TimeSpan.FromDays(7), [a, b, c]);
        var after = Snapshot(new string('b', 32), "Après", Now, [a with { Dn = "CN=PC-A," + Paris }, b with { Name = "PC-B2", Dn = "CN=PC-B2," + Lyon, Description = "x" }, SnapshotLine.From(Row("PC-D"))]);
        var report = SyncSnapshots.Compare(before, after, Zone);
        Check.True(report.Comparable, "comparable");
        Check.Equal(1, report.Counts.Added, "ajout");
        Check.Equal(1, report.Counts.Disappeared, "disparition");
        Check.Equal(1, report.Counts.Moved, "déplacement");
        Check.Equal(1, report.Counts.Renamed, "renommage");
        Check.Equal(2, report.Counts.Differing, "objets différents");
        Check.Equal(0, report.Counts.Unchanged, "inchangés");
        Check.True(report.Rows.Any(r => r.Nature == SnapshotDiffNature.Changed && r.Detail == "Description"), "valeur modifiée nommée");
        Check.Contains("non prouvé ici", report.Rows.Single(r => r.Nature == SnapshotDiffNature.Disappeared).Detail, "disparition non prouvée");
        var bounded = SyncSnapshots.Compare(before, after, Zone, limit: 1);
        Check.True(bounded.Truncated, "affichage borné");
        Check.Equal(1, bounded.Counts.Added, "totaux exacts malgré la borne");
        var self = SyncSnapshots.Compare(before, before, Zone);
        Check.False(self.Comparable, "un relevé ne se compare pas à lui-même");
        var otherScope = SyncSnapshots.Compare(before, Snapshot(new string('c', 32), "Ailleurs", Now, [a], scope: Lyon), Zone);
        Check.True(otherScope.Reasons.Any(r => r.StartsWith("Périmètres différents", StringComparison.Ordinal)), "même périmètre exigé");
        var reversed = SyncSnapshots.Comparable(after, Snapshot(new string('d', 32), "Vieux", Now - TimeSpan.FromDays(30), [a], coverage: SnapshotCoverageState.Partial));
        Check.Equal(2, reversed.Warnings.Length, "ordre inversé et couverture incomplète signalés");
    }

    // ---------------------------------------------------------------- park (SYN-028 to SYN-030)

    [Test]
    public static void Park_surveys_merge_by_workstation_and_the_most_recent_line_wins()
    {
        var local = new Dictionary<string, ParkEntry> { ["PC1"] = new("PC1", Now - TimeSpan.FromHours(5), ParkStatus.Session, "a", 0, "x"), ["PC2"] = new("PC2", Now, ParkStatus.Empty, null, 0, "x") };
        var shared = new Dictionary<string, ParkEntry> { ["pc1"] = new("PC1", Now - TimeSpan.FromHours(1), ParkStatus.Empty, null, 0, "y"), ["PC2"] = new("PC2", Now - TimeSpan.FromDays(1), ParkStatus.Session, "b", 0, "y"), ["PC3"] = new("PC3", Now, ParkStatus.Unreachable, null, 2, "y") };
        var merge = SyncPark.Merge(local, shared);
        Check.Equal(1, merge.Added, "poste ajouté");
        Check.Equal(1, merge.Replaced, "relevé plus récent du partage");
        Check.Equal(3, merge.Total, "total");
        Check.Equal(ParkStatus.Empty, merge.State["PC1"].Status, "la ligne la plus récente gagne");
        Check.Equal(ParkStatus.Empty, merge.State["PC2"].Status, "une ligne plus ancienne ne remplace rien");
        Check.Equal(3, SyncPark.Differences(local, shared).Length, "trois postes diffèrent");
        var coverage = SyncPark.Coverage(merge.State.Values.ToList(), 10, 2, Now);
        Check.Equal(30.0, coverage.Percent, "couverture");
        Check.Contains("10 postes actifs, 3 relevés soit 30 %", coverage.Text, "texte de couverture");
        Check.Contains("2 écartés faute d’activité", coverage.Text, "postes écartés");
        Check.Contains("s’affiche dès que", SyncPark.Coverage([], -1, 0, Now).Text, "compte inconnu : texte d’attente");
        Check.Contains("construisez d’abord la base", SyncPark.Coverage([], 0, 0, Now).Text, "aucun poste indexé");
    }

    // ---------------------------------------------------------------- plans of the base (SYN-009, SYN-013, SYN-022, SYN-024)

    [Test]
    public static void Plans_of_the_base_seal_and_decode_their_first_change()
    {
        var head = new WriteChange(SyncStoreChange.BatchAttribute, "Lot vérifié", WriteChangeKind.Add, null, "Lecture", null, SyncStoreChange.HeadValue("index", new string('e', 32), new string('f', 64), 412));
        var draft = SyncStoreChange.Draft("Enregistrer", "Mise à jour de la base locale", "Résumé", SyncStoreChange.IndexTarget("OU Postes", true), head,
            [SyncStoreChange.Effect("index.added", "Objets ajoutés", WriteChangeKind.Add, null, "12 objets", null, "added=12")], [], SyncStoreChange.BackedUp("Sauvegarde."), "DC1");
        Check.False(draft.Confirmation.TypedNameRequired, "confirmation simple : base locale seulement");
        Check.Equal(Tone.Info, draft.Risks[0].Tone, "rien ne quitte le poste");
        var plan = WritePlans.Seal(draft, WritePlans.NewId(), @"TEST\adm", AppMode.Simulation, Now, Zone);
        var decoded = SyncStoreChange.Head(plan);
        Check.NotNull(decoded, "décodé");
        Check.Equal(SyncStoreOperation.Batch, decoded!.Operation, "opération");
        Check.Equal("index", decoded.Kind, "type de lot");
        Check.Equal(412, decoded.Count, "nombre de lignes");
        Check.Equal(SyncStoreChange.IndexStoreGuid.ToString("D"), plan.Target.ObjectGuid, "cible : la base, pas un objet de l’annuaire");
        Check.Null(SyncStoreChange.Head(plan with { Kind = "account.unlock" }), "plan d’un autre type");
        Check.Null(SyncStoreChange.Head(plan with { Changes = [head with { AfterValue = "illisible" }] }), "valeur illisible");
    }
}

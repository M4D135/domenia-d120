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
        Check.Contains("Lire les objets manquants", recent.GapText ?? "", "les écarts du domaine sont donnés à part du conseil de l’OU");
        Check.False(recent.Text.Contains("Lire les objets manquants", StringComparison.Ordinal), "le conseil ne répète pas les objets manquants");
        Check.True(SyncCoverageRules.Census(Cov(CoverageStatus.Complete, Now - TimeSpan.FromDays(1)), 0, 7, Now, false).GapText is null, "aucun écart, aucun texte");
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
        var unreadable = SyncCoverageRules.Tiles(null, null, Now, Zone);
        Check.True(unreadable.All(t => t.Value == "—" && t.Number is null && t.Parts.IsEmpty && t.Gauge is null), "base illisible\u00A0: jamais de zéros");
        var tiles = SyncCoverageRules.Tiles(new SyncCoverageRules.TileCounts(1200, 58, 431, 23, 104, 300), Now - TimeSpan.FromMinutes(12), Now, Zone);
        Check.Equal("1\u202F258", tiles[0].Value, "milliers séparés par une espace fine insécable");
        Check.Equal(1200, tiles[0].Parts[0].Count, "comptes activés");
        Check.Equal(58, tiles[0].Parts[1].Count, "comptes désactivés");
        Check.Contains("431 actifs · 23 désactivés", tiles[1].Detail, "postes actifs et désactivés");
        Check.Equal(300, tiles[2].Parts[0].Count, "postes avec utilisateur");
        Check.Equal(154, tiles[2].Parts[1].Count, "postes sans utilisateur");
        Check.Equal("il y a 12 min", tiles[3].Value, "âge de la dernière lecture");
        Check.True(tiles[3].Gauge is > 0.99 and <= 1, "jauge de fraîcheur pleine après 12 min");
        var old = SyncCoverageRules.Tiles(new SyncCoverageRules.TileCounts(1, 0, 1, 0, 0, 0), Now - TimeSpan.FromDays(10), Now, Zone, 7)[3];
        Check.Equal(0.0, old.Gauge ?? -1, "au-delà du seuil, jauge vide");
        Check.Contains("au-delà du seuil", old.GaugeText ?? "", "seuil nommé");
        Check.Equal("Jamais", SyncCoverageRules.Tiles(new SyncCoverageRules.TileCounts(1, 0, 1, 0, 0, 0), null, Now, Zone)[3].Value, "jamais lu");
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
        Check.Equal("", decoded.Preview, "sans empreinte d’aperçu");
        var withPreview = SyncStoreChange.Head(plan with { Changes = [head with { AfterValue = SyncStoreChange.HeadValue("index", new string('e', 32), new string('f', 64), 412, new string('9', 64)) }] });
        Check.Equal(new string('9', 64), withPreview?.Preview, "empreinte de l’aperçu relue");
    }

    // ---------------------------------------------------------------- empty reads, failed classes, rebuild (SYN-013, SYN-016)

    [Test]
    public static void An_empty_or_failed_read_never_empties_the_base()
    {
        var failed = SyncReconcile.EmptyReadCut(120, 400, ["comptes"], null, false, true, false);
        Check.Equal("erreur", failed?.Reason, "échec d’une classe : passe incomplète");
        Check.Contains("jamais un annuaire vide", failed?.Text, "règle nommée");
        Check.Equal("erreur", SyncReconcile.EmptyReadCut(0, 0, ["postes"], 0, true, true, true)?.Reason, "même une reconstruction ne passe pas une classe en échec");
        var emptyOu = SyncReconcile.EmptyReadCut(0, 37, [], null, false, true, false);
        Check.Equal("vide", emptyOu?.Reason, "lecture complète vide d’une OU remplie");
        Check.Contains("37 objets", emptyOu?.Text, "objets de la base nommés");
        Check.Equal("vide", SyncReconcile.EmptyReadCut(1200, 1500, [], 0, true, true, false)?.Reason, "recensement vide refusé");
        Check.Contains("reconstruction complète explicite", SyncReconcile.EmptyReadCut(0, 1500, [], 0, true, true, false)?.Text, "domaine vide après repère");
        Check.Null(SyncReconcile.EmptyReadCut(0, 1500, [], 0, true, true, true), "reconstruction explicite : un domaine vide est confirmé");
        Check.Null(SyncReconcile.EmptyReadCut(0, 0, [], null, false, false, false), "OU vide dans une base vide : rien à protéger");
        Check.Null(SyncReconcile.EmptyReadCut(25, 30, [], 1700, true, true, false), "lecture normale");

        var current = new Dictionary<Guid, IndexRecord> { [Fixtures.IdOf("PC1")] = Row("PC1"), [Fixtures.IdOf("PC2")] = Row("PC2") };
        Check.Equal(0, SyncReconcile.Reconcile(current, [], Lyon, assertAbsence: true).Counts.Unseen, "lecture vide : aucune absence, jamais un périmètre vidé");
        Check.Equal(2, SyncReconcile.Reconcile(current, [], Lyon, assertAbsence: true, rebuild: true).Counts.Unseen, "reconstruction explicite : les absents sortent de la copie");

        Check.Contains("Recensement vide", SyncReconcile.StorageRefusal(true, true, false, 0, 1500), "enregistrement refusé");
        Check.Null(SyncReconcile.StorageRefusal(true, true, true, 0, 1500), "reconstruction explicite admise");
        Check.Null(SyncReconcile.StorageRefusal(true, false, false, 0, 1500), "lot incomplet : rien de déduit, admis");
        Check.Null(SyncReconcile.StorageRefusal(false, true, false, 0, 1500), "lecture d’OU : pas de recensement");
        Check.Null(SyncReconcile.StorageRefusal(true, true, false, 0, 0), "base vide : rien à protéger");
    }

    [Test]
    public static void The_preview_fingerprint_changes_with_the_objects_not_only_the_counts()
    {
        var current = new Dictionary<Guid, IndexRecord> { [Fixtures.IdOf("PC1")] = Row("PC1"), [Fixtures.IdOf("PC2")] = Row("PC2") };
        var a = SyncReconcile.Reconcile(current, [Row("PC1", description: "x"), Row("PC3")], Lyon, false);
        var b = SyncReconcile.Reconcile(current, [Row("PC2", description: "x"), Row("PC4")], Lyon, false);
        Check.Equal(a.Counts.Added, b.Counts.Added, "mêmes ajouts");
        Check.Equal(a.Counts.Changed, b.Counts.Changed, "mêmes valeurs modifiées");
        Check.False(SyncReconcile.PreviewFingerprint(a) == SyncReconcile.PreviewFingerprint(b), "autres objets : autre empreinte d’aperçu");
        Check.Equal(SyncReconcile.PreviewFingerprint(a), SyncReconcile.PreviewFingerprint(SyncReconcile.Reconcile(current, [Row("PC3"), Row("PC1", description: "x")], Lyon, false)), "l’ordre de lecture ne compte pas");
        Check.Contains("rien n’est supprimé dans l’annuaire", SyncReconcile.Reconcile(current, [Row("PC1")], Lyon, true).Samples.Single(x => x.Category == "unseen").Detail, "non revu : absence non prouvée");
    }

    // ---------------------------------------------------------------- storage readiness (SYN-017)

    [Test]
    public static void New_passes_wait_for_a_healthy_storage()
    {
        var unknown = SyncCoverageRules.Storage(false, 0, null, null, 0, Now, Zone);
        Check.Equal("unknown", unknown.SpaceState, "sans mesure : inconnu");
        Check.Null(unknown.Refusal, "sans mesure, rien n’est bloqué");
        Check.Contains("Maintenance", SyncCoverageRules.Storage(true, 0, null, null, 0, Now, Zone).Refusal, "maintenance : nouvelles passes suspendues");
        var suspended = SyncCoverageRules.Storage(false, 3, null, null, 0, Now, Zone);
        Check.True(suspended.WriterSuspended, "trois échecs : rédacteur suspendu");
        Check.Contains("suspendu", suspended.Refusal, "refus nommé");
        Check.Null(SyncCoverageRules.Storage(false, 2, null, null, 0, Now, Zone).Refusal, "deux échecs : pas encore suspendu");
        var low = SyncCoverageRules.Storage(false, 0, 400L * 1024 * 1024, Now - TimeSpan.FromMinutes(5), 0, Now, Zone);
        Check.Equal("suspend", low.SpaceState, "moins de 512 Mo : collectes suspendues");
        Check.Contains("400", low.Refusal, "espace nommé");
        Check.Equal("critical", SyncCoverageRules.Storage(false, 0, 10L * 1024 * 1024, Now, 0, Now, Zone).SpaceState, "moins de 32 Mo : critique");
        Check.Equal("low", SyncCoverageRules.Storage(false, 0, 1024L * 1024 * 1024, Now, 0, Now, Zone).SpaceState, "moins de 2 Go : à surveiller, sans refus");
        Check.Equal("suspend", SyncCoverageRules.Storage(false, 0, 1024L * 1024 * 1024, Now, 200L * 1024 * 1024, Now, Zone).SpaceState, "la file d’attente relève les seuils (×4)");
        Check.Contains("Mesure ancienne", SyncCoverageRules.Storage(false, 0, 8L * 1024 * 1024 * 1024, Now - TimeSpan.FromHours(2), 0, Now, Zone).SpaceText, "mesure de plus de 30 min");
        Check.False(SyncCoverageRules.Readiness(false, false, low.Refusal).Ready, "la garde d’écriture refuse la passe");
        Check.Equal("1,5" + FrenchText.Nbsp + "Go", SyncCoverageRules.Size(1536L * 1024 * 1024), "taille lisible");
    }

    // ---------------------------------------------------------------- LAPS (SYN-018)

    [Test]
    public static void The_laps_state_tells_an_absent_schema_from_a_value_not_visible()
    {
        var withDate = Row("PC1") with { Laps = LapsKind.Windows, LapsExpiration = Now + TimeSpan.FromDays(10) };
        Check.Equal("windows", SyncIndex.Laps(withDate, SyncIndex.LapsSchemaPresent).State, "Windows LAPS daté");
        Check.Equal("legacy", SyncIndex.Laps(withDate with { Laps = LapsKind.Legacy }, SyncIndex.LapsSchemaPresent).State, "LAPS hérité daté");
        Check.Equal("noSchema", SyncIndex.Laps(Row("PC2"), SyncIndex.LapsSchemaAbsent).State, "attribut absent du domaine");
        Check.Contains("non disponible dans ce domaine", SyncIndex.Laps(Row("PC2"), SyncIndex.LapsSchemaAbsent).Text, "texte : absent du schéma");
        Check.Equal("none", SyncIndex.Laps(Row("PC2"), SyncIndex.LapsSchemaPresent).State, "schéma présent, valeur non visible");
        Check.Contains("visible avec ce compte", SyncIndex.Laps(Row("PC2"), SyncIndex.LapsSchemaPresent).Text, "texte : non visible avec ce compte");
        Check.Equal("unknown", SyncIndex.Laps(Row("PC2"), SyncIndex.LapsSchemaUnknown).State, "schéma jamais lu");
        Check.Null(SyncIndex.Laps(Row("Anne", Fixtures.People, IndexObjectType.User), SyncIndex.LapsSchemaPresent).State, "un compte n’a pas de LAPS");
        var hit = SyncIndex.Hit(Row("PC2"), 0, true, null, SyncIndex.LapsSchemaAbsent);
        Check.Equal("noSchema", hit.LapsState, "transmis à la fiche locale");
    }

    // ---------------------------------------------------------------- park results and shared survey (SYN-029, SYN-030)

    [Test]
    public static void Park_results_wait_for_the_reload_and_build_on_the_stored_counters()
    {
        var stored = new Dictionary<string, ParkEntry> { ["PC1"] = new("PC1", Now - TimeSpan.FromDays(2), ParkStatus.Unreachable, null, 3, "x") };
        var probe = new ParkProbe("pc1", Now, ParkStatus.Session, "anne", "y");
        Check.Equal(4, SyncPark.Apply(stored, probe).Attempts, "tentatives : compteur enregistré + 1");
        Check.Equal(1, SyncPark.Apply(new Dictionary<string, ParkEntry>(), probe).Attempts, "sans compteur enregistré : 1");
        Check.Equal("anne", SyncPark.Apply(stored, probe).User, "utilisateur vu");
        Check.Null(SyncPark.Apply(stored, probe with { Status = ParkStatus.Unreachable, User = "z" }).User, "sans session : aucun utilisateur");
        var waiting = ImmutableArray<ParkProbe>.Empty;
        for (var i = 0; i < 20; i++)
        {
            waiting = SyncPark.Defer(waiting, probe with { Computer = "PC" + i });
        }
        Check.Equal(SyncPark.DeferredLimit, waiting.Length, "16 résultats au plus en attente");
        Check.Equal("PC4", waiting[0].Computer, "les plus anciens partent d’abord");
        var reload = SyncPark.Reload(stored, new Dictionary<string, ParkEntry>(), [probe]);
        Check.Equal(1, reload.Applied, "appliqué après la relecture");
        Check.Equal(4, reload.State["PC1"].Attempts, "à partir des compteurs enregistrés");
        Check.Contains("appliqué ensuite", reload.Text, "dit à l’opérateur");
        var session = new Dictionary<string, ParkEntry> { ["PC1"] = new("PC1", Now - TimeSpan.FromHours(1), ParkStatus.Empty, null, 5, "y") };
        Check.Equal(ParkStatus.Empty, SyncPark.Reload(stored, session, []).State["PC1"].Status, "ce que la session a vu depuis gagne s’il est plus récent");
        Check.Null(SyncPark.Reload(stored, session, []).Text, "rien en attente : aucun texte");
    }

    [Test]
    public static void Shared_survey_outcomes_keep_the_work_local()
    {
        var busy = SyncPark.SharedText(SharedSyncOutcome.LockBusy, @"\\srv\p\r.json", 12, Now + TimeSpan.FromSeconds(30), Zone);
        Check.Contains("non obtenu après 12 essais", busy, "verrou non obtenu");
        Check.Contains("travaille en local", busy, "travail en local");
        Check.Contains("nouvel essai à", busy, "nouvel essai annoncé");
        var unreachable = SyncPark.SharedText(SharedSyncOutcome.Unreachable, @"\\srv\p\r.json", 0, null, Zone);
        Check.Contains("Partage inaccessible", unreachable, "partage inaccessible");
        Check.Contains("journal Parc", unreachable, "noté dans le journal Parc");
        Check.Contains("1ᵉʳ essai", SyncPark.SharedText(SharedSyncOutcome.Merged, "x", 1, null, Zone), "verrou au premier essai");
        Check.Contains("2ᵉ essai", SyncPark.SharedText(SharedSyncOutcome.Merged, "x", 2, null, Zone), "verrou au deuxième essai");
    }

    // ---------------------------------------------------------------- settings and absences of the scope (SYN-016, SYN-024)

    [Test]
    public static void Settings_are_read_from_the_index_section()
    {
        static SyncSettings Parse(string json) => SyncSettings.Parse(System.Text.Encoding.UTF8.GetBytes(json));
        Check.Equal(SyncSettings.Default.BudgetMs, Parse("{}").BudgetMs, "sans section : défauts");
        Check.Equal("Réglages par défaut", Parse("{}").Source, "source par défaut");
        var read = Parse("{ \"index\": { \"MaxObjects\": 5000, \"BudgetMs\": \"600000\", \"FullRebuildDays\": 14, \"StartupDeltaMaxAgeMinutes\": 90 } }");
        Check.Equal(5000L, read.MaxObjects, "Index.MaxObjects (nom insensible à la casse)");
        Check.Equal(600_000, read.BudgetMs, "Index.BudgetMs en texte, comme le cast [int] de Domenia 1");
        Check.Equal(14, read.FullRebuildDays, "Index.FullRebuildDays");
        Check.Equal(90, read.StartupDeltaMaxAgeMinutes, "Index.StartupDeltaMaxAgeMinutes");
        Check.Contains("Index.MaxObjects", read.Source, "clés lues nommées");
        Check.Equal(SyncSettings.Default.FullRebuildDays, Parse("{ \"Index\": { \"FullRebuildDays\": 400 } }").FullRebuildDays, "hors bornes : défaut");
        Check.Equal(SyncSettings.Default.MaxObjects, Parse("{ \"Index\": { \"MaxObjects\": -1 } }").MaxObjects, "quota négatif : défaut");
        Check.Equal(ConfigurationFileState.Invalid, Parse("{ \"Index\": {}, \"INDEX\": {} }").State, "section en double : fichier ignoré");
        Check.Equal(ConfigurationFileState.Invalid, Parse("{ pas du json").State, "JSON illisible");
        Check.Contains("ignoré", Parse("[1]").Source, "fichier ignoré dit");
    }

    [Test]
    public static void Absences_say_whether_they_were_last_seen_in_the_scope()
    {
        var records = new List<AbsenceRecord>
        {
            new(Fixtures.IdOf("PC1"), "PC1", IndexObjectType.Computer, "CN=PC1," + Lyon, null, AbsenceStatus.NotSeen, Now, null, "", Postes, null),
            new(Fixtures.IdOf("Anne"), "Anne", IndexObjectType.User, "CN=Anne," + Fixtures.People, null, AbsenceStatus.NotSeen, Now, null, "", Root, null),
            new(Fixtures.IdOf("PC9"), "PC9", IndexObjectType.Computer, "CN=PC9," + Fixtures.People, "CN=PC9," + Paris, AbsenceStatus.Moved, Now, Now, "", Root, null),
        };
        var list = SyncAbsences.List(records, Zone, true, SyncAbsences.ShownLimit, Postes);
        Check.Equal(3, list.Total, "toutes les disparitions du domaine");
        Check.Equal(2, list.InScope, "vues pour la dernière fois dans le périmètre (ou retrouvées dedans)");
        Check.False(list.Rows.Single(r => r.Name == "Anne").InScope, "hors périmètre");
        Check.Equal(3, SyncAbsences.List(records, Zone, true).InScope, "domaine entier : toutes");
    }

    [Test]
    public static void Comparisons_show_places_and_explain_overlaps()
    {
        var a = SnapshotLine.From(Row("PC-A"));
        var before = Snapshot(new string('a', 32), "Avant", Now - TimeSpan.FromDays(7), [a, SnapshotLine.From(Row("PC-Z"))]);
        var after = Snapshot(new string('b', 32), "Après", Now, [a with { Dn = "CN=PC-A," + Paris, Description = "y" }, SnapshotLine.From(Row("PC-N"))]);
        var report = SyncSnapshots.Compare(before, after, Zone);
        var move = report.Rows.Single(r => r.Nature == SnapshotDiffNature.Moved);
        Check.Equal("Postes › Lyon", move.Before, "avant : emplacement lisible");
        Check.Equal("Postes › Paris", move.After, "après : emplacement lisible");
        Check.Equal("CN=PC-A," + Paris, move.AfterDn, "DN gardé pour l’export");
        Check.Equal("Postes › Lyon", report.Rows.Single(r => r.Nature == SnapshotDiffNature.Added).After, "ajout : emplacement");
        Check.Equal(3, report.Counts.Distinct, "objets distincts : communs, ajouts, disparitions");
        Check.Contains("3 objets distincts", report.Headline, "titre de la comparaison");
        Check.Contains("se recouvrent", report.Overlap, "un objet déplacé et modifié est expliqué");
    }
}

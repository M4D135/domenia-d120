using System.Text.Json;
using Domenia.Ad;
using Domenia.Core;

namespace Domenia.Tests;

internal static class AdSearchCheckpointTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static SearchQuery Query() => new(SearchListKind.Search, SearchText.Plan("poste*", SearchTypeFilter.Computers, SearchMatchMode.Prefix),
        SearchTypeFilter.Computers, Fixtures.Postes, true, null, null, new HashSet<string>(), 10) { Reconcile = true };

    [Test]
    public static async Task Periodic_delta_reads_only_changes_and_saves_the_before_query_watermark()
    {
        using var ldap = new VersionedConnection(); var clock = TestClock.Fixed();
        using var source = Source(ldap, clock); var reader = new AdSearchReader(source);
        var baseline = (await reader.FindAsync(Query(), None)).Qualification!.Checkpoint!;
        ldap.Rows = [Entry(1, 110), Entry(2, 100)]; ldap.Usn = 120;
        ldap.DuringList = _ => ldap.Usn = 130;
        var delta = await reader.FindAsync(Query() with { Checkpoint = baseline, Incremental = true }, None);
        Check.Equal(1, delta.Rows.Length, "seul l’objet modifié est relu");
        Check.Equal(Fixtures.IdOf("checkpoint-1").ToString("D"), delta.Rows[0].Id, "identité du changement");
        Check.True(delta.Qualification!.Incremental && delta.Qualification.Continuous, "delta identifié, jamais une liste complète");
        Check.Equal<long?>(120, delta.Qualification.Checkpoint!.HighestCommittedUsn, "borne d’avant lecture ; pas 130 observé après");
        Check.Equal(baseline.FullReadAt, delta.Qualification.Checkpoint.FullReadAt, "la date du dernier contrôle complet n’est pas rajeunie");
        Check.Contains("(uSNChanged>=101)", ldap.ListRequests.Last().Filter, "borne stricte issue du repère qualifié");
        Check.Null(ldap.ListRequests.Last().SortAttribute, "aucun tri serveur pour un delta sans pagination par nom");
        Check.Null(delta.LastKey, "aucun curseur client exposé pour le delta");
        ldap.DuringList = null; ldap.Rows = [Entry(1, 125), Entry(2, 100)];
        var concurrent = await reader.FindAsync(Query() with { Checkpoint = delta.Qualification.Checkpoint, Incremental = true }, None);
        Check.Equal(1, concurrent.Rows.Length, "un changement pendant la lecture précédente reste éligible");
        Check.Contains("(uSNChanged>=121)", ldap.ListRequests.Last().Filter, "aucun saut au repère final 130");
        clock.Advance(TimeSpan.FromMinutes(16));
        var full = await reader.FindAsync(Query() with { Checkpoint = concurrent.Qualification!.Checkpoint, Incremental = true }, None);
        Check.False(full.Qualification!.Incremental, "contrôle complet périodique pour sorties, suppressions et changements de visibilité");
        Check.Equal(2, full.Rows.Length, "le contrôle complet relit aussi les objets inchangés");
        Check.False(ldap.ListRequests.Last().Filter.Contains("uSNChanged>=", StringComparison.Ordinal), "aucun delta au-delà de quinze minutes sans contrôle complet");
    }

    [Test]
    public static async Task Partial_delta_never_advances_and_an_incompatible_checkpoint_falls_back_to_full()
    {
        using var ldap = new VersionedConnection(); using var source = Source(ldap); var reader = new AdSearchReader(source);
        var baseline = (await reader.FindAsync(Query(), None)).Qualification!.Checkpoint!;
        ldap.Usn = 200; ldap.Rows = Enumerable.Range(1, 12).Select(n => Entry(n, 150)).ToArray();
        var capped = await reader.FindAsync(Query() with { Checkpoint = baseline, Incremental = true }, None);
        Check.True(capped.More && capped.Qualification!.Incremental, "delta plafonné reste explicitement partiel");
        Check.Null(capped.Qualification!.Checkpoint, "aucune borne avancée sur une réponse tronquée");
        Check.True(capped.Qualification.KeepPrevious, "reprise sur le repère précédent pour ne perdre aucun changement");
        ldap.Rows = [Entry(1)];
        foreach (var prior in new[] { baseline with { InvocationId = Guid.NewGuid() }, baseline with { ReaderFingerprint = "other" },
            baseline with { Controller = "other.test.local" }, baseline with { QueryFingerprint = "other" }, baseline with { HighestCommittedUsn = 201 } })
        {
            var full = await reader.FindAsync(Query() with { Checkpoint = prior, Incremental = true }, None);
            Check.False(full.Qualification!.Incremental, "repère incompatible : relecture complète");
            Check.False(full.Qualification.Continuous, "aucune absence certifiée sur une autre origine");
            Check.False(ldap.ListRequests.Last().Filter.Contains("uSNChanged>=", StringComparison.Ordinal), "pas de delta avec une origine différente");
        }
    }

    [Test]
    public static async Task Service_never_marks_unchanged_objects_missing_from_a_delta()
    {
        using var ldap = new VersionedConnection(); var clock = TestClock.Fixed(); using var source = Source(ldap, clock);
        await source.ConnectAsync(None);
        using var context = new EngineContext(new(AppMode.Directory, ModeReason.Argument, "test", null, "test.local", []), source,
            new MemoryPreferenceStore(), clock, new RecordingJournal(), ScreenReaders.Discover(source, [typeof(AdDirectorySource).Assembly]));
        var service = SearchService.From(context);
        var list = await service.RunAsync("poste*", null, SearchTypeFilter.Computers, 10, SearchMatchMode.Prefix, None);
        await service.ReconcileAsync(list.ListId, None);
        ldap.Rows = [Entry(1, 110), Entry(2, 100)]; ldap.Usn = 120;
        var changed = await service.ReconcileAsync(list.ListId, None, incremental: true);
        Check.Equal(1, changed.Rows.Length, "seule la ligne modifiée traverse le pont");
        Check.Equal(0, changed.Missing.Length, "objet inchangé absent du delta : jamais marqué manquant");
        Check.Equal(0, changed.Moved.Length, "aucune relecture GUID inutile des lignes inchangées");
        Check.Equal(2, changed.Loaded, "le dénominateur de la liste est conservé");
        ldap.Rows = [Entry(1, 110)];
        var manual = await service.ReconcileAsync(list.ListId, None);
        Check.Equal(1, manual.Missing.Length, "une revérification manuelle reste complète et détecte la sortie");
        Check.Equal(2, manual.Loaded, "aucune suppression automatique de ligne");
    }

    [Test]
    public static async Task Complete_rereads_qualify_the_actual_instance_without_using_a_delta_filter()
    {
        using var ldap = new VersionedConnection();
        using var source = Source(ldap);
        var reader = new AdSearchReader(source);
        var first = await reader.FindAsync(Query(), None);
        Check.Equal(2, first.Rows.Length, "setup : deux objets reçus");
        var saved = first.Qualification!.Checkpoint!;
        Check.True(saved is not null, "repère réel établi");
        Check.Equal(ldap.Invocation, saved!.InvocationId, "invocationID physiquement relu");
        Check.Equal(ldap.Server, saved.Controller, "contrôleur exact");
        Check.Equal<long?>(100, saved.HighestCommittedUsn, "USN RootDSE sans invention");
        Check.False(first.Qualification.Continuous, "pas de continuité avant premier repère");
        ldap.Usn = 150;
        var query = Query() with { Checkpoint = saved };
        var second = await reader.FindAsync(query, None);
        Check.True(second.Qualification!.Continuous, "continuité certifiée");
        Check.Equal<long?>(150, second.Qualification.Checkpoint!.HighestCommittedUsn, "repère avancé seulement avec données reçues");
        Check.True(ldap.InstanceReads >= 4, "instance relue avant et après chaque liste");
        Check.False(ldap.ListRequests.Any(r => r.Filter.Contains("uSNChanged>=", StringComparison.Ordinal)), "liste complète, aucun filtre delta qui masquerait les sorties");
        Check.False(JsonSerializer.Serialize(query).Contains("ReaderFingerprint", StringComparison.Ordinal), "repère serveur absent des arguments sérialisés");
        Check.False(JsonSerializer.Serialize(second).Contains("InvocationId", StringComparison.Ordinal), "métadonnées de page non exportées comme curseur");
    }

    [Test]
    public static async Task Capped_or_interrupted_reread_never_advances_a_previous_checkpoint()
    {
        using var ldap = new VersionedConnection(); using var source = Source(ldap);
        var reader = new AdSearchReader(source);
        var saved = (await reader.FindAsync(Query(), None)).Qualification!.Checkpoint!;
        Check.True(saved is not null, "setup repère complet");
        ldap.Rows = Enumerable.Range(1, 11).Select(n => Entry(n)).ToArray(); ldap.Usn = 200;
        var capped = await reader.FindAsync(Query() with { Checkpoint = saved }, None);
        Check.True(capped.More, "sentinelle réellement reçue");
        Check.Null(capped.Qualification!.Checkpoint, "aucun nouveau repère pour une liste plafonnée");
        Check.True(capped.Qualification.KeepPrevious, "ancien repère seulement conservé");
        Check.False(capped.Qualification.Continuous, "aucune absence déduite d’une liste plafonnée");
        ldap.DuringList = q => { q.EntryReceived!.Invoke(Entry(1)); throw new DomeniaOperationException(AdErrors.Timeout, "lecture interrompue"); };
        var interrupted = await reader.FindAsync(Query() with { Checkpoint = saved }, None);
        Check.True(interrupted.Interrupted, "interruption effective"); Check.Equal(1, interrupted.Rows.Length, "ligne terminée conservée");
        Check.Null(interrupted.Qualification!.Checkpoint, "timeout sans avancement");
        Check.True(interrupted.Qualification.KeepPrevious, "ancien repère inchangé");
    }

    [Test]
    public static async Task Controller_instance_change_during_read_discards_the_checkpoint()
    {
        using var ldap = new VersionedConnection(); using var source = Source(ldap);
        var reader = new AdSearchReader(source);
        var saved = (await reader.FindAsync(Query(), None)).Qualification!.Checkpoint!;
        var hook = false;
        ldap.DuringList = _ => { hook = true; ldap.Invocation = Guid.NewGuid(); };
        var result = await reader.FindAsync(Query() with { Checkpoint = saved }, None);
        Check.True(hook, "changement injecté pendant la recherche réelle");
        Check.Equal(2, result.Rows.Length, "lignes positives conservées");
        Check.Null(result.Qualification!.Checkpoint, "pas de nouveau repère");
        Check.False(result.Qualification.KeepPrevious, "ancienne instance invalidée");
        Check.False(result.Qualification.Continuous, "aucune continuité inventée");
    }

    [Test]
    public static async Task Changed_controller_account_scope_and_USN_regression_reset_continuity()
    {
        using var ldap = new VersionedConnection(); using var source = Source(ldap);
        var reader = new AdSearchReader(source);
        var saved = (await reader.FindAsync(Query(), None)).Qualification!.Checkpoint!;
        Check.True(saved is not null, "setup complet");
        foreach (var prior in new[] { saved! with { Controller = "other.test.local" }, saved! with { InvocationId = Guid.NewGuid() },
            saved! with { ReaderFingerprint = new string('a', 64) }, saved! with { QueryFingerprint = new string('b', 64) }, saved! with { HighestCommittedUsn = 101 } })
        {
            var page = await reader.FindAsync(Query() with { Checkpoint = prior }, None);
            Check.Equal(2, page.Rows.Length, "relecture complète exécutée");
            Check.Null(page.Qualification!.Checkpoint, "repère incompatible non avancé");
            Check.False(page.Qualification.KeepPrevious || page.Qualification.Continuous, "repère incompatible écarté");
        }
        ldap.Usn = null;
        var unknownUsn = await reader.FindAsync(Query(), None);
        Check.True(unknownUsn.Qualification!.Checkpoint is not null, "couple DC/instance lisible");
        Check.Null(unknownUsn.Qualification.Checkpoint!.HighestCommittedUsn, "USN absent reste absent");
    }

    [Test]
    public static async Task Missing_version_identity_and_user_cancellation_never_publish_a_checkpoint()
    {
        using var ldap = new VersionedConnection { InvocationReadable = false }; using var source = Source(ldap);
        var reader = new AdSearchReader(source);
        var page = await reader.FindAsync(Query(), None);
        Check.Equal(2, page.Rows.Length, "lecture de liste possible sans objet de version");
        Check.Null(page.Qualification!.Checkpoint, "instance inconnue sans repère");
        using var stop = new CancellationTokenSource();
        ldap.InvocationReadable = true;
        var hook = false;
        ldap.DuringList = q => { hook = true; q.EntryReceived!.Invoke(Entry(1)); stop.Cancel(); };
        await Check.ThrowsAsync<OperationCanceledException>(() => reader.FindAsync(Query(), stop.Token), "annulation réelle propagée");
        Check.True(hook, "annulation entre réception et publication");
    }

    [Test]
    public static async Task Session_replacement_during_the_read_never_publishes_rows_or_a_new_checkpoint()
    {
        using var ldap = new VersionedConnection(); using var source = Source(ldap);
        var reader = new AdSearchReader(source);
        var saved = (await reader.FindAsync(Query(), None)).Qualification!.Checkpoint!;
        Check.True(saved is not null, "setup complet avant remplacement");
        var hook = false;
        ldap.DuringList = _ => { hook = true; source.Reset(); };
        var refusal = await Check.ThrowsAsync<DomeniaOperationException>(() => reader.FindAsync(Query() with { Checkpoint = saved }, None), "ancienne session refusée");
        Check.True(hook, "session remplacée pendant le transport");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, refusal.Code, "refus de contexte exact");
        Check.Contains("Session modifiée", refusal.Message, "résultat tardif écarté");
        Check.True(source.CurrentDirectory is null, "aucune publication locale après remplacement");
    }

    [Test]
    public static async Task Service_marks_absence_only_after_same_instance_continuity_and_keeps_the_row()
    {
        using var ldap = new VersionedConnection(); var clock = TestClock.Fixed();
        using var source = Source(ldap, clock);
        // SearchService starts from a connected or locally loaded session; it never connects implicitly.
        await source.ConnectAsync(None);
        using var context = new EngineContext(new(AppMode.Directory, ModeReason.Argument, "test", null, "test.local", []), source,
            new MemoryPreferenceStore(), clock, new RecordingJournal(), ScreenReaders.Discover(source, [typeof(AdDirectorySource).Assembly]));
        var service = SearchService.From(context);
        var list = await service.RunAsync("poste*", null, SearchTypeFilter.Computers, 10, SearchMatchMode.Prefix, None);
        Check.Equal(2, list.Rows.Length, "setup de liste complète");
        var first = await service.ReconcileAsync(list.ListId, None);
        Check.Contains(ldap.Invocation.ToString("D"), first.Checkpoint, "affichage du vrai repère");
        Check.False(first.Checkpoint.Contains("lecture n°", StringComparison.Ordinal), "compteur trompeur retiré");
        ldap.Rows = [Entry(1)];
        var next = await service.ReconcileAsync(list.ListId, None);
        Check.True(next.Missing.SequenceEqual([Fixtures.IdOf("checkpoint-2").ToString("D")]), "absence qualifiée et bornée");
        Check.Equal(2, next.Loaded, "aucune ligne supprimée");
        ldap.Invocation = Guid.NewGuid();
        var changed = await service.ReconcileAsync(list.ListId, None);
        Check.Equal(0, changed.Missing.Length, "aucune absence sur une autre instance");
        Check.Contains("ancien repère écarté", changed.Checkpoint, "rupture visible");
    }

    private static AdDirectorySource Source(IAdConnection connection, TimeProvider? clock = null) =>
        new("test.local", () => "TEST\\adm", clock ?? TestClock.Fixed(), connection: connection);
    private static AdEntry Entry(int n, long usn = 100)
    {
        var entry = AdPosteNetworkTests.Entry(Fixtures.Computer("POSTE" + n) with
        {
            ObjectGuid = Fixtures.IdOf("checkpoint-" + n), Sid = Fixtures.Domain.DomainSid + "-" + (2000 + n), UsnChanged = usn,
        });
        var values = entry.AttributeNames.ToDictionary(name => name, entry.Raw, StringComparer.OrdinalIgnoreCase);
        values["uSNChanged"] = [usn.ToString(System.Globalization.CultureInfo.InvariantCulture)];
        return new AdEntry(entry.DistinguishedName, values);
    }

    private sealed class VersionedConnection : IAdConnection
    {
        private readonly AdBoundaryTests.RecordingAdConnection inner = new();
        private const string Configuration = "CN=Configuration," + Fixtures.Root;
        private const string Service = "CN=NTDS Settings,CN=DC1,CN=Servers,CN=Site,CN=Sites," + Configuration;
        public string Server => inner.Server;
        public Guid Invocation { get; set; } = Guid.NewGuid();
        public long? Usn { get; set; } = 100;
        public bool InvocationReadable { get; set; } = true;
        public int InstanceReads { get; private set; }
        public IReadOnlyList<AdEntry> Rows { get; set; } = [Entry(1), Entry(2)];
        public Action<AdSearchRequest>? DuringList { get; set; }
        public List<AdSearchRequest> ListRequests { get; } = [];
        public async Task<AdRootDse> RootDseAsync(CancellationToken token) => (await inner.RootDseAsync(token)) with
        { ConfigurationNamingContext = Configuration, DsServiceName = Service, IsSynchronized = true, HighestCommittedUsn = Usn };
        public Task<IReadOnlyList<AdEntry>> SearchAsync(AdSearchRequest request, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            if (request.BaseDn.Length == 0)
            {
                Check.Equal(AdSearchScope.Base, request.Scope, "RootDSE frais et borné");
                Check.False(request.ExpandRanges, "pas de lecture annexe implicite");
                var values = new Dictionary<string, IReadOnlyList<object>>
                {
                    ["defaultNamingContext"] = [Fixtures.Root], ["configurationNamingContext"] = [Configuration],
                    ["schemaNamingContext"] = ["CN=Schema," + Configuration], ["rootDomainNamingContext"] = [Fixtures.Root],
                    ["dnsHostName"] = [Server], ["dsServiceName"] = [Service], ["isSynchronized"] = ["TRUE"],
                };
                if (Usn is { } usn) { values["highestCommittedUSN"] = [usn.ToString(System.Globalization.CultureInfo.InvariantCulture)]; }
                return Task.FromResult<IReadOnlyList<AdEntry>>([new AdEntry("", values)]);
            }
            if (request.BaseDn == Service)
            {
                InstanceReads++;
                Check.Equal(AdSearchScope.Base, request.Scope, "version lue sur un seul objet");
                return Task.FromResult<IReadOnlyList<AdEntry>>(InvocationReadable ? [new AdEntry(Service, new Dictionary<string, IReadOnlyList<object>> { ["invocationID"] = [Invocation.ToByteArray()] })] : []);
            }
            if (request.SortAttribute is not null || request.EntryReceived is not null)
            {
                ListRequests.Add(request); DuringList?.Invoke(request);
                var lower = System.Text.RegularExpressions.Regex.Match(request.Filter, @"\(uSNChanged>=(\d+)\)");
                var filtered = lower.Success ? Rows.Where(r => r.Long("uSNChanged") >= long.Parse(lower.Groups[1].Value, System.Globalization.CultureInfo.InvariantCulture)) : Rows;
                return Task.FromResult<IReadOnlyList<AdEntry>>(filtered.Take(request.SizeLimit).ToArray());
            }
            return inner.SearchAsync(request, token);
        }
        public Task<AdEntry?> ReadAsync(string dn, IReadOnlyList<string> attributes, CancellationToken token) => inner.ReadAsync(dn, attributes, token);
        public Task ModifyAsync(string dn, IReadOnlyList<AdModification> changes, CancellationToken token) => inner.ModifyAsync(dn, changes, token);
        public Task RenameAsync(string dn, string parent, string rdn, CancellationToken token) => inner.RenameAsync(dn, parent, rdn, token);
        public Task AddAsync(string dn, IReadOnlyDictionary<string, IReadOnlyList<object>> attributes, CancellationToken token) => inner.AddAsync(dn, attributes, token);
        public Task DeleteAsync(string dn, CancellationToken token) => inner.DeleteAsync(dn, token);
        public void Dispose() => inner.Dispose();
    }
}

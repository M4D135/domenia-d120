using System.Globalization;
using System.Security.Principal;
using System.Text.Json;
using Domenia.Ad;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class NativeSyncIncrementalTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static SyncScope Domain => new(Fixtures.Root, "Domaine", "Domaine", true, true, "Test explicite");

    [Test]
    public static async Task Typed_sync_statistics_survive_native_store_reopen_and_feed_the_real_estimator_without_network_reads()
    {
        using var setup = new Setup(); setup.Ldap.SecondComputer = true; await setup.Connect();
        // The native reader supplies the complete contract; time is fixed at its observer boundary, not benchmarked by this fixture.
        var result = (await setup.Run()) with { DurationMs = 250 };
        Check.True(result.Complete && result.Read > 0, "vrai parcours du lecteur sur annuaire scripté");
        await setup.Store(result);
        var clock = TestClock.Fixed();
        using var context = new EngineContext(ModeResolver.Resolve([], null, () => new DomainJoinInfo(DomainJoinState.Joined, "test.local")),
            setup.Source, new MemoryPreferenceStore(), clock, new RecordingJournal());
        setup.Source.BindAccountContext(context);
        var definition = new OperationDefinition("synchro.read.run", OperationClass.NetworkRead, (_, _, _) => Task.FromResult<object?>(result), "Lecture");
        var tracked = OperationTracking.Track(context, definition);
        await tracked.Handler(JsonSerializer.SerializeToElement(new { }), new BridgeContext(_ => { }, "complete", definition.Name), None);
        clock.Advance(TimeSpan.FromSeconds(1));
        var partial = OperationTracking.Track(context, definition with { Handler = (_, _, _) => Task.FromResult<object?>(result with { Complete = false }) });
        await partial.Handler(JsonSerializer.SerializeToElement(new { }), new BridgeContext(_ => { }, "partial", definition.Name), None);
        using (var writer = new AdOperationsReader(setup.Source)) { await writer.PersistStatisticsAsync(None); }
        var database = await setup.Cache.DatabaseAsync(None);
        var reopened = new DomeniaDatabase(database.Path, Fixtures.Root, clock);
        var saved = await reopened.ReadOperationsAsync(None);
        Check.Equal(2, saved.Samples.Length, "les deux observations sont conservées");
        Check.Equal(1, saved.Samples.Count(s => s.Sync is not null), "la lecture partielle ne qualifie pas une estimation");
        Check.Equal(result.Read, saved.Samples.Single(s => s.Sync is not null).Sync!.Items, "volume réel du contrat, pas un objet réponse compté comme un poste");
        using var coldConnection = new Connection();
        using var coldSource = new AdDirectorySource("test.local", () => @"TEST\test", clock, connection: coldConnection, localStore: new SqliteDirectoryCache(reopened));
        await coldSource.ConnectAsync(None); coldConnection.Queries.Clear();
        var estimate = await new AdSyncReader(coldSource).EstimateAsync(new(SyncTarget.Domain, Domain, null, null, SyncSettings.Default, true), None);
        Check.Equal(250, estimate.EstimatedMs, "l’estimateur réel retrouve la mesure qualifiée du disque à froid");
        Check.Equal(2, estimate.KnownObjects, "deux identités réellement conservées, même sans quota opérateur");
        var bounded = await new AdSyncReader(coldSource).EstimateAsync(new(SyncTarget.Domain, Domain, 1, null, SyncSettings.Default, true), None);
        Check.Equal(125, bounded.EstimatedMs, "quota positif appliqué au coût sans perdre la population connue");
        Check.Equal(2, bounded.KnownObjects, "population locale entière conservée sous quota");
        Check.Equal(0, coldConnection.Queries.Count, "aucune recherche LDAP pour estimer");
        var (simulation, _, _, _) = WriteCircuitTests.FakeCircuit(); using var owned = simulation;
        await OperationTracking.Track(simulation, definition).Handler(JsonSerializer.SerializeToElement(new { }), new BridgeContext(_ => { }, "demo", definition.Name), None);
        Check.Null(OperationActivity.From(simulation).Samples().Single().Sync, "la simulation ne devient pas un calibrage du domaine réel");
    }

    [Test]
    public static async Task Native_checkpoint_uses_the_before_read_high_water_mark_and_commits_with_its_rows()
    {
        using var setup = new Setup(); await setup.Connect();
        var first = await setup.Run();
        Check.Equal(SyncReadMode.Full, first.Mode, "premier passage complet"); Check.True(first.CheckpointAdvances, "instance certifiée");
        Check.Equal(100L, first.HighestUsn, "borne RootDSE avant lecture, pas maximum des objets");
        Check.True((await setup.Cache.ReadSyncStateAsync(None)).Scopes.IsEmpty, "aperçu ne déplace aucun repère");
        await setup.Store(first);
        var marker = (await setup.Cache.ReadSyncStateAsync(None)).Scopes.Single(x => x.Key == "directory");
        Check.Equal(100L, marker.Usn, "repère conservé avec le lot"); Check.Equal(setup.Ldap.Invocation.ToString("D"), marker.InvocationId, "instance exacte");
        setup.Ldap.Highest = 200; setup.Ldap.ComputerUsn = 150; setup.Ldap.Description = "nouveau";
        setup.Ldap.Queries.Clear();
        var next = await setup.Run();
        Check.Equal(SyncReadMode.Incremental, next.Mode, "passage différentiel réel");
        Check.True(setup.Ldap.Queries.Any(x => x.Filter.Contains("(uSNChanged>=101)", StringComparison.Ordinal)), "filtre supérieur au repère");
        Check.True(setup.Ldap.Queries.Any(x => x.Attributes.Count == 2 && x.Attributes.Contains("objectGUID")), "recensement des identités distinct");
        Check.Equal(100L, (await setup.Cache.ReadSyncStateAsync(None)).Scopes.Single(x => x.Key == "directory").Usn, "ancien curseur tant que non confirmé");
        await setup.Store(next);
        var state = await setup.Cache.ReadSyncStateAsync(None);
        Check.Equal(200L, state.Scopes.Single(x => x.Key == "directory").Usn, "borne persistée après transaction");
        Check.Equal("nouveau", state.Rows.Single().Description, "données correspondant au repère relues");
    }

    [Test]
    public static async Task An_empty_delta_with_a_complete_nonempty_census_is_a_valid_unchanged_pass()
    {
        using var setup = new Setup(); await setup.Connect(); await setup.Store(await setup.Run());
        setup.Ldap.Highest = 200;
        var result = await setup.Run();
        Check.Equal(SyncReadMode.Incremental, result.Mode, "delta demandé sur la même instance");
        Check.Equal(0, result.Read, "aucun objet modifié depuis le repère");
        Check.True(result.Complete && result.CheckpointAdvances, "recensement non vide distingue absence de changement et annuaire vide");
        await setup.Store(result);
        var state = await setup.Cache.ReadSyncStateAsync(None);
        Check.Equal(1, state.Rows.Length, "copie existante conservée");
        Check.Equal(200L, state.Scopes.Single(x => x.Key == "directory").Usn, "borne réellement lue persistée après lot vide confirmé");
    }

    [Test]
    public static async Task A_partial_incremental_batch_keeps_the_previous_committed_cursor()
    {
        using var setup = new Setup(); await setup.Connect(); await setup.Store(await setup.Run());
        setup.Ldap.Highest = 200; setup.Ldap.ComputerUsn = 150; setup.Ldap.FailUsers = true;
        var result = await setup.Run();
        Check.False(result.Complete, "classe refusée => passe incomplète"); Check.False(result.CheckpointAdvances, "aucun avancement partiel");
        Check.Equal(1, result.Read, "résultat effectivement reçu conservé");
        await setup.Store(result);
        var state = await setup.Cache.ReadSyncStateAsync(None);
        Check.Equal(100L, state.Scopes.Single(x => x.Key == "directory").Usn, "ancien curseur conservé malgré enregistrement partiel");
        Check.Equal(0L, state.Scopes.Single(x => x.Key == "attempt:directory").Usn, "tentative sans faux repère");
        Check.Equal(0, state.Absences.Length, "aucune absence issue de la passe partielle");
    }

    [Test]
    public static async Task An_identity_becoming_visible_with_an_old_usn_forces_full_read_in_the_confirmed_budget()
    {
        using var setup = new Setup(); await setup.Connect(); await setup.Store(await setup.Run());
        setup.Ldap.SecondComputer = true; setup.Ldap.Highest = 200; setup.Ldap.Queries.Clear();
        var result = await setup.Run();
        Check.Equal(SyncReadMode.Full, result.Mode, "GUID absent détecté par recensement"); Check.Equal(2, result.Read, "ancien USN de PC2 ne masque pas son identité nouvellement visible");
        Check.False(setup.Ldap.Queries.Any(x => x.Filter.Contains("uSNChanged>=", StringComparison.Ordinal)), "aucun filtre périmé après repli complet");
        await setup.Store(result);
        Check.Equal(2, (await setup.Cache.ReadSyncStateAsync(None)).Rows.Length, "nouvelle visibilité enregistrée");
    }

    [Test]
    public static async Task Changed_controller_instance_never_reuses_a_previous_usn()
    {
        using var setup = new Setup(); await setup.Connect(); await setup.Store(await setup.Run());
        setup.Ldap.Invocation = Guid.NewGuid(); setup.Ldap.Highest = 200; setup.Ldap.Queries.Clear();
        var result = await setup.Run();
        Check.Equal(SyncReadMode.Full, result.Mode, "nouvelle instance impose lecture complète");
        Check.False(setup.Ldap.Queries.Any(x => x.Filter.Contains("uSNChanged>=", StringComparison.Ordinal)), "aucun ancien USN reporté");
        await setup.Store(result);
        Check.Equal(setup.Ldap.Invocation.ToString("D"), (await setup.Cache.ReadSyncStateAsync(None)).Scopes.Single(x => x.Key == "directory").InvocationId, "nouvelle instance enregistrée avec ses données");
    }

    [Test]
    public static async Task Controller_restore_during_read_and_empty_census_cannot_advance_a_checkpoint()
    {
        using var setup = new Setup(); await setup.Connect(); await setup.Store(await setup.Run());
        setup.Ldap.Highest = 200; setup.Ldap.ComputerUsn = 150; setup.Ldap.ChangeInstanceAfterObjects = true;
        var changed = await setup.Run();
        Check.False(changed.Complete, "instance différente lors de la relecture finale"); Check.False(changed.CheckpointAdvances, "restauration ne déplace pas le curseur");
        await setup.Store(changed);
        Check.Equal(100L, (await setup.Cache.ReadSyncStateAsync(None)).Scopes.Single(x => x.Key == "directory").Usn, "repère antérieur conservé");
        setup.Ldap.ChangeInstanceAfterObjects = false; setup.Ldap.EmptyCensus = true;
        var empty = await setup.Run();
        Check.False(empty.Complete, "recensement vide inattendu refusé"); Check.False(empty.CheckpointAdvances, "aucun curseur sur recensement vide");
        Check.False(empty.Storable, "aucun lot vide proposé comme réussi");
    }

    private sealed class Setup : IDisposable
    {
        private readonly TemporaryFolder folder = new();
        internal CompatibleDirectoryCache Cache { get; }
        internal Connection Ldap { get; } = new();
        internal AdDirectorySource Source { get; }
        private AdSyncReader Reader { get; }
        internal Setup()
        {
            Cache = new(folder.File("app"), folder.File("profile"), "test.local", TestClock.Fixed());
            Source = new("test.local", () => @"TEST\test", TestClock.Fixed(), connection: Ldap, localStore: Cache); Reader = new(Source);
        }
        internal async Task Connect() => _ = await Source.ConnectAsync(None);
        internal async Task<SyncReadResult> Run()
        {
            var estimate = await Reader.EstimateAsync(new(SyncTarget.Domain, Domain, null, null, SyncSettings.Default, false), None);
            return await Reader.RunReadAsync(estimate.Id, _ => { }, None);
        }
        internal async Task Store(SyncReadResult result)
        {
            var executor = new AdSyncStoreExecutor(Source);
            var draft = await executor.PlanBatchAsync(result.BatchId, None);
            var plan = WritePlans.Seal(draft, WritePlans.NewId(), @"TEST\test", AppMode.Directory, Fixtures.Now, TimeZoneInfo.Utc);
            executor.Bind(draft, plan); await executor.ExecuteAsync(plan, None);
            Check.Equal(VerificationState.Verified, (await executor.VerifyAsync(plan, None)).State, "preuve native du lot");
        }
        public void Dispose() { Source.Dispose(); folder.Dispose(); }
    }

    private sealed class Connection : IAdConnection
    {
        private const string Configuration = "CN=Configuration," + Fixtures.Root;
        private const string Service = "CN=NTDS Settings,CN=DC1,CN=Servers,CN=Site,CN=Sites," + Configuration;
        private readonly AdBoundaryTests.RecordingAdConnection basis = new();
        private readonly Guid computer = Guid.NewGuid();
        private readonly Guid other = Guid.NewGuid();
        public string Server => "DC1.test.local";
        internal Guid Invocation { get; set; } = Guid.NewGuid();
        internal long Highest { get; set; } = 100;
        internal long ComputerUsn { get; set; } = 12;
        internal string Description { get; set; } = "initial";
        internal bool SecondComputer { get; set; }
        internal bool FailUsers { get; set; }
        internal bool EmptyCensus { get; set; }
        internal bool ChangeInstanceAfterObjects { get; set; }
        private bool objectRead;
        internal List<AdSearchRequest> Queries { get; } = [];
        public Task<AdRootDse> RootDseAsync(CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested(); objectRead = false;
            return Task.FromResult(new AdRootDse(Fixtures.Root, Configuration, "CN=Schema," + Configuration, Fixtures.Root, Server, null, 7, [], Fixtures.Now)
            { HighestCommittedUsn = Highest, IsSynchronized = true, DsServiceName = Service });
        }
        public Task<AdEntry?> ReadAsync(string distinguishedName, IReadOnlyList<string> attributes, CancellationToken cancellationToken) => basis.ReadAsync(distinguishedName, attributes, cancellationToken);
        public Task<IReadOnlyList<AdEntry>> SearchAsync(AdSearchRequest request, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested(); Queries.Add(request);
            if (request.BaseDn == Service)
            {
                var invocation = ChangeInstanceAfterObjects && objectRead ? Guid.NewGuid() : Invocation;
                return Task.FromResult<IReadOnlyList<AdEntry>>([new(Service, new Dictionary<string, IReadOnlyList<object>> { ["invocationID"] = [invocation.ToByteArray()] })]);
            }
            if (request.BaseDn != Fixtures.Root) { return Task.FromResult<IReadOnlyList<AdEntry>>([]); }
            // The runner's Windows SID is not one of these invented computers. An identity lookup must never receive
            // the computer inventory simply because both projections contain objectSid.
            if (request.Attributes.SequenceEqual(AdSessionIdentity.Attributes)) { return Task.FromResult<IReadOnlyList<AdEntry>>([]); }
            if (request.Attributes.Count == 2 && request.Attributes.Contains("objectGUID"))
            { return Task.FromResult<IReadOnlyList<AdEntry>>(EmptyCensus ? [] : SecondComputer ? [Entry(computer, "PC1", ComputerUsn), Entry(other, "PC2", 5)] : [Entry(computer, "PC1", ComputerUsn)]); }
            if (!request.Attributes.Contains("objectSid")) { return Task.FromResult<IReadOnlyList<AdEntry>>([]); }
            objectRead = true;
            if (request.Filter.Contains(AdDirectoryMapper.UserFilter, StringComparison.Ordinal))
            {
                if (FailUsers) { throw new DomeniaOperationException(AdErrors.Failed, "Lecture utilisateurs interrompue."); }
                return Task.FromResult<IReadOnlyList<AdEntry>>([]);
            }
            var min = request.Filter.Contains("uSNChanged>=", StringComparison.Ordinal)
                ? long.Parse(request.Filter.Split("uSNChanged>=", StringSplitOptions.None)[1].Split(')')[0], CultureInfo.InvariantCulture) : 0;
            var rows = new List<AdEntry>();
            if (ComputerUsn >= min) { rows.Add(Entry(computer, "PC1", ComputerUsn)); }
            if (SecondComputer && 5 >= min) { rows.Add(Entry(other, "PC2", 5)); }
            return Task.FromResult<IReadOnlyList<AdEntry>>(rows);
        }
        private AdEntry Entry(Guid id, string name, long usn)
        {
            var sid = new SecurityIdentifier(Fixtures.Domain.DomainSid + "-1234"); var bytes = new byte[sid.BinaryLength]; sid.GetBinaryForm(bytes, 0);
            return new("CN=" + name + "," + Fixtures.Postes, new Dictionary<string, IReadOnlyList<object>>
            {
                ["objectGUID"] = [id.ToByteArray()], ["objectSid"] = [bytes], ["userAccountControl"] = ["4096"], ["name"] = [name],
                ["sAMAccountName"] = [name + "$"], ["dNSHostName"] = [name + ".test.local"], ["uSNChanged"] = [usn.ToString(CultureInfo.InvariantCulture)], ["description"] = [Description],
            });
        }
        public Task ModifyAsync(string distinguishedName, IReadOnlyList<AdModification> modifications, CancellationToken cancellationToken) => throw new InvalidOperationException("Écriture LDAP inattendue.");
        public Task RenameAsync(string distinguishedName, string newParentDn, string newRdn, CancellationToken cancellationToken) => throw new InvalidOperationException("Écriture LDAP inattendue.");
        public Task AddAsync(string distinguishedName, IReadOnlyDictionary<string, IReadOnlyList<object>> attributes, CancellationToken cancellationToken) => throw new InvalidOperationException("Écriture LDAP inattendue.");
        public Task DeleteAsync(string distinguishedName, CancellationToken cancellationToken) => throw new InvalidOperationException("Écriture LDAP inattendue.");
        public void Dispose() => basis.Dispose();
    }
}

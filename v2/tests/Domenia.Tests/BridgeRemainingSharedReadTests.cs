using System.Collections.Concurrent;
using System.Security.Principal;
using System.Text.Json;
using Domenia.Ad;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;
using Domenia.Store;

namespace Domenia.Tests;

internal static class BridgeRemainingSharedReadTests
{
    private static readonly string[] Names = ["fiche.lockouts", "fiche.logonByDc", "poste.logonByDc", "search.revalidate", "relations.targets.search"];
    private static TaskCompletionSource Signal() => new(TaskCreationOptions.RunContinuationsAsynchronously);

    [Test]
    public static void Remaining_shared_reads_require_identity_binding_and_never_enable_precommit_checks()
    {
        using var fixture = new Harness("fiche.lockouts");
        foreach (var name in Names)
        {
            var definition = BridgeScheduling.Declare(fixture.Definitions().Single(d => d.Name == name));
            Check.True(definition.ShareRead, "déclaration explicite : " + name);
            Check.Throws<ArgumentException>(() => new OperationRegistry([definition]), "pas de partage sans qualification de cible");
            var bound = BridgeReadIdentity.Bind(fixture.Context, definition);
            _ = new OperationRegistry([bound]);
            Check.NotNull(bound.CaptureReadIdentity, "vraie qualification locale raccordée");
            Check.Throws<BridgeOperationException>(() => BridgeScheduling.Target(bound.Scheduling!,
                JsonSerializer.SerializeToElement(new { dn = fixture.Dn, credential = "forbidden" })), "arguments fermés");
            var independent = BridgeReadIdentity.Bind(fixture.Context, definition with { ShareRead = false });
            Check.False(independent.ShareRead, "aucun opt-in implicite");
            Check.Null(independent.CaptureReadIdentity, "aucune capture attachée à une opération non partagée");
        }
        foreach (var name in new[] { "search.run", "search.browse", "search.preload", "search.survey.plan", "relations.check", "relations.link.plan", "write.execute" })
        {
            var declared = BridgeScheduling.Declare(new(name, OperationClass.NetworkRead, (_, _, _) => Task.FromResult<object?>(null), "fixture"));
            Check.False(declared.ShareRead, "aucun handle ni contrôle d’écriture ajouté : " + name);
        }
    }

    [Test]
    public static async Task Five_real_simulated_handlers_share_one_execution_and_keep_the_surviving_subscriber()
    {
        foreach (var name in Names)
        {
            using var fixture = new Harness(name); using var stop = new CancellationTokenSource();
            var first = fixture.Read("first", fixture.Arguments, stop.Token);
            await fixture.Started(1).WaitAsync(TimeSpan.FromSeconds(5));
            var second = fixture.Read("second", fixture.Arguments);
            try
            {
                await fixture.Admitted("second").WaitAsync(TimeSpan.FromSeconds(5));
                Check.Equal(1, fixture.Calls, "un handler réel : " + name);
                Check.Equal(1, PhysicalWorkBudget.Snapshot().Outstanding, "un bail physique jusqu’à la fin");
                stop.Cancel(); await first.WaitAsync(TimeSpan.FromSeconds(5));
                Check.Equal("operation.cancelled", fixture.Final("first").Error!.Code, "premier abonné seulement");
                Check.False(fixture.HandlerToken.IsCancellationRequested, "le second garde la lecture");
                fixture.Release.TrySetResult(); await second.WaitAsync(TimeSpan.FromSeconds(10));
                Check.Equal("result", fixture.Final("second").Kind, "le service réel termine : " + name);
                Check.NotNull(fixture.Final("second").Data, "projection réelle conservée");
                Check.Equal(1L, (await fixture.Queue()).SharedReadJoins, "rattachement réellement accepté");
                Check.Equal(0, PhysicalWorkBudget.Snapshot().Outstanding, "bail réellement terminé");
            }
            finally { fixture.Release.TrySetResult(); await Task.WhenAll(first, second); }
        }
    }

    [Test]
    public static async Task Every_remaining_route_retains_its_physical_permit_after_the_last_subscriber_cancels()
    {
        foreach (var name in Names)
        {
            using var fixture = new Harness(name); using var one = new CancellationTokenSource(); using var two = new CancellationTokenSource();
            var first = fixture.Read("one", fixture.Arguments, one.Token);
            await fixture.Started(1).WaitAsync(TimeSpan.FromSeconds(5));
            var second = fixture.Read("two", fixture.Arguments, two.Token);
            try
            {
                await fixture.Admitted("two").WaitAsync(TimeSpan.FromSeconds(5));
                one.Cancel(); two.Cancel(); await Task.WhenAll(first, second).WaitAsync(TimeSpan.FromSeconds(5));
                await fixture.Cancelled.Task.WaitAsync(TimeSpan.FromSeconds(5));
                Check.Equal(1, fixture.Dispatcher.AdmissionLoad.Running, "handler encore bloqué : " + name);
                Check.Equal(1, PhysicalWorkBudget.Snapshot().Outstanding, "annulation logique ne libère pas le physique");
                await fixture.Read("late", fixture.Arguments);
                Check.Equal("operation.sharedClosing", fixture.Final("late").Error!.Code, "pas de deuxième envoi pendant arrêt");
                Check.Equal(1L, (await fixture.Queue()).SharedReadJoins, "refus non compté comme rattachement");
            }
            finally { fixture.Release.TrySetResult(); await fixture.Finished.Task.WaitAsync(TimeSpan.FromSeconds(5)); }
            Check.Equal(0, PhysicalWorkBudget.Snapshot().Outstanding, "libération après sortie du vrai handler");
        }
    }

    [Test]
    public static async Task Different_lockout_windows_and_GUID_selections_are_distinct_reads()
    {
        foreach (var name in new[] { "fiche.lockouts", "search.revalidate", "relations.targets.search" })
        {
            using var fixture = new Harness(name);
            object other = name == "fiche.lockouts" ? new { dn = fixture.Dn, hours = 24 }
                : name == "relations.targets.search" ? new { dn = fixture.Dn, text = "unautre" }
                : new { ids = new[] { Guid.NewGuid().ToString("D") } };
            var first = fixture.Read("first", fixture.Arguments);
            await fixture.Started(1).WaitAsync(TimeSpan.FromSeconds(5));
            var second = fixture.Read("other", other);
            try
            {
                await fixture.Started(2).WaitAsync(TimeSpan.FromSeconds(5));
                Check.Equal(0L, (await fixture.Queue()).SharedReadJoins, "exigences distinctes");
            }
            finally { fixture.Release.TrySetResult(); await Task.WhenAll(first, second); }
            Check.Equal("result", fixture.Final("first").Kind, "première lecture réelle");
            Check.Equal("result", fixture.Final("other").Kind, "seconde lecture réelle");
        }
    }

    [Test]
    public static async Task A_DN_absent_from_the_local_index_is_never_given_a_shared_identity()
    {
        using var fixture = new Harness("fiche.logonByDc");
        var args = new { dn = "CN=Absent," + fixture.Simulation!.CurrentDirectory.Domain.RootDn };
        var first = fixture.Read("first", args);
        await fixture.Started(1).WaitAsync(TimeSpan.FromSeconds(5));
        var second = fixture.Read("second", args);
        try
        {
            await fixture.Started(2).WaitAsync(TimeSpan.FromSeconds(5));
            Check.Equal(0L, (await fixture.Queue()).SharedReadJoins, "pas de fausse identité déduite du nom");
        }
        finally { fixture.Release.TrySetResult(); await Task.WhenAll(first, second); }
        Check.Equal("fiche.identityChanged", fixture.Final("first").Error!.Code, "identité absente refusée localement avant lecture de diagnostic");
        Check.Equal("fiche.identityChanged", fixture.Final("second").Error!.Code, "second refus indépendant, pas de cache d’erreur partagé");
    }

    [Test]
    public static async Task Five_hundred_GUIDs_fit_the_bounded_envelope_but_handles_and_empty_GUIDs_are_rejected()
    {
        using var fixture = new Harness("search.revalidate");
        var ids = Enumerable.Range(0, 500).Select(_ => Guid.NewGuid().ToString("D")).ToArray();
        ids[0] = fixture.Simulation!.CurrentDirectory.Users.First().ObjectGuid.ToString("D");
        var args = new { ids };
        var length = JsonSerializer.Serialize(new { id = "first", op = "search.revalidate", args }).Length;
        Check.True(length > 16_384 && length < 32_768, "cas de 500 GUID réellement au-delà de l’ancienne borne");
        var first = fixture.Read("first", args);
        await fixture.Started(1).WaitAsync(TimeSpan.FromSeconds(5));
        var second = fixture.Read("second", args);
        try
        {
            await fixture.Admitted("second").WaitAsync(TimeSpan.FromSeconds(5));
            foreach (var invalid in new[] { "selection-handle", Guid.Empty.ToString("D") })
            {
                await fixture.Read("invalid", new { ids = new[] { invalid } });
                Check.Equal("arguments.invalid", fixture.Final("invalid").Error!.Code, "référence non qualifiée rejetée avant handler");
            }
            await fixture.Read("excess", new { ids = ids.Append(Guid.NewGuid().ToString("D")).ToArray() });
            Check.Equal("arguments.invalid", fixture.Final("excess").Error!.Code, "501 identités refusées");
            await fixture.Dispatcher.HandleAsync(JsonSerializer.Serialize(new { id = "oversize", op = "search.revalidate", args }) + new string(' ', 32_768), default);
            Check.Equal("operation.queuePayload", fixture.Final("oversize").Error!.Code, "plafond d’enveloppe 32 Kio toujours appliqué");
            Check.Equal(1, fixture.Calls, "aucun handler supplémentaire pour les entrées invalides");
            Check.Equal(1L, (await fixture.Queue()).SharedReadJoins, "seul le rattachement valide compté");
        }
        finally { fixture.Release.TrySetResult(); await Task.WhenAll(first, second); }
        var result = (SearchRevalidation)fixture.Final("second").Data!;
        Check.Equal(1, result.Rows.Length, "vrai objet relu");
        Check.Equal(499, result.Missing.Length, "absences explicites, jamais suppressions supposées");
    }

    [Test]
    public static async Task Native_revalidation_shares_one_real_GUID_query_and_returns_the_native_projection()
    {
        using var fixture = await NativeFixture.Create();
        using var harness = new Harness("search.revalidate", fixture.Context);
        var args = new { ids = new[] { fixture.User.ObjectGuid.ToString("D") } };
        fixture.Connection.Searches.Clear();
        var first = harness.Read("first", args);
        await harness.Started(1).WaitAsync(TimeSpan.FromSeconds(5));
        var second = harness.Read("second", args);
        try
        {
            await harness.Admitted("second").WaitAsync(TimeSpan.FromSeconds(5));
            Check.Equal(0, fixture.Connection.Searches.Count, "qualification locale sans recherche LDAP cachée");
            harness.Release.TrySetResult(); await Task.WhenAll(first, second).WaitAsync(TimeSpan.FromSeconds(10));
            Check.Equal(1, harness.Calls, "un seul handler de production");
            foreach (var id in new[] { "first", "second" })
            {
                Check.Equal("result", harness.Final(id).Kind, "résultat natif complet");
                var read = (SearchRevalidation)harness.Final(id).Data!;
                Check.Equal(fixture.User.ObjectGuid.ToString("D"), read.Rows.Single().Id, "GUID réellement relu");
                Check.Equal(0, read.Missing.Length, "aucune absence inventée");
            }
            Check.Equal(1, fixture.Connection.Searches.Count(q => q.Filter.Contains(AdObjectAccess.GuidFilter(fixture.User.ObjectGuid), StringComparison.Ordinal)),
                "une véritable requête GUID, pas seulement un compteur de handlers");
        }
        finally { harness.Release.TrySetResult(); await Task.WhenAll(first, second); }
    }

    [Test]
    public static async Task A_reassigned_DN_changes_the_key_without_an_epoch_change_and_refuses_the_old_result()
    {
        using var fixture = await NativeFixture.Create();
        var original = new FicheOperations().CreateOperations(fixture.Context).Single(d => d.Name == "fiche.logonByDc");
        var definition = BridgeReadIdentity.Bind(fixture.Context, BridgeScheduling.Declare(original));
        var args = JsonSerializer.SerializeToElement(new { dn = fixture.User.DistinguishedName });
        var before = await BridgeScheduling.Capture(fixture.Context, default);
        using var admission = new BridgeAdmission(fixture.Clock, token => BridgeScheduling.Capture(fixture.Context, token));
        using var first = await admission.EnterAsync("first", definition, args, default, () => { });
        await fixture.ReplaceLocalIdentity();
        Check.Equal(before, await BridgeScheduling.Capture(fixture.Context, default), "même source/session ; seul le vrai GUID local a changé");
        using var second = await admission.EnterAsync("second", definition, args, default, () => { });
        Check.False(first.Entry.SharedKey == second.Entry.SharedKey, "même DN, identités distinctes");
        Check.Equal(0L, admission.Snapshot().SharedReadJoins, "pas de rattachement à l’ancienne identité");
        var error = await Check.ThrowsAsync<BridgeOperationException>(() => admission.RevalidateAsync(first, default), "résultat ancien refusé");
        Check.Equal("operation.contextChanged", error.Code, "motif identité changé");
        await admission.RevalidateAsync(second, default);
        Check.Equal(0, fixture.Connection.Searches.Count, "index/qualification restent purement locaux");
    }

    [Test]
    public static async Task Cached_fiche_from_a_former_GUID_cannot_label_a_new_accounts_lockout_or_logon_read()
    {
        using var fixture = await NativeFixture.Create();
        var old = FicheEntry.Create(FicheKind.User, fixture.User.ObjectGuid, fixture.User.DistinguishedName, fixture.User.Cn,
            new Dictionary<string, IEnumerable<string?>> { ["objectGUID"] = [fixture.User.ObjectGuid.ToString("D")], ["objectSid"] = [fixture.User.Sid] });
        FicheSession.From(fixture.Context).BindOwner(await fixture.Context.Directory.GetSessionAsync(default));
        FicheSession.From(fixture.Context).KeepRead(new(old, fixture.Clock.GetUtcNow(), "fixture", 0));
        await fixture.ReplaceLocalIdentity();
        foreach (var name in new[] { "fiche.lockouts", "fiche.logonByDc" })
        {
            var operation = new FicheOperations().CreateOperations(fixture.Context).Single(d => d.Name == name);
            var error = await Check.ThrowsAsync<DomeniaOperationException>(() => operation.Handler(
                JsonSerializer.SerializeToElement(new { dn = fixture.User.DistinguishedName }), new(_ => { }, "cached", name), default), "fiche ancienne refusée");
            Check.Equal("fiche.identityChanged", error.Code, "aucun mélange GUID ancien et relevé du nouveau DN");
        }
        Check.Equal(0, fixture.Connection.Searches.Count, "aucun LDAP ni lecture 4740 lancé après refus local");
    }

    [Test]
    public static async Task Missing_deleted_or_ambiguous_local_identity_never_authorizes_diagnostics_from_the_session_cache()
    {
        foreach (var condition in new[] { "missing", "deleted", "ambiguous" })
        {
            using var fixture = await NativeFixture.Create(empty: condition == "missing");
            var old = FicheEntry.Create(FicheKind.User, fixture.User.ObjectGuid, fixture.User.DistinguishedName, fixture.User.Cn,
                new Dictionary<string, IEnumerable<string?>> { ["objectGUID"] = [fixture.User.ObjectGuid.ToString("D")], ["objectSid"] = [fixture.User.Sid] });
            var session = FicheSession.From(fixture.Context); session.BindOwner(await fixture.Context.Directory.GetSessionAsync(default));
            session.KeepRead(new(old, fixture.Clock.GetUtcNow(), "fixture", 0));
            if (condition == "deleted")
            {
                fixture.Clock.Advance(TimeSpan.FromSeconds(1));
                await fixture.Cache.ApplyDeletionAsync(new("user", "Compte", fixture.User.Cn, fixture.User.DistinguishedName,
                    fixture.User.ObjectGuid.ToString("D"), fixture.User.SamAccountName), fixture.Clock.GetUtcNow(), default);
            }
            if (condition == "ambiguous")
            {
                fixture.Clock.Advance(TimeSpan.FromSeconds(1));
                // The old GUID is deliberately first: a first-match preview must never qualify this DN.
                await fixture.Cache.SaveAsync(Fixtures.Snapshot(users: [fixture.User, fixture.User with { ObjectGuid = Guid.NewGuid() }]),
                    new(Fixtures.People, "Personnes", true), "DC1.test.local", default);
            }
            foreach (var name in new[] { "fiche.lockouts", "fiche.logonByDc" })
            {
                var operation = new FicheOperations().CreateOperations(fixture.Context).Single(d => d.Name == name);
                var error = await Check.ThrowsAsync<DomeniaOperationException>(() => operation.Handler(
                    JsonSerializer.SerializeToElement(new { dn = fixture.User.DistinguishedName }), new(_ => { }, "missing", name), default), "identité locale non qualifiée");
                Check.Equal("fiche.identityChanged", error.Code, condition + " : aucun ancien GUID autorisé pour " + name);
            }
            Check.Equal(0, fixture.Connection.Searches.Count, "aucun réseau pour tenter de contourner le refus local");
        }
    }

    [Test]
    public static async Task Two_equally_recent_GUIDs_at_one_DN_are_not_a_qualified_shared_target()
    {
        using var fixture = await NativeFixture.Create();
        await fixture.ReplaceLocalIdentity();
        var id = Guid.NewGuid();
        var concurrent = FicheEntry.Create(FicheKind.User, id, fixture.User.DistinguishedName, "Autre titulaire",
            new Dictionary<string, IEnumerable<string?>> { ["objectGUID"] = [id.ToString("D")], ["objectSid"] = [fixture.User.Sid] });
        await fixture.Cache.SaveFicheAsync(new(concurrent, fixture.Clock.GetUtcNow()), default);
        var identity = await BridgeReadIdentity.Capture(fixture.Context, "fiche.logonByDc",
            JsonSerializer.SerializeToElement(new { dn = fixture.User.DistinguishedName }), default);
        Check.Null(identity, "ambiguïté réelle de deux fiches locales au même instant");
        Check.Equal(0, fixture.Connection.Searches.Count, "aucune tentative LDAP pour résoudre implicitement l’ambiguïté");
    }

    [Test]
    public static async Task A_session_change_during_local_identity_capture_is_refused_before_the_handler()
    {
        using var fixture = new Harness("fiche.logonByDc", transform: (context, definition) => definition with
        {
            CaptureReadIdentity = async (args, token) =>
            {
                var identity = await definition.CaptureReadIdentity!(args, token);
                MachineAccountService.From(context).UseRemote(@"EXAMPLE\changed", null);
                return identity;
            }
        });
        await fixture.Read("changed", fixture.Arguments);
        Check.Equal("operation.contextChanged", fixture.Final("changed").Error!.Code, "deux stamps autour de la qualification");
        Check.Equal(0, fixture.Calls, "aucun handler envoyé");
        Check.Equal(0L, (await fixture.Queue()).SharedReadJoins, "aucun rattachement accepté");
    }

    [Test]
    public static async Task Cancelled_local_identity_captures_keep_the_existing_qualification_bound_until_they_end()
    {
        var entered = new ConcurrentDictionary<int, TaskCompletionSource>(); var release = Signal(); var finished = Signal(); var calls = 0; var ended = 0;
        using var fixture = new Harness("fiche.logonByDc", transform: (context, definition) => definition with
        {
            CaptureReadIdentity = async (args, token) =>
            {
                var result = await definition.CaptureReadIdentity!(args, token);
                entered.GetOrAdd(Interlocked.Increment(ref calls), _ => Signal()).TrySetResult();
                try { await release.Task; return result; }
                finally { if (Interlocked.Increment(ref ended) == BridgeAdmission.MaxPendingQualifications) { finished.TrySetResult(); } }
            }
        });
        try
        {
            for (var i = 1; i <= BridgeAdmission.MaxPendingQualifications; i++)
            {
                using var stop = new CancellationTokenSource();
                var request = fixture.Read("q" + i, fixture.Arguments, stop.Token);
                await entered.GetOrAdd(i, _ => Signal()).Task.WaitAsync(TimeSpan.FromSeconds(5));
                stop.Cancel(); await request.WaitAsync(TimeSpan.FromSeconds(5));
                Check.Equal("operation.cancelled", fixture.Final("q" + i).Error!.Code, "attente abandonnée");
            }
            await fixture.Read("overflow", fixture.Arguments);
            Check.Equal("operation.busy", fixture.Final("overflow").Error!.Code, "32 qualifications réellement encore actives");
            Check.Equal(BridgeAdmission.MaxPendingQualifications, calls, "pas de 33e appel caché");
            Check.Equal(0, fixture.Calls, "aucun transport physique lancé par la qualification");
        }
        finally { release.TrySetResult(); }
        await finished.Task.WaitAsync(TimeSpan.FromSeconds(5));
    }

    private sealed class Harness : IDisposable
    {
        internal readonly TaskCompletionSource Release = Signal(), Cancelled = Signal(), Finished = Signal();
        private readonly ConcurrentDictionary<int, TaskCompletionSource> starts = new();
        private readonly ConcurrentDictionary<string, TaskCompletionSource> admitted = new();
        private readonly ConcurrentQueue<BridgeResponse> responses = new();
        private readonly string name;
        private readonly bool ownsContext;
        private int request;
        internal readonly SimulatedDirectorySource? Simulation;
        internal readonly EngineContext Context;
        internal readonly BridgeDispatcher Dispatcher;
        internal CancellationToken HandlerToken;
        internal int Calls;
        internal string Dn { get; }
        internal object Arguments => name == "search.revalidate" ? new { ids = new[] { Simulation!.CurrentDirectory.Users.First().ObjectGuid.ToString("D") } }
            : name == "relations.targets.search" ? new { dn = Dn, text = "PC" } : new { dn = Dn };
        internal Harness(string name, EngineContext? context = null, Func<EngineContext, OperationDefinition, OperationDefinition>? transform = null)
        {
            this.name = name; ownsContext = context is null;
            if (context is null)
            {
                var clock = TestClock.Fixed(); Simulation = new(SimulationOptions.Default with { Latency = SimulationLatency.None }, clock);
                Context = new(SimulatedBridge.Decision, Simulation, new MemoryPreferenceStore(), clock, new RecordingJournal(),
                    ScreenReaders.Discover(Simulation, [typeof(SimulatedDirectorySource).Assembly]));
            }
            else { Context = context; }
            Dn = Simulation is null ? Fixtures.User("Alice").DistinguishedName : name == "poste.logonByDc"
                ? Simulation.CurrentDirectory.Computers.First().DistinguishedName : Simulation.CurrentDirectory.Users.First().DistinguishedName;
            var original = Definitions().Single(d => d.Name == name);
            var definition = BridgeReadIdentity.Bind(Context, BridgeScheduling.Declare(original with { Handler = async (args, bridge, token) =>
            {
                var physical = PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Directory);
                try
                {
                    using var cancellation = token.Register(() => Cancelled.TrySetResult());
                    HandlerToken = token; starts.GetOrAdd(Interlocked.Increment(ref Calls), _ => Signal()).TrySetResult();
                    await Release.Task; token.ThrowIfCancellationRequested(); return await original.Handler(args, bridge, token);
                }
                finally { physical.Dispose(); Finished.TrySetResult(); }
            } }));
            if (transform is not null) { definition = transform(Context, definition); }
            Dispatcher = new(new OperationRegistry([definition, .. BridgeQueueOperations.Definitions()], Context.Clock,
                token => BridgeScheduling.Capture(Context, token)), response =>
            {
                responses.Enqueue(response);
                if (response.Operation == name + ":admitted" && response.Id is { } id) { admitted.GetOrAdd(id, _ => Signal()).TrySetResult(); }
            });
        }
        internal IEnumerable<OperationDefinition> Definitions() => new FicheOperations().CreateOperations(Context).Concat(new PosteOperations().CreateOperations(Context))
            .Concat(new SearchOperations().CreateOperations(Context)).Concat(new RelationsOperations().CreateOperations(Context));
        internal Task Started(int number) => starts.GetOrAdd(number, _ => Signal()).Task;
        internal Task Admitted(string id) => admitted.GetOrAdd(id, _ => Signal()).Task;
        internal Task Read(string id, object args, CancellationToken token = default) => Send(id, name, args, token);
        private Task Send(string id, string operation, object args, CancellationToken token = default)
            => Dispatcher.HandleAsync(JsonSerializer.Serialize(new { id, op = operation, args }), token);
        internal BridgeResponse Final(string id) => responses.Last(r => r.Id == id && r.Kind is "result" or "error");
        internal async Task<BridgeQueueSnapshot> Queue()
        {
            var id = "queue" + Interlocked.Increment(ref request); await Send(id, "operations.queue.read", new { });
            return (BridgeQueueSnapshot)Final(id).Data!;
        }
        public void Dispose() { Release.TrySetResult(); Dispatcher.Dispose(); if (ownsContext) { Context.Dispose(); } }
    }

    private sealed class NativeFixture : IDisposable
    {
        private readonly TemporaryFolder folder = new();
        internal readonly FixedTimeProvider Clock = TestClock.Fixed();
        internal readonly DirectoryUser User = Fixtures.User("Alice");
        internal readonly AdBoundaryTests.RecordingAdConnection Connection = new();
        internal SqliteDirectoryCache Cache = null!;
        internal AdDirectorySource Source = null!;
        internal EngineContext Context = null!;
        internal static async Task<NativeFixture> Create(bool empty = false)
        {
            var fixture = new NativeFixture();
            try
            {
                var database = new DomeniaDatabase(fixture.folder.File("identities.db"), Fixtures.Root, fixture.Clock);
                await database.InitializeAsync(default); fixture.Cache = new(database);
                await fixture.Cache.SaveAsync(Fixtures.Snapshot(users: empty ? [] : [fixture.User]), new(Fixtures.People, "Personnes", true), "DC1.test.local", default);
                var sid = new SecurityIdentifier(fixture.User.Sid!); var bytes = new byte[sid.BinaryLength]; sid.GetBinaryForm(bytes, 0);
                var entry = new AdEntry(fixture.User.DistinguishedName, new Dictionary<string, IReadOnlyList<object>>
                {
                    ["objectGUID"] = [fixture.User.ObjectGuid.ToByteArray()], ["objectClass"] = ["user"], ["objectSid"] = [bytes],
                    ["name"] = [fixture.User.Cn], ["sAMAccountName"] = [fixture.User.SamAccountName], ["userAccountControl"] = ["512"]
                });
                fixture.Connection.SearchAnswer = query => query.Filter.Contains(AdObjectAccess.GuidFilter(fixture.User.ObjectGuid), StringComparison.Ordinal) ? [entry] : [];
                fixture.Source = new("test.local", () => @"TEST\adm", fixture.Clock, connection: fixture.Connection, localStore: fixture.Cache);
                fixture.Context = new(new(AppMode.Directory, ModeReason.Argument, "Transport de test local", null, "test.local", []), fixture.Source,
                    new MemoryPreferenceStore(), fixture.Clock, new RecordingJournal(), ScreenReaders.Discover(fixture.Source, [typeof(AdDirectorySource).Assembly]));
                await fixture.Source.DomainAsync(default); await fixture.Source.GetSessionAsync(default);
                fixture.Connection.Searches.Clear();
                return fixture;
            }
            catch { fixture.Dispose(); throw; }
        }
        internal async Task ReplaceLocalIdentity()
        {
            Clock.Advance(TimeSpan.FromSeconds(1));
            var id = Guid.NewGuid();
            var replacement = FicheEntry.Create(FicheKind.User, id, User.DistinguishedName, "Nouveau titulaire",
                new Dictionary<string, IEnumerable<string?>> { ["objectGUID"] = [id.ToString("D")], ["objectSid"] = [User.Sid] });
            await Cache.SaveFicheAsync(new(replacement, Clock.GetUtcNow()), default);
        }
        public void Dispose() { Context?.Dispose(); Source?.Dispose(); Connection.Dispose(); folder.Dispose(); }
    }
}

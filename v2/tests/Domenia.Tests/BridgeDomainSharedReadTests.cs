using System.Collections.Concurrent;
using System.Security;
using System.Security.Principal;
using System.Text.Json;
using Domenia.Ad;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;
using Domenia.Store;

namespace Domenia.Tests;

internal static class BridgeDomainSharedReadTests
{
    private static TaskCompletionSource Signal() => new(TaskCreationOptions.RunContinuationsAsynchronously);
    private static readonly string[] Added = ["audit.overview", "audit.dc.compare", "audit.dc.services", "audit.object.policy",
        "audit.object.groups", "audit.object.membership", "audit.object.acl", "audit.object.gpoLinks", "audit.object.gpoApplied",
        "audit.object.machineIdentity", "audit.object.history", "audit.identities.scan", "fiche.read", "poste.sessions"];

    [Test]
    public static void Shared_domain_reads_are_closed_server_declarations_without_enabling_handles_or_writes()
    {
        using var fixture = new Fixture("audit.object.policy");
        var definitions = fixture.Definitions().ToDictionary(d => d.Name);
        foreach (var name in Added)
        {
            var declared = BridgeScheduling.Declare(definitions[name]);
            Check.True(declared.ShareRead && BridgeScheduling.Eligible(declared), "contrat réel explicitement déclaré : " + name);
            Check.True(declared.Scheduling!.ReplacementKey is null, "aucun remplacement de sélection partagé");
            _ = new OperationRegistry([declared]);
            Check.Throws<BridgeOperationException>(() => BridgeScheduling.Target(declared.Scheduling,
                JsonSerializer.SerializeToElement(new { credential = "forbidden" })), "argument sensible impossible avant rattachement");
        }
        foreach (var name in new[] { "search.run", "search.browse", "search.view", "search.preload", "fiche.callSheet.read", "poste.restart.sessions", "write.execute" })
        {
            var value = BridgeScheduling.Declare(new(name, OperationClass.NetworkRead, (_, _, _) => Task.FromResult<object?>(null), "fixture"));
            Check.False(value.ShareRead, "aucune généralisation par préfixe : " + name);
            Check.Throws<ArgumentException>(() => new OperationRegistry([value with { ShareRead = true }]), "aucun opt-in extérieur à la liste fermée");
        }
    }

    [Test]
    public static async Task Real_audit_fiche_and_sessions_handlers_run_once_and_survive_first_subscriber_cancellation()
    {
        foreach (var name in new[] { "audit.object.policy", "fiche.read", "poste.sessions" })
        {
            using var fixture = new Fixture(name); using var stop = new CancellationTokenSource();
            var arguments = fixture.Arguments;
            var first = fixture.Read("first", arguments, stop.Token);
            await fixture.Started(1).WaitAsync(TimeSpan.FromSeconds(5));
            var second = fixture.Read("second", arguments);
            try
            {
                await fixture.Admitted("second").WaitAsync(TimeSpan.FromSeconds(5));
                Check.Equal(1, fixture.Calls, "une seule entrée du vrai handler " + name);
                Check.Equal(1, fixture.Dispatcher.AdmissionLoad.Running, "une admission pour deux abonnés");
                Check.Equal(1, PhysicalWorkBudget.Snapshot().Outstanding, "un seul transport fixture détenu");
                stop.Cancel(); await first.WaitAsync(TimeSpan.FromSeconds(5));
                Check.Equal("operation.cancelled", fixture.Final("first").Error!.Code, "seul le premier abonné est annulé");
                Check.False(fixture.HandlerToken.IsCancellationRequested, "le survivant conserve la lecture réelle");
                fixture.Release.TrySetResult(); await second.WaitAsync(TimeSpan.FromSeconds(10));
                Check.Equal("result", fixture.Final("second").Kind, "le vrai service répond au survivant");
                Check.NotNull(fixture.Final("second").Data, "résultat réel non remplacé par une valeur de fixture");
                Check.Equal(1L, (await fixture.Queue()).SharedReadJoins, "un rattachement observé, conservé après achèvement");
                Check.Equal(0, PhysicalWorkBudget.Snapshot().Outstanding, "ressource libérée après achèvement du handler");
            }
            finally { fixture.Release.TrySetResult(); await Task.WhenAll(first, second); }
        }
    }

    [Test]
    public static async Task Sessions_last_subscriber_keeps_the_physical_slot_until_the_handler_stops()
    {
        using var fixture = new Fixture("poste.sessions"); using var one = new CancellationTokenSource(); using var two = new CancellationTokenSource();
        var first = fixture.Read("first", fixture.Arguments, one.Token);
        await fixture.Started(1).WaitAsync(TimeSpan.FromSeconds(5));
        var second = fixture.Read("second", fixture.Arguments, two.Token);
        try
        {
            await fixture.Admitted("second").WaitAsync(TimeSpan.FromSeconds(5));
            one.Cancel(); two.Cancel(); await Task.WhenAll(first, second).WaitAsync(TimeSpan.FromSeconds(5));
            await fixture.Cancelled.Task.WaitAsync(TimeSpan.FromSeconds(5));
            Check.Equal(1, fixture.Dispatcher.AdmissionLoad.Running, "attente annulée ne libère pas l’exécution encore bloquée");
            Check.Equal(1, PhysicalWorkBudget.Snapshot().Outstanding, "transport encore détenu");
            await fixture.Read("late", fixture.Arguments);
            Check.Equal("operation.sharedClosing", fixture.Final("late").Error!.Code, "aucun deuxième envoi pendant nettoyage");
            Check.Equal(1L, (await fixture.Queue()).SharedReadJoins, "le rattachement refusé n’incrémente rien");
        }
        finally { fixture.Release.TrySetResult(); await fixture.Finished.Task.WaitAsync(TimeSpan.FromSeconds(5)); }
        Check.Equal(0, PhysicalWorkBudget.Snapshot().Outstanding, "transport réellement fermé");
    }

    [Test]
    public static async Task Different_fiche_payloads_never_share_and_invalid_payloads_do_not_increment_joins()
    {
        using var fixture = new Fixture("fiche.read");
        var first = fixture.Read("first", fixture.Arguments);
        await fixture.Started(1).WaitAsync(TimeSpan.FromSeconds(5));
        var other = fixture.Read("other", new { dn = fixture.Dn, reread = true });
        try
        {
            await fixture.Started(2).WaitAsync(TimeSpan.FromSeconds(5));
            await fixture.Read("secret", new { dn = fixture.Dn, credential = "not retained" });
            await fixture.Read("live", new { dn = new { value = fixture.Dn } });
            Check.Equal("arguments.invalid", fixture.Final("secret").Error!.Code, "schéma fermé avant partage");
            Check.Equal("arguments.invalid", fixture.Final("live").Error!.Code, "objet opaque interdit");
            Check.Equal(2, fixture.Calls, "les deux exigences de relecture distinctes ont chacune leur handler");
            Check.Equal(0L, (await fixture.Queue()).SharedReadJoins, "ni demande distincte ni demande refusée comptée comme partagée");
        }
        finally { fixture.Release.TrySetResult(); await Task.WhenAll(first, other); }
        Check.Equal("result", fixture.Final("first").Kind, "premier vrai service terminé");
        Check.Equal("result", fixture.Final("other").Kind, "relecture explicite distincte terminée");
    }

    [Test]
    public static async Task Actual_account_epoch_working_scope_and_machine_generation_changes_reject_old_shared_results()
    {
        foreach (var change in new[] { "account", "scope", "machine" })
        {
            using var fixture = new Fixture("audit.object.policy");
            var first = fixture.Read("first", fixture.Arguments);
            await fixture.Started(1).WaitAsync(TimeSpan.FromSeconds(5));
            var before = await BridgeScheduling.Capture(fixture.Context, default);
            if (change == "account")
            {
                using var password = new SecureString(); var reader = new SimulatedAccountsReader(fixture.Source);
                var epoch = fixture.Source.CurrentSession.Epoch;
                foreach (var user in fixture.Source.CurrentDirectory.Users)
                {
                    await reader.OpenSessionAsync(new(fixture.Source.CurrentDirectory.Domain.NetbiosName + "\\" + user.SamAccountName,
                        CredentialRules.Directory, null), password, default);
                    if (fixture.Source.CurrentSession.Epoch != epoch) { break; }
                }
                Check.True(fixture.Source.CurrentSession.Epoch != epoch, "nouvelle session réellement ouverte par le lecteur de comptes");
            }
            else if (change == "machine") { MachineAccountService.From(fixture.Context).UseRemote("EXAMPLE\\fixture-remote", null); }
            else
            {
                var session = await fixture.Source.GetSessionAsync(default);
                var scope = WorkingScope.From(fixture.Context); var current = await scope.CurrentAsync(session, default);
                const string paris = "OU=Paris,OU=Postes,DC=example,DC=local";
                await scope.SetAsync(session, current?.Dn == paris ? "OU=Postes,DC=example,DC=local" : paris, true, default);
            }
            var after = await BridgeScheduling.Capture(fixture.Context, default);
            Check.True(before.Identity != after.Identity, "le vrai contexte a changé, sans empreinte fabriquée");
            var second = fixture.Read("second", fixture.Arguments);
            try
            {
                await fixture.Started(2).WaitAsync(TimeSpan.FromSeconds(5));
                Check.Equal(0L, (await fixture.Queue()).SharedReadJoins, "deux contextes incompatibles n’ont pas été réunis");
            }
            finally { fixture.Release.TrySetResult(); await Task.WhenAll(first, second); }
            Check.Equal("operation.contextChanged", fixture.Final("first").Error!.Code, "pas de succès tardif de l’ancien contexte");
            Check.Equal("result", fixture.Final("second").Kind, "le contexte actuel reçoit le résultat réel");
        }
    }

    [Test]
    public static async Task Health_reports_observed_bridge_joins_without_inventing_avoided_queries_or_absent_queue()
    {
        using var fixture = new Fixture("audit.object.policy");
        Check.Equal(0L, (await fixture.Queue()).SharedReadJoins, "aucun partage inventé à partir de la déclaration");
        var first = fixture.Read("first", fixture.Arguments);
        await fixture.Started(1).WaitAsync(TimeSpan.FromSeconds(5));
        var second = fixture.Read("second", fixture.Arguments);
        try
        {
            await fixture.Admitted("second").WaitAsync(TimeSpan.FromSeconds(5));
            await fixture.Send("health", "operations.health", new { });
            var health = (EngineHealth)fixture.Final("health").Data!;
            Check.True(health.Collection.Any(line => line.Contains("Rattachements", StringComparison.Ordinal) && line.Contains("1.", StringComparison.Ordinal)), "compteur réellement raccordé à la fenêtre");
            Check.True(health.Collection.Any(line => line.Contains("ne prouve ni succès", StringComparison.Ordinal)), "interprétation exacte du compteur");
            Check.False(health.Collection.Any(line => line.Contains("sans file d’attente", StringComparison.Ordinal) || line.Contains("faute de file", StringComparison.Ordinal)), "ancienne affirmation devenue fausse retirée");
        }
        finally { fixture.Release.TrySetResult(); await Task.WhenAll(first, second); }
    }

    [Test]
    public static async Task Shared_policy_reaches_the_real_native_reader_with_only_one_LDAP_policy_query()
    {
        using var folder = new TemporaryFolder(); var clock = TestClock.Fixed(); var user = Fixtures.User("Alice");
        var database = new DomeniaDatabase(folder.File("audit.db"), Fixtures.Root, clock);
        await database.InitializeAsync(default);
        var cache = new SqliteDirectoryCache(database);
        await cache.SaveAsync(Fixtures.Snapshot(users: [user]), new(Fixtures.People, "Personnes", true), "DC1.test.local", default);
        var sid = new SecurityIdentifier(user.Sid!); var sidBytes = new byte[sid.BinaryLength]; sid.GetBinaryForm(sidBytes, 0);
        using var connection = new AdBoundaryTests.RecordingAdConnection
        {
            SearchAnswer = query => query.Scope != AdSearchScope.Base ? [] : query.BaseDn == user.DistinguishedName
                ? [new(query.BaseDn, new Dictionary<string, IReadOnlyList<object>>
                {
                    ["objectGUID"] = [user.ObjectGuid.ToByteArray()], ["objectClass"] = ["user"], ["objectSid"] = [sidBytes],
                    ["name"] = [user.Cn], ["sAMAccountName"] = [user.SamAccountName], ["userAccountControl"] = ["512"],
                    ["pwdLastSet"] = [user.PasswordLastSet!.Value.ToString(System.Globalization.CultureInfo.InvariantCulture)]
                })]
                : [],
        };
        using var source = new AdDirectorySource("test.local", () => @"TEST\adm", clock, connection: connection, localStore: cache);
        using var context = new EngineContext(new(AppMode.Directory, ModeReason.Argument, "Fixture native locale", null, "test.local", []),
            source, new MemoryPreferenceStore(), clock, new RecordingJournal(), ScreenReaders.Discover(source, [typeof(AdDirectorySource).Assembly]));
        // Bootstrap the real session/cache before counting the physical policy read.
        await source.GetSessionAsync(default); connection.Searches.Clear();
        var original = new AuditOperations().CreateOperations(context).Single(d => d.Name == "audit.object.policy");
        var entered = Signal(); var release = Signal(); var joined = Signal(); var calls = 0;
        var definition = BridgeScheduling.Declare(original with { Handler = async (args, bridge, token) =>
        {
            Interlocked.Increment(ref calls); entered.TrySetResult(); await release.Task;
            return await original.Handler(args, bridge, token);
        } });
        var responses = new ConcurrentQueue<BridgeResponse>();
        using var dispatcher = new BridgeDispatcher(new OperationRegistry([definition], clock, token => BridgeScheduling.Capture(context, token)), response =>
        {
            responses.Enqueue(response);
            if (response.Id == "second" && response.Operation == "audit.object.policy:admitted") { joined.TrySetResult(); }
        });
        string Request(string id) => JsonSerializer.Serialize(new { id, op = "audit.object.policy", args = new { dn = user.DistinguishedName } });
        var first = dispatcher.HandleAsync(Request("first"), default);
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var second = dispatcher.HandleAsync(Request("second"), default);
        try
        {
            await joined.Task.WaitAsync(TimeSpan.FromSeconds(5));
            release.TrySetResult(); await Task.WhenAll(first, second).WaitAsync(TimeSpan.FromSeconds(10));
            Check.Equal(1, calls, "un seul handler de production invoqué");
            foreach (var id in new[] { "first", "second" })
            {
                var final = responses.Last(r => r.Id == id && r.Kind is "result" or "error");
                Check.Equal("result", final.Kind, "lecture native réellement aboutie pour " + id);
                Check.True(final.Data is AuditPolicy, "projection native complète renvoyée à chaque abonné");
            }
            Check.Equal(1, connection.Searches.Count(q => q.BaseDn == user.DistinguishedName && q.Attributes.Contains("msDS-ResultantPSO")),
                "une seule lecture LDAP des attributs de stratégie, pas seulement un handler artificiel");
        }
        finally { release.TrySetResult(); await Task.WhenAll(first, second); }
    }

    private sealed class Fixture : IDisposable
    {
        internal readonly TaskCompletionSource Release = Signal(), Cancelled = Signal(), Finished = Signal();
        private readonly ConcurrentDictionary<int, TaskCompletionSource> starts = new();
        private readonly ConcurrentDictionary<string, TaskCompletionSource> admitted = new();
        private readonly ConcurrentQueue<BridgeResponse> responses = new();
        private int request;
        private readonly string operation;
        internal readonly SimulatedDirectorySource Source;
        internal readonly EngineContext Context;
        internal readonly BridgeDispatcher Dispatcher;
        internal CancellationToken HandlerToken;
        internal int Calls;
        internal string Dn { get; }
        internal object Arguments => new { dn = Dn };
        internal Fixture(string operation)
        {
            this.operation = operation; var clock = TestClock.Fixed();
            Source = new(SimulationOptions.Default with { Latency = SimulationLatency.None }, clock);
            Context = new(SimulatedBridge.Decision, Source, new MemoryPreferenceStore(), clock, new RecordingJournal(),
                ScreenReaders.Discover(Source, [typeof(SimulatedDirectorySource).Assembly]));
            Dn = operation == "poste.sessions" ? Source.CurrentDirectory.Computers.First().DistinguishedName : Source.CurrentDirectory.Users.First().DistinguishedName;
            var original = Definitions().Single(d => d.Name == operation);
            var definition = BridgeScheduling.Declare(original with { Handler = async (args, bridge, token) =>
            {
                var physical = PhysicalWorkBudget.Acquire(operation == "poste.sessions" ? PhysicalWorkRoute.Wts : PhysicalWorkRoute.Directory);
                try
                {
                    using var cancellation = token.Register(() => Cancelled.TrySetResult());
                    HandlerToken = token; var call = Interlocked.Increment(ref Calls); starts.GetOrAdd(call, _ => Signal()).TrySetResult();
                    await Release.Task; token.ThrowIfCancellationRequested(); return await original.Handler(args, bridge, token);
                }
                finally { physical.Dispose(); Finished.TrySetResult(); }
            } });
            var health = new OperationsOperations().CreateOperations(Context).Single(d => d.Name == "operations.health");
            Dispatcher = new(new OperationRegistry([definition, health, .. BridgeQueueOperations.Definitions()], clock, token => BridgeScheduling.Capture(Context, token)), response =>
            {
                responses.Enqueue(response);
                if (response.Operation == operation + ":admitted" && response.Id is { } id) { admitted.GetOrAdd(id, _ => Signal()).TrySetResult(); }
            });
        }
        internal IEnumerable<OperationDefinition> Definitions() => new AuditOperations().CreateOperations(Context)
            .Concat(new FicheOperations().CreateOperations(Context)).Concat(new PosteOperations().CreateOperations(Context));
        internal Task Started(int number) => starts.GetOrAdd(number, _ => Signal()).Task;
        internal Task Admitted(string id) => admitted.GetOrAdd(id, _ => Signal()).Task;
        internal Task Read(string id, object args, CancellationToken token = default) => Send(id, operation, args, token);
        internal Task Send(string id, string name, object args, CancellationToken token = default)
            => Dispatcher.HandleAsync(JsonSerializer.Serialize(new { id, op = name, args }), token);
        internal BridgeResponse Final(string id) => responses.Last(r => r.Id == id && r.Kind is "result" or "error");
        internal async Task<BridgeQueueSnapshot> Queue()
        {
            var id = "queue" + Interlocked.Increment(ref request); await Send(id, "operations.queue.read", new { });
            return (BridgeQueueSnapshot)Final(id).Data!;
        }
        public void Dispose() { Release.TrySetResult(); Dispatcher.Dispose(); Context.Dispose(); }
    }
}

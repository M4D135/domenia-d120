using System.Collections.Immutable;
using System.Security;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Core.Queries;
using Domenia.Inventory;
using ProbeReading = Domenia.Core.Accueil.ProbeReading;

namespace Domenia.Tests;

internal static class PostePersonalProbeNativeTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static readonly TimeSpan Guard = TimeSpan.FromSeconds(10);
    private static WmiInstance Row(params (string Key, object? Value)[] values) => new(values.ToDictionary(v => v.Key, v => v.Value));

    [Test]
    public static async Task Actual_Poste_reader_qualifies_AD_CIM_and_cache_without_any_ping_and_keeps_the_full_version_key()
    {
        using var fixture = await Fixture.Create(); var queries = new List<string>();
        var reader = fixture.Reader(query =>
        {
            queries.Add(query);
            return query.Contains("DomainRole", StringComparison.Ordinal) ? [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"), ("DomainRole", 1))]
                : [Row(("Manufacturer", "Fabricant lu"))];
        });
        var result = await reader.CollectPersonalProbeAsync(fixture.Request(), None);
        Check.Equal(MeasureState.Known, result.Reading.State, "lecture confirmée par le consommateur Poste");
        Check.True(queries.SequenceEqual(new[] { "SELECT Name, DNSHostName, Domain, DomainRole FROM Win32_ComputerSystem", "SELECT Manufacturer FROM Win32_ComputerSystem" }), "seule projection de la version confirmée");
        Check.Equal(2, fixture.Ldap.Searches.Count(q => q.Filter == "(objectClass=computer)"), "qualification AD avant et après");
        Check.True(fixture.Source.CurrentObservations.Workstations.IsEmpty, "aucun ping exigé ou enregistré");
        var local = await new AdAccueilReader(fixture.Source).StoredProbesAsync(None);
        Check.Equal("Fabricant lu", local.ByProbe[fixture.Probe.Key][fixture.Computer.ObjectGuid].Values.Single(), "même cache scalaire relu depuis le lecteur local");
        Check.False(local.ByProbe.ContainsKey(fixture.Probe.Definition.Id), "alias jamais utilisé pour les valeurs");
    }

    [Test]
    public static async Task Stale_plan_tampering_disabled_CIM_and_missing_profile_definition_refuse_before_LDAP_or_CIM()
    {
        using var fixture = await Fixture.Create(); var native = 0;
        var reader = fixture.Reader(_ => { native++; return []; });
        var request = fixture.Request();
        foreach (var changed in new[]
        {
            request with { Epoch = request.Epoch + 1 },
            request with { Computer = request.Computer with { Host = "other.test.local" } },
            request with { StoreId = "another-store" },
            request with { MachineGeneration = request.MachineGeneration + 1 },
            request with { Configuration = request.Configuration with { UseCim = false } },
            request with { Probe = fixture.Probe with { Definition = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document("Model")).Single().Definition } },
        })
        { await Check.ThrowsAsync<DomeniaOperationException>(() => reader.CollectPersonalProbeAsync(changed, None), "plan altéré refusé"); }
        await fixture.Context.Preferences.SetAsync(PersonalProbeCatalog.PreferenceKey, System.Text.Json.JsonSerializer.SerializeToElement<object?>(null), None);
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.CollectPersonalProbeAsync(request, None), "définition absente refusée même avec copie figée");
        Check.Equal(0, native, "aucune session CIM");
        Check.Equal(0, fixture.Ldap.Calls, "aucune qualification réseau après refus local");
    }

    [Test]
    public static async Task Reader_without_current_profile_refuses_even_a_valid_frozen_definition_before_any_contact()
    {
        var computer = Fixtures.Computer("PC1"); var probe = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document()).Single();
        var cache = new AdAccueilTests.FleetCache(Fixtures.Snapshot(computers: [computer]));
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        await source.ReadLocalAsync(None);
        var request = new PostePersonalProbeRequest(probe, QueryComputerIdentity.Of(computer), source.Epoch, cache.Fleet.Facts.StoreId, 0, 0, PosteConfiguration.Defaults);
        var reader = new AdPosteReader(source)
        { PersonalProbeReaderOverride = new WmiFleetProbeReader(source.Clock) { SessionFactory = (_, _, _) => throw new TestFailureException("Aucun fournisseur sans profil.") } };
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.CollectPersonalProbeAsync(request, None), "catalogue de profil installé requis à la frontière native");
        Check.Equal(0, ldap.Calls, "aucun LDAP sans contexte courant");
        Check.True(cache.Fleet.Probes.ByProbe.IsEmpty, "aucune définition cachée à partir du cache");
    }

    [Test]
    public static async Task Changed_AD_identity_or_controller_role_blocks_the_projection_or_its_publication()
    {
        using var fixture = await Fixture.Create(); var native = 0;
        var reader = fixture.Reader(query =>
        {
            native++;
            if (query.Contains("DomainRole", StringComparison.Ordinal)) return [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"), ("DomainRole", 1))];
            fixture.Live = fixture.Computer with { UserAccountControl = AdValues.ServerTrustAccount };
            return [Row(("Manufacturer", "Ne pas publier"))];
        });
        fixture.Live = fixture.Computer with { DnsHostName = "other.test.local" };
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.CollectPersonalProbeAsync(fixture.Request(), None), "cible AD remplacée avant CIM");
        Check.Equal(0, native, "aucune projection après substitution DNS");
        fixture.Live = fixture.Computer;
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.CollectPersonalProbeAsync(fixture.Request(), None), "rôle AD changé pendant la lecture");
        Check.True(fixture.Cache.Fleet.Probes.ByProbe.IsEmpty, "résultat non attribué après changement final UAC");
        fixture.Live = fixture.Computer;
        var dcReader = fixture.Reader(query => query.Contains("DomainRole", StringComparison.Ordinal)
            ? [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"), ("DomainRole", 5))] : throw new TestFailureException("Aucune projection personnelle sur DC CIM."));
        var excluded = await dcReader.CollectPersonalProbeAsync(fixture.Request(), None);
        Check.Equal(MeasureState.NotRead, excluded.Reading.State, "DC confirmé par CIM exclu même si le cache AD indique poste");
    }

    [Test]
    public static async Task Stop_waits_for_physical_worker_and_saves_only_a_local_incomplete_result_without_final_LDAP()
    {
        using var fixture = await Fixture.Create(); using var stop = new CancellationTokenSource(); using var release = new ManualResetEventSlim();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var reader = fixture.Reader(query =>
        {
            if (query.Contains("DomainRole", StringComparison.Ordinal)) return [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"), ("DomainRole", 1))];
            entered.TrySetResult();
            if (!release.Wait(Guard)) throw new TestFailureException("Le test n’a pas libéré son fournisseur.");
            return [Row(("Manufacturer", "Valeur tardive"))];
        });
        var work = reader.CollectPersonalProbeAsync(fixture.Request(), stop.Token);
        var beforeStop = 0;
        try
        {
            await entered.Task.WaitAsync(Guard); beforeStop = fixture.Ldap.Calls; await stop.CancelAsync();
            var finished = await Task.WhenAny(work, Task.Delay(TimeSpan.FromMilliseconds(75)));
            Check.False(ReferenceEquals(work, finished), "arrêt logique sans restitution prématurée");
            Check.True(fixture.Cache.Fleet.Probes.ByProbe.IsEmpty, "aucun faux commit tant que le fournisseur tourne");
        }
        finally { release.Set(); }
        await Check.ThrowsAsync<OperationCanceledException>(() => work.WaitAsync(Guard), "annulation rendue après fin physique et enregistrement");
        Check.Equal(beforeStop, fixture.Ldap.Calls, "aucune nouvelle qualification AD après arrêt");
        var value = fixture.Cache.Fleet.Probes.ByProbe[fixture.Probe.Key][fixture.Computer.ObjectGuid];
        Check.True(value.State != MeasureState.Known, "réponse arrêtée jamais qualifiée complète");
        Check.Contains("qualification AD finale", value.Error!, "limite de la mesure conservée");
    }

    [Test]
    public static async Task One_shot_machine_account_survives_passive_UI_poll_during_the_native_read_without_a_second_selection()
    {
        using var fixture = await Fixture.Create(); var machine = MachineAccountService.From(fixture.Context);
        var session = await fixture.Source.GetSessionAsync(None);
        using var secret = Password(); machine.AcceptTemporary(session, null, @"TEST\once", secret.Copy(), MachineLeaseMode.OneShot);
        _ = machine.Resolve(session, fixture.Computer.DnsHostName);
        var request = fixture.Request();
        var reader = fixture.Reader(query =>
        {
            // A passive UI check sweeps the consumed slot. It must not invalidate the owned credential.
            _ = machine.Resolve(session, fixture.Computer.DnsHostName);
            return query.Contains("DomainRole", StringComparison.Ordinal) ? [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"), ("DomainRole", 1))]
                : [Row(("Manufacturer", "Bail unique gardé"))];
        });
        var result = await reader.CollectPersonalProbeAsync(request, None);
        Check.Equal("Bail unique gardé", result.Reading.Values.Single(), "lecture admise reste qualifiée après le balayage UI");
        Check.Equal(machine.Generation, result.MachineGeneration, "génération réellement retenue rendue pour la relecture locale");
        Check.True(machine.Resolve(session, fixture.Computer.DnsHostName).Source != MachineAccountSource.Temporary, "bail consommé non disponible pour un autre relevé");
    }

    [Test]
    public static async Task One_shot_LDAP_account_is_admitted_before_the_ordinary_machine_account_and_survives_passive_polling()
    {
        using var fixture = await Fixture.Create(directoryAccounts: true);
        await fixture.RecoverAsync(CredentialRules.Directory, @"TEST\directory-once");
        var accounts = AccountAccess.From(fixture.Context); var machine = MachineAccountService.From(fixture.Context);
        var session = await fixture.Source.GetSessionAsync(None);
        _ = machine.Resolve(session, fixture.Computer.DnsHostName);
        var preview = await accounts.PreviewDirectoryReadAsync(CredentialRules.Directory, fixture.Computer.DistinguishedName, None);
        Check.True(preview.OneShot, "aperçu local du bail LDAP sans consommation");
        Check.Equal(preview, await accounts.PreviewDirectoryReadAsync(CredentialRules.Directory, fixture.Computer.DistinguishedName, None), "second aperçu sans changement de choix");
        var request = fixture.Request(); var projections = 0;
        var reader = fixture.Reader(query =>
        {
            Check.Equal(@"TEST\probe", machine.Resolve(session, fixture.Computer.DnsHostName).Account, "compte machine ordinaire inchangé au contrôle UI");
            if (query.Contains("DomainRole", StringComparison.Ordinal)) return [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"), ("DomainRole", 1))];
            projections++;
            return [Row(("Manufacturer", "LDAP unique conservé"))];
        });
        var result = await reader.CollectPersonalProbeAsync(request, None);
        Check.Equal("LDAP unique conservé", result.Reading.Values.Single(), "sonde personnelle lue avec les deux accès détenus");
        Check.Equal(1, projections, "une projection et aucun nouvel essai");
        Check.True(fixture.LdapSelections.SequenceEqual(new[] { @"TEST\directory-once" }), "une seule copie du compte LDAP sélectionné");
        Check.Equal(2, fixture.Ldap.Searches.Count(q => q.Filter == "(objectClass=computer)"), "le même accès LDAP qualifie avant et après CIM");
        Check.False((await accounts.PreviewDirectoryReadAsync(CredentialRules.Directory, fixture.Computer.DistinguishedName, None)).OneShot, "bail unique indisponible pour un autre départ");
        Check.Equal(accounts.SelectionVersion, result.AccountVersion, "génération admise renvoyée pour le cache");
        Check.Equal(machine.Generation, result.MachineGeneration, "génération machine conservée après qualification finale");
    }

    [Test]
    public static async Task Two_distinct_shared_one_shots_refuse_before_any_LDAP_or_CIM_contact_without_account_fallback()
    {
        using var fixture = await Fixture.Create(directoryAccounts: true);
        await fixture.RecoverAsync(CredentialRules.Directory, @"TEST\directory-once");
        await fixture.RecoverAsync(CredentialRules.Remote, @"TEST\machine-once");
        var session = await fixture.Source.GetSessionAsync(None); var machine = MachineAccountService.From(fixture.Context);
        _ = machine.Resolve(session, fixture.Computer.DnsHostName);
        var native = 0;
        var reader = fixture.Reader(_ => { native++; return []; });
        var error = await Check.ThrowsAsync<DomeniaOperationException>(() => reader.CollectPersonalProbeAsync(fixture.Request(), None), "deux retraits de baux partagés refusés sans rescellement");
        Check.Equal(AccountAccess.EpochChanged, error.Code, "refus explicite de sélection incompatible");
        Check.Equal(0, native, "aucun contact CIM avec des générations incompatibles");
        Check.Equal(0, fixture.Ldap.Calls, "aucun contact LDAP avant admission cohérente");
        Check.True(fixture.LdapSelections.Count <= 1 && fixture.LdapSelections.All(a => a == @"TEST\directory-once"), "aucun remplacement du compte LDAP par la session");
        Check.True(fixture.Cache.Fleet.Probes.ByProbe.IsEmpty, "aucun résultat attribué après refus d’admission");
    }

    [Test]
    public static async Task Explicit_machine_choice_change_during_LDAP_admission_is_rejected_before_contact()
    {
        using var fixture = await Fixture.Create(directoryAccounts: true);
        await fixture.RecoverAsync(CredentialRules.Directory, @"TEST\directory-once");
        var machine = MachineAccountService.From(fixture.Context); var session = await fixture.Source.GetSessionAsync(None);
        _ = machine.Resolve(session, fixture.Computer.DnsHostName);
        var request = fixture.Request(); var native = 0;
        fixture.OnDirectoryAdmission = () =>
        {
            using var replacement = Password(); machine.UseRemote(@"TEST\replacement", replacement.Copy());
        };
        var reader = fixture.Reader(_ => { native++; return []; });
        var error = await Check.ThrowsAsync<DomeniaOperationException>(() => reader.CollectPersonalProbeAsync(request, None), "changement explicite pendant l’admission non adopté par le plan");
        Check.Equal(AccountAccess.EpochChanged, error.Code, "aucune nouvelle base de génération après changement concurrent");
        Check.Equal(0, native, "aucun envoi sous le compte de remplacement");
        Check.Equal(0, fixture.Ldap.Calls, "construction du transport sans contact réseau avant refus");
        Check.True(fixture.Cache.Fleet.Probes.ByProbe.IsEmpty, "aucune valeur de la nouvelle sélection attribuée à l’ancien plan");
    }

    [Test]
    public static async Task Frozen_plan_versions_are_checked_again_at_joint_admission_before_any_copy_or_contact()
    {
        foreach (var changeMachine in new[] { true, false })
        {
            using var fixture = await Fixture.Create(directoryAccounts: true);
            var machine = MachineAccountService.From(fixture.Context); var session = await fixture.Source.GetSessionAsync(None);
            _ = machine.Resolve(session, fixture.Computer.DnsHostName);
            var request = fixture.Request();
            if (changeMachine)
            { using var replacement = Password(); machine.UseRemote(@"TEST\replacement", replacement.Copy()); }
            else { await fixture.RecoverAsync(CredentialRules.Directory, @"TEST\directory-once"); }
            var error = await Check.ThrowsAsync<DomeniaOperationException>(async () =>
            {
                using var access = await AdQueryAccess.OpenAsync(fixture.Source, fixture.Computer.ObjectGuid, None,
                    expectedAccountVersion: request.AccountVersion, expectedMachineGeneration: request.MachineGeneration);
            }, "sélection modifiée après le contrôle local du plan refusée à l’admission");
            Check.Equal(AccountAccess.EpochChanged, error.Code, "versions du plan transportées jusqu’à la copie atomique");
            Check.Equal(0, fixture.LdapSelections.Count, "aucune copie LDAP avant refus du plan obsolète");
            Check.Equal(0, fixture.Ldap.Calls, "aucune qualification distante après changement de sélection");
        }
    }

    private static SecureString Password()
    {
        var result = new SecureString(); foreach (var character in "fixture-only") result.AppendChar(character); result.MakeReadOnly(); return result;
    }

    private sealed class Fixture : IDisposable
    {
        internal DirectoryComputer Computer { get; } = Fixtures.Computer("PC1");
        internal DirectoryComputer Live { get; set; }
        internal FrozenProbe Probe { get; } = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document()).Single();
        internal AdBoundaryTests.RecordingAdConnection Ldap { get; }
        internal AdAccueilTests.FleetCache Cache { get; }
        internal AdDirectorySource Source { get; }
        internal EngineContext Context { get; }
        internal List<string?> LdapSelections { get; } = [];
        internal Action? OnDirectoryAdmission { get; set; }
        private Fixture(bool directoryAccounts)
        {
            Live = Computer;
            Ldap = new() { SearchAnswer = request => request.BaseDn == Computer.DistinguishedName ? [AdPosteNetworkTests.Entry(Live)] : [] };
            Cache = new(Fixtures.Snapshot(computers: [Computer]));
            Source = new("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: new AdBoundaryTests.RecordingAdConnection(), localStore: Cache)
            {
                AdministrationOverride = AdBoundaryTests.NativeAdministrator,
                ReadConnectionFactory = directoryAccounts ? selected =>
                {
                    LdapSelections.Add(selected?.Account);
                    OnDirectoryAdmission?.Invoke();
                    return Ldap;
                } : null,
            };
            Source.AdoptConnection(Ldap, Fixtures.Domain, new(new(@"TEST\operator", "operator", "Opérateur", "CN=operator," + Fixtures.People),
                Fixtures.Domain.DomainSid + "-1001", new(RightsLevel.Unknown, "Inconnus", true, "Non mesurés")), Source.Epoch, false);
            Context = new(ModeResolver.Resolve([], "0", () => new(DomainJoinState.Unknown, null)), Source, new MemoryPreferenceStore(), Source.Clock, new RecordingJournal());
            if (directoryAccounts)
            {
                _ = Context.Shared(c => new AccountAccess(c.Directory, new AcceptedAccounts(), c.Preferences, c.Journal,
                    c.Clock, c.Log, c.Mode, _ => Task.FromResult(0)));
            }
            using var password = Password(); MachineAccountService.From(Context).UseRemote(@"TEST\probe", password.Copy());
        }
        internal static async Task<Fixture> Create(bool directoryAccounts = false)
        {
            var fixture = new Fixture(directoryAccounts); await fixture.Source.ReadLocalAsync(None);
            await fixture.Context.Preferences.SetAsync(PersonalProbeCatalog.PreferenceKey,
                PersonalProbeCatalog.Merge(PersonalProbeCatalog.Read(null), [fixture.Probe]), None);
            return fixture;
        }
        internal async Task RecoverAsync(string scope, string login)
        {
            var access = AccountAccess.From(Context); await access.OverviewAsync(None);
            var target = scope == CredentialRules.Remote ? Computer.DnsHostName : Computer.DistinguishedName;
            access.RegisterRefusal(scope, "Admission de la sonde personnelle", target, "accessDenied", null, true);
            var request = (await access.OverviewAsync(None)).Pending.First(p => p.Scope == scope && p.Target == target);
            using var password = Password();
            var result = await access.RecoverAsync(request.Id, login, password, LeaseMode.OneShot, 30,
                scope == CredentialRules.Remote ? target : null, None);
            Check.True(result.Result.Success, "bail de la ressource accepté dans la fixture");
        }
        internal PostePersonalProbeRequest Request() => new(Probe, QueryComputerIdentity.Of(Computer), Source.Epoch, Cache.Fleet.Facts.StoreId,
            AccountAccess.From(Context).SelectionVersion, MachineAccountService.From(Context).Generation, PosteConfiguration.Defaults);
        internal AdPosteReader Reader(Func<string, IReadOnlyList<WmiInstance>> read) => new(Source)
        {
            PersonalProbeReaderOverride = new WmiFleetProbeReader(Source.Clock)
            {
                SessionFactory = (host, budget, token) => new(host, budget, Source.Clock, cancellationToken: token)
                { ReadOverride = (_, query, _) => read(query) },
            },
        };
        public void Dispose() { Context.Dispose(); Source.Dispose(); }
    }

    private sealed class AcceptedAccounts : IAccountsAccessReader
    {
        public Task<CredentialAnswer> ValidateAsync(CredentialRequest request, SecureString password, CancellationToken token)
        { token.ThrowIfCancellationRequested(); return Task.FromResult(new CredentialAnswer(true, "ok", request.Login, null, "Validation de fixture sans transport.")); }
        public Task<ImmutableArray<AccessRequestSeed>> InitialRequestsAsync(CancellationToken token) => Task.FromResult(ImmutableArray<AccessRequestSeed>.Empty);
        public Task<string?> SessionSidAsync(CancellationToken token) => Task.FromResult<string?>(Fixtures.Domain.DomainSid + "-1001");
        public Task<RemoteProbeAnswer> ProbeAsync(string computer, RemoteProbeCredential credential, CancellationToken token) => throw new TestFailureException("Aucun essai implicite du compte.");
        public Task<SessionOpenAnswer> OpenSessionAsync(CredentialRequest request, SecureString password, CancellationToken token) => throw new TestFailureException("Aucun changement de session.");
        public Task<ConnectionSecretSwap> SwapConnectionPasswordAsync(SecureString password, CancellationToken token) => throw new TestFailureException("Aucune correction de secret.");
        public bool SessionSwitchAvailable => false;
        public bool Simulated => true;
        public DateTimeOffset? SessionStartedAt => null;
    }
}

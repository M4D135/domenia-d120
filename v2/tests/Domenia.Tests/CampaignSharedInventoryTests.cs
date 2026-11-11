using System.Collections.Immutable;
using System.Security;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Core.Queries;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class CampaignSharedInventoryTests
{
    private static readonly TimeSpan Guard = TimeSpan.FromSeconds(10);

    [Test]
    public static async Task Cancelled_campaign_waits_for_another_subscriber_and_retains_a_dated_partial_without_console()
    {
        using var fixture = new Fixture(); using var stop = new CancellationTokenSource();
        await fixture.Source.ReadLocalAsync(CancellationToken.None);
        var reader = new AdRelationsReader(fixture.Source) { InventoryReaderOverride = _ => fixture.Reader() };
        var campaign = reader.InventoryAsync(fixture.Computer, WorkstationReading.Survey, null, stop.Token, awaitPhysicalCompletion: true);
        Task<(InventorySnapshot Value, bool Shared)>? other = null;
        var ldapBeforeStop = 0;
        try
        {
            await fixture.Entered.Task.WaitAsync(Guard);
            using var account = await AdWorkstationAccess.AcquireAsync(fixture.Source, fixture.Computer.DnsHostName!, CancellationToken.None);
            var key = new InventoryReadKey(fixture.Computer.ObjectGuid, fixture.Computer.DistinguishedName.ToUpperInvariant(), fixture.Computer.WhenCreated,
                fixture.Computer.DnsHostName!.ToUpperInvariant(), WorkstationReading.Survey, account.SharingGeneration,
                account.Settings.UseCim, account.Settings.UseRemoteRegistry, account.Settings.Options.UseWinRm)
                { SelectedTransport = account.Settings.ReadCimTransport, WinRmFallback = account.Settings.ReadsFallBackToWinRm };
            other = SharedInventoryReads.For(fixture.Source).ReadAsync(key, (_, _) => throw new InvalidOperationException("Un second worker ne doit pas démarrer."), null, CancellationToken.None);
            ldapBeforeStop = fixture.Ldap.Calls;
            await stop.CancelAsync(); await StillOwned(campaign);
            Check.False(fixture.NativeToken.IsCancellationRequested, "l’autre abonné conserve son worker");
            Check.False(other.IsCompleted, "l’autre abonné attend toujours la même réponse physique");
            Check.Equal(1, fixture.NativeSessions, "un seul worker pour les deux consommateurs");
        }
        finally
        {
            fixture.Release.Set();
            await Drain(other is null ? [campaign] : [campaign, other]);
        }
        var result = await campaign.WaitAsync(Guard);
        var live = await other!.WaitAsync(Guard);
        Check.True(live.Shared, "le second abonné partage effectivement la lecture");
        Check.Equal(@"TEST\alice", live.Value.Console!.Account, "résultat de l’autre abonné non modifié");
        Check.Equal(SourceStatus.Ok, live.Value.StatusOf(InventoryCategories.System), "succès natif conservé pour l’autre abonné");
        Check.Equal("Model", result.Value.System!.Model, "mesure matérielle reçue conservée");
        Check.Equal(Fixtures.Now, result.Value.CollectedAt, "date native conservée sans rajeunissement");
        Check.Equal(SourceStatus.Partial, result.Value.StatusOf(InventoryCategories.System), "campagne annulée distincte du succès partagé");
        Check.True(result.Value.ReadPhysicallyCompleted, "fin physique atteinte avant retour");
        Check.Null(result.Value.Console, "aucune console sans qualification AD finale");
        Check.Null(result.Value.System!.UserName, "aucun ancien compte associé au partiel");
        Check.Equal(ldapBeforeStop, fixture.Ldap.Calls, "aucun LDAP de qualification après l’arrêt de la campagne");
    }

    [Test]
    public static async Task Last_campaign_subscriber_waits_even_when_the_native_worker_faults_after_cancellation()
    {
        var sharing = new SharedInventoryReads(); using var stop = new CancellationTokenSource();
        var finished = new TaskCompletionSource<InventorySnapshot>(TaskCreationOptions.RunContinuationsAsynchronously);
        CancellationToken native = default;
        var computer = Fixtures.Computer("PC1");
        var key = new InventoryReadKey(computer.ObjectGuid, computer.DistinguishedName, computer.WhenCreated, computer.DnsHostName!,
            WorkstationReading.Survey, "fixture", true, false, false);
        var pending = sharing.ReadAsync(key, (_, token) => { native = token; return finished.Task; }, null, stop.Token, awaitPhysicalCompletion: true);
        try
        {
            await stop.CancelAsync(); await StillOwned(pending);
            Check.True(native.IsCancellationRequested, "dernier abonné : arrêt demandé au worker");
        }
        finally { finished.TrySetException(new IOException("native fixture failure")); await Drain([pending]); }
        await Check.ThrowsAsync<IOException>(() => pending.WaitAsync(Guard), "faute réelle observée après fin physique, pas de succès fabriqué");
    }

    [Test]
    public static async Task Exclusive_campaign_callback_keeps_physical_ownership_and_does_not_run_followup_after_stop()
    {
        using var fixture = new Fixture(); using var stop = new CancellationTokenSource();
        await fixture.Source.ReadLocalAsync(CancellationToken.None);
        var after = 0;
        var reader = new AdRelationsReader(fixture.Source) { InventoryReaderOverride = _ => fixture.Reader() };
        var pending = reader.InventoryAsync(fixture.Computer, WorkstationReading.Survey, null, stop.Token,
            beforeRead: (_, _) => Task.CompletedTask,
            afterRead: (value, _, _) => { after++; return Task.FromResult(value); }, awaitPhysicalCompletion: true);
        try { await fixture.Entered.Task.WaitAsync(Guard); await stop.CancelAsync(); await StillOwned(pending); }
        finally { fixture.Release.Set(); await Drain([pending]); }
        var result = await pending.WaitAsync(Guard);
        Check.True(fixture.NativeToken.IsCancellationRequested, "annulation transmise au worker exclusif");
        Check.True(result.Value.ReadPhysicallyCompleted, "les callbacks exclusifs ne contournent pas l’attente physique");
        Check.Equal(0, after, "aucun suivi consenti ni repli lancé après arrêt");
        Check.Equal("Model", result.Value.System!.Model, "source terminée conservée");
        Check.Null(result.Value.Console, "console non qualifiée écartée");
    }

    [Test]
    public static async Task Search_and_home_query_consumers_commit_native_partials_before_propagating_stop()
    {
        foreach (var search in new[] { false, true })
        {
            using var fixture = new Fixture(); using var stop = new CancellationTokenSource();
            await fixture.Source.ReadLocalAsync(CancellationToken.None);
            Task pending;
            if (search)
            {
                var reader = new AdSearchReader(fixture.Source)
                {
                    EchoOverride = (_, _) => Task.FromResult(Fixtures.Presence(true, TimeSpan.Zero)),
                    ConsoleReaderOverride = _ => fixture.Reader(),
                };
                pending = reader.ProbeAsync(fixture.Computer.ObjectGuid, SurveyMode.Analyse, 1, TimeSpan.Zero, stop.Token);
            }
            else
            {
                var reader = new AdQueryWorkshopReader(fixture.Source) { InventoryReaderOverride = _ => fixture.Reader() };
                pending = reader.MeasureAsync(new([fixture.Computer.ObjectGuid], false, false, true, [])
                {
                    ExpectedEpoch = fixture.Source.Epoch,
                    ExpectedIdentities = ImmutableDictionary<Guid, QueryComputerIdentity>.Empty.Add(fixture.Computer.ObjectGuid, QueryComputerIdentity.Of(fixture.Computer)),
                }, stop.Token);
            }
            var writesBeforeStop = 0; var ldapBeforeStop = 0;
            try
            {
                await fixture.Entered.Task.WaitAsync(Guard);
                writesBeforeStop = fixture.Cache.FleetWrites; ldapBeforeStop = fixture.Ldap.Calls;
                await stop.CancelAsync(); await StillOwned(pending);
                Check.Equal(writesBeforeStop, fixture.Cache.FleetWrites, "pas de reçu avant la fin du worker");
            }
            finally { fixture.Release.Set(); await Drain([pending]); }
            await Check.ThrowsAsync<OperationCanceledException>(() => pending.WaitAsync(Guard), "arrêt propagé après persistance locale");
            Check.Equal(writesBeforeStop + 1, fixture.Cache.FleetWrites, "résultat partiel enregistré avant de libérer la campagne");
            Check.Equal(ldapBeforeStop, fixture.Ldap.Calls, "aucune nouvelle qualification après arrêt");
            var inventory = fixture.Cache.Fleet.Inventories[fixture.Computer.ObjectGuid];
            Check.Equal("Model", inventory.System!.Model, "contenu reçu sauvegardé par le consommateur");
            Check.Equal(Fixtures.Now, inventory.CollectedAt, "horodatage natif sauvegardé");
            Check.Null(inventory.Console, "aucune console non qualifiée conservée");
            Check.Equal(MeasureState.Incomplete, fixture.Cache.Fleet.Observations.Workstations.Single().Inventory.State, "arrêt visible dans la projection du parc");
        }
    }

    private static async Task StillOwned(Task pending)
    {
        var observed = await Task.WhenAny(pending, Task.Delay(TimeSpan.FromMilliseconds(75)));
        Check.False(ReferenceEquals(pending, observed), "annulation logique ne libère pas la campagne avant son travail natif");
    }
    private static async Task Drain(Task[] tasks)
    {
        try { await Task.WhenAll(tasks).WaitAsync(Guard); }
        catch (Exception) { /* Cleanup observes each failed task; assertions above/below decide the expected outcome. */ }
    }

    private sealed class Fixture : IDisposable
    {
        internal DirectoryComputer Computer { get; } = Fixtures.Computer("PC1");
        internal AdPosteNetworkTests.Cache Cache { get; }
        internal AdBoundaryTests.RecordingAdConnection Ldap { get; } = new();
        internal AdDirectorySource Source { get; }
        internal EngineContext Context { get; }
        internal TimeProvider Clock { get; } = TestClock.Fixed();
        internal TaskCompletionSource Entered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal ManualResetEventSlim Release { get; } = new();
        internal CancellationToken NativeToken;
        internal int NativeSessions;
        internal Fixture()
        {
            Cache = new(Fixtures.Snapshot(computers: [Computer]));
            Ldap.SearchAnswer = request => request.BaseDn == Computer.DistinguishedName ? [AdPosteNetworkTests.Entry(Computer)] : [];
            Source = new("test.local", () => @"TEST\operator", Clock, connection: new AdBoundaryTests.RecordingAdConnection(), localStore: Cache)
            { AdministrationOverride = AdBoundaryTests.NativeAdministrator };
            Source.AdoptConnection(Ldap, Fixtures.Domain, new(new(@"TEST\operator", "operator", "Opérateur", "CN=operator," + Fixtures.People),
                Fixtures.Domain.DomainSid + "-1001", new(RightsLevel.Unknown, "Inconnus", true, "Non mesurés")), Source.Epoch, false);
            Context = new(ModeResolver.Resolve([], "0", () => new(DomainJoinState.Unknown, null)), Source, new MemoryPreferenceStore(), Clock, new RecordingJournal());
            using var password = new SecureString(); foreach (var character in "fixture-only") { password.AppendChar(character); }
            MachineAccountService.From(Context).UseRemote(@"TEST\probe", password.Copy());
        }
        internal WmiWorkstationReader Reader() => new(Clock)
        {
            SessionFactory = (host, budget, token) =>
            {
                Interlocked.Increment(ref NativeSessions); NativeToken = token;
                return new(host, budget, Clock, cancellationToken: token)
                {
                    RegistryOverride = (_, _) => new(2, null),
                    ReadOverride = (_, query, _) =>
                    {
                        if (query.Contains("Win32_OperatingSystem", StringComparison.Ordinal)) { return [Row(("Caption", "Windows"), ("SystemDrive", "C:"))]; }
                        if (query.Contains("Win32_ComputerSystem", StringComparison.Ordinal)) { return [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"), ("Model", "Model"), ("UserName", @"TEST\alice"))]; }
                        if (query.Contains("Win32_NetworkAdapter", StringComparison.Ordinal))
                        { Entered.TrySetResult(); Check.True(Release.Wait(Guard), "barrière du fournisseur natif libérée"); }
                        return [];
                    },
                };
            },
        };
        private static WmiInstance Row(params (string Key, object? Value)[] values) => new(values.ToDictionary(v => v.Key, v => v.Value));
        public void Dispose() { Release.Set(); Context.Dispose(); Source.Dispose(); Release.Dispose(); }
    }
}

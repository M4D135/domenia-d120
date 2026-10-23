using System.Collections.Immutable;
using System.Security.Principal;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class AdPosteNetworkTests
{
    internal sealed class Cache(DirectorySnapshot directory) : IObjectDirectoryCache, IAccueilCache
    {
        public CachedFleet Fleet { get; private set; } = CachedFleet.Empty("test");
        public int FleetWrites { get; private set; }
        public Task<DirectorySnapshot?> ReadAsync(CancellationToken cancellationToken) => Task.FromResult<DirectorySnapshot?>(directory);
        public Task<DirectorySnapshot?> ReadKnownAsync(CancellationToken cancellationToken) => ReadAsync(cancellationToken);
        public Task SaveAsync(DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken cancellationToken) => throw new InvalidOperationException("Pas de recensement");
        public Task<DirectorySnapshot> SaveObjectsAsync(DirectorySnapshot objects, string? controller, CancellationToken cancellationToken) => Task.FromResult(directory = directory with { Computers = objects.Computers });
        public Task<CachedFleet> ReadFleetAsync(CancellationToken cancellationToken) => Task.FromResult(Fleet);
        public Task<CachedFleet> SaveFleetAsync(FleetCachePatch patch, CancellationToken cancellationToken) { FleetWrites++; return Task.FromResult(Fleet = Fleet.Merge(patch)); }
        public Task<ImmutableArray<FleetSnapshot>> ReadFleetHistoryAsync(ScopeSelection scope, CancellationToken cancellationToken) => Task.FromResult(ImmutableArray<FleetSnapshot>.Empty);
    }

    internal static AdEntry Entry(DirectoryComputer pc)
    {
        var sid = new SecurityIdentifier(pc.Sid); var bytes = new byte[sid.BinaryLength]; sid.GetBinaryForm(bytes, 0);
        return new(pc.DistinguishedName, new Dictionary<string, IReadOnlyList<object>>
        {
            ["objectGUID"] = [pc.ObjectGuid.ToByteArray()], ["objectSid"] = [bytes], ["objectClass"] = ["top", "user", "computer"],
            ["name"] = [pc.Name], ["sAMAccountName"] = [pc.SamAccountName], ["dNSHostName"] = [pc.DnsHostName!],
            ["whenCreated"] = [pc.WhenCreated.UtcDateTime.ToString("yyyyMMddHHmmss.0'Z'", System.Globalization.CultureInfo.InvariantCulture)], ["userAccountControl"] = [pc.UserAccountControl],
        });
    }

    private static WmiInstance Row(params (string Key, object? Value)[] values) => new(values.ToDictionary(v => v.Key, v => v.Value));
    private static WmiWorkstationReader Native(Func<string, IReadOnlyList<WmiInstance>> answer, Action? interrupt = null)
    {
        var clock = TestClock.Fixed();
        return new(clock) { SessionFactory = (host, budget, token) => new(host, budget, clock, cancellationToken: token)
        {
            ReadOverride = (_, query, _) => { var rows = answer(query); if (query.Contains("FROM Win32_OperatingSystem", StringComparison.Ordinal)) { interrupt?.Invoke(); } return rows; },
            RegistryOverride = (_, _) => new(2, null),
        } };
    }

    [Test]
    public static async Task Workstation_network_reads_revalidate_AD_GUID_before_any_native_contact()
    {
        var pc = Fixtures.Computer("PC1"); var cache = new Cache(Fixtures.Snapshot(computers: [pc]));
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => q.BaseDn == pc.DistinguishedName ? [Entry(pc with { ObjectGuid = Guid.NewGuid() })] : [] };
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        var calls = 0; var reader = new AdPosteReader(source) { InventoryReaderOverride = _ => { calls++; return Native(_ => []); } };
        var error = await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ServicesAsync(pc.DistinguishedName, CancellationToken.None), "identité refusée");
        Check.Equal(PosteErrors.ComputerUnknown, error.Code, "recréation du même DN écartée");
        Check.Equal(0, calls, "aucun appel natif après changement de GUID"); Check.Equal(0, cache.FleetWrites, "aucun faux relevé enregistré");
    }

    [Test]
    public static async Task Workstation_services_accept_CN_only_rename_and_refuse_foreign_Windows_identity()
    {
        var pc = Fixtures.Computer("PC1") with { Name = "Bureau rénové" }; var cache = new Cache(Fixtures.Snapshot(computers: [pc]));
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => q.BaseDn == pc.DistinguishedName ? [Entry(pc)] : [] };
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        var host = "PC1";
        var reader = new AdPosteReader(source) { InventoryReaderOverride = _ => Native(q => q.Contains("Win32_ComputerSystem", StringComparison.Ordinal)
            ? [Row(("Name", host), ("NumberOfLogicalProcessors", 4))]
            : q.Contains("Win32_Service", StringComparison.Ordinal) ? [Row(("Name", "Spooler"), ("State", "Running"), ("StartMode", "Auto"))] : []) };
        var services = await reader.ServicesAsync(pc.DistinguishedName, CancellationToken.None);
        Check.Equal("Spooler", services.Rows.Single().Name, "service du compte Windows, malgré le CN distinct");
        Check.Equal(pc.Name, services.Computer, "nom d’affichage AD conservé");
        host = "OTHER";
        var error = await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ServicesAsync(pc.DistinguishedName, CancellationToken.None), "identité refusée");
        Check.Equal(DomeniaErrors.SourceUnavailable, error.Code, "résultat d’un autre poste écarté");
        Check.Equal(0, cache.FleetWrites, "une lecture services n’écrase pas l’inventaire");
    }

    [Test]
    public static async Task Refused_workstation_identity_never_publishes_other_native_payload_or_a_healthy_services_profile()
    {
        var pc = Fixtures.Computer("PC1"); var cache = new Cache(Fixtures.Snapshot(computers: [pc]));
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => q.BaseDn == pc.DistinguishedName ? [Entry(pc)] : [] };
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        var reader = new AdPosteReader(source) { InventoryReaderOverride = _ => Native(q => q.Contains("Win32_ComputerSystem", StringComparison.Ordinal)
            ? throw new UnauthorizedAccessException() : [Row(("Name", "Unproven"), ("State", "Running"), ("StartMode", "Auto"))]) };
        var services = await reader.ServicesAsync(pc.DistinguishedName, CancellationToken.None);
        Check.Equal(0, services.Rows.Length, "contenu sans identité écarté"); Check.Equal(0, services.Profile.Length, "aucun profil sain fabriqué");
        Check.True(services.Summary.Contains("incomplet", StringComparison.Ordinal), "lecture non concluante visible");
    }

    [Test]
    public static async Task Workstation_inventory_keeps_partial_data_after_cancellation_and_does_not_cancel_its_save()
    {
        var pc = Fixtures.Computer("PC1"); var cache = new Cache(Fixtures.Snapshot(computers: [pc]));
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => q.BaseDn == pc.DistinguishedName ? [Entry(pc)] : [] };
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        using var stop = new CancellationTokenSource();
        var reader = new AdPosteReader(source) { InventoryReaderOverride = _ => Native(q => q.Contains("Win32_ComputerSystem", StringComparison.Ordinal)
            ? [Row(("Name", "PC1"), ("NumberOfLogicalProcessors", 4))]
            : q.Contains("Win32_Processor", StringComparison.Ordinal) ? throw new OperationCanceledException() : []) };
        // Use a real cancellation during a later progress notification, after the identity-bearing step was published.
        var progress = new CallbackProgress(p => { if (p.Done >= 2) { stop.Cancel(); } });
        var result = await reader.InventoryAsync(pc.DistinguishedName, false, PosteHealthPolicy.Default, progress, stop.Token);
        Check.Equal(1, cache.FleetWrites, "résultat partiel enregistré une fois");
        Check.True(cache.Fleet.Inventories[pc.ObjectGuid].Interrupted, "sources restantes interrompues");
        Check.True(result.Notice?.Contains("arrêtée", StringComparison.Ordinal) == true, "arrêt expliqué à l’opérateur");
    }

    private sealed class CallbackProgress(Action<PosteProgress> callback) : IProgress<PosteProgress> { public void Report(PosteProgress value) => callback(value); }

    [Test]
    public static void Process_measurement_requires_creation_identity_and_never_calls_an_unmeasured_sample_zero_percent()
    {
        var first = new ProcessEntry(42, "app.exe", 1024, 1, null, null);
        var second = first with { CpuSeconds = 2 };
        var missing = PosteProcesses.Measure("PC1", [first], [second], 1000, 4, Fixtures.Now, TestClock.Paris);
        Check.Null(missing.TotalCpu, "identité du PID non prouvée"); Check.Null(missing.Rows[0].CpuPercent, "aucune part inventée");
        Check.Equal(FactState.Unknown, missing.Facts[0].State, "pas de bilan à zéro sain");
        var created = Fixtures.Now.AddMinutes(-1);
        var valid = PosteProcesses.Measure("PC1", [first with { StartedAt = created }], [second with { StartedAt = created }], 1000, 4, Fixtures.Now, TestClock.Paris);
        Check.Equal(25d, valid.TotalCpu!.Value, "normalisation sur les quatre processeurs logiques");
    }

    [Test]
    public static async Task WTS_partial_read_preserves_unread_sessions_and_selected_account()
    {
        var pc = Fixtures.Computer("PC1"); var cache = new Cache(Fixtures.Snapshot(computers: [pc]));
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => q.BaseDn == pc.DistinguishedName ? [Entry(pc)] : [] };
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        var reader = new AdPosteReader(source) { SessionsOverride = (host, credential, token) =>
        {
            Check.Equal(pc.DnsHostName, host, "cible fraîche"); Check.Equal(@"TEST\operator", credential.Account, "compte de connexion sélectionné");
            return Task.FromResult(new WindowsSessionsRead(SourceStatus.Partial,
                [new("1", "Console", "alice", "TEST", "Active", "Console", null, null, null), new("2", "RDP-Tcp#1", null, null, "Lecture partielle", "RDP", null, null, null)], 1, Fixtures.Now, "Une session illisible."));
        } };
        var result = await reader.SessionsAsync(pc.DistinguishedName, CancellationToken.None);
        Check.True(result.Partial, "partiel conservé"); Check.Equal(1, result.UserSessions, "une session identifiée");
        Check.Equal(1, result.UnreadSessions, "une session non lue"); Check.True(result.StatusText.Contains("illisible", StringComparison.Ordinal), "diagnostic conservé");
    }
}

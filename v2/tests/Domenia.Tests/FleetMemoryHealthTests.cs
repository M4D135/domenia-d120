using System.Collections.Immutable;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Inventory;
using Domenia.Store;
using ProbeReadings = Domenia.Core.Accueil.ProbeReadings;

namespace Domenia.Tests;

internal static class FleetMemoryHealthTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static readonly CustomHealthRule Rule = new("custom.00000000000000000000000000000027", "Mémoire utilisée", "MemoryUsed", "GreaterThan", 80, "Warn", true);
    private static WmiInstance Row(params (string Name, object? Value)[] values) => new(values.ToDictionary(v => v.Name, v => v.Value));
    private static MachineFacts Facts(MemoryUsageFact? memory, DateTimeOffset? at = null) => new(null, null, null, null, MeasureState.Known, at ?? Fixtures.Now, null) { Memory = memory };
    private static FleetCachePatch Patch(Guid id, MachineFacts facts) => FleetCachePatch.Empty with { Machines = ImmutableDictionary<Guid, MachineFacts>.Empty.Add(id, facts) };
    private static FleetComputation Board(DirectoryComputer[] computers, ImmutableDictionary<Guid, MachineFacts> facts, CustomHealthRule? rule = null)
    {
        var policy = HealthPolicy.Default with { DisabledRules = [.. HealthRules.Catalog.Select(r => r.Id)], CustomRules = [rule ?? Rule] };
        return FleetBoardCalculator.Compute(new(new(Fixtures.Snapshot(computers: computers), FleetObservations.Empty, [], []),
            new(Fixtures.Postes, "Postes", true), Fixtures.Root, "test.local", HealthPolicyBook.Empty(Fixtures.Root) with { Default = policy },
            AccueilFacts.Empty("local") with { Machines = facts }, null, ProbeReadings.Empty, FleetCatalog.DefaultLayout(), [], Fixtures.Now, TimeZoneInfo.Utc));
    }

    [Test]
    public static void Memory_alert_uses_the_same_sample_and_keeps_missing_stale_invalid_and_future_unknown()
    {
        var machines = Enumerable.Range(0, 8).Select(n => Fixtures.Computer("PC" + n)).ToArray();
        MemoryUsageFact?[] samples = [new(1000, 100, Fixtures.Now), new(1000, 500, Fixtures.Now), new(1000, 200, Fixtures.Now), null,
            new(1000, 50, Fixtures.Now.AddDays(-31)), new(1000, 1001, Fixtures.Now), new(1000, -1, Fixtures.Now), new(1000, 100, Fixtures.Now.AddMinutes(6))];
        var facts = machines.Select((m, n) => (m.ObjectGuid, Value: Facts(samples[n]))).ToImmutableDictionary(x => x.ObjectGuid, x => x.Value);
        var board = Board(machines, facts);
        Check.Equal(1, board.Board.Health.Problems, "90 % seulement ; seuil 80 strict");
        Check.Equal(2, board.Board.Health.Healthy, "deux mesures connues sans dépassement");
        Check.Equal(5, board.Board.Health.Unassessed, "absence, âge, corruption et futur exclus du score sain");
        var explanation = board.Explanation.Rows.Single(r => r.Id == Rule.Id);
        Check.Equal(3, explanation.EligibleCount!.Value, "couverture mémoire propre à la règle");
        Check.Equal(5, explanation.Missing, "liste exacte des données manquantes");
        Check.True(board.Targets[explanation.TargetsKey!].SequenceEqual([machines[0].ObjectGuid]), "clic alerte ouvre le bon poste");
        Check.True(board.Targets[explanation.MissingKey!].ToHashSet().SetEquals(machines.Skip(3).Select(m => m.ObjectGuid)), "clic manquants identique au dénominateur");
        Check.Contains("même relevé", explanation.Evidence.Source, "provenance mémoire explicite");
        Check.Contains("instantanée", explanation.Evidence.Rule, "limite de la mesure");
        var below = Board(machines, facts, Rule with { Operator = "LessThan", Threshold = 60 });
        Check.True(below.Targets["rule:" + Rule.Id].SequenceEqual([machines[1].ObjectGuid]), "seuil inférieur pris en compte");
        Check.Null(MemoryUsageFact.Read(0, 0, Fixtures.Now), "total nul jamais divisé");
        Check.Null(MemoryUsageFact.Read(1000, null, Fixtures.Now), "champ absent ne vaut pas zéro");
        Check.Equal(100.0, MemoryUsageFact.Read(1000, 0, Fixtures.Now)!.UsedPercent!.Value, "zéro libre explicite reste une vraie mesure");
        Check.Equal(0.0, MemoryUsageFact.Read(long.MaxValue, long.MaxValue, Fixtures.Now)!.UsedPercent!.Value, "aucun débordement de conversion en octets");
    }

    [Test]
    public static async Task Light_inventory_reads_memory_in_its_existing_OS_query_and_projects_the_real_pair()
    {
        var queries = new List<string>(); var clock = TestClock.Fixed();
        var reader = new WmiWorkstationProbe(clock) { SessionFactory = (host, budget, token) => new(host, budget, clock, cancellationToken: token)
        {
            ReadOverride = (_, query, _) =>
            {
                queries.Add(query);
                return query.Contains("Win32_OperatingSystem", StringComparison.Ordinal) ? [Row(("Caption", "Windows"), ("SystemDrive", "C:"), ("TotalVisibleMemorySize", 1000L), ("FreePhysicalMemory", 100L))]
                    : query.Contains("Win32_ComputerSystem", StringComparison.Ordinal) ? [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"), ("TotalPhysicalMemory", 16L << 30))]
                    : query.Contains("Win32_LogicalDisk", StringComparison.Ordinal) ? [Row(("Size", 1000L), ("FreeSpace", 500L))] : [Row(("SMBIOSBIOSVersion", "v1"))];
            },
        } };
        var read = await reader.ReadFactsAsync("PC1.test.local", TimeSpan.FromSeconds(10), None);
        Check.Equal(4, queries.Count, "aucune requête supplémentaire pour la mémoire");
        var os = queries.Single(q => q.Contains("Win32_OperatingSystem", StringComparison.Ordinal));
        Check.Contains("TotalVisibleMemorySize, FreePhysicalMemory", os, "couple lu dans le même appel");
        Check.Equal(90.0, read.Facts.Memory!.UsedPercent!.Value, "total Windows ; pas les 16 Go installés");
        foreach (var status in new[] { SourceStatus.Refused, SourceStatus.Partial, SourceStatus.Empty })
        {
            var refused = WmiWorkstationProbe.Project(new Dictionary<string, CimReading> { ["system"] = new("system", status, "", 0, [Row(("TotalVisibleMemorySize", 1000L), ("FreePhysicalMemory", 0L))]) }, Fixtures.Now);
            Check.Null(refused.Facts.Memory, "source non qualifiée jamais connue");
        }
    }

    [Test]
    public static async Task Full_inventory_and_persistent_cache_keep_the_memory_sample_date_across_failed_attempts()
    {
        var pc = Fixtures.Computer("PC1"); var clock = TestClock.Fixed();
        var reader = new WmiWorkstationReader(clock) { SessionFactory = (host, budget, token) => new(host, budget, clock, cancellationToken: token)
        {
            RegistryOverride = (_, _) => new(2, null), ReadOverride = (_, query, _) =>
                query.Contains("Win32_ComputerSystem", StringComparison.Ordinal) ? [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"), ("TotalPhysicalMemory", 16L << 30))]
                : query.Contains("Win32_OperatingSystem", StringComparison.Ordinal) ? [Row(("Caption", "Windows"), ("TotalVisibleMemorySize", 1000L), ("FreePhysicalMemory", 100L))] : [],
        } };
        var snapshot = await reader.ReadAsync("PC1.test.local", WorkstationReading.Survey, null, None);
        var patch = AdSearchReader.MapInventory(pc.ObjectGuid, snapshot);
        Check.Equal(90.0, patch.Machines[pc.ObjectGuid].Memory!.UsedPercent!.Value, "vraie projection de l’inventaire complet");
        using var folder = new TemporaryFolder();
        var database = new DomeniaDatabase(folder.File("memory.db"), Fixtures.Root, clock);
        await database.InitializeAsync(None);
        await database.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [pc]), new(Fixtures.Postes, "Postes", true), "DC1", None);
        await database.SaveFleetAsync(patch, None);
        clock.Advance(TimeSpan.FromMinutes(5));
        await database.SaveFleetAsync(Patch(pc.ObjectGuid, Facts(null, Fixtures.Now.AddMinutes(5)) with { WmiState = MeasureState.Refused }), None);
        await database.SaveFleetAsync(Patch(pc.ObjectGuid, Facts(new(1000, 900, Fixtures.Now.AddMinutes(-2)))), None);
        var cold = new DomeniaDatabase(database.Path, Fixtures.Root, clock);
        var stored = (await cold.ReadFleetAsync(None)).Facts.Machines[pc.ObjectGuid];
        Check.Equal(90.0, stored.Memory!.UsedPercent!.Value, "échec et résultat ancien ne remplacent pas la mesure");
        Check.Equal(Fixtures.Now, stored.Memory.At, "aucun rajeunissement au refus");
        Check.Equal(MeasureState.Refused, stored.WmiState, "tentative refusée reste visible séparément");
        Check.Equal(1, Board([pc], ImmutableDictionary<Guid, MachineFacts>.Empty.Add(pc.ObjectGuid, stored)).Board.Health.Problems, "l’alerte retrouve son observation après réouverture");
    }

    [Test]
    public static void Campaign_fallback_never_mixes_old_total_with_new_free_memory()
    {
        var pc = Fixtures.Computer("PC1");
        var first = new WorkstationInventoryRead(Fixtures.Disk(1000, 500, TimeSpan.Zero), Facts(new(1000, 100, Fixtures.Now))) { ReportedName = pc.Name, HostIdentity = new(pc.DnsHostName!, pc.Name, pc.Name, "test.local"), ReadPhysicallyCompleted = true };
        var next = first with { Facts = Facts(null, Fixtures.Now.AddMinutes(2)) };
        var kept = CampaignInventoryMerge.Combine(pc, first, next);
        Check.Equal(first.Facts.Memory!, kept.Facts.Memory!, "couple et date conservés ensemble");
        var fresh = next with { Facts = Facts(new(2000, 1000, Fixtures.Now.AddMinutes(2))) };
        Check.Equal(fresh.Facts.Memory!, CampaignInventoryMerge.Combine(pc, first, fresh).Facts.Memory!, "nouvelle paire entière remplace la précédente");
    }
}

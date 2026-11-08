using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Queries;

namespace Domenia.Tests;

internal static class AccueilDirectoryReceiptTests
{
    private static readonly CancellationToken None = CancellationToken.None;

    [Test]
    public static async Task Incoherent_receipt_stops_the_actual_home_pipeline_before_any_workstation_call()
    {
        var mutations = new (string Name, Func<DirectoryRefreshCommit, DirectoryRefreshCommit?> Change)[]
        {
            ("absent", _ => null),
            ("magasin", c => c with { Receipt = c.Receipt with { StoreId = "foreign" } }),
            ("domaine", c => c with { Receipt = c.Receipt with { DomainDn = "DC=other,DC=local" } }),
            ("portée", c => c with { Receipt = c.Receipt with { Scope = ReceiptPipelineSource.Scope with { Subtree = false } } }),
            ("époque", c => c with { SessionEpoch = c.SessionEpoch - 1 }),
            ("lecture", c => c with { Receipt = c.Receipt with { ReadAt = c.Receipt.ReadAt.AddSeconds(-1) } }),
            ("date", c => c with { Receipt = c.Receipt with { CommittedAt = Fixtures.Now.AddHours(1) } }),
            ("lot vide", c => c with { Receipt = c.Receipt with { BatchId = Guid.Empty.ToString("D") } }),
        };
        foreach (var test in mutations)
        {
            var source = new ReceiptPipelineSource { Alter = test.Change };
            using var context = Context(source);
            var service = AccueilService.From(context); var plan = await service.PlanRefreshAsync("all", None);
            Check.True(plan.Targets > 0, "au moins une cible figée, refus pas vide : " + test.Name);
            var report = await service.RunRefreshAsync(plan.Id, true, _ => { }, None);
            Check.Equal(1, source.DirectoryCalls, "lecture complète réellement atteinte : " + test.Name);
            Check.Equal("done", report.Stages.Single(s => s.Id == "directory").State, "lecture AD réussie avant refus : " + test.Name);
            var commit = report.Stages.Single(s => s.Id == "commit");
            Check.Equal("failed", commit.State, "refus au reçu, pas à une étape préalable : " + test.Name);
            Check.Contains("Reçu local absent ou incohérent", commit.Detail, "cause précise : " + test.Name);
            Check.Equal(0, source.PresenceCalls, "aucune collecte ping : " + test.Name);
            Check.Equal(0, source.InventoryCalls, "aucune collecte inventaire : " + test.Name);
            Check.Equal(0, source.ProbeCalls, "aucune sonde complémentaire : " + test.Name);
            Check.Equal(CollectionStatus.Error, report.Runs.Single(r => r.Family == CollectionFamily.Directory).Status, "pas de fraîcheur réussie après reçu refusé : " + test.Name);
            Check.True(report.Stages.Where(s => s.Id is "presence" or "inventory").All(s => s.State == "skipped"), "étapes réseau explicitement non lancées");
        }
    }

    [Test]
    public static async Task Coherent_receipt_reports_its_batch_revision_and_sha_then_allows_collection()
    {
        var source = new ReceiptPipelineSource(); using var context = Context(source);
        var service = AccueilService.From(context); var plan = await service.PlanRefreshAsync("all", None);
        var report = await service.RunRefreshAsync(plan.Id, true, _ => { }, None);
        var commit = report.Stages.Single(s => s.Id == "commit");
        Check.Equal("done", commit.State, "contrôle positif du même pipeline");
        var proof = source.LastCommit!.Receipt;
        Check.Contains(proof.BatchId, commit.Detail, "identifiant du vrai reçu fourni affiché");
        Check.Contains("révision " + proof.Revision, commit.Detail, "révision du reçu");
        Check.Contains(proof.Sha256, commit.Detail, "SHA du reçu");
        Check.Equal(1, source.PresenceCalls, "collecte réellement atteinte après reçu");
        Check.Equal(1, source.InventoryCalls, "inventaire réellement atteint après ping");
        Check.Equal(CollectionStatus.Success, report.Runs.Single(r => r.Family == CollectionFamily.Directory).Status, "seul un reçu qualifié donne une réussite de cette étape");
    }

    [Test]
    public static async Task Failed_or_partial_AD_read_stops_the_chain_and_keeps_the_known_computers()
    {
        foreach (var partial in new[] { false, true })
        {
            var source = new ReceiptPipelineSource { FailDirectory = !partial, PartialDirectory = partial };
            using var context = Context(source); var service = AccueilService.From(context);
            var plan = await service.PlanRefreshAsync("all", None);
            var originalId = source.Current.Directory.Computers.Single().ObjectGuid;
            var report = await service.RunRefreshAsync(plan.Id, true, _ => { }, None);
            Check.Equal(1, source.DirectoryCalls, "échec/partiel AD réellement atteint");
            Check.Equal(partial ? "failed" : "skipped", report.Stages.Single(s => s.Id == "commit").State, "aucun reçu complet annoncé");
            Check.Equal(0, source.PresenceCalls, "décision ACC-005 du 26/10 : aucun ping après échec du prérequis");
            Check.Equal(0, source.InventoryCalls, "aucun inventaire après échec du prérequis");
            Check.Equal(originalId, source.Current.Directory.Computers.Single().ObjectGuid, "identité connue conservée pour une nouvelle action explicite");
            Check.Equal(partial ? CollectionStatus.Partial : CollectionStatus.Error,
                report.Runs.Single(r => r.Family == CollectionFamily.Directory).Status, "arrêt ne transforme pas le recensement en succès");
        }
    }

    private static EngineContext Context(ReceiptPipelineSource source) => new(
        ModeResolver.Resolve([], null, () => new DomainJoinInfo(DomainJoinState.Joined, "test.local")), source,
        new MemoryPreferenceStore(), TestClock.Fixed(), new RecordingJournal(),
        ScreenReaders.Discover(source, [typeof(ReceiptPipelineReader).Assembly]));
}

// Public only for the production reader-discovery path; fixture performs no LDAP, ICMP or WMI.
public sealed class ReceiptPipelineSource : IDirectorySource, IDirectoryRefreshPreparation
{
    internal static ScopeSelection Scope => DirectoryStorageReceiptTests.Scope;
    internal DirectoryState Current = new(Fixtures.Snapshot(computers: [Fixtures.Computer("PC1")]) with { Coverage = Scope }, FleetObservations.Empty, [], []);
    internal Func<DirectoryRefreshCommit, DirectoryRefreshCommit?> Alter = c => c;
    internal DirectoryRefreshCommit? LastCommit;
    internal bool FailDirectory, PartialDirectory;
    internal int DirectoryCalls, PresenceCalls, InventoryCalls, ProbeCalls;
    internal Guid LastPresenceTarget;
    private const long Epoch = 7;
    public DirectorySourceKind Kind => DirectorySourceKind.ActiveDirectory;
    public bool CanPrepareDirectoryRefresh => true;
    public Task<DirectoryBackupReceipt> PrepareDirectoryRefreshAsync(CancellationToken token) =>
        Task.FromResult(new DirectoryBackupReceipt(DirectoryStorageReceiptTests.StoreId, new('c', 64), Fixtures.Now));
    public Task<SessionSnapshot> GetSessionAsync(CancellationToken token) => Task.FromResult(new SessionSnapshot(
        ConnectionState.Connected, new("test.local", "TEST", Fixtures.Root), new("DC1.test.local", null),
        new(@"TEST\operator", null, null, null), new(AuthenticationMethod.WindowsSession, null, "Fixture"), Scope,
        new(RightsLevel.Read, "Lecture", false, "Fixture locale"), false,
        new(Current.Directory.ReadAt, Current.Directory.ObjectCount, Current.Directory.Complete), Epoch));
    public Task<DirectoryState> ReadLocalAsync(CancellationToken token) => Task.FromResult(Current);
    public Task<DirectoryState> RefreshAsync(MeasureFamily family, ScopeSelection? scope, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (family != MeasureFamily.Directory) { throw new InvalidOperationException("Les collectes doivent passer par le lecteur figé."); }
        DirectoryCalls++;
        if (FailDirectory) { throw new DomeniaOperationException("fixture.ad", "Lecture AD interrompue pour la recette."); }
        var snapshot = Current.Directory with { ReadAt = Fixtures.Now, Complete = !PartialDirectory, Coverage = Scope };
        LastCommit = PartialDirectory ? null : Alter(new(DirectoryStorageReceiptTests.Proof(snapshot), Epoch));
        Current = Current with { Directory = snapshot, DirectoryCommit = LastCommit };
        return Task.FromResult(Current);
    }
}

public sealed class ReceiptPipelineReader(ReceiptPipelineSource source) : IAccueilReader
{
    public Task<AccueilFacts> FactsAsync(CancellationToken token) => Task.FromResult(AccueilFacts.Empty(DirectoryStorageReceiptTests.StoreId));
    public Task<ImmutableArray<FleetSnapshot>> HistoryAsync(ScopeSelection scope, CancellationToken token) => Task.FromResult(ImmutableArray<FleetSnapshot>.Empty);
    public Task<BitLockerPresence> ReadBitLockerAsync(ScopeSelection scope, CancellationToken token) => throw new InvalidOperationException("Aucun index secret demandé.");
    public Task<ProbeReadings> CollectProbesAsync(ImmutableArray<string> ids, ScopeSelection scope, IReadOnlyCollection<Guid> online, CancellationToken token)
    { source.ProbeCalls++; return Task.FromResult(ProbeReadings.Empty); }
    public Task<DirectoryState> ReadPresenceAsync(ScopeSelection scope, IReadOnlyDictionary<Guid, QueryComputerIdentity> targets, long epoch, CancellationToken token)
    {
        source.PresenceCalls++; source.LastPresenceTarget = targets.Keys.Single();
        source.Current = source.Current with { Observations = new(Fixtures.Now, [.. source.Current.Directory.Computers.Where(c => targets.ContainsKey(c.ObjectGuid))
            .Select(c => Fixtures.Observe(c, Fixtures.Presence(true, TimeSpan.Zero)))]) };
        return Task.FromResult(source.Current);
    }
    public Task<DirectoryState> ReadInventoryAsync(ScopeSelection scope, IReadOnlyDictionary<Guid, QueryComputerIdentity> targets, long epoch, CancellationToken token) =>
        ReadInventoryAsync(scope, targets.Keys.ToHashSet(), token);
    public Task<DirectoryState> ReadInventoryAsync(ScopeSelection scope, IReadOnlySet<Guid> targets, CancellationToken token)
    {
        source.InventoryCalls++;
        source.Current = source.Current with { Observations = new(Fixtures.Now, [.. source.Current.Directory.Computers.Where(c => targets.Contains(c.ObjectGuid))
            .Select(c => Fixtures.Observe(c, Fixtures.Presence(true, TimeSpan.Zero), Fixtures.Disk(100, 80, TimeSpan.Zero)))]) };
        return Task.FromResult(source.Current);
    }
}

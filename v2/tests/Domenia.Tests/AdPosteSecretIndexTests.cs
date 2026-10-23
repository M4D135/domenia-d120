using System.Collections.Immutable;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;

namespace Domenia.Tests;

internal static class AdPosteSecretIndexTests
{
    private static ScopeSelection Scope(bool subtree = true) => new(Fixtures.Postes, "Postes", subtree);
    private static AdEntry Key(DirectoryComputer pc, string name = "Recovery", Guid? objectId = null, Guid? recovery = null) => new("CN=" + name + "," + pc.DistinguishedName,
        new Dictionary<string, IReadOnlyList<object>>
        {
            ["objectGUID"] = [(objectId ?? Fixtures.IdOf(name)).ToByteArray()], ["objectClass"] = ["top", "msFVE-RecoveryInformation"],
            ["msFVE-RecoveryGuid"] = [(recovery ?? Fixtures.IdOf("key-" + name)).ToByteArray()], ["name"] = [name], ["whenCreated"] = ["20260101000000.0Z"],
        });
    private static (AdPosteNetworkTests.Cache Cache, AdBoundaryTests.RecordingAdConnection Ldap, AdDirectorySource Source, AdPosteReader Reader) Fixture(params DirectoryComputer[] computers)
    {
        var cache = new AdPosteNetworkTests.Cache(Fixtures.Snapshot(computers: computers));
        var ldap = new AdBoundaryTests.RecordingAdConnection();
        var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        return (cache, ldap, source, new(source));
    }

    [Test]
    public static async Task Secret_index_refuses_the_domain_root_and_foreign_scope_before_network_contact()
    {
        var (_, ldap, source, reader) = Fixture(); using var owned = source;
        foreach (var scope in new[] { new ScopeSelection(Fixtures.Root, "Domaine", true), new ScopeSelection("OU=Postes,DC=other,DC=local", "Autre", true) })
        { await Check.ThrowsAsync<DomeniaOperationException>(() => reader.SecretsIndexAsync(scope, null, CancellationToken.None), "périmètre refusé"); }
        Check.Equal(0, ldap.Calls, "aucune requête hors périmètre");
    }

    [Test]
    public static async Task Secret_index_collects_only_metadata_and_revalidates_parents_after_the_OU_scan()
    {
        var pc = Fixtures.Computer("PC1"); var (cache, ldap, source, reader) = Fixture(pc); using var owned = source;
        ldap.SearchAnswer = q => q.Filter.Contains("msFVE", StringComparison.Ordinal) ? [Key(pc)] : [AdPosteNetworkTests.Entry(pc)];
        var result = await reader.SecretsIndexAsync(Scope(), null, CancellationToken.None);
        Check.Equal(1, result.WithKeys, "présence observée"); Check.False(result.Truncated, "lecture de tous les objets visibles achevée");
        Check.Equal(Fixtures.Now, result.Rows[0].BitLockerReadAt!.Value, "constat daté");
        Check.Equal(1, result.LapsMissing, "expiration invisible distincte d’une absence LAPS");
        Check.Equal("Unknown", result.Rows[0].LapsKind, "type non inventé");
        Check.True(ldap.Searches.All(q => q.Attributes.All(a => a is not ("msFVE-RecoveryPassword" or "msFVE-KeyPackage" or "msLAPS-Password" or "msLAPS-EncryptedPassword" or "ms-Mcs-AdmPwd"))), "aucune valeur secrète demandée");
        Check.True(ldap.Searches.First().ExpandRanges, "projection AD complète des postes conservés");
        Check.Equal("whenCreated", ldap.Searches.Last().Attributes.Last(), "identité temporelle relue après les clés");
        Check.Equal(1, cache.Fleet.WorkstationSecrets[pc.ObjectGuid].BitLocker!.Keys!.Value, "constat lié au GUID");
    }

    [Test]
    public static async Task Nonrecursive_secret_index_never_queries_a_subtree_or_keeps_a_computer_from_a_deeper_OU()
    {
        var pc = Fixtures.Computer("PC1"); var deeper = Fixtures.Computer("PC2", "OU=Enfant," + Fixtures.Postes);
        var (_, ldap, source, reader) = Fixture(pc); using var owned = source;
        ldap.SearchAnswer = q => q.BaseDn == Fixtures.Postes ? [AdPosteNetworkTests.Entry(pc), AdPosteNetworkTests.Entry(deeper)]
            : q.Scope == AdSearchScope.Base ? [AdPosteNetworkTests.Entry(pc)] : [Key(pc)];
        var result = await reader.SecretsIndexAsync(Scope(false), null, CancellationToken.None);
        Check.Equal(1, result.Total, "poste enfant hors sélection écarté"); Check.True(result.Truncated, "réponse inattendue signalée");
        Check.True(ldap.Searches.All(q => q.Scope != AdSearchScope.Subtree), "aucune recherche récursive");
        Check.False(ldap.Searches.Any(q => q.BaseDn == deeper.DistinguishedName), "aucun contact sous l’autre OU");
    }

    [Test]
    public static async Task Secret_index_discards_recreated_parent_counts_and_ambiguous_computer_identifiers()
    {
        var pc = Fixtures.Computer("PC1"); var (_, ldap, source, reader) = Fixture(pc); using var owned = source;
        ldap.SearchAnswer = q => q.Filter.Contains("msFVE", StringComparison.Ordinal) ? [Key(pc)]
            : [AdPosteNetworkTests.Entry(q.ExpandRanges ? pc : pc with { ObjectGuid = Guid.NewGuid() })];
        var result = await reader.SecretsIndexAsync(Scope(), null, CancellationToken.None);
        Check.Null(result.Rows[0].BitLockerKeys, "aucun nombre attribué après recréation du parent");
        Check.Equal(1, result.Unknown, "identité non concluante explicite");
        ldap.SearchAnswer = _ => [AdPosteNetworkTests.Entry(pc), AdPosteNetworkTests.Entry(pc)];
        var duplicate = await reader.SecretsIndexAsync(Scope(), null, CancellationToken.None);
        Check.Equal(0, duplicate.Total, "deux identités ambiguës exclues"); Check.True(duplicate.Truncated, "réponse ambiguë visible");
    }

    [Test]
    public static async Task Secret_index_does_not_turn_malformed_DNs_or_duplicated_recovery_objects_into_a_complete_zero()
    {
        var pc = Fixtures.Computer("PC1"); var (_, ldap, source, reader) = Fixture(pc); using var owned = source;
        ldap.SearchAnswer = q => q.Filter.Contains("msFVE", StringComparison.Ordinal)
            ? [Key(pc, "One", Fixtures.IdOf("same")), Key(pc, "Two", Fixtures.IdOf("same")), new AdEntry("invalid", new Dictionary<string, IReadOnlyList<object>>())]
            : [AdPosteNetworkTests.Entry(pc)];
        var result = await reader.SecretsIndexAsync(Scope(), null, CancellationToken.None);
        Check.Null(result.Rows[0].BitLockerKeys, "aucun faux zéro après ambiguïté"); Check.True(result.Truncated, "lecture partielle");
        Check.False(result.Summary.Contains("Lecture complète", StringComparison.Ordinal), "aucune promesse de lecture complète");
    }

    [Test]
    public static async Task Secret_index_retains_old_positive_presence_at_its_date_after_empty_or_refused_read()
    {
        foreach (var refused in new[] { false, true })
        {
            var pc = Fixtures.Computer("PC1"); var (cache, ldap, source, reader) = Fixture(pc); using var owned = source;
            var old = Fixtures.Now.AddDays(-1);
            await cache.SaveFleetAsync(FleetCachePatch.Empty with { WorkstationSecrets = ImmutableDictionary<Guid, WorkstationSecretMetadata>.Empty
                .Add(pc.ObjectGuid, new(new(old, FactState.Observed, 2, null), null, null)) }, CancellationToken.None);
            ldap.SearchAnswer = q => q.Filter.Contains("msFVE", StringComparison.Ordinal)
                ? refused ? throw new DomeniaOperationException(AdErrors.AccessDenied, "Refus simulé") : [] : [AdPosteNetworkTests.Entry(pc)];
            var result = await reader.SecretsIndexAsync(Scope(), null, CancellationToken.None);
            Check.Equal(2, result.Rows[0].BitLockerKeys!.Value, "présence ancienne conservée"); Check.Equal(old, result.Rows[0].BitLockerReadAt!.Value, "date non rajeunie");
            Check.Equal(FactState.Estimated, result.Rows[0].BitLockerState, "historique identifié");
            Check.Equal(refused ? 1 : 0, result.Refused, "refus actuel indépendant du constat ancien");
            Check.Equal(refused ? FactState.Refused : FactState.Observed, cache.Fleet.WorkstationSecrets[pc.ObjectGuid].BitLocker!.State, "tentative actuelle conservée séparément");
        }
    }

    [Test]
    public static async Task Stopped_secret_index_keeps_confirmed_rows_and_does_not_claim_a_zero_for_remaining_computers()
    {
        var pc = Fixtures.Computer("PC1"); var second = Fixtures.Computer("PC2"); var (cache, ldap, source, reader) = Fixture(pc, second); using var owned = source;
        using var stop = new CancellationTokenSource();
        ldap.SearchAnswer = q => q.BaseDn == Fixtures.Postes ? [AdPosteNetworkTests.Entry(pc), AdPosteNetworkTests.Entry(second)]
            : q.Scope == AdSearchScope.Base ? [AdPosteNetworkTests.Entry(pc)] : [Key(pc)];
        var result = await reader.SecretsIndexAsync(Scope(false), new Progress(p => { if (p.Done == 1) { stop.Cancel(); } }), stop.Token);
        Check.True(result.Truncated, "arrêt visible"); Check.Equal(1, result.WithKeys, "premier constat confirmé conservé"); Check.Equal(1, result.Unknown, "second non lu");
        Check.Equal(1, cache.Fleet.WorkstationSecrets[pc.ObjectGuid].BitLocker!.Keys!.Value, "sauvegarde achevée malgré l’arrêt");
        Check.False(ldap.Searches.Any(q => q.BaseDn == second.DistinguishedName), "aucun contact après arrêt");
    }

    private sealed class Progress(Action<PosteProgress> callback) : IProgress<PosteProgress> { public void Report(PosteProgress value) => callback(value); }
}

using System.Runtime.InteropServices;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class AdRelationConsoleTests
{
    private static WmiInstance Row(params (string Name, object? Value)[] values) => new(values.ToDictionary(v => v.Name, v => v.Value));
    private static WmiWorkstationReader Reader(Func<string, IReadOnlyList<WmiInstance>> answer) => new(TestClock.Fixed())
    {
        SessionFactory = (host, budget, token) => new(host, budget, TestClock.Fixed(), cancellationToken: token)
        {
            ReadOverride = (_, query, _) => answer(query),
            RegistryOverride = (_, _) => throw new InvalidOperationException("Aucun registre pour la console."),
        },
    };

    [Test]
    public static async Task Relation_console_is_current_native_evidence_with_a_pending_result_and_a_durable_local_receipt()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        var pc = Fixtures.Computer("PC1"); var user = Fixtures.User("alice"); var calls = 0;
        ldap.SearchAnswer = q => q.BaseDn == pc.DistinguishedName ? [AdPosteNetworkTests.Entry(pc)] : [AdRelationDirectoryTests.User(user)];
        var reader = new AdRelationsReader(source) { InventoryReaderOverride = _ => Reader(q =>
        {
            calls++; Check.Equal("SELECT Name, UserName FROM Win32_ComputerSystem", q, "une seule source courante");
            return [Row(("Name", "PC1"), ("UserName", @"TEST\alice"))];
        }) };
        var result = await reader.ComputerSessionAsync(pc.DistinguishedName, CancellationToken.None);
        Check.True(result.Savable, "observation qualifiée"); Check.False(result.Observed!.Certain, "SID du jeton inconnu");
        Check.Equal(RelationKind.Console, result.Observed.Kind, "console et non historique"); Check.Equal(Fixtures.Now, result.Observed.ObservedAt, "date native");
        Check.Equal(1, calls, "aucun repli"); Check.Equal(3, ldap.Searches.Count, "poste avant et après, utilisateur exact");
        Check.Equal(0L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "lecteur prépare ; le pont déclenche le stockage");
        var pending = await reader.PendingAsync(CancellationToken.None);
        Check.Equal(1, pending.Sets.Single(s => s.ResultId == result.ResultId).Remaining, "résultat spécifique visible en attente");
        using var writer = new AdRelationChangeExecutor(source);
        var saved = await writer.SaveObservationsAsync(CancellationToken.None);
        Check.Equal(1, saved.Saved, "stockage local automatique");
        Check.Equal(1, (await db.ReadRelationJournalAsync(CancellationToken.None)).Entries.Length, "journal durable");
        Check.Equal(0, (await reader.PendingAsync(CancellationToken.None)).Total, "aucun reste masqué");
        // Completed result handles do not fill the 16-slot preview pool during repeated console readings.
        for (var i = 0; i < 20; i++)
        {
            Check.True((await reader.ComputerSessionAsync(pc.DistinguishedName, CancellationToken.None)).Savable, "relecture toujours possible");
            await writer.SaveObservationsAsync(CancellationToken.None);
        }
        Check.Equal(1L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "aucun doublon");
    }

    [Test]
    public static async Task Console_missing_fields_duplicate_instances_and_partial_failures_never_mean_no_session()
    {
        var samples = new IReadOnlyList<WmiInstance>[] { [], [Row(("Name", "PC1"))],
            [Row(("Name", "PC1"), ("UserName", @"TEST\alice")), Row(("Name", "PC1"), ("UserName", @"TEST\bob"))] };
        foreach (var sample in samples)
        {
            var read = await Reader(_ => sample).ReadConsoleAccountAsync("PC1.test.local", CancellationToken.None, dcomOnly: true);
            Check.Equal(SourceStatus.Partial, read!.Status, "absence de champ ou ambiguïté explicite"); Check.Null(read.ConsoleUser, "aucun compte arbitraire");
        }
        var empty = await Reader(_ => [Row(("Name", "PC1"), ("UserName", null))]).ReadConsoleAccountAsync("PC1.test.local", CancellationToken.None);
        Check.Equal(SourceStatus.Empty, empty!.Status, "champ null réellement lu"); Check.Equal(Fixtures.Now, empty.ObservedAt!.Value, "lecture datée");
    }

    [Test]
    public static async Task Console_bare_local_foreign_and_ambiguous_accounts_do_not_create_relations()
    {
        foreach (var account in new[] { "alice", @"PC1\alice", @"OTHER\alice", @"TEST\alice" })
        {
            using var folder = new TemporaryFolder(); var (_, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
            var pc = Fixtures.Computer("PC1"); var user = AdRelationDirectoryTests.User(Fixtures.User("alice"));
            ldap.SearchAnswer = q => q.BaseDn == pc.DistinguishedName ? [AdPosteNetworkTests.Entry(pc)] : [user, user];
            var reader = new AdRelationsReader(source) { InventoryReaderOverride = _ => Reader(_ => [Row(("Name", "PC1"), ("UserName", account))]) };
            var result = await reader.ComputerSessionAsync(pc.DistinguishedName, CancellationToken.None);
            Check.False(result.Savable, "aucun compte qualifié"); Check.False(result.Observed!.Match, "lecture visible sans rapprochement");
            Check.Equal(account == @"TEST\alice" ? 3 : 2, ldap.Searches.Count, "aucune recherche d’homonyme non qualifié");
            Check.Equal(0, AdRelationSession.For(source).Snapshot(source.Epoch).Length, "aucune mémoire fabriquée");
        }
    }

    [Test]
    public static async Task Console_UPN_is_resolved_exactly_even_when_its_prefix_differs_from_SAM()
    {
        using var folder = new TemporaryFolder(); var (_, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        var pc = Fixtures.Computer("PC1"); var user = AdRelationDirectoryTests.User(Fixtures.User("alice"));
        var attrs = user.AttributeNames.ToDictionary(n => n, user.Raw, StringComparer.OrdinalIgnoreCase);
        attrs["userPrincipalName"] = ["a.autre@test.local"]; user = new(user.DistinguishedName, attrs);
        ldap.SearchAnswer = q => q.BaseDn == pc.DistinguishedName ? [AdPosteNetworkTests.Entry(pc)] : [user];
        var reader = new AdRelationsReader(source) { InventoryReaderOverride = _ => Reader(_ => [Row(("Name", "PC1"), ("UserName", "a.autre@test.local"))]) };
        var read = await reader.ComputerSessionAsync(pc.DistinguishedName, CancellationToken.None);
        Check.True(read.Savable, "UPN exact qualifié"); Check.Equal("alice", read.Observed!.Login, "SAM réel conservé");
        Check.True(ldap.Searches.Any(q => q.Filter.Contains("(userPrincipalName=a.autre@test.local)", StringComparison.Ordinal) && q.SizeLimit == 2), "filtre exact, ambiguïté détectable");
    }

    [Test]
    public static async Task Console_rejects_wrong_Windows_names_recreated_parents_and_users_created_after_the_reading()
    {
        foreach (var failure in new[] { "name", "parent", "user-date" })
        {
            using var folder = new TemporaryFolder(); var (_, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
            var pc = Fixtures.Computer("PC1"); var user = Fixtures.User("alice"); var parents = 0;
            ldap.SearchAnswer = q => q.BaseDn == pc.DistinguishedName
                ? [AdPosteNetworkTests.Entry(failure == "parent" && ++parents > 1 ? pc with { ObjectGuid = Guid.NewGuid() } : pc)]
                : [AdRelationDirectoryTests.User(failure == "user-date" ? user with { WhenCreated = Fixtures.Now.AddSeconds(1) } : user)];
            var reader = new AdRelationsReader(source) { InventoryReaderOverride = _ => Reader(_ => [Row(("Name", failure == "name" ? "OTHER" : "PC1"), ("UserName", @"TEST\alice"))]) };
            if (failure == "user-date") { Check.False((await reader.ComputerSessionAsync(pc.DistinguishedName, CancellationToken.None)).Savable, "compte créé après lecture écarté"); }
            else { await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ComputerSessionAsync(pc.DistinguishedName, CancellationToken.None), "identité remplacée refusée"); }
            Check.Equal(0, AdRelationSession.For(source).Snapshot(source.Epoch).Length, "pas de publication tardive");
        }
    }

    [Test]
    public static async Task Console_authentication_rejection_stops_before_other_sources_and_user_LDAP()
    {
        using var folder = new TemporaryFolder(); var (_, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        var pc = Fixtures.Computer("PC1"); var calls = 0; ldap.SearchAnswer = _ => [AdPosteNetworkTests.Entry(pc)];
        var reader = new AdRelationsReader(source) { InventoryReaderOverride = _ => Reader(_ => { calls++; throw new COMException("Rejet simulé", unchecked((int)0x8007052E)); }) };
        var result = await reader.ComputerSessionAsync(pc.DistinguishedName, CancellationToken.None);
        Check.False(result.Savable, "aucune observation"); Check.True(result.Attempts.Any(a => a.Status == "AUTH_REJETEE"), "rejet identifié");
        Check.Equal(1, calls, "aucun autre essai"); Check.Equal(1, ldap.Searches.Count, "aucune recherche utilisateur");
    }

    [Test]
    public static async Task Public_observation_strings_can_only_acknowledge_existing_native_evidence_without_changing_it()
    {
        using var folder = new TemporaryFolder(); var (_, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        var pc = Fixtures.Computer("PC1"); var reader = new AdRelationsReader(source);
        var request = new RelationObservationRequest(pc.DistinguishedName, @"TEST\alice", RelationRules.ConsoleSource, Fixtures.Now, "Fausse déclaration");
        Check.False((await reader.ObserveAsync(request, CancellationToken.None)).Accepted, "textes seuls insuffisants");
        var user = Fixtures.User("alice"); var record = new StoredRelation(user.SamAccountName, user.ObjectGuid, user.DistinguishedName, "PC1", pc.ObjectGuid, pc.DistinguishedName,
            RelationKind.Console, RelationRules.ConsoleSource, Fixtures.Now, "Preuve native conservée", true, null, null);
        AdRelationSession.For(source).ObserveValidated(record, source.Epoch);
        Check.True((await reader.ObserveAsync(request, CancellationToken.None)).Accepted, "accusé de réception seulement");
        foreach (var changed in new[] { request with { Account = "alice" }, request with { Account = @"OTHER\alice" }, request with { Source = "Autre" }, request with { ObservedAt = Fixtures.Now.AddMinutes(-1) } })
        { Check.False((await reader.ObserveAsync(changed, CancellationToken.None)).Accepted, "origine ou identité altérée refusée"); }
        Check.Equal(record, AdRelationSession.For(source).Snapshot(source.Epoch).Single(), "date, source, détails inchangés");
        Check.Equal(0, ldap.Searches.Count, "aucun réseau implicite");
    }
}

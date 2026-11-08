using Domenia.Ad;
using Domenia.Core;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class AdConsoleIdentityCacheTests
{
    [Test]
    public static async Task Actual_console_pipeline_reuses_only_positive_user_validation_and_still_requalifies_the_computer()
    {
        using var folder = new TemporaryFolder(); var (_, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        var pc = Fixtures.Computer("PC1"); var user = Fixtures.User("alice"); var userReads = 0; var machineReads = 0; var native = 0;
        ldap.SearchAnswer = q =>
        {
            if (q.BaseDn == pc.DistinguishedName) { machineReads++; return [AdPosteNetworkTests.Entry(pc)]; }
            userReads++; return [AdRelationDirectoryTests.User(user)];
        };
        var reader = new AdRelationsReader(source) { InventoryReaderOverride = _ => new WmiWorkstationReader(source.Clock)
        {
            SessionFactory = (host, budget, token) => new(host, budget, source.Clock, cancellationToken: token)
            { ReadOverride = (_, _, _) => { native++; return [new WmiInstance(new Dictionary<string, object?> { ["Name"] = "PC1", ["DNSHostName"] = "PC1", ["Domain"] = "test.local", ["UserName"] = @"TEST\alice" })]; } },
        } };
        Check.True((await reader.ComputerSessionAsync(pc.DistinguishedName, default)).Savable, "première qualification réelle");
        var second = await reader.ComputerSessionAsync(pc.DistinguishedName, default);
        Check.True(second.Savable, "console native relue"); Check.Contains("moins de 5 minutes", second.Observed!.Reason, "preuve datée indiquée");
        Check.Equal(1, userReads, "seule la recherche utilisateur évitée"); Check.Equal(4, machineReads, "poste avant et après chaque lecture"); Check.Equal(2, native, "pas de console mise en cache");
        ((FixedTimeProvider)source.Clock).Advance(TimeSpan.FromMinutes(5));
        Check.True((await reader.ComputerSessionAsync(pc.DistinguishedName, default)).Savable, "nouvelle vérification après expiration");
        Check.Equal(2, userReads, "TTL sans prolongation par consultation");
    }

    [Test]
    public static void Owner_bound_positive_cache_expires_is_bounded_and_cannot_cross_a_base_account_or_controller()
    {
        var clock = TestClock.Fixed(); var cache = new AdConsoleIdentityCache(clock, 2);
        var user = Fixtures.User("alice");
        var relation = new RelationObject(RelationSubjectKind.User, user.ObjectGuid, user.DistinguishedName, user.Cn,
            user.SamAccountName, null, true, null, user.WhenCreated, user.Sid, null);
        var key = new AdConsoleIdentityCache.Key(1, Fixtures.Root, "store", "reader", 1, "DC1", "filter");
        cache.Remember(key, relation); Check.NotNull(cache.Find(key), "preuve positive");
        foreach (var changed in new[] { key with { Epoch = 2 }, key with { Store = "other" }, key with { Account = "other" },
            key with { Selection = 2 }, key with { Controller = "DC2" }, key with { Filter = "other" }, key with { Domain = "DC=other" } })
        { Check.Null(cache.Find(changed), "aucun propriétaire voisin accepté"); }
        cache.Remember(key with { Filter = "second" }, relation); cache.Remember(key with { Filter = "third" }, relation);
        Check.Equal(2, cache.Count, "borne réelle"); Check.Null(cache.Find(key), "plus ancien évincé");
        clock.Advance(TimeSpan.FromMinutes(5)); Check.Null(cache.Find(key with { Filter = "third" }), "expiration à cinq minutes");
        cache.Remember(key, relation); clock.Advance(TimeSpan.FromMinutes(-1)); Check.Null(cache.Find(key), "retour horloge ne prolonge pas une preuve");
    }

    [Test]
    public static async Task Ambiguous_user_answers_are_never_cached_as_absence_or_confirmation()
    {
        using var folder = new TemporaryFolder(); var (_, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        var pc = Fixtures.Computer("PC1"); var user = AdRelationDirectoryTests.User(Fixtures.User("alice")); var userReads = 0;
        ldap.SearchAnswer = q => q.BaseDn == pc.DistinguishedName ? [AdPosteNetworkTests.Entry(pc)] : ++userReads == 1 ? [user, user] : [user];
        var reader = new AdRelationsReader(source) { InventoryReaderOverride = _ => new WmiWorkstationReader(source.Clock)
        {
            SessionFactory = (host, budget, token) => new(host, budget, source.Clock, cancellationToken: token)
            { ReadOverride = (_, _, _) => [new WmiInstance(new Dictionary<string, object?> { ["Name"] = "PC1", ["DNSHostName"] = "PC1", ["Domain"] = "test.local", ["UserName"] = @"TEST\alice" })] },
        } };
        Check.False((await reader.ComputerSessionAsync(pc.DistinguishedName, default)).Savable, "ambiguïté refusée");
        Check.True((await reader.ComputerSessionAsync(pc.DistinguishedName, default)).Savable, "lecture suivante réellement refaite");
        Check.Equal(2, userReads, "échec non mémorisé");
    }
}

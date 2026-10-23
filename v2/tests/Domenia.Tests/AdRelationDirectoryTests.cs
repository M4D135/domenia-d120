using System.Globalization;
using System.Security.Principal;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class AdRelationDirectoryTests
{
    private static AdEntry User(DirectoryUser user)
    {
        var sid = new SecurityIdentifier(user.Sid); var bytes = new byte[sid.BinaryLength]; sid.GetBinaryForm(bytes, 0);
        return new(user.DistinguishedName, new Dictionary<string, IReadOnlyList<object>>
        {
            ["objectGUID"] = [user.ObjectGuid.ToByteArray()], ["objectSid"] = [bytes], ["objectClass"] = ["top", "person", "user"],
            ["name"] = [user.Cn], ["sAMAccountName"] = [user.SamAccountName], ["displayName"] = [user.DisplayName ?? user.Cn], ["userAccountControl"] = [user.UserAccountControl],
            ["whenCreated"] = [user.WhenCreated.UtcDateTime.ToString("yyyyMMddHHmmss.0'Z'", CultureInfo.InvariantCulture)],
        });
    }
    private static async Task<(DomeniaDatabase Db, AdDirectorySource Source, AdBoundaryTests.RecordingAdConnection Ldap)> Open(TemporaryFolder folder)
    {
        var db = new DomeniaDatabase(folder.File("declarations.db"), Fixtures.Root, TestClock.Fixed()); var cache = new SqliteDirectoryCache(db);
        await cache.SaveObjectsAsync(Fixtures.Snapshot(users: [Fixtures.User("alice")], computers: [Fixtures.Computer("PC1")]), null, CancellationToken.None);
        var ldap = new AdBoundaryTests.RecordingAdConnection();
        ldap.SearchAnswer = q => DistinguishedName.AreEqual(q.BaseDn, Fixtures.User("alice").DistinguishedName) ? [User(Fixtures.User("alice"))]
            : DistinguishedName.AreEqual(q.BaseDn, Fixtures.Computer("PC1").DistinguishedName) ? [AdPosteNetworkTests.Entry(Fixtures.Computer("PC1"))] : [];
        var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        await source.ReadLocalAsync(CancellationToken.None); return (db, source, ldap);
    }
    private static Task<WritePlanDraft> Association(AdRelationChangeExecutor executor) => executor.PlanAssociationAsync(Fixtures.User("alice").DistinguishedName,
        Fixtures.User("alice").ObjectGuid, Fixtures.Computer("PC1").DistinguishedName, Fixtures.Computer("PC1").ObjectGuid, CancellationToken.None);
    private static WritePlan Bind(AdRelationChangeExecutor executor, WritePlanDraft draft, AdDirectorySource source)
    {
        var plan = WritePlans.Seal(draft, WritePlans.NewId(), @"TEST\operator", AppMode.Directory, source.Clock.GetUtcNow(), source.Zone); executor.Bind(draft, plan); return plan;
    }

    [Test]
    public static async Task Declared_native_relations_re_read_both_GUIDs_and_preserve_legacy_and_other_assignments()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await Open(folder); using var owned = source;
        using (var sql = new SqliteDatabase(db.Path, false))
        {
            sql.Execute("INSERT INTO user_machine_links(computer_key,user_login,computer,source) VALUES('PC1','alice','PC1','Saisie manuelle');");
            sql.Execute("INSERT INTO user_machine_links(computer_key,user_login,computer,source,user_guid,computer_guid) VALUES('autre','bob','PC1','Saisie manuelle',?1,?2);",
                Fixtures.User("bob").ObjectGuid.ToString("D"), Fixtures.Computer("PC1").ObjectGuid.ToString("D"));
        }
        using var executor = new AdRelationChangeExecutor(source); var draft = await Association(executor);
        Check.True(draft.Risks.Any(r => r.Tone == Tone.Warn), "autre affectation signalée");
        Check.Equal(2L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "aucune association modifiée pendant le plan");
        var plan = Bind(executor, draft, source); Check.True((await executor.CheckAsync(plan, CancellationToken.None)).Current, "identités toujours exactes");
        await executor.ExecuteAsync(plan, CancellationToken.None); var rows = (await db.ReadRelationsAsync(CancellationToken.None)).Rows;
        Check.Equal(3, rows.Length, "ancien nom et autre déclaration conservés"); Check.Null(rows.Single(r => r.StorageKey == "PC1").Relation.UserGuid, "historique sans GUID non réidentifié");
        Check.True(ldap.Searches.All(q => q.Scope == AdSearchScope.Base && q.SizeLimit == 2), "lectures de deux objets exacts seulement");
        Check.Equal(VerificationState.Verified, (await executor.VerifyAsync(plan, CancellationToken.None)).State, "relecture locale conforme");
        ((FixedTimeProvider)source.Clock).Advance(TimeSpan.FromMinutes(1));
        var refresh = await Association(executor); Check.Equal(WriteChangeKind.Replace, refresh.Changes.Single().Kind, "répétition actualise la déclaration GUID exacte");
        await executor.ExecuteAsync(Bind(executor, refresh, source), CancellationToken.None);
        Check.Equal(3L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "pas de quatrième association");
    }

    [Test]
    public static async Task Recreated_objects_cannot_prepare_or_execute_an_association_from_an_old_GUID()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await Open(folder); using var owned = source;
        using var executor = new AdRelationChangeExecutor(source); var plan = Bind(executor, await Association(executor), source);
        var original = ldap.SearchAnswer;
        ldap.SearchAnswer = q => DistinguishedName.AreEqual(q.BaseDn, Fixtures.User("alice").DistinguishedName)
            ? [User(Fixtures.User("alice") with { ObjectGuid = Fixtures.User("bob").ObjectGuid })] : original!(q);
        Check.False((await executor.CheckAsync(plan, CancellationToken.None)).Current, "GUID remplacé depuis le plan refusé");
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.ExecuteAsync(plan, CancellationToken.None), "aucun ajout avec ancienne identité");
        await Check.ThrowsAsync<DomeniaOperationException>(() => Association(executor), "GUID affiché devenu périmé refusé à la préparation");
        Check.Equal(0L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "aucune association créée");
    }

    [Test]
    public static async Task Foreign_DNs_and_empty_GUIDs_are_rejected_before_contact_and_a_foreign_controller_sends_no_object_query()
    {
        using var folder = new TemporaryFolder(); var (_, source, ldap) = await Open(folder); using var owned = source;
        using var executor = new AdRelationChangeExecutor(source);
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.PlanAssociationAsync(Fixtures.User("alice").DistinguishedName, Fixtures.User("alice").ObjectGuid,
            "CN=PC1,DC=foreign,DC=local", Fixtures.Computer("PC1").ObjectGuid, CancellationToken.None), "DN étranger");
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.PlanAssociationAsync(Fixtures.User("alice").DistinguishedName, Guid.Empty,
            Fixtures.Computer("PC1").DistinguishedName, Fixtures.Computer("PC1").ObjectGuid, CancellationToken.None), "GUID vide");
        Check.Equal(0, ldap.Calls, "aucun contact pour ces arguments"); ldap.RootContext = "DC=foreign,DC=local";
        await Check.ThrowsAsync<DomeniaOperationException>(() => Association(executor), "contrôleur étranger");
        Check.Equal(0, ldap.Searches.Count, "aucun objet demandé au contrôleur étranger");
    }

    [Test]
    public static async Task Native_target_search_is_bounded_escapes_literal_text_and_never_uses_full_member_projections()
    {
        using var folder = new TemporaryFolder(); var (_, source, ldap) = await Open(folder); using var owned = source;
        var reader = new AdRelationsReader(source); var user = Fixtures.User("alice");
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.TargetsAsync(user.DistinguishedName, "*", CancellationToken.None), "texte trop court");
        Check.Equal(0, ldap.Calls, "aucun réseau pendant refus de saisie");
        ldap.SearchAnswer = q => q.Scope == AdSearchScope.Base ? [User(user)] : Enumerable.Range(1, 51).Select(i => AdPosteNetworkTests.Entry(Fixtures.Computer("PC" + i))).ToArray();
        var found = await reader.TargetsAsync(user.DistinguishedName, "PC*)(x=y", CancellationToken.None);
        Check.Equal(50, found.Results.Length, "50 cibles maximum"); Check.True(found.Capped, "sentinelle explicite");
        var search = ldap.Searches.Single(q => q.Scope == AdSearchScope.Subtree);
        Check.Equal(51, search.SizeLimit, "une sentinelle seulement"); Check.Contains(@"\2a\29\28", search.Filter, "métacaractères littéraux échappés");
        Check.False(search.Attributes.Contains("memberOf"), "pas de groupes de chaque cible lus implicitement"); Check.False(search.ExpandRanges, "pas d’expansion secondaire");
    }

    [Test]
    public static async Task Target_search_excludes_duplicate_GUIDs_unknown_account_flags_and_wrong_object_types()
    {
        using var folder = new TemporaryFolder(); var (_, source, ldap) = await Open(folder); using var owned = source;
        var user = Fixtures.User("alice"); var pc1 = Fixtures.Computer("PC1");
        var missing = AdPosteNetworkTests.Entry(Fixtures.Computer("PC3"));
        var unreadable = new AdEntry(missing.DistinguishedName, missing.AttributeNames.Where(n => n != "userAccountControl").ToDictionary(n => n, missing.Raw));
        ldap.SearchAnswer = q => q.Scope == AdSearchScope.Base ? [User(user)] : [AdPosteNetworkTests.Entry(pc1),
            AdPosteNetworkTests.Entry(Fixtures.Computer("PC2") with { ObjectGuid = pc1.ObjectGuid }), unreadable, User(Fixtures.User("bob")), AdPosteNetworkTests.Entry(Fixtures.Computer("PC4"))];
        var result = await new AdRelationsReader(source).TargetsAsync(user.DistinguishedName, "PC", CancellationToken.None);
        Check.Equal(1, result.Results.Length, "une seule identité admissible"); Check.Equal("PC4", result.Results.Single().Name, "aucun premier doublon choisi");
        Check.Contains("écartées", result.Message, "incomplétude annoncée");
    }

    [Test]
    public static async Task Restoring_a_historical_assignment_does_not_implicitly_requalify_its_old_directory_identity()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await Open(folder); using var owned = source;
        using var executor = new AdRelationChangeExecutor(source); await executor.ExecuteAsync(Bind(executor, await Association(executor), source), CancellationToken.None);
        var relation = (await db.ReadRelationsAsync(CancellationToken.None)).Rows.Single().Relation;
        await executor.ExecuteAsync(Bind(executor, await executor.PlanRemovalAsync(RelationRules.Key(relation), RelationRules.Fingerprint(relation), CancellationToken.None), source), CancellationToken.None);
        var calls = ldap.Calls; ldap.SearchAnswer = _ => throw new InvalidOperationException("Une restauration historique ne lit pas LDAP.");
        var restore = Bind(executor, await executor.PlanRestoreAsync(null, CancellationToken.None), source);
        Check.True((await executor.CheckAsync(restore, CancellationToken.None)).Current, "restauration locale"); await executor.ExecuteAsync(restore, CancellationToken.None);
        Check.Equal(calls, ldap.Calls, "aucune requalification réseau"); Check.Equal(RelationRules.Fingerprint(relation), RelationRules.Fingerprint((await db.ReadRelationsAsync(CancellationToken.None)).Rows.Single().Relation), "historique exact conservé");
    }
}

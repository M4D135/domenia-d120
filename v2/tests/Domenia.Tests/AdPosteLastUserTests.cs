using System.Globalization;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;
using Domenia.Store;

namespace Domenia.Tests;

internal static class AdPosteLastUserTests
{
    private static WmiInstance Row(params (string Name, object? Value)[] values) => new(values.ToDictionary(p => p.Name, p => p.Value));
    private static string Dmtf(DateTimeOffset at) => at.UtcDateTime.ToString("yyyyMMddHHmmss.ffffff'+000'", CultureInfo.InvariantCulture);
    private static AdEntry User(DirectoryUser user)
    {
        var sid = new SecurityIdentifier(user.Sid); var bytes = new byte[sid.BinaryLength]; sid.GetBinaryForm(bytes, 0);
        return new(user.DistinguishedName, new Dictionary<string, IReadOnlyList<object>>
        {
            ["objectGUID"] = [user.ObjectGuid.ToByteArray()], ["objectSid"] = [bytes], ["objectClass"] = ["top", "person", "user"],
            ["sAMAccountName"] = [user.SamAccountName], ["displayName"] = [user.DisplayName ?? user.Cn],
            ["whenCreated"] = [user.WhenCreated.UtcDateTime.ToString("yyyyMMddHHmmss.0'Z'", CultureInfo.InvariantCulture)],
        });
    }
    private static (AdPosteNetworkTests.Cache Cache, AdBoundaryTests.RecordingAdConnection Ldap, AdDirectorySource Source) Fixture(DirectoryComputer pc, params DirectoryUser[] users)
    {
        var cache = new AdPosteNetworkTests.Cache(Fixtures.Snapshot(computers: [pc], users: users));
        var ldap = new AdBoundaryTests.RecordingAdConnection();
        return (cache, ldap, new("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache));
    }
    private static WmiWorkstationReader Reader(Func<string, IReadOnlyList<WmiInstance>> read, Func<RegistryRequest, RegistryReply>? registry = null) => new(TestClock.Fixed())
    {
        SessionFactory = (host, budget, token) => new(host, budget, TestClock.Fixed(), cancellationToken: token)
        { ReadOverride = (_, query, _) => read(query), RegistryOverride = (request, _) => registry?.Invoke(request) ?? new(2, null), UserRegistryOverride = (_, _) => new(2, null) },
    };

    [Test]
    public static async Task Confirmed_native_last_user_is_memorized_in_SQLite_with_a_durable_journal_and_without_AD_writes()
    {
        using var folder = new TemporaryFolder(); var pc = Fixtures.Computer("PC1"); var alice = Fixtures.User("alice");
        var db = new DomeniaDatabase(folder.File("last-user.db"), Fixtures.Root, TestClock.Fixed()); var cache = new SqliteDirectoryCache(db);
        await cache.SaveObjectsAsync(Fixtures.Snapshot(computers: [pc], users: [alice]), null, CancellationToken.None);
        var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => q.BaseDn == pc.DistinguishedName ? [AdPosteNetworkTests.Entry(pc)] : [User(alice)] };
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        var reader = new AdPosteReader(source) { InventoryReaderOverride = _ => Reader(_ => [Row(("Name", "PC1"), ("UserName", @"TEST\alice"))]) };
        var result = await reader.DetectLastUserAsync(pc.DistinguishedName, null, CancellationToken.None);
        Check.True(result.Verified, "compte confirmé"); Check.Contains("mémorisée", result.Verdict, "stockage local annoncé");
        var stored = (await db.ReadRelationsAsync(CancellationToken.None)).Rows.Single().Relation;
        Check.Equal(alice.ObjectGuid, stored.UserGuid!.Value, "utilisateur vérifié conservé"); Check.Equal(pc.ObjectGuid, stored.ComputerGuid!.Value, "poste vérifié conservé");
        Check.Equal(RelationKind.Console, stored.Kind, "observation, pas affectation déclarée");
        Check.Equal(1, (await db.ReadRelationJournalAsync(CancellationToken.None)).Entries.Length, "journal durable relu");
        Check.Equal(3, ldap.Searches.Count, "seulement les trois lectures de validation prévues");
        Check.Equal("CONFIRME", (await db.ReadRelationSweepsAsync(CancellationToken.None)).Rows.Single().Status, "passage console partagé avec Relations");
    }

    [Test]
    public static async Task Last_user_detection_stops_at_a_resolved_console_name_without_claiming_a_token_SID_or_replacing_an_assignment()
    {
        var alice = Fixtures.User("alice"); var bob = Fixtures.User("bob"); var pc = Fixtures.Computer("PC1") with { ManagedByDn = bob.DistinguishedName };
        var (cache, ldap, source) = Fixture(pc, alice, bob); using var owned = source; var reads = 0;
        ldap.SearchAnswer = q => q.BaseDn == pc.DistinguishedName ? [AdPosteNetworkTests.Entry(pc)] : [User(alice)];
        var reader = new AdPosteReader(source) { InventoryReaderOverride = _ => Reader(_ => { reads++; return [Row(("Name", "PC1"), ("UserName", @"TEST\alice"))]; }) };
        var result = await reader.DetectLastUserAsync(pc.DistinguishedName, null, CancellationToken.None);
        Check.True(result.Verified, "compte exact résolu dans AD"); Check.Equal(alice.ObjectGuid, result.Candidate!.Guid!.Value, "GUID du compte AD");
        Check.Equal(bob.ObjectGuid, result.Association.User!.Guid!.Value, "déclaration conservée");
        Check.True(result.Verdict.Contains("SID de l’observation n’a pas été lu", StringComparison.Ordinal), "absence de preuve SID visible");
        Check.Equal(1, reads, "aucune méthode supplémentaire après résolution"); Check.Equal(0, cache.FleetWrites, "aucune affectation écrite automatiquement");
        Check.Equal(2, ldap.Searches.Count(q => q.BaseDn == pc.DistinguishedName), "poste relu avant publication");
    }

    [Test]
    public static async Task Local_or_bare_console_names_never_become_a_same_named_domain_user()
    {
        foreach (var login in new[] { @"PC1\alice", @"OTHER\alice", "alice" })
        {
            var pc = Fixtures.Computer("PC1"); var (_, ldap, source) = Fixture(pc); using var owned = source;
            ldap.SearchAnswer = _ => [AdPosteNetworkTests.Entry(pc)];
            var reader = new AdPosteReader(source) { InventoryReaderOverride = _ => Reader(q => q.Contains("Win32_ComputerSystem", StringComparison.Ordinal)
                ? [Row(("Name", "PC1"), ("UserName", login))] : []) };
            var result = await reader.DetectLastUserAsync(pc.DistinguishedName, null, CancellationToken.None);
            Check.Null(result.Candidate, "aucune homonymie AD"); Check.Equal(1, ldap.Searches.Count, "aucune recherche de l’utilisateur non qualifié");
        }
    }

    [Test]
    public static async Task Profile_history_uses_the_SID_and_actual_last_use_date_without_reading_or_inventing_an_account_from_a_folder()
    {
        var alice = Fixtures.User("alice"); var pc = Fixtures.Computer("PC1"); var (_, ldap, source) = Fixture(pc); using var owned = source;
        ldap.SearchAnswer = q => q.BaseDn == pc.DistinguishedName ? [AdPosteNetworkTests.Entry(pc)] : [User(alice)];
        var at = Fixtures.Now.AddDays(-1);
        var reader = new AdPosteReader(source) { InventoryReaderOverride = _ => Reader(q => q.Contains("Win32_ComputerSystem", StringComparison.Ordinal)
            ? [Row(("Name", "PC1"), ("UserName", null))] : [Row(("SID", alice.Sid), ("LastUseTime", Dmtf(at)), ("Special", false))]) };
        var result = await reader.DetectLastUserAsync(pc.DistinguishedName, null, CancellationToken.None);
        Check.Equal(alice.ObjectGuid, result.Candidate!.Guid!.Value, "identité par SID"); Check.Equal(AssociationBadge.History, result.Association.Badge, "historique distinct du courant");
        Check.Equal(at, result.Association.At!.Value, "date réelle du profil conservée"); Check.True(result.Association.IdentityProven, "SID effectivement comparé");
        Check.True(ldap.Searches.Any(q => q.Filter.Contains("(objectSid=" + alice.Sid + ")", StringComparison.Ordinal)), "recherche exacte par SID");
    }

    [Test]
    public static async Task LogonUI_names_remain_undated_history_and_are_not_presented_as_live_sessions()
    {
        var alice = Fixtures.User("alice"); var pc = Fixtures.Computer("PC1"); var (_, ldap, source) = Fixture(pc); using var owned = source;
        ldap.SearchAnswer = q => q.BaseDn == pc.DistinguishedName ? [AdPosteNetworkTests.Entry(pc)] : [User(alice)];
        var reader = new AdPosteReader(source) { InventoryReaderOverride = _ => Reader(_ => [Row(("Name", "PC1"), ("UserName", null))], _ => new(0, @"TEST\alice")) };
        var result = await reader.DetectLastUserAsync(pc.DistinguishedName, null, CancellationToken.None);
        Check.Equal(AssociationBadge.History, result.Association.Badge, "nom historique seulement"); Check.False(result.Association.IdentityProven, "SID inconnu");
        Check.True(result.Association.Rule.Contains("date de connexion inconnue", StringComparison.Ordinal), "date de lecture distinguée de la connexion");
    }

    [Test]
    public static async Task Last_user_detection_rejects_another_Windows_machine_and_a_parent_recreated_before_publication()
    {
        foreach (var wrongHost in new[] { true, false })
        {
            var pc = Fixtures.Computer("PC1"); var alice = Fixtures.User("alice"); var (_, ldap, source) = Fixture(pc); using var owned = source; var parentReads = 0;
            ldap.SearchAnswer = q => q.BaseDn == pc.DistinguishedName ? [AdPosteNetworkTests.Entry(++parentReads > 1 ? pc with { ObjectGuid = Guid.NewGuid() } : pc)] : [User(alice)];
            var reader = new AdPosteReader(source) { InventoryReaderOverride = _ => Reader(_ => [Row(("Name", wrongHost ? "OTHER" : "PC1"), ("UserName", @"TEST\alice"))]) };
            await Check.ThrowsAsync<DomeniaOperationException>(() => reader.DetectLastUserAsync(pc.DistinguishedName, null, CancellationToken.None), "identité différente refusée");
            var consent = new ConsentState(new(false, null, 0, "", null), new(false, null, 0, "", null));
            Check.Null((await reader.OpenAsync(pc.DistinguishedName, PosteHealthPolicy.Default, consent, CancellationToken.None)).Association.User, "aucun résultat tardif mémorisé");
        }
    }

    [Test]
    public static async Task Authentication_rejection_stops_the_detection_before_registry_profiles_or_AD_user_lookup()
    {
        var pc = Fixtures.Computer("PC1"); var (_, ldap, source) = Fixture(pc); using var owned = source; var calls = 0;
        ldap.SearchAnswer = _ => [AdPosteNetworkTests.Entry(pc)];
        var reader = new AdPosteReader(source) { InventoryReaderOverride = _ => Reader(_ => { calls++; throw new COMException("Rejet simulé", unchecked((int)0x8007052E)); }) };
        var result = await reader.DetectLastUserAsync(pc.DistinguishedName, null, CancellationToken.None);
        Check.False(result.Verified, "rien confirmé"); Check.Equal(1, calls, "une seule tentative d’authentification");
        Check.True(result.Attempts.Any(a => a.Status == "AUTH_REJETEE"), "rejet explicite"); Check.Equal(1, ldap.Searches.Count, "pas de recherche d’identité utilisateur");
    }

    [Test]
    public static async Task Missing_console_field_and_ambiguous_profiles_never_become_a_complete_empty_result()
    {
        var alice = Fixtures.User("alice");
        var reader = Reader(q => q.Contains("Win32_ComputerSystem", StringComparison.Ordinal) ? [Row(("Name", "PC1"))]
            : [Row(("SID", alice.Sid), ("LastUseTime", Dmtf(Fixtures.Now.AddDays(-1))), ("Special", false)),
                Row(("SID", alice.Sid), ("LastUseTime", Dmtf(Fixtures.Now.AddDays(-2))), ("Special", false))]);
        var console = await reader.ReadUserSourceAsync("PC1.test.local", UserDetectionSource.Console, CancellationToken.None);
        Check.Equal(SourceStatus.Partial, console.Access.Status, "champ manquant non transformé en console vide");
        var profiles = await reader.ReadUserSourceAsync("PC1.test.local", UserDetectionSource.Profiles, CancellationToken.None);
        Check.Equal(SourceStatus.Partial, profiles.Access.Status, "doublon non transformé en absence de profils"); Check.Equal(0, profiles.Candidates.Length, "deux SID ambigus écartés");
    }
}

using System.Security.Principal;
using Domenia.Ad;
using Domenia.Core;

namespace Domenia.Tests;

internal static class AdFicheObjectTests
{
    private const string Dn = "CN=Compte,OU=Postes,DC=test,DC=local";

    [Test]
    public static async Task Fiche_reads_use_safe_schema_names_and_do_not_expand_members_on_open()
    {
        using var ldap = new AdBoundaryTests.RecordingAdConnection
        {
            SearchAnswer = q => q.Scope != AdSearchScope.Base ? [] :
                [Entry(q.Attributes.Contains("allowedAttributes") ? new() { ["allowedAttributes"] = ["description", "memberOf", "nTSecurityDescriptor", "unicodePwd", "msLAPS-Password"] }
                    : new() { ["description"] = ["Équipe"], ["memberOf;range=0-1"] = ["CN=A," + Fixtures.Root, "CN=B," + Fixtures.Root] })],
        };
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), connection: ldap);
        var read = await new AdFicheObjects(source).ReadAsync(Dn, CancellationToken.None);
        var requests = ldap.Searches.Where(q => q.Scope == AdSearchScope.Base).ToArray();
        Check.Equal(2, requests.Length, "schéma de l’objet puis valeurs");
        Check.True(requests.All(q => q.BaseDn == Dn && q.SizeLimit == 2), "objet exact et sentinelle");
        Check.False(requests.SelectMany(q => q.Attributes).Any(a => a == "*" || FicheAttributeRules.IsSensitive(a)), "aucun secret demandé");
        Check.False(requests[1].ExpandRanges, "pas de lecture implicite de tous les membres");
        Check.True(requests[1].ReadOwnerAndDacl, "droits sans SACL");
        Check.Equal(2, read.HiddenSensitive, "noms sensibles exclus avant lecture");
        Check.Equal("FALSE", read.Entry.First("__memberOfComplete"), "appartenances partielles dites");
        Check.Equal(Fixtures.IdOf("fiche-exact").ToString("D"), read.Entry.First("objectGUID"), "identité en format D");
        Check.True(read.Entry.First("objectSid")!.StartsWith("S-1-5-21-", StringComparison.Ordinal), "SID lisible");
    }

    [Test]
    public static async Task A_changed_object_is_refused_between_schema_and_value_reads()
    {
        using var ldap = new AdBoundaryTests.RecordingAdConnection
        {
            SearchAnswer = q => q.Scope != AdSearchScope.Base ? [] : [Entry(q.Attributes.Contains("allowedAttributes")
                ? new() { ["allowedAttributes"] = ["description"] } : new() { ["uSNChanged"] = ["2"] })],
        };
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), connection: ldap);
        var failure = await Check.ThrowsAsync<DomeniaOperationException>(() => new AdFicheObjects(source).ReadAsync(Dn, CancellationToken.None), "objet modifié pendant la lecture");
        Check.Equal(DomeniaErrors.SourceUnavailable, failure.Code, "relecture explicite nécessaire");
    }

    [Test]
    public static async Task Exact_account_reads_do_not_invent_enabled_state_or_reuse_a_cached_account()
    {
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => q.Scope == AdSearchScope.Base ? [Entry(new())] : [] };
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), connection: ldap);
        var reader = new AdFicheObjects(source);
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.UserAsync(Dn, CancellationToken.None), "UAC absent");
        ldap.SearchAnswer = q => q.Scope == AdSearchScope.Base ? [Entry(new() { ["userAccountControl"] = ["512"] })] : [];
        var user = await reader.UserAsync(Dn, CancellationToken.None);
        Check.True(user is not null, "compte confirmé");
        ldap.SearchAnswer = _ => [];
        Check.Null(await reader.UserAsync(Dn, CancellationToken.None), "aucun compte récupéré d’un ancien cache");
    }

    [Test]
    public static async Task Exact_object_reads_refuse_malformed_DNs_before_connecting_and_foreign_targets_before_searching()
    {
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), connection: ldap);
        var reader = new AdFicheObjects(source);
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ReadAsync("not-a-dn", CancellationToken.None), "DN invalide");
        Check.Equal(0, ldap.Calls, "aucune connexion");
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ReadAsync("CN=A,DC=elsewhere,DC=local", CancellationToken.None), "objet étranger");
        Check.False(ldap.Searches.Any(q => q.Scope == AdSearchScope.Base), "aucun objet étranger interrogé");
    }

    [Test]
    public static void Binary_attributes_keep_their_raw_value_and_only_initial_ranges_are_projected()
    {
        var entry = Entry(new() { ["userCertificate"] = [new byte[] { 0, 255, 128 }], ["memberOf;range=0-*"] = ["CN=A," + Fixtures.Root] });
        var fiche = AdFicheObjects.Project(entry);
        Check.Equal("00FF80", fiche.First("userCertificate"), "binaire en hexadécimal sans décodage UTF-8");
        Check.False(fiche.Has("__memberOfComplete"), "tranche terminale complète");
        Check.Throws<DomeniaOperationException>(() => AdFicheObjects.Project(Entry(new() { ["memberOf;range=1-*"] = ["CN=A," + Fixtures.Root] })), "début de liste manquant");
        Check.Throws<DomeniaOperationException>(() => AdFicheObjects.Project(Entry(new() { ["memberOf;range=0-2"] = ["CN=A," + Fixtures.Root] })), "tranche incomplète");
    }

    private static AdEntry Entry(Dictionary<string, IReadOnlyList<object>> extra)
    {
        var sid = new SecurityIdentifier("S-1-5-21-1-2-3-1001");
        var bytes = new byte[sid.BinaryLength];
        sid.GetBinaryForm(bytes, 0);
        var values = new Dictionary<string, IReadOnlyList<object>>(StringComparer.OrdinalIgnoreCase)
        {
            ["objectGUID"] = [Fixtures.IdOf("fiche-exact").ToByteArray()], ["objectClass"] = ["top", "person", "user"],
            ["name"] = ["Compte"], ["objectSid"] = [bytes], ["uSNChanged"] = ["1"],
        };
        foreach (var pair in extra) { values[pair.Key] = pair.Value; }
        return new(Dn, values);
    }
}

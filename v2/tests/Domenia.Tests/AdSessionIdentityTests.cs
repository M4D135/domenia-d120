using System.Net;
using System.Security;
using System.Security.Principal;
using Domenia.Ad;
using Domenia.Core;

namespace Domenia.Tests;

internal static class AdSessionIdentityTests
{
    [Test]
    public static void Explicit_accounts_never_use_the_desktop_SID_and_filter_values_are_escaped()
    {
        var sid = Fixtures.Domain.DomainSid + "-1001";
        var filter = AdSessionIdentity.Filter(Fixtures.Domain, "TEST\\a*)(name=*)", sid, true)!;
        Check.True(filter.Contains("a\\2a\\29\\28name=\\2a\\29", StringComparison.Ordinal), "syntaxe LDAP traitée comme valeur");
        Check.False(filter.Contains("objectSid", StringComparison.Ordinal), "SID Windows jamais utilisé pour un compte explicite");
        Check.Null(AdSessionIdentity.Filter(Fixtures.Domain, "OTHER\\Alice", sid, true), "aucun repli sur un homonyme de ce domaine");
        Check.True(AdSessionIdentity.Filter(Fixtures.Domain, "Alice@alias.example", sid, true)!.Contains("(userPrincipalName=Alice@alias.example)", StringComparison.Ordinal), "suffixe UPN recherché exactement");
        Check.Equal("(objectSid=" + sid + ")", AdSessionIdentity.Filter(Fixtures.Domain, "TEST\\desktop", sid, false), "session Windows par SID");
    }

    [Test]
    public static async Task The_authenticated_object_is_exact_and_membership_does_not_prove_delegated_rights()
    {
        var item = User("Alice", 1002);
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = _ => [item] };
        var identity = await AdSessionIdentity.ReadAsync(ldap, Fixtures.Domain, "Alice@test.local", Fixtures.Domain.DomainSid + "-1001", true, CancellationToken.None);
        Check.Equal("TEST\\Alice", identity.Identity.Login, "compte de la connexion explicite");
        Check.Equal(Fixtures.Domain.DomainSid + "-1002", identity.Sid, "SID de ce compte, pas celui du bureau");
        Check.Equal(RightsLevel.Unknown, identity.Rights.Level, "adminCount et groupes ne prouvent pas un droit effectif");
        Check.Equal(2, ldap.Searches.Single().SizeLimit, "ambiguïté détectable");
        await Check.ThrowsAsync<DomeniaOperationException>(() => AdSessionIdentity.ReadAsync(ldap, Fixtures.Domain, "TEST\\Alice", Fixtures.Domain.DomainSid + "-1001", false, CancellationToken.None), "autre SID Windows refusé");
        ldap.SearchAnswer = _ => [item, item];
        await Check.ThrowsAsync<DomeniaOperationException>(() => AdSessionIdentity.ReadAsync(ldap, Fixtures.Domain, "TEST\\Alice", null, true, CancellationToken.None), "plusieurs résultats refusés");
    }

    [Test]
    public static void LDAP_connections_own_independent_secure_copies()
    {
        Check.Throws<DomeniaOperationException>(() => new AdConnection(new(null, "test.local") { Credential = new NetworkCredential() }), "compte incomplet sans repli implicite");
        using var secret = new SecureString(); secret.AppendChar('x'); secret.MakeReadOnly();
        var supplied = new NetworkCredential("Alice", secret, "TEST");
        using var original = new AdConnection(new(null, "test.local") { Credential = supplied });
        supplied.UserName = "Changed"; supplied.SecurePassword = null;
        Check.Equal("TEST\\Alice", original.ExplicitLogin, "identité indépendante de l’objet du demandeur");
        using var otherDc = original.ForServer("dc2.test.local");
        original.Dispose();
        var copy = otherDc.CopyCredential();
        using (copy.Password) { Check.Equal(1, copy.Password!.Length, "fermeture d’un contrôleur sans effacer l’autre"); }
        Check.Equal(1, secret.Length, "secret original toujours détenu par son appelant");
    }

    [Test]
    public static async Task A_local_session_card_does_not_claim_Kerberos_or_the_desktop_identity_for_an_explicit_connection()
    {
        using var secret = new SecureString(); secret.AppendChar('x'); secret.MakeReadOnly();
        using var connection = new AdConnection(new(null, "test.local") { Credential = new NetworkCredential("Alice", secret, "TEST") });
        using var source = new AdDirectorySource("test.local", () => "DESKTOP\\Other", TestClock.Fixed(), connection: connection);
        var session = await source.GetSessionAsync(CancellationToken.None);
        Check.Equal("TEST\\Alice", session.Account.Login, "compte explicite annoncé avant connexion");
        Check.Equal(AuthenticationMethod.ExplicitCredentials, session.Authentication.Method, "origine du compte exacte");
        Check.Null(session.Authentication.Protocol, "protocole non mesuré");
        Check.Equal(ConnectionState.Disconnected, session.Connection, "aucune connexion implicite");
    }

    [Test]
    public static async Task Reset_during_connection_does_not_publish_a_late_account()
    {
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => "test", TestClock.Fixed(), connection: ldap);
        ldap.SearchAnswer = _ => { source.Reset(); return []; };
        var error = await Check.ThrowsAsync<DomeniaOperationException>(() => source.ConnectAsync(CancellationToken.None), "connexion périmée");
        Check.Equal(AdErrors.NotConnected, error.Code, "session restée fermée");
        Check.Equal(ConnectionState.Disconnected, (await source.GetSessionAsync(CancellationToken.None)).Connection, "aucun état tardif publié");
    }

    private static AdEntry User(string sam, int rid)
    {
        var sid = new SecurityIdentifier(Fixtures.Domain.DomainSid + "-" + rid);
        var bytes = new byte[sid.BinaryLength]; sid.GetBinaryForm(bytes, 0);
        return AdFicheReaderTests.Entry("CN=" + sam + "," + Fixtures.People, "user", new()
        {
            ["objectSid"] = [bytes], ["sAMAccountName"] = [sam], ["userPrincipalName"] = [sam + "@test.local"],
            ["adminCount"] = ["1"], ["memberOf"] = ["CN=Domain Admins," + Fixtures.Root],
        });
    }
}

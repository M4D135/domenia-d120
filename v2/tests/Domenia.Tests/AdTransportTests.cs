using System.Collections;
using System.DirectoryServices.Protocols;
using System.Globalization;
using System.Reflection;
using Domenia.Ad;
using Domenia.Core;

namespace Domenia.Tests;

internal static class AdTransportTests
{
    [Test]
    public static void Schema_binary_hints_preserve_custom_octets_and_cannot_request_extra_or_secret_fields()
    {
        var entry = (SearchResultEntry)Activator.CreateInstance(typeof(SearchResultEntry), BindingFlags.Instance | BindingFlags.NonPublic,
            binder: null, args: [Fixtures.Postes], culture: CultureInfo.InvariantCulture)!;
        ((IDictionary)entry.Attributes).Add("customBinary", new DirectoryAttribute("customBinary", new byte[] { 0, 255, 128, 0, 1 }));
        var hints = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "customBinary" };
        var read = AdConnection.ReadEntry(entry, hints);
        Check.True(read.Bytes("customBinary")!.SequenceEqual(new byte[] { 0, 255, 128, 0, 1 }), "octets non UTF-8 conservés sans remplacement");
        AdConnection.ValidateReadRequest(new(Fixtures.Postes, "(objectClass=*)", AdSearchScope.Base, ["customBinary"]) { BinaryAttributes = hints });
        Check.Throws<DomeniaOperationException>(() => AdConnection.ValidateReadRequest(new(Fixtures.Postes, "(objectClass=*)", AdSearchScope.Base, ["description"]) { BinaryAttributes = hints }), "indice ne peut pas étendre la requête");
        Check.Throws<DomeniaOperationException>(() => AdConnection.ValidateReadRequest(new(Fixtures.Postes, "(objectClass=*)", AdSearchScope.Base, ["unicodePwd"]) { BinaryAttributes = new HashSet<string> { "unicodePwd" } }), "secret toujours interdit");
    }

    [Test]
    public static void Binary_schema_results_are_bounded_local_to_the_schema_and_exclude_secret_names()
    {
        const string schema = "CN=Schema,CN=Configuration," + Fixtures.Root;
        AdEntry Definition(string name, string syntax, string parent = schema) => new("CN=" + name + "," + parent,
            new Dictionary<string, IReadOnlyList<object>> { ["lDAPDisplayName"] = [name], ["attributeSyntax"] = [syntax] });
        var custom = Definition("customBinary", "2.5.5.10");
        var names = AdConnection.BinarySchemaNames([custom, Definition("unicodePwd", "2.5.5.10"), Definition("descriptor", "2.5.5.15"), Definition("sidField", "2.5.5.17")], schema);
        Check.True(names.Contains("CUSTOMBINARY") && names.Contains("descriptor") && names.Contains("sidField"), "trois syntaxes binaires confirmées");
        Check.False(names.Contains("unicodePwd"), "valeur sensible jamais demandée");
        Check.Throws<DomeniaOperationException>(() => AdConnection.BinarySchemaNames([Definition("x", "2.5.5.12")], schema), "syntaxe étrangère au filtre");
        Check.Throws<DomeniaOperationException>(() => AdConnection.BinarySchemaNames([Definition("x", "2.5.5.10", Fixtures.Root)], schema), "objet hors schéma");
        Check.Throws<DomeniaOperationException>(() => AdConnection.BinarySchemaNames([custom, custom], schema), "doublon refusé");
        Check.Throws<DomeniaOperationException>(() => AdConnection.BinarySchemaNames(Enumerable.Repeat(custom, 2001).ToArray(), schema), "troncature refusée");
    }

    [Test]
    public static async Task Password_UTF16_buffers_are_quoted_then_erased_even_when_the_send_fails()
    {
        using var password = PasswordSecrets.FromText("Été-🦊-2026!");
        foreach (var fail in new[] { false, true })
        {
            byte[]? held = null;
            ModifyRequest? seen = null;
            var task = AdConnection.WithPasswordRequestAsync(Fixtures.IdOf("reset"), password, true, true,
                AdConnection.PasswordPolicyControl(["1.2.840.113556.1.4.2239"]), (request, token) =>
                {
                    seen = request; held = (byte[])request.Modifications[0][0];
                    Check.True(held.SequenceEqual(System.Text.Encoding.Unicode.GetBytes("\"Été-🦊-2026!\"")), "octets UTF-16 entre guillemets, sans double encodage BER");
                    Check.Equal(3, request.Modifications.Count, "secret et deux options dans la même requête");
                    Check.Equal("0", request.Modifications[1][0], "changement imposé");
                    Check.True(request.Controls[0].IsCritical, "stratégie obligatoire");
                    Check.True(request.Controls[0].GetValue().SequenceEqual(new byte[] { 0x30, 0x03, 0x02, 0x01, 0x01 }), "historique et âge minimal exigés");
                    return fail ? Task.FromException(new AdWriteOutcomeUnknownException()) : Task.CompletedTask;
                }, CancellationToken.None);
            if (fail) { await Check.ThrowsAsync<AdWriteOutcomeUnknownException>(() => task, "réponse perdue"); } else { await task; }
            Check.True(held!.All(b => b == 0), "tampon effacé après retour réel");
            Check.Equal(0, seen!.Modifications.Count, "références du message libérées");
        }
        Check.Equal("1.2.840.113556.1.4.2066", AdConnection.PasswordPolicyControl(["1.2.840.113556.1.4.2066"]), "ancien contrôle documenté");
        Check.Throws<DomeniaOperationException>(() => AdConnection.PasswordPolicyControl([]), "aucun repli sans stratégie");
    }

    [Test]
    public static void A_transport_failure_after_a_mutation_is_never_a_proven_directory_refusal()
    {
        foreach (var failure in new Exception[] { new LdapException(81, "diagnostic privé"), new TimeoutException("diagnostic privé"), new ObjectDisposedException("diagnostic privé"), new DirectoryOperationException("diagnostic privé") })
        {
            var result = AdConnection.MapMutationFailure("modify", failure);
            Check.True(result is AdWriteOutcomeUnknownException, "issue inconnue sans réponse LDAP définitive");
            Check.False(result is DomeniaOperationException, "le circuit ne doit pas conclure non appliqué");
            Check.False(result.ToString().Contains("diagnostic privé", StringComparison.Ordinal), "diagnostic brut absent des journaux");
            Check.Null(result.InnerException, "aucun diagnostic indirect");
        }
    }

    [Test]
    public static void Another_Windows_protocol_gets_the_selected_credential_and_an_independent_secure_copy()
    {
        using var secret = new System.Security.SecureString();
        secret.AppendChar('x');
        secret.MakeReadOnly();
        using var connection = new AdConnection(new("dc.test.local", "test.local")
        { Credential = new System.Net.NetworkCredential(@"TEST\alice", secret) });
        var first = connection.CopyCredential();
        Check.Equal("alice", first.User, "identité sélectionnée");
        Check.Equal("TEST", first.Domain, "autorité du compte");
        Check.True(first.Password!.IsReadOnly(), "copie en lecture seule");
        first.Dispose();
        var second = connection.CopyCredential();
        using (second) { Check.Equal(1, second.Password!.Length, "la copie précédente ne détruit pas le secret de connexion"); }
        using var windows = new AdConnection(new("dc.test.local", "test.local"));
        using var windowsCopy = windows.CopyCredential();
        Check.Null(windowsCopy.Password, "contexte Windows sans mot de passe");
    }

    [Test]
    public static void LDAP_result_attributes_are_read_as_dictionary_values_with_binary_identity_intact()
    {
        // Protocols constructs entries internally; this fixture exercises its real collection, not a look-alike dictionary.
        var entry = (SearchResultEntry)Activator.CreateInstance(typeof(SearchResultEntry), BindingFlags.Instance | BindingFlags.NonPublic,
            binder: null, args: [Fixtures.Postes], culture: CultureInfo.InvariantCulture)!;
        var id = Fixtures.IdOf("transport-entry");
        var attributes = (IDictionary)entry.Attributes;
        attributes.Add("objectguid", new DirectoryAttribute("objectGUID", id.ToByteArray()));
        attributes.Add("description", new DirectoryAttribute("description", "Équipe de test"));
        attributes.Add("member;range=0-1", new DirectoryAttribute("member;range=0-1", "CN=A," + Fixtures.Postes, "CN=B," + Fixtures.Postes));
        var read = AdConnection.ReadEntry(entry);
        Check.Equal(id, read.Guid("objectGUID"), "GUID binaire conservé");
        Check.Equal("Équipe de test", read.String("description"), "texte intact");
        Check.Equal(2, read.Raw("member;range=0-1").Count, "tranche explicite conservée");
        Check.False(read.Has("member"), "une tranche ne devient pas une liste complète");
    }

    [Test]
    public static async Task Empty_wildcard_secret_or_malformed_attribute_requests_are_refused_before_connecting()
    {
        using var connection = new AdConnection(new("unreachable.invalid", "test.local"));
        foreach (var attributes in new string[][] { [], ["*"], ["+"], ["unicodePwd"], ["MSLAPS-Password;range=0-*"], ["member;range=2-1"], ["member;range=0-*;binary"] })
        {
            var failure = await Check.ThrowsAsync<DomeniaOperationException>(() => connection.SearchAsync(new(Fixtures.Postes, "(objectClass=*)", AdSearchScope.Base, attributes), CancellationToken.None), "attributs interdits");
            Check.Equal(DomeniaErrors.ArgumentsInvalid, failure.Code, "refus local avant résolution de serveur");
            Check.Null(connection.Server, "connexion non ouverte");
        }
    }

    [Test]
    public static void Ranges_require_exact_continuity_and_an_explicit_terminal_slice()
    {
        Check.True(AdAttributeRange.TryParse("member;range=0-1499", out var first), "première tranche");
        first!.Validate(0, 1500, 0, 50000);
        Check.True(AdAttributeRange.TryParse("member;range=1500-*", out var last), "dernière tranche");
        last!.Validate(1500, 400, 1500, 50000);
        Check.Throws<DomeniaOperationException>(() => first.Validate(0, 1499, 0, 50000), "tranche amputée");
        Check.Throws<DomeniaOperationException>(() => last.Validate(1499, 400, 1500, 50000), "trou ou chevauchement");
        Check.Throws<DomeniaOperationException>(() => first.Validate(0, 1500, 0, 1500), "limite atteinte avec suite annoncée");
        last.Validate(1500, 400, 1500, 1900);
        Check.Throws<DomeniaOperationException>(() => last.Validate(1500, 401, 1500, 1900), "débordement de la limite");
        foreach (var malformed in new[] { "member;range=0-2147483647", "member;range=-1-*", "member;range=4-2", "member;range=+0-*", "member;range=0-*;x" })
        { Check.False(AdAttributeRange.TryParse(malformed, out _), "syntaxe de tranche stricte"); }
    }

    [Test]
    public static void LDAP_read_budgets_and_security_descriptor_scope_cannot_be_disabled()
    {
        var request = new AdSearchRequest(Fixtures.Postes, "(objectClass=*)", AdSearchScope.Base, ["objectGUID"]);
        foreach (var invalid in new[] { request with { Budget = TimeSpan.Zero }, request with { Budget = TimeSpan.FromHours(1) },
            request with { MaxRangeValues = 0 }, request with { MaxRangeValues = 50001 }, request with { ReadOwnerAndDacl = true } })
        { Check.Throws<DomeniaOperationException>(() => AdConnection.ValidateReadRequest(invalid), "budget ou contrôle incohérent"); }
        AdConnection.ValidateReadRequest(request with { ReadOwnerAndDacl = true, Attributes = ["nTSecurityDescriptor"] });
        AdConnection.ValidateReadRequest(request with { Attributes = ["member;range=0-1499"], ExpandRanges = false });
    }
}

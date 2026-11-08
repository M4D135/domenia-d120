using System.Buffers.Binary;
using System.Text;
using System.Text.Json;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Tests;

internal static class LapsReadingTests
{
    private const string Value = "fixture-Secret-À-123!";
    private static string Json => JsonSerializer.Serialize(new { n = "LocalAdmin", t = Fixtures.Now.ToFileTime().ToString("x", System.Globalization.CultureInfo.InvariantCulture), p = Value });
    private static byte[] Envelope()
    {
        var value = new byte[32]; BinaryPrimitives.WriteInt64LittleEndian(value, Fixtures.Now.ToFileTime());
        BinaryPrimitives.WriteUInt32LittleEndian(value.AsSpan(8), 16); return value;
    }
    private static AdEntry Entry(DirectoryComputer pc, params (string Name, object Value)[] attributes)
    {
        var first = AdPosteNetworkTests.Entry(pc);
        var values = first.AttributeNames.ToDictionary(n => n, first.Raw, StringComparer.OrdinalIgnoreCase);
        foreach (var (name, value) in attributes) { values[name] = [value]; }
        return new(first.DistinguishedName, values);
    }
    private static (DirectoryComputer Computer, AdBoundaryTests.RecordingAdConnection Ldap, AdDirectorySource Source) Fixture()
    {
        var pc = Fixtures.Computer("PC1"); var cache = new AdPosteNetworkTests.Cache(Fixtures.Snapshot(computers: [pc]));
        var ldap = new AdBoundaryTests.RecordingAdConnection();
        return (pc, ldap, new("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache));
    }

    [Test]
    public static void LAPS_JSON_preserves_unicode_and_rejects_ambiguous_or_unbounded_values_without_echoing_them()
    {
        using var parsed = LapsPassword.ParseText(Json);
        Check.Equal("LocalAdmin", parsed.Account, "compte publié"); Check.Equal(Value, new string(parsed.Password), "valeur Unicode intacte");
        Check.Equal(Fixtures.Now, parsed.Updated, "horodatage hexadécimal UTC");
        foreach (var invalid in new[] { Json[..^1] + ",\"p\":\"second\"}", Json + "{}", "{\"p\":\"" + Value + "\"}",
            Json.Replace("LocalAdmin", "DOMAIN\\\\someone", StringComparison.Ordinal), Json.Replace("fixture-Secret-", new string('a', 257), StringComparison.Ordinal),
            "{\"n\":\"a\",\"t\":\"0\",\"p\":\"" + Value + "\"}", "{\"n\":\"a\",\"t\":\"1\",\"p\":null}", new string('x', 16385) })
        {
            var error = Check.Throws<DomeniaOperationException>(() => LapsPassword.ParseText(invalid), "JSON incohérent rejeté");
            Check.False(error.Message.Contains(Value, StringComparison.Ordinal), "pas de valeur dans l’erreur");
        }
    }

    [Test]
    public static void LAPS_envelope_checks_size_reserved_timestamp_and_UTF16_payload_agreement()
    {
        var blob = Envelope(); Check.Equal(Fixtures.Now.ToFileTime(), LapsPassword.CheckEnvelope(blob), "en-tête valide");
        foreach (var field in new[] { 0, 8, 12 })
        {
            var bad = (byte[])blob.Clone(); if (field == 0) { Array.Clear(bad, 0, 8); } else { bad[field] ^= 1; }
            Check.Throws<DomeniaOperationException>(() => LapsPassword.CheckEnvelope(bad), "en-tête refusé");
        }
        var utf16 = Encoding.Unicode.GetBytes(Json + "\0");
        using var parsed = LapsPassword.ParseUtf16(utf16, Fixtures.Now.ToFileTime());
        Check.Equal(Value, new string(parsed.Password), "JSON UTF16 avec terminaison native");
        Check.Throws<DomeniaOperationException>(() => LapsPassword.ParseUtf16(utf16, Fixtures.Now.AddMinutes(1).ToFileTime()), "date du JSON différente de l’en-tête");
        Check.Throws<DomeniaOperationException>(() => LapsPassword.ParseUtf16([0], Fixtures.Now.ToFileTime()), "UTF16 tronqué");
    }

    [Test]
    public static async Task Plain_Windows_LAPS_reveals_only_after_GUID_revalidation_and_never_requests_legacy_passwords()
    {
        var (pc, ldap, source) = Fixture(); using var owned = source; var reader = new AdPosteReader(source);
        ldap.SearchAnswer = _ => [Entry(pc, ("msLAPS-PasswordExpirationTime", Fixtures.Now.AddDays(1).ToFileTime()), ("msLAPS-Password", Json))];
        using var secret = await reader.RevealLapsAsync(pc.DistinguishedName, CancellationToken.None);
        Check.Equal("LocalAdmin", secret.Identifier, "compte publié"); Check.Equal(Value, secret.CopyText(), "mot de passe choisi");
        Check.False(JsonSerializer.Serialize(secret).Contains(Value, StringComparison.Ordinal), "pas de secret sérialisé");
        Check.False(ldap.Searches.Any(q => q.Attributes.Contains("ms-Mcs-AdmPwd")), "ancien mot de passe non demandé");
        Check.Equal(3, ldap.Searches.Count, "identité, lecture, revalidation");
    }

    [Test]
    public static async Task Legacy_LAPS_never_invents_the_managed_account_name()
    {
        var (pc, ldap, source) = Fixture(); using var owned = source;
        ldap.SearchAnswer = _ => [Entry(pc, ("ms-Mcs-AdmPwdExpirationTime", Fixtures.Now.AddDays(1).ToFileTime()), ("ms-Mcs-AdmPwd", Value))];
        using var secret = await new AdPosteReader(source).RevealLapsAsync(pc.DistinguishedName, CancellationToken.None);
        Check.True(secret.Identifier.Contains("non publié", StringComparison.Ordinal), "pas d’Administrateur inventé");
        Check.Equal(Value, secret.CopyText(), "valeur historique explicite");
        Check.False(ldap.Searches.Any(q => q.Attributes.Contains("msLAPS-EncryptedPassword")), "source historique choisie sur métadonnées");
    }

    [Test]
    public static async Task An_unreadable_Windows_LAPS_value_never_falls_back_to_an_obsolete_legacy_password()
    {
        var (pc, ldap, source) = Fixture(); using var owned = source;
        ldap.SearchAnswer = _ => [Entry(pc, ("msLAPS-PasswordExpirationTime", Fixtures.Now.AddDays(1).ToFileTime()), ("ms-Mcs-AdmPwd", Value))];
        var error = await Check.ThrowsAsync<DomeniaOperationException>(() => new AdPosteReader(source).RevealLapsAsync(pc.DistinguishedName, CancellationToken.None), "valeur Windows invisible");
        Check.Equal(PosteErrors.Refused, error.Code, "publication ou droit non confirmé");
        Check.False(ldap.Searches.Any(q => q.Attributes.Contains("ms-Mcs-AdmPwd")), "aucun repli sur l’ancien mot de passe");
    }

    [Test]
    public static async Task Encrypted_LAPS_uses_the_sealed_identity_and_a_decrypt_refusal_never_uses_a_clear_value()
    {
        var (pc, ldap, source) = Fixture(); using var owned = source; var count = 0;
        ldap.SearchAnswer = _ => [Entry(pc, ("msLAPS-PasswordExpirationTime", Fixtures.Now.AddDays(1).ToFileTime()), ("msLAPS-EncryptedPassword", Envelope()), ("msLAPS-Password", Json))];
        var reader = new AdPosteReader(source) { DecryptLapsOverride = (_, identity, _) =>
        {
            count++; Check.True(identity.Session, "identité Windows explicitement sélectionnée");
            Check.Equal(@"TEST\operator", identity.Account, "compte scellé");
            throw LapsDecryptor.Status(5);
        } };
        var error = await Check.ThrowsAsync<DomeniaOperationException>(() => reader.RevealLapsAsync(pc.DistinguishedName, CancellationToken.None), "décryptage refusé");
        Check.Equal(LapsDecryptor.Denied, error.Code, "refus distinct d’une absence"); Check.Equal(1, count, "un seul essai");
        Check.Equal(2, ldap.Searches.Count, "pas d’autre lecture après refus");
    }

    [Test]
    public static async Task Computer_recreation_after_LAPS_decryption_discards_the_value_and_disposes_the_payload()
    {
        var (pc, ldap, source) = Fixture(); using var owned = source; var read = false;
        var payload = new LapsPassword("LocalAdmin", Fixtures.Now, Value.ToCharArray());
        ldap.SearchAnswer = _ => [Entry(read ? pc with { ObjectGuid = Guid.NewGuid() } : pc,
            ("msLAPS-PasswordExpirationTime", Fixtures.Now.AddDays(1).ToFileTime()), ("msLAPS-EncryptedPassword", Envelope()))];
        var reader = new AdPosteReader(source) { DecryptLapsOverride = (_, _, _) => { read = true; return Task.FromResult(payload); } };
        var error = await Check.ThrowsAsync<DomeniaOperationException>(() => reader.RevealLapsAsync(pc.DistinguishedName, CancellationToken.None), "identité modifiée après déchiffrement");
        Check.Equal(PosteErrors.ComputerUnknown, error.Code, "résultat écarté"); Check.True(payload.Password.ToArray().All(c => c == 0), "tampon déchiffré effacé");
    }

    [Test]
    public static void Decryption_error_classification_separates_credentials_rights_and_unavailable_keys()
    {
        Check.Equal(AdErrors.Credentials, LapsDecryptor.Status(1326).Code, "rejet d’authentification suspendable");
        Check.Equal(LapsDecryptor.Denied, LapsDecryptor.Status(unchecked((int)0x80090010)).Code, "refus de déchiffrement");
        Check.Equal(LapsDecryptor.Failed, LapsDecryptor.Status(unchecked((int)0x80090011)).Code, "clé CNG indisponible ne prouve pas un refus de droit");
    }
}

using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Tests;

internal static class AdPosteSecretsTests
{
    private const string Password = "000011-000022-000033-000044-000055-000066-000077-000088";
    private static readonly Guid Recovery = Guid.Parse("b9ebcb0c-3054-40ac-b2c0-3b3846de69dc");
    private static readonly Guid ObjectId = Guid.Parse("fbe4b995-3535-4248-a969-87152a344d1b");
    private static string KeyDn(DirectoryComputer pc) => "CN=Recovery," + pc.DistinguishedName;
    private static AdEntry Add(AdEntry entry, params (string Name, object Value)[] attributes)
    {
        var values = entry.AttributeNames.ToDictionary(n => n, entry.Raw, StringComparer.OrdinalIgnoreCase);
        foreach (var (name, value) in attributes) { values[name] = [value]; }
        return new(entry.DistinguishedName, values);
    }
    private static AdEntry Key(DirectoryComputer pc, Guid? recovery = null, Guid? objectId = null, string? password = null) => new(KeyDn(pc),
        new Dictionary<string, IReadOnlyList<object>>
        {
            ["objectGUID"] = [(objectId ?? ObjectId).ToByteArray()], ["objectClass"] = ["top", "msFVE-RecoveryInformation"],
            ["msFVE-RecoveryGuid"] = [(recovery ?? Recovery).ToByteArray()], ["msFVE-VolumeGuid"] = [Guid.Parse("3bdbb9e3-bb66-4370-91f2-f833122df054").ToByteArray()],
            ["name"] = ["Recovery"], ["whenCreated"] = ["20260101000000.0Z"], ["msFVE-RecoveryPassword"] = password is null ? [] : [password],
        });
    private static (DirectoryComputer Computer, AdPosteNetworkTests.Cache Cache, AdBoundaryTests.RecordingAdConnection Ldap, AdDirectorySource Source, AdPosteReader Reader) Fixture()
    {
        var pc = Fixtures.Computer("PC1"); var cache = new AdPosteNetworkTests.Cache(Fixtures.Snapshot(computers: [pc]));
        var ldap = new AdBoundaryTests.RecordingAdConnection();
        var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        return (pc, cache, ldap, source, new(source));
    }

    [Test]
    public static async Task LAPS_metadata_never_reads_a_password_or_claims_that_an_expiration_proves_a_readable_value()
    {
        var (pc, cache, ldap, source, reader) = Fixture(); using var owned = source;
        ldap.SearchAnswer = _ => [Add(AdPosteNetworkTests.Entry(pc), ("msLAPS-PasswordExpirationTime", Fixtures.Now.AddDays(1).ToFileTime()))];
        var view = await reader.LapsAsync(pc.DistinguishedName, CancellationToken.None);
        Check.Equal(LapsState.Unconfirmed, view.State, "aucun état disponible avant lecture du mot de passe");
        Check.True(view.CanReveal, "geste explicite proposé sans prélecture secrète");
        Check.True(ldap.Searches.All(q => q.Attributes.All(a => a is "objectGUID" or "objectClass" or "msLAPS-PasswordExpirationTime" or "ms-Mcs-AdmPwdExpirationTime")), "projection fermée sans secret");
        Check.Equal(1, cache.FleetWrites, "métadonnées enregistrées seules");
        Check.NotNull(cache.Fleet.WorkstationSecrets[pc.ObjectGuid].Laps, "expiration datée liée au GUID");
    }

    [Test]
    public static async Task Recovery_listing_excludes_ambiguous_ids_and_never_requests_recovery_passwords()
    {
        var (pc, cache, ldap, source, reader) = Fixture(); using var owned = source;
        ldap.SearchAnswer = q => q.Scope == AdSearchScope.OneLevel ? [Key(pc), Key(pc, objectId: Guid.NewGuid())] : [AdPosteNetworkTests.Entry(pc)];
        var list = await reader.BitLockerListAsync(pc.DistinguishedName, CancellationToken.None);
        Check.Equal(0, list.Keys.Length, "doublons exclus tous les deux");
        Check.True(list.StatusText.Contains("partielle", StringComparison.Ordinal), "réponse ambiguë signalée");
        var query = ldap.Searches.Single(q => q.Scope == AdSearchScope.OneLevel);
        Check.Equal(257, query.SizeLimit, "une ligne de garde détecte le dépassement de 256");
        Check.True(query.BinaryAttributes.Contains("msFVE-RecoveryGuid"), "GUID demandé sous forme binaire");
        Check.False(ldap.Searches.Any(q => q.Attributes.Contains("msFVE-RecoveryPassword")), "aucun mot de passe demandé");
        Check.Equal(1, cache.FleetWrites, "tentative enregistrée sans secret");
        Check.Null(cache.Fleet.WorkstationSecrets[pc.ObjectGuid].BitLocker!.Keys, "ambiguïté non transformée en zéro");
    }

    [Test]
    public static async Task Recovery_reveal_rejects_a_foreign_child_or_incomplete_identifier_before_any_LDAP_contact()
    {
        var (pc, _, ldap, source, reader) = Fixture(); using var owned = source;
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.RevealBitLockerAsync(pc.DistinguishedName, "CN=Recovery," + Fixtures.People, Recovery.ToString(), CancellationToken.None), "autre parent refusé");
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.RevealBitLockerAsync(pc.DistinguishedName, KeyDn(pc), Recovery.ToString()[..8], CancellationToken.None), "GUID incomplet refusé");
        Check.Equal(0, ldap.Calls, "validation avant le moindre contact");
    }

    [Test]
    public static async Task Recovery_identifier_mismatch_stops_before_the_secret_attribute_is_requested()
    {
        var (pc, _, ldap, source, reader) = Fixture(); using var owned = source;
        ldap.SearchAnswer = q => q.BaseDn == pc.DistinguishedName ? [AdPosteNetworkTests.Entry(pc)] : [Key(pc, Guid.NewGuid())];
        var error = await Check.ThrowsAsync<DomeniaOperationException>(() => reader.RevealBitLockerAsync(pc.DistinguishedName, KeyDn(pc), Recovery.ToString(), CancellationToken.None), "identifiant étranger");
        Check.Equal(PosteErrors.KeyMismatch, error.Code, "erreur sans contenu");
        Check.False(ldap.Searches.Any(q => q.Attributes.Contains("msFVE-RecoveryPassword")), "la clé non choisie n’est pas lue");
    }

    [Test]
    public static async Task Recovery_reveal_uses_one_exact_object_then_revalidates_the_parent_and_never_serializes_the_value()
    {
        var (pc, cache, ldap, source, reader) = Fixture(); using var owned = source;
        ldap.SearchAnswer = q => q.BaseDn == pc.DistinguishedName ? [AdPosteNetworkTests.Entry(pc)] : [Key(pc, password: q.Attributes.Contains("msFVE-RecoveryPassword") ? Password : null)];
        using var result = await reader.RevealBitLockerAsync(pc.DistinguishedName, KeyDn(pc), Recovery.ToString(), CancellationToken.None);
        Check.Equal(Password, result.CopyText(), "valeur reçue par le propriétaire natif seulement");
        Check.Equal(8, result.Blocks.Length, "huit blocs");
        Check.True(ldap.Searches.Single(q => q.Attributes.Contains("msFVE-RecoveryPassword")).Filter.Contains(AdObjectAccess.GuidFilter(ObjectId), StringComparison.Ordinal), "requête scellée au GUID de l’objet récupération");
        Check.Equal(2, ldap.Searches.Count(q => q.BaseDn == pc.DistinguishedName), "parent relu avant et après");
        Check.False(JsonSerializer.Serialize(result).Contains("000011", StringComparison.Ordinal), "aucun bloc JSON");
        Check.False(result.ToString().Contains("000011", StringComparison.Ordinal), "aucun bloc dans les traces");
        Check.Equal(0, cache.FleetWrites, "aucun stockage de clé");
    }

    [Test]
    public static async Task Recovery_recreation_or_parent_recreation_discards_a_secret_already_received()
    {
        foreach (var parentChanged in new[] { false, true })
        {
            var (pc, _, ldap, source, reader) = Fixture(); using var owned = source; var received = false;
            ldap.SearchAnswer = q =>
            {
                if (q.BaseDn == pc.DistinguishedName) { return [AdPosteNetworkTests.Entry(parentChanged && received ? pc with { ObjectGuid = Guid.NewGuid() } : pc)]; }
                if (q.Attributes.Contains("msFVE-RecoveryPassword")) { received = true; return [Key(pc, objectId: parentChanged ? ObjectId : Guid.NewGuid(), password: Password)]; }
                return [Key(pc)];
            };
            var error = await Check.ThrowsAsync<DomeniaOperationException>(() => reader.RevealBitLockerAsync(pc.DistinguishedName, KeyDn(pc), Recovery.ToString(), CancellationToken.None), "objet remplacé après sélection");
            Check.Equal(parentChanged ? PosteErrors.ComputerUnknown : PosteErrors.KeyMismatch, error.Code, "recréation écartée");
            Check.False(error.Message.Contains("000011", StringComparison.Ordinal), "erreur sans secret");
        }
    }

    [Test]
    public static void Secret_owner_clears_its_buffer_on_disposal_and_cannot_copy_or_reveal_again()
    {
        foreach (var laps in new[] { false, true })
        {
            var value = new SecretReading(laps ? "laps" : "bitlocker", "PC1", "identifier", null, laps ? "fixture-password" : null,
                laps ? [] : PosteSecrets.Blocks(Password), 30, 30, 1, "notice", "notice", false, Fixtures.Now);
            Check.True(value.CopyText().Length > 0, "valeur disponible avant fermeture");
            value.Dispose(); value.Dispose();
            Check.Null(value.Value, "mot de passe libéré"); Check.Equal(0, value.Blocks.Length, "blocs libérés");
            Check.Throws<ObjectDisposedException>(() => value.CopyText(), "aucune recopie après fermeture");
            Check.Equal("identifier", value.Identifier, "métadonnées non secrètes disponibles pour le reçu de fermeture");
        }
    }
}

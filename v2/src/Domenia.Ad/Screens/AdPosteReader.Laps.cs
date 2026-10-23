using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Ad;

public sealed partial class AdPosteReader
{
    internal Func<byte[], RemoteProbeCredential, CancellationToken, Task<LapsPassword>>? DecryptLapsOverride { get; init; }

    public async Task<SecretReading> RevealLapsAsync(string dn, CancellationToken cancellationToken)
    {
        using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(35), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
        var local = await LocalAsync(dn, budget.Token).ConfigureAwait(false);
        using var access = await AdReadAccess.AcquireAsync(source, CredentialRules.Laps, dn, budget.Token).ConfigureAwait(false);
        // First validate the selected computer without any confidential attribute. The secret request repeats its GUID filter.
        var metadata = await SecretComputerAsync(local, access, LapsMetadata, budget.Token).ConfigureAwait(false);
        var windows = metadata.Has("msLAPS-PasswordExpirationTime") || !metadata.Has("ms-Mcs-AdmPwdExpirationTime");
        string[] attributes = windows ? [.. LapsMetadata, "msLAPS-EncryptedPassword", "msLAPS-Password"] : [.. LapsMetadata, "ms-Mcs-AdmPwd"];
        var query = SecretQuery(dn, "(&(objectClass=computer)" + AdObjectAccess.GuidFilter(local.Computer.ObjectGuid) + ")", AdSearchScope.Base, attributes)
            with { BinaryAttributes = windows ? ImmutableHashSet.Create(StringComparer.OrdinalIgnoreCase, "msLAPS-EncryptedPassword") : ImmutableHashSet<string>.Empty };
        var entries = await access.SearchAsync(query, budget.Token).ConfigureAwait(false);
        if (entries.Count != 1 || entries[0].Guid("objectGUID") != local.Computer.ObjectGuid || !HasClass(entries[0], "computer")
            || !DistinguishedName.AreEqual(entries[0].DistinguishedName, dn))
        { throw new DomeniaOperationException(PosteErrors.ComputerUnknown, "Identité du poste modifiée pendant la lecture LAPS ; résultat écarté."); }
        var entry = entries[0];
        LapsPassword? password = null; SecretReading? result = null;
        try
        {
            // Never downgrade to a legacy/clear value after a failed encrypted Windows value.
            if (entry.Has("msLAPS-EncryptedPassword"))
            {
                if (entry.Raw("msLAPS-EncryptedPassword").Count != 1 || entry.Bytes("msLAPS-EncryptedPassword") is not { } blob) { throw LapsPassword.Invalid(); }
                _ = LapsPassword.CheckEnvelope(blob);
                using var credential = access.CopyNativeCredential();
                try { password = await (DecryptLapsOverride ?? LapsDecryptor.ReadAsync)(blob, credential, budget.Token).ConfigureAwait(false); }
                catch (DomeniaOperationException ex) when (ex.Code is AdErrors.Credentials or LapsDecryptor.Denied)
                {
                    access.EnsureCurrent();
                    if (source.AccountContext is { } context)
                    { AccountAccess.From(context).RegisterRefusal(CredentialRules.Laps, "Déchiffrement LAPS", dn, ex.Code == AdErrors.Credentials ? "badCredentials" : "decryptionDenied", access.AccountKey, true); }
                    throw;
                }
            }
            else if (entry.Has("msLAPS-Password"))
            {
                if (entry.Raw("msLAPS-Password") is not [string json]) { throw LapsPassword.Invalid(); }
                password = LapsPassword.ParseText(json);
            }
            else if (windows || entry.Has("msLAPS-PasswordExpirationTime"))
            {
                // A current Windows LAPS deployment may leave an obsolete legacy value behind; it is not the current password.
                throw LapsNotVisible(access, dn);
            }
            else if (entry.Raw("ms-Mcs-AdmPwd") is [string legacy] && legacy.Length is > 0 and <= 256 && !legacy.Any(char.IsControl))
            {
                result = SecretReading.FromPassword(local.Computer.Name, "Compte local géré (nom non publié par LAPS historique)", legacy,
                    "LAPS historique ne publie pas le nom du compte local. Vérifiez ce compte avant utilisation. Valeur non enregistrée ni exportée.", source.Clock.GetUtcNow());
            }
            else { throw LapsNotVisible(access, dn); }
            if (password is not null)
            {
                result = SecretReading.FromPassword(local.Computer.Name, password.Account, password.Password,
                    "Mot de passe LAPS courant lu à la demande. Valeur non enregistrée, non journalisée et non exportée.", source.Clock.GetUtcNow());
            }
            await SecretComputerAsync(local, access, ["objectGUID", "objectClass"], budget.Token).ConfigureAwait(false);
            access.EnsureCurrent();
            var published = result ?? throw LapsPassword.Invalid(); result = null; return published;
        }
        finally { password?.Dispose(); result?.Dispose(); }
    }

    private DomeniaOperationException LapsNotVisible(AdReadAccess access, string dn)
    {
        access.EnsureCurrent();
        if (source.AccountContext is { } context)
        { AccountAccess.From(context).RegisterRefusal(CredentialRules.Laps, "Mot de passe LAPS non visible", dn, "possible", access.AccountKey, true); }
        return new(PosteErrors.Refused, "Aucun mot de passe LAPS courant visible avec ce compte ; publication et droits à vérifier. Aucun ancien mot de passe utilisé.");
    }
}

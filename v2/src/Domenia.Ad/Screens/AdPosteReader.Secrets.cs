using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Ad;

public sealed partial class AdPosteReader
{
    private static readonly string[] LapsMetadata = ["objectGUID", "objectClass", "msLAPS-PasswordExpirationTime", "ms-Mcs-AdmPwdExpirationTime"];
    private static readonly string[] RecoveryMetadata = ["objectGUID", "objectClass", "name", "whenCreated", "msFVE-RecoveryGuid", "msFVE-VolumeGuid"];
    private static readonly ImmutableHashSet<string> RecoveryBinary = ImmutableHashSet.Create(StringComparer.OrdinalIgnoreCase, "msFVE-RecoveryGuid", "msFVE-VolumeGuid");

    private static AdSearchRequest SecretQuery(string dn, string filter, AdSearchScope scope, IReadOnlyList<string> attributes, int cap = 2) => new(dn, filter, scope, attributes)
    {
        PageSize = Math.Min(128, cap), SizeLimit = cap, Timeout = TimeSpan.FromSeconds(6), Budget = TimeSpan.FromSeconds(12), ExpandRanges = false,
        BinaryAttributes = RecoveryBinary.Intersect(attributes).ToImmutableHashSet(StringComparer.OrdinalIgnoreCase),
    };

    private static bool HasClass(AdEntry entry, string name) => entry.Strings("objectClass").Contains(name, StringComparer.OrdinalIgnoreCase);

    private async Task<AdEntry> SecretComputerAsync(LocalPoste local, AdReadAccess access, IReadOnlyList<string> attributes, CancellationToken token)
    {
        var rows = await access.SearchAsync(SecretQuery(local.Computer.DistinguishedName,
            "(&(objectClass=computer)" + AdObjectAccess.GuidFilter(local.Computer.ObjectGuid) + ")", AdSearchScope.Base, attributes), token).ConfigureAwait(false);
        EnsureEpoch(local.Epoch);
        if (rows.Count != 1 || !HasClass(rows[0], "computer") || rows[0].Guid("objectGUID") != local.Computer.ObjectGuid
            || !DistinguishedName.AreEqual(rows[0].DistinguishedName, local.Computer.DistinguishedName))
        { throw new DomeniaOperationException(PosteErrors.ComputerUnknown, "Le compte ordinateur a disparu ou changé d’identité ; aucune valeur révélée."); }
        return rows[0];
    }

    public async Task<LapsView> LapsAsync(string dn, CancellationToken cancellationToken)
    {
        using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(20), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
        var local = await LocalAsync(dn, budget.Token).ConfigureAwait(false);
        using var access = await AdReadAccess.AcquireAsync(source, CredentialRules.Laps, dn, budget.Token).ConfigureAwait(false);
        var now = source.Clock.GetUtcNow();
        try
        {
            var entry = await SecretComputerAsync(local, access, LapsMetadata, budget.Token).ConfigureAwait(false);
            var windows = entry.Has("msLAPS-PasswordExpirationTime"); var legacy = entry.Has("ms-Mcs-AdmPwdExpirationTime");
            var attribute = windows ? "msLAPS-PasswordExpirationTime" : "ms-Mcs-AdmPwdExpirationTime";
            var raw = entry.Raw(attribute).Count == 1 ? entry.Long(attribute) : null;
            var expiration = AdValues.FromFileTime(raw);
            var kind = windows ? "Windows LAPS" : legacy ? "LAPS historique" : "Source non déterminée";
            ImmutableArray<PosteFact> facts = [
                PosteText.Fact("Source", kind, windows || legacy ? FactState.Observed : FactState.Unknown, "Attributs d’expiration AD", at: now),
                PosteText.Fact("Expiration", raw == 0 ? "Rotation demandée (expiration zéro)" : expiration is { } date ? PosteText.LocalDateTime(date, source.Zone) : "Non visible ou invalide", expiration is not null || raw == 0 ? FactState.Observed : FactState.Unknown,
                    "Attributs d’expiration AD", "Une expiration visible ne prouve ni la présence ni la lisibilité du mot de passe.", at: now,
                    tone: raw == 0 || expiration < now ? Tone.Warn : Tone.Info),
                PosteText.Fact("Mot de passe", "Non demandé", FactState.Unknown, "Lecture des métadonnées seulement", "La révélation est un geste distinct dans la fenêtre sécurisée.", at: now),
            ];
            access.EnsureCurrent();
            return new(local.Computer.Name, now, LapsState.Unconfirmed, "Lecture du mot de passe non tentée",
                "Métadonnées seulement. « Révéler » demande une valeur au contrôleur ; une expiration absente ne prouve pas l’absence de LAPS.",
                Tone.Info, true, false, access.Account, facts);
        }
        catch (DomeniaOperationException ex) when (ex.Code is AdErrors.Credentials or AdErrors.AccessDenied)
        {
            return PosteSecrets.Laps(local.Computer.Name, "AccessDenied", "NotAttempted", false, false, "Unknown", null, null, null, access.Account, now, source.Zone);
        }
    }

    private static BitLockerKeyInfo? RecoveryInfo(AdEntry entry, string parent, TimeZoneInfo zone)
    {
        if (!PosteSecrets.IsDirectChild(parent, entry.DistinguishedName) || !HasClass(entry, "msFVE-RecoveryInformation")
            || entry.Raw("objectGUID").Count != 1 || entry.Guid("objectGUID") is not { } objectId || objectId == Guid.Empty
            || entry.Raw("msFVE-RecoveryGuid").Count != 1 || entry.Guid("msFVE-RecoveryGuid") is not { } recovery || recovery == Guid.Empty)
        { return null; }
        // A volume GUID is not a drive letter; never infer C: or a current system volume from it.
        var volume = entry.Raw("msFVE-VolumeGuid").Count == 1 && entry.Guid("msFVE-VolumeGuid") is { } id && id != Guid.Empty
            ? id.ToString("D").ToUpperInvariant() : "Volume non identifié";
        return PosteSecrets.KeyInfo(entry.String("name") ?? "", entry.DistinguishedName, recovery, entry.Time("whenCreated"), volume, zone);
    }

    public async Task<BitLockerList> BitLockerListAsync(string dn, CancellationToken cancellationToken)
    {
        using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(25), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
        var local = await LocalAsync(dn, budget.Token).ConfigureAwait(false);
        using var access = await AdReadAccess.AcquireAsync(source, CredentialRules.BitLocker, dn, budget.Token).ConfigureAwait(false);
        var now = source.Clock.GetUtcNow();
        try
        {
            await SecretComputerAsync(local, access, ["objectGUID", "objectClass"], budget.Token).ConfigureAwait(false);
            var rows = await access.SearchAsync(SecretQuery(dn, "(objectClass=msFVE-RecoveryInformation)", AdSearchScope.OneLevel, RecoveryMetadata, PosteSecrets.BitLockerCap + 1), budget.Token).ConfigureAwait(false);
            var projected = rows.Take(PosteSecrets.BitLockerCap).Select(e => RecoveryInfo(e, dn, source.Zone)).ToArray();
            var repeated = projected.OfType<BitLockerKeyInfo>().GroupBy(k => k.KeyGuid, StringComparer.OrdinalIgnoreCase).Where(g => g.Count() > 1).Select(g => g.Key).ToHashSet(StringComparer.OrdinalIgnoreCase);
            var keys = projected.OfType<BitLockerKeyInfo>().Where(k => !repeated.Contains(k.KeyGuid)).OrderByDescending(k => k.CreatedAt).ThenBy(k => k.KeyGuid, StringComparer.Ordinal).ToImmutableArray();
            var incomplete = rows.Count > PosteSecrets.BitLockerCap || projected.Any(k => k is null) || repeated.Count > 0;
            await SecretComputerAsync(local, access, ["objectGUID", "objectClass"], budget.Token).ConfigureAwait(false);
            access.EnsureCurrent();
            return new(local.Computer.Name, now, FactState.Observed,
                (incomplete ? "Liste partielle : limite atteinte ou identités illisibles/ambiguës écartées. " : "")
                + (keys.IsEmpty ? "Aucun objet de récupération visible avec ce compte ; cela ne prouve pas l’absence de clés." : FrenchText.Count(keys.Length, "objet de récupération visible", "objets de récupération visibles") + "; aucune clé demandée."),
                keys, PosteSecrets.ColumnHeader(true, false), access.Account, keys.IsEmpty,
                [PosteText.Fact("Recherche", "Un niveau sous le poste, 256 objets au plus", incomplete ? FactState.Unknown : FactState.Observed,
                    "Contrôleur " + access.Controller, "Les droits peuvent masquer des objets. msFVE-RecoveryPassword n’est jamais demandé par cette liste.", at: now, tone: incomplete ? Tone.Warn : Tone.Info)]);
        }
        catch (DomeniaOperationException ex) when (ex.Code is AdErrors.Credentials or AdErrors.AccessDenied)
        {
            return new(local.Computer.Name, now, FactState.Refused, "Lecture refusée ; aucune conclusion sur la présence de clés.", [],
                PosteSecrets.ColumnHeader(true, false), access.Account, true, []);
        }
    }

    public async Task<SecretReading> RevealBitLockerAsync(string dn, string keyDn, string expectedId, CancellationToken cancellationToken)
    {
        if (!PosteSecrets.IsDirectChild(dn, keyDn)) { throw new DomeniaOperationException(PosteErrors.KeyNotChild, PosteErrors.KeyNotChildMessage); }
        if (!Guid.TryParse(expectedId, out var expected) || expected == Guid.Empty)
        { throw new DomeniaOperationException(PosteErrors.KeyMismatch, PosteErrors.KeyMismatchMessage); }
        using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(25), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
        var local = await LocalAsync(dn, budget.Token).ConfigureAwait(false);
        using var access = await AdReadAccess.AcquireAsync(source, CredentialRules.BitLocker, dn, budget.Token).ConfigureAwait(false);
        await SecretComputerAsync(local, access, ["objectGUID", "objectClass"], budget.Token).ConfigureAwait(false);
        var metadata = await access.SearchAsync(SecretQuery(keyDn, "(objectClass=msFVE-RecoveryInformation)", AdSearchScope.Base, RecoveryMetadata), budget.Token).ConfigureAwait(false);
        var key = metadata.Count == 1 && DistinguishedName.AreEqual(metadata[0].DistinguishedName, keyDn) ? RecoveryInfo(metadata[0], dn, source.Zone) : null;
        if (key is null || !PosteSecrets.MatchesExpected(key.KeyGuid, expected.ToString("D")))
        { throw new DomeniaOperationException(PosteErrors.KeyMismatch, PosteErrors.KeyMismatchMessage); }
        var objectGuid = metadata[0].Guid("objectGUID")!.Value;
        var rows = await access.SearchAsync(SecretQuery(keyDn, "(&(objectClass=msFVE-RecoveryInformation)" + AdObjectAccess.GuidFilter(objectGuid) + ")",
            AdSearchScope.Base, [.. RecoveryMetadata, "msFVE-RecoveryPassword"]), budget.Token).ConfigureAwait(false);
        var found = rows.Count == 1 && DistinguishedName.AreEqual(rows[0].DistinguishedName, keyDn) ? RecoveryInfo(rows[0], dn, source.Zone) : null;
        if (found is null || rows[0].Guid("objectGUID") != objectGuid || !PosteSecrets.MatchesExpected(found.KeyGuid, key.KeyGuid))
        { throw new DomeniaOperationException(PosteErrors.KeyMismatch, PosteErrors.KeyMismatchMessage); }
        var raw = rows[0].Raw("msFVE-RecoveryPassword");
        var blocks = raw.Count == 1 && raw[0] is string { Length: 55 } value ? PosteSecrets.Blocks(value) : [];
        if (blocks.Length != 8)
        {
            if (source.AccountContext is { } context)
            { AccountAccess.From(context).RegisterRefusal(CredentialRules.BitLocker, "Clé BitLocker non visible", dn, "possible", access.AccountKey, true); }
            throw new DomeniaOperationException(PosteErrors.Refused, "Valeur absente, illisible ou invalide ; publication et droits à vérifier. Aucun secret affiché.");
        }
        var result = new SecretReading("bitlocker", local.Computer.Name, key.RecoveryId, key.KeyGuid, null, blocks,
            SecretPolicy.RevealSeconds, SecretPolicy.ExtensionSeconds, SecretPolicy.Extensions, SecretPolicy.ClipboardLimit,
            "Comparez l’identifiant de récupération avec l’écran du poste avant de dicter. La valeur n’est ni enregistrée ni exportée.", false, source.Clock.GetUtcNow());
        try
        {
            await SecretComputerAsync(local, access, ["objectGUID", "objectClass"], budget.Token).ConfigureAwait(false);
            access.EnsureCurrent(); return result;
        }
        catch { result.Dispose(); throw; }
    }
}

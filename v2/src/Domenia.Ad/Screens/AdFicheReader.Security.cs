using System.Collections.Immutable;
using System.Security.AccessControl;
using System.Security.Principal;
using Domenia.Core;

namespace Domenia.Ad;

public sealed partial class AdFicheReader
{
    public async Task<FicheSecurityReading> SecurityAsync(string dn, CancellationToken cancellationToken)
    {
        AdFicheObjects.ValidateDn(dn);
        using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(15), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
        var epoch = await NetworkEpochAsync(dn, budget.Token).ConfigureAwait(false);
        try
        {
            var entry = await objects.ReadExactAsync(dn, ["nTSecurityDescriptor", "objectSid"], TimeSpan.FromSeconds(10), budget.Token).ConfigureAwait(false)
                ?? throw FicheErrors.Error(FicheErrors.Unknown, FicheErrors.UnknownMessage);
            var session = await source.GetSessionAsync(budget.Token).ConfigureAwait(false);
            if (session.Account.Dn is not { } accountDn) { return Unavailable("Compte de connexion non identifié dans ce domaine."); }
            var account = await objects.ReadExactAsync(accountDn, ["objectSid", "tokenGroups", "sIDHistory", "primaryGroupID"], TimeSpan.FromSeconds(10), budget.Token).ConfigureAwait(false);
            if (account?.Sid("objectSid") is not { } sid || !account.Has("tokenGroups")) { return Unavailable("Groupes de sécurité du compte de connexion non lus."); }
            var sids = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { sid, "S-1-1-0", "S-1-5-11", "S-1-5-2" };
            foreach (var value in account.Raw("tokenGroups").Concat(account.Raw("sIDHistory")))
            {
                if (value is not byte[] bytes) { throw AdAttributeRange.Incomplete(); }
                sids.Add(new SecurityIdentifier(bytes, 0).Value);
            }
            if (account.Int("primaryGroupID") is > 0 and var rid) { sids.Add(sid[..(sid.LastIndexOf('-') + 1)] + rid.ToString(System.Globalization.CultureInfo.InvariantCulture)); }
            EnsureEpoch(epoch);
            return entry.Bytes("nTSecurityDescriptor") is { } descriptor
                ? ParseSecurity(descriptor, sids, entry.Sid("objectSid"), source.Clock.GetUtcNow()) : Unavailable("Descripteur de sécurité non retourné par le contrôleur.");
        }
        catch (DomeniaOperationException ex) when (ex.Code is AdErrors.AccessDenied or AdErrors.Timeout or AdErrors.Unavailable or DomeniaErrors.SourceUnavailable) { return Unavailable(ex.Message); }
        catch (ArgumentException) { return Unavailable("Descripteur ou SID de sécurité illisible."); }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { return Unavailable("Budget de lecture des droits atteint."); }

        FicheSecurityReading Unavailable(string reason) { EnsureEpoch(epoch); return new(false, reason, "Non lu", 0, [], source.Clock.GetUtcNow()); }
    }

    internal static FicheSecurityReading ParseSecurity(byte[] bytes, IReadOnlySet<string> token, string? objectSid, DateTimeOffset at)
    {
        if (bytes.Length is < 20 or > 1_048_576 || token.Count is 0 or > 50_000) { throw AdAttributeRange.Incomplete(); }
        var descriptor = new RawSecurityDescriptor(bytes, 0);
        var owner = descriptor.Owner?.Value ?? "Non lu";
        if (descriptor.DiscretionaryAcl is null)
        {
            // A null DACL grants full access; an empty DACL below has no granting entry.
            return new(true, null, owner, token.Count, [new(false, "DACL absente", 0xF01FF, true, null)], at);
        }
        var aces = ImmutableArray.CreateBuilder<FicheAce>();
        foreach (GenericAce generic in descriptor.DiscretionaryAcl)
        {
            if (generic is not QualifiedAce ace || (ace.AceFlags & AceFlags.InheritOnly) != 0) { continue; }
            var trustee = ace.SecurityIdentifier.Value;
            if (trustee == "S-1-5-10") { trustee = objectSid ?? "SELF non résolu"; }
            if (!token.Contains(trustee)) { continue; }
            if (ace.IsCallback) { return new(false, "Une autorisation conditionnelle concerne ce compte : estimation indéterminée.", owner, token.Count, [], at); }
            if (ace.AceQualifier is not (AceQualifier.AccessAllowed or AceQualifier.AccessDenied)) { continue; }
            long rights = (uint)ace.AccessMask;
            if ((rights & 0x10000000) != 0) { rights |= 0xF01FF; }
            if ((rights & 0x80000000) != 0) { rights |= 0x20094; }
            if ((rights & 0x40000000) != 0) { rights |= 0x20028; }
            if ((rights & 0x20000000) != 0) { rights |= 0x20004; }
            var reset = (rights & 0x100) != 0;
            if (ace is ObjectAce specific && (specific.ObjectAceFlags & ObjectAceFlags.ObjectAceTypePresent) != 0)
            {
                reset = reset && specific.ObjectAceType == new Guid("00299570-246d-11d0-a768-00aa006e0529");
                // A right limited to one attribute/child class is never expanded to every property/child.
                rights &= ~0x13BL;
            }
            aces.Add(new(ace.AceQualifier == AceQualifier.AccessDenied, trustee, rights, reset,
                (ace.AceFlags & AceFlags.Inherited) != 0 ? "un parent (origine exacte non fournie dans la DACL)" : null));
        }
        return new(true, null, owner, token.Count, aces.ToImmutable(), at) { InDirectoryOrder = true };
    }
}

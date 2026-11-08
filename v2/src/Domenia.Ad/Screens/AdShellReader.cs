using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Ad;

public sealed class AdShellReader(AdDirectorySource source) : IShellReader
{
    public async Task<ShellLookupResult> LookupAsync(string text, IReadOnlySet<ShellLookupKind> kinds, int limit, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(text); ArgumentNullException.ThrowIfNull(kinds);
        if (limit is < 1 or > 100 || text.Length > 256 || text.Any(char.IsControl) || kinds.Any(k => !Enum.IsDefined(k)))
        { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Recherche limitée à 100 objets et 256 caractères."); }
        var state = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        var needle = FrenchText.Fold(text.Trim());
        var found = Items(state.Directory).Where(item => kinds.Contains(item.Kind) && needle.Length > 0
            && new[] { item.Name, item.Detail, item.Dn }.Any(v => v is not null && FrenchText.Fold(v).Contains(needle, StringComparison.Ordinal)))
            .OrderBy(item => item.Kind).ThenBy(item => FrenchText.Fold(item.Name), StringComparer.Ordinal).ThenBy(item => item.Dn, StringComparer.Ordinal).ToArray();
        return new([.. found.Take(limit)], found.Length, found.Length > limit, FrenchText.Count(found.Length, "objet dans la base locale", "objets dans la base locale")
            + (found.Length > limit ? " ; précisez la recherche pour afficher les autres." : "."));
    }

    public async Task<ShellLookupCheck> VerifyAsync(string dn, Guid objectGuid, CancellationToken cancellationToken)
    {
        AdFicheObjects.ValidateDn(dn);
        try
        {
            var directory = await AdSupportObjects.ReadAsync(source, null, objectGuid, cancellationToken).ConfigureAwait(false);
            AdFicheObjects.EnsureDomain(dn, directory.Domain.RootDn);
            var item = Items(directory).SingleOrDefault();
            return item is null ? new("missing", "Objet absent ou non visible pour le compte choisi ; choisissez-le de nouveau.", null)
                : new(DistinguishedName.AreEqual(item.Dn, dn) ? "ok" : "moved", "GUID relu avec le compte sélectionné ; nom distinctif actualisé.", item);
        }
        catch (DomeniaOperationException ex) when (ex.Code == AdErrors.NoSuchObject) { return new("missing", "Objet absent ou non visible ; choisissez-le de nouveau.", null); }
        catch (DomeniaOperationException ex) when (AdSupportObjects.Denied(ex)) { return new("denied", ShellErrors.LookupDeniedMessage, null); }
    }

    public async Task<ShellLookupCheck> ResolveOuAsync(string dn, CancellationToken cancellationToken)
    {
        try
        {
            var directory = await AdSupportObjects.ReadAsync(source, dn, null, cancellationToken).ConfigureAwait(false);
            var item = Items(directory).SingleOrDefault(i => i.Kind == ShellLookupKind.Ou);
            return item is null ? new("missing", "Aucune OU visible à ce nom distinctif.", null) : new("ok", "OU et GUID relus avec le compte sélectionné.", item);
        }
        catch (DomeniaOperationException ex) when (ex.Code == AdErrors.NoSuchObject) { return new("missing", "Objet absent ou non visible ; choisissez-le de nouveau.", null); }
        catch (DomeniaOperationException ex) when (AdSupportObjects.Denied(ex)) { return new("denied", ShellErrors.LookupDeniedMessage, null); }
    }

    public Task<ShellDemoCoverage> CoverageAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(new ShellDemoCoverage(false, "annuaire", [], 0, 0, "Le catalogue de démonstration concerne uniquement le mode simulation."));
    }

    public async Task<ImmutableArray<AutomationComputerRow>> ComputersAsync(AutomationPerimeter perimeter, int limit, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(perimeter);
        if (limit is < 1 or > 5000) { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Liste limitée à 5 000 postes."); }
        var local = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        if (perimeter.OrganizationalUnit is { } dn) { AdFicheObjects.EnsureDomain(dn, local.Directory.Domain.RootDn); }
        return [.. ShellAutomation.Select(local.Directory.Computers, perimeter).Take(limit + 1).Select(c =>
            new AutomationComputerRow(c.Name, c.DnsHostName, c.ObjectGuid.ToString("D"), c.DistinguishedName, !AdValues.IsDisabled(c.UserAccountControl), c.OperatingSystem, AdValues.FromFileTime(c.LastLogonTimestamp)))];
    }

    internal static IEnumerable<ShellLookupItem> Items(DirectorySnapshot directory)
    {
        foreach (var user in directory.Users) { yield return new(ShellLookupKind.User, "Utilisateur", user.DisplayName ?? user.Cn, user.DistinguishedName, user.ObjectGuid.ToString("D"),
            string.Join(" · ", new[] { user.SamAccountName, user.UserPrincipalName, user.Mail }.OfType<string>()), AdSupportObjects.Container(user.DistinguishedName), !AdValues.IsDisabled(user.UserAccountControl)); }
        foreach (var pc in directory.Computers) { yield return new(ShellLookupKind.Computer, "Poste", pc.Name, pc.DistinguishedName, pc.ObjectGuid.ToString("D"),
            pc.DnsHostName, AdSupportObjects.Container(pc.DistinguishedName), !AdValues.IsDisabled(pc.UserAccountControl)); }
        foreach (var ou in directory.OrganizationalUnits.Where(o => DistinguishedName.Parse(o.DistinguishedName)[0].Type.Equals("OU", StringComparison.OrdinalIgnoreCase)))
        { yield return new(ShellLookupKind.Ou, "OU", ou.Name, ou.DistinguishedName, ou.ObjectGuid.ToString("D"), ou.Description, AdSupportObjects.Container(ou.DistinguishedName), true); }
    }
}

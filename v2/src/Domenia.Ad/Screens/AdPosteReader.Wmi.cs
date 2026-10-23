using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Core.Queries;
using Domenia.Inventory;

namespace Domenia.Ad;

public sealed partial class AdPosteReader
{
    private async Task<WorkstationWmiReading> WmiAsync(LocalPoste local, WmiMetadataKind kind, string ns, string? className, WmiRequest? request, CancellationToken token)
    {
        using var access = await AdWorkstationAccess.AcquireAsync(source, local.Computer.DnsHostName!, token).ConfigureAwait(false);
        EnsureEpoch(local.Epoch);
        var reader = InventoryReader(access);
        var result = request is null ? await reader.ReadWmiMetadataAsync(local.Computer.DnsHostName!, kind, ns, className, token, access.Credential).ConfigureAwait(false)
            : await reader.ReadWmiQueryAsync(local.Computer.DnsHostName!, request, token, access.Credential).ConfigureAwait(false);
        access.EnsureCurrent(); EnsureEpoch(local.Epoch);
        if (result.Status == SourceStatus.Refused || result.AuthenticationRejected) { access.Refused(local.Computer.DnsHostName!, "Explorateur WMI", result.AuthenticationRejected); }
        if (result.ReportedName is not null) { ConfirmIdentity(local.Computer, result.ReportedName); }
        return result;
    }

    public async Task<WmiNamespaces> WmiNamespacesAsync(string dn, string? parent, CancellationToken cancellationToken)
    {
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(30), source.Clock);
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, deadline.Token);
        var ns = string.IsNullOrWhiteSpace(parent) ? "root" : parent.Trim();
        if (!PosteWmi.IsNamespace(ns)) { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Espace de noms WMI invalide."); }
        var local = await NetworkAsync(dn, stop.Token).ConfigureAwait(false);
        var result = await WmiAsync(local, WmiMetadataKind.Namespaces, ns, null, null, stop.Token).ConfigureAwait(false);
        return new(local.Computer.Name, ns, [.. result.Names.Select(n => new WmiNamespace(n, ns + "\\" + n, null))],
            PosteLabels.SourceStatusLabel(result.Status) + " · " + result.Detail + " Les enfants d’un espace sont lus à son ouverture.");
    }

    public async Task<WmiClasses> WmiClassesAsync(string dn, string ns, CancellationToken cancellationToken)
    {
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(30), source.Clock);
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, deadline.Token);
        if (!PosteWmi.IsNamespace(ns)) { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Espace de noms WMI invalide."); }
        var local = await NetworkAsync(dn, stop.Token).ConfigureAwait(false);
        var result = await WmiAsync(local, WmiMetadataKind.Classes, ns, null, null, stop.Token).ConfigureAwait(false);
        return new(local.Computer.Name, ns, [.. result.Names.Select(n => new Domenia.Core.Poste.WmiClassInfo(n, PosteLabels.MsiProviderClasses.Contains(n),
            PosteLabels.MsiProviderClasses.Contains(n) ? "Fournisseur MSI bloqué ; aucune instance interrogée." : null))], PosteLabels.SourceStatusLabel(result.Status) + " · " + result.Detail);
    }

    public async Task<WmiQueryResult> WmiQueryAsync(string dn, WmiRequest request, CancellationToken cancellationToken)
    {
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(45), source.Clock);
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, deadline.Token);
        try { WmiWorkstationReader.CheckExplorerRequest(request); }
        catch (QueryDefinitionException) { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Requête WMI refusée par la garde de lecture ; aucun contact envoyé."); }
        var local = await NetworkAsync(dn, stop.Token).ConfigureAwait(false);
        var result = await WmiAsync(local, WmiMetadataKind.Properties, request.Namespace, request.Class, request, stop.Token).ConfigureAwait(false);
        return new(local.Computer.Name, request.Namespace, request.Class, request.Where, request.Limit, result.Status == SourceStatus.Partial,
            result.Schema, result.Rows, PosteLabels.SourceStatusLabel(result.Status) + " · " + result.Detail, result.Query ?? "Aucune requête d’instances envoyée.", result.DurationMs)
            { NoInstancesConfirmed = result.Status == SourceStatus.Empty && result.Rows.IsEmpty };
    }
}

using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Ad;

public sealed partial class AdPosteReader
{
    private static ProbeStore EmptyProbes(string name) => new(name, null,
        [.. Domenia.Core.Poste.ProbeCatalog.Probes.Select(p => new ProbeStatus(p.Id, ProbeState.NotRead, null, null, null, 0))], [], [], [], null);

    public async Task<ProbeStore> ProbeStoreAsync(string dn, CancellationToken cancellationToken)
    {
        var local = await LocalAsync(dn, cancellationToken).ConfigureAwait(false);
        var stored = local.Fleet.WorkstationProbes.GetValueOrDefault(local.Computer.ObjectGuid);
        if (stored is null) { return EmptyProbes(local.Computer.Name); }
        PosteProbeCache.Validate(stored, source.Clock.GetUtcNow());
        if (stored.Values.Count > 0 && !WorkstationIdentity.Matches(local.Computer, stored.ReportedName)
            || stored.Values.Values.Any(v => v.At < local.Computer.WhenCreated))
        { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Identité ou date des sondes conservées incompatible avec le compte ordinateur ; relancez un relevé."); }
        EnsureEpoch(local.Epoch);
        return WmiWorkstationReader.ProjectProbes(stored with { Computer = local.Computer.Name });
    }

    public async Task<ProbeStore> CollectProbesAsync(string dn, ImmutableArray<string> probes, IProgress<PosteProgress>? progress, CancellationToken cancellationToken)
    {
        WmiWorkstationReader.CheckProbes(probes); // Reject the entire selection before LDAP or workstation contacts.
        var local = await NetworkAsync(dn, cancellationToken).ConfigureAwait(false);
        using var access = await AdWorkstationAccess.AcquireAsync(source, local.Computer.DnsHostName!, cancellationToken).ConfigureAwait(false);
        var read = await InventoryReader(access).ReadProbesAsync(local.Computer.DnsHostName!, probes, progress, cancellationToken, access.Credential).ConfigureAwait(false);
        access.EnsureCurrent(); EnsureEpoch(local.Epoch);
        if (read.Access.Any(a => a.Status == SourceStatus.Refused || a.AuthenticationRejected))
        { access.Refused(local.Computer.DnsHostName!, "poste.probes.collect", read.Access.Any(a => a.AuthenticationRejected)); }
        if (read.ReportedName is not null || read.Values.Count > 0) { ConfirmIdentity(local.Computer, read.ReportedName); }
        var statuses = read.Access.Select(a =>
        {
            var values = read.Values.GetValueOrDefault(a.Category); var at = values?.At ?? read.At;
            var state = a.Status switch
            {
                SourceStatus.Ok or SourceStatus.Empty => ProbeState.Read, SourceStatus.Partial => ProbeState.Partial,
                SourceStatus.Refused => ProbeState.Refused, SourceStatus.Unavailable => ProbeState.Absent,
                SourceStatus.Error or SourceStatus.Unreachable => ProbeState.Failed, _ => ProbeState.NotRead,
            };
            // A source unavailable after a failed identity read is not proof that its provider is absent.
            if (read.ReportedName is null && state == ProbeState.Absent) { state = ProbeState.NotRead; }
            return new ProbeStatus(a.Category, state, values?.Complete == true ? at : null, at, a.Detail, values?.Rows.Length ?? 0) { DataAt = values?.At };
        }).ToImmutableArray();
        var patch = new ProbeStore(local.Computer.Name, null, statuses, [], [], [], read.At) { ReportedName = read.ReportedName, Values = read.Values };
        PosteProbeCache.Validate(patch, source.Clock.GetUtcNow());
        var saved = await source.SaveFleetAsync(FleetCachePatch.Empty with { WorkstationProbes = ImmutableDictionary<Guid, ProbeStore>.Empty.Add(local.Computer.ObjectGuid, patch) }, local.Epoch, CancellationToken.None).ConfigureAwait(false);
        access.EnsureCurrent(); EnsureEpoch(local.Epoch);
        progress?.Report(new(statuses.Length, statuses.Length, statuses.All(s => s.State == ProbeState.Read) ? "Sondes enregistrées" : "Relevé partiel enregistré"));
        return WmiWorkstationReader.ProjectProbes(saved.WorkstationProbes[local.Computer.ObjectGuid]);
    }
}

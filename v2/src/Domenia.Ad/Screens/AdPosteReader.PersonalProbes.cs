using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Inventory;
using ProbeReading = Domenia.Core.Accueil.ProbeReading;

namespace Domenia.Ad;

public sealed partial class AdPosteReader : IPostePersonalProbeReader
{
    internal WmiFleetProbeReader? PersonalProbeReaderOverride { get; init; }

    public async Task<PostePersonalProbeRead> CollectPersonalProbeAsync(PostePersonalProbeRequest request, CancellationToken token)
    {
        ArgumentNullException.ThrowIfNull(request);
        PersonalProbeCatalog.Validate([request.Probe]);
        if (!PersonalProbeCatalog.IsKey(request.Probe.Key)) { throw PersonalChanged("Définition personnelle figée attendue."); }
        token.ThrowIfCancellationRequested();
        await source.ReadLocalAsync(token).ConfigureAwait(false);
        await ConfirmPersonalLocalAsync(request, true, token).ConfigureAwait(false);
        if (AdValues.IsDisabled(request.Computer.UserAccountControl) || (request.Computer.UserAccountControl & AdValues.ServerTrustAccount) != 0)
        { throw PersonalChanged("Compte désactivé ou contrôleur de domaine ; aucun contact de sonde."); }
        if (!request.Configuration.UseCim) { throw PersonalChanged("Lecture CIM désactivée ; aucun contact de sonde."); }

        using var access = await AdQueryAccess.OpenAsync(source, request.Computer.Guid, token,
            expectedAccountVersion: request.AccountVersion, expectedMachineGeneration: request.MachineGeneration).ConfigureAwait(false);
        if (!request.Computer.Matches(access.Computer) || !PostePersonalProbes.SameTransport(access.Machine.Settings, request.Configuration))
        { throw PersonalChanged("Identité ou transport modifié avant la lecture ; sonde non envoyée."); }
        access.EnsureCurrent();
        await ConfirmPersonalLocalAsync(request, false, token).ConfigureAwait(false);
        var reader = PersonalProbeReaderOverride ?? new WmiFleetProbeReader(source.Clock) { ProjectionReused = () => { if (source.AccountContext is { } context) { OperationActivity.From(context).RecordGroupedCimReuse(); } } };
        var readings = await reader.ReadFrozenAsync(access.Computer, [request.Probe], token, access.Machine.Credential, access.Machine.Settings,
            retainPartialOnCancellation: true).ConfigureAwait(false);
        // ReadFrozenAsync has drained the native worker, including timeout and stop. Neither these leases
        // nor the outer Poste collection admission are released while a provider is still running.
        access.EnsureCurrent();
        var value = readings.GetValueOrDefault(request.Probe.Key)
            ?? new ProbeReading(MeasureState.NotRead, source.Clock.GetUtcNow(), [], "Aucune réponse de cette version de sonde.");
        if (value.State == MeasureState.Refused || value.AuthenticationRejected)
        { access.Machine.Refused(access.Computer.Name, "Sonde personnelle Poste", value.AuthenticationRejected); }
        var interrupted = false;
        try
        {
            token.ThrowIfCancellationRequested();
            await access.ConfirmDirectoryAsync(token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
            interrupted = true;
            value = value with
            {
                State = value.State == MeasureState.Known ? MeasureState.Incomplete : value.State,
                Error = "Lecture arrêtée ; qualification AD finale non terminée." + (value.Error is null ? "" : " " + value.Error),
            };
        }
        access.EnsureCurrent();
        // After stop, only local guards and the completed result are persisted; no new LDAP/CIM call.
        await ConfirmPersonalLocalAsync(request, false, CancellationToken.None).ConfigureAwait(false);
        var measured = new ProbeReadings(ImmutableDictionary<string, ImmutableDictionary<Guid, ProbeReading>>.Empty.WithComparers(StringComparer.Ordinal)
            .Add(request.Probe.Key, ImmutableDictionary<Guid, ProbeReading>.Empty.Add(request.Computer.Guid, value)));
        await source.SaveFleetAsync(FleetCachePatch.Empty with { Probes = measured }, request.Epoch, CancellationToken.None).ConfigureAwait(false);
        access.EnsureCurrent();
        if (interrupted || token.IsCancellationRequested) { throw new OperationCanceledException(token); }
        return new(value, source.AccountContext is { } context ? AccountAccess.From(context).SelectionVersion : request.AccountVersion,
            source.AccountContext is { } machineContext ? MachineAccountService.From(machineContext).Generation : request.MachineGeneration);
    }

    private async Task ConfirmPersonalLocalAsync(PostePersonalProbeRequest request, bool beforeAdmission, CancellationToken token)
    {
        var context = source.AccountContext ?? throw PersonalChanged("Profil courant indisponible ; aucune sonde personnelle contactée.");
        void ConfirmSource()
        {
            if (!ReferenceEquals(source.AccountContext, context) || source.Epoch != request.Epoch || source.FleetDetails.Facts.StoreId != request.StoreId
                || source.CurrentDirectory is not { } directory || !directory.Computers.Any(c => request.Computer.Matches(c)))
            { throw PersonalChanged("Profil, base, session ou identité différente du plan ; résultat écarté."); }
        }
        ConfirmSource();
        await ProfileProbeCatalog.ConfirmAsync(context.Preferences, [request.Probe], token).ConfigureAwait(false);
        var settings = await RemoteCollectionSettings.EffectiveAsync(context, token).ConfigureAwait(false);
        if (!PostePersonalProbes.SameTransport(settings, request.Configuration)
            || beforeAdmission && (AccountAccess.From(context).SelectionVersion != request.AccountVersion
                || MachineAccountService.From(context).Generation != request.MachineGeneration))
        { throw PersonalChanged("Compte ou réglage différent du plan ; sonde non attribuée au poste."); }
        ConfirmSource();
    }

    private static DomeniaOperationException PersonalChanged(string message) => new("poste.probeChanged", message);
}

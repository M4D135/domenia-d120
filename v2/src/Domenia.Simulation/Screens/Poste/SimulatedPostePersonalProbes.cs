using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;

namespace Domenia.Simulation;

/// <summary>The Poste projection shares the same simulated scalar store, without requiring a fleet ping or changing an OU.</summary>
public sealed partial class SimulatedAccueilReader : IPostePersonalProbeReader
{
    public async Task<PostePersonalProbeRead> CollectPersonalProbeAsync(PostePersonalProbeRequest request, CancellationToken token)
    {
        PersonalProbeCatalog.Validate([request.Probe]);
        if (!PersonalProbeCatalog.IsKey(request.Probe.Key)) { throw new DomeniaOperationException("poste.probeChanged", "Définition personnelle attendue."); }
        void Confirm()
        {
            token.ThrowIfCancellationRequested();
            if (source.CurrentSession.Epoch != request.Epoch || facts.Value.StoreId != request.StoreId
                || !source.CurrentDirectory.Computers.Any(c => request.Computer.Matches(c)))
            { throw new DomeniaOperationException("poste.probeChanged", "Identité, session ou base simulée modifiée ; aucune sonde conservée."); }
        }
        Confirm();
        if (!request.Configuration.UseCim || AdValues.IsDisabled(request.Computer.UserAccountControl)
            || (request.Computer.UserAccountControl & AdValues.ServerTrustAccount) != 0)
        { throw new DomeniaOperationException("poste.probeChanged", "Lecture CIM désactivée, compte désactivé ou contrôleur simulé exclu."); }
        await source.SimulateScreenLatencyAsync("poste/personalProbe", 400, 1100, token).ConfigureAwait(false);
        Confirm();
        var result = SimulatePersonalProbe(request.Probe.Definition, request.Computer.Guid, source.Clock.GetUtcNow());
        RememberProbes(new(ImmutableDictionary<string, ImmutableDictionary<Guid, Domenia.Core.Accueil.ProbeReading>>.Empty.WithComparers(StringComparer.Ordinal)
            .Add(request.Probe.Key, ImmutableDictionary<Guid, Domenia.Core.Accueil.ProbeReading>.Empty.Add(request.Computer.Guid, result))), request.Epoch);
        return new(result, request.AccountVersion, request.MachineGeneration);
    }
}

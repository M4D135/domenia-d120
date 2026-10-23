namespace Domenia.Core.Accueil;

public sealed partial class AccueilService
{
    private string? operationsSaving;
    private RefreshCounters? operationsCounters;
    private sealed record RefreshCounters(string Id, string Stage, int Total, int Done, int Failed, int PingErrors);

    /// <summary>Local scalar projection only. The batch remains open until the refresh and its final persistence really end.</summary>
    public SurveyState? OperationsRefresh()
    {
        lock (gate) { return run is null ? null : ProjectOperationsRefresh(run); }
    }

    /// <summary>An obsolete displayed id cannot stop a newer OU refresh.</summary>
    public SurveyState StopOperationsRefresh(string id)
    {
        RunState state; SurveyState projected;
        lock (gate)
        {
            if (run is null || !string.Equals("accueil-" + run.Id, id, StringComparison.Ordinal))
            { throw new DomeniaOperationException(OperationActivity.TaskUnknown, OperationActivity.TaskUnknownMessage); }
            state = run; state.Stopping = true;
            state.StopReason ??= "Arrêt demandé depuis Opérations ; les lectures engagées se terminent et les mesures reçues restent conservées.";
            projected = ProjectOperationsRefresh(state);
        }
        try { state.Cancellation.Cancel(); }
        catch (ObjectDisposedException) { /* The same refresh completed between the id check and cancellation. */ }
        return projected;
    }

    private SurveyState ProjectOperationsRefresh(RunState state)
    {
        var stage = state.Stages.LastOrDefault();
        var saving = operationsSaving == state.Id;
        var phase = saving ? SurveyPhase.Saving : state.Stopping ? SurveyPhase.Stopping : stage?.Id switch
        {
            "directory" => SurveyPhase.ReadingDirectory,
            "commit" => SurveyPhase.Saving,
            "presence" or "inventory" or "queries" => SurveyPhase.Running,
            _ => SurveyPhase.Preparing,
        };
        var family = stage?.Id is "presence" ? OperationsCollectionFamily.Presence
            : stage?.Id is "inventory" or "queries" ? OperationsCollectionFamily.Inventory : OperationsCollectionFamily.Directory;
        var counts = operationsCounters is { } value && value.Id == state.Id && (saving || value.Stage == stage?.Id) ? value : null;
        var total = counts?.Total ?? (family == OperationsCollectionFamily.Directory ? -1 : state.Plan.Targets);
        var phaseLabel = phase switch
        {
            SurveyPhase.Saving => "Enregistrement",
            SurveyPhase.Stopping => "Arrêt demandé",
            SurveyPhase.ReadingDirectory => "Lecture AD",
            SurveyPhase.Running => stage?.Label ?? "En cours",
            _ => "Préparation",
        };
        var detail = saving ? "Les mesures sont reçues ; le lot reste actif jusqu’à la fin de leur enregistrement local."
            : state.StopReason ?? stage?.Detail ?? "Préparation de l’actualisation de l’OU choisie.";
        return new("accueil-" + state.Id, family, "Actualisation Accueil", state.Plan.Scope.Dn, state.Plan.Scope.Label,
            total, counts?.Done ?? -1, counts?.Failed ?? -1, phase, phaseLabel, true, state.Stopping, state.StartedAt, null,
            detail, counts?.PingErrors ?? -1, phase is SurveyPhase.Running or SurveyPhase.ReadingDirectory or SurveyPhase.Stopping ? -1 : 0,
            phase == SurveyPhase.Saving ? 1 : 0, -1);
    }

    private void MarkOperationsSaving(string id)
    {
        lock (gate) { if (run?.Id == id) { operationsSaving = id; } }
    }

    private void RecordOperationsPresence(string id, DirectoryState state, DateTimeOffset since)
    {
        lock (gate)
        {
            if (run?.Id != id) { return; }
            var targets = state.Directory.Computers.Where(c => !AdValues.IsDisabled(c.UserAccountControl) && ScopeRules.Contains(run.Plan.Scope, c.DistinguishedName))
                .Select(c => c.ObjectGuid).ToHashSet();
            var rows = state.Observations.Workstations.Where(o => targets.Contains(o.ComputerGuid) && o.Presence.CheckedAt >= since).ToArray();
            operationsCounters = new(id, "presence", targets.Count, rows.Length, rows.Count(o => !o.Presence.HasReading), rows.Count(o => o.Presence.State == MeasureState.Error));
        }
    }

    private void RecordOperationsInventory(string id, DirectoryState state, DateTimeOffset since, int online)
    {
        lock (gate)
        {
            if (run?.Id != id) { return; }
            var targets = state.Directory.Computers.Where(c => !AdValues.IsDisabled(c.UserAccountControl) && ScopeRules.Contains(run.Plan.Scope, c.DistinguishedName))
                .Select(c => c.ObjectGuid).ToHashSet();
            var rows = state.Observations.Workstations.Where(o => targets.Contains(o.ComputerGuid) && o.Inventory.CheckedAt >= since).ToArray();
            operationsCounters = new(id, "inventory", online, rows.Length, rows.Count(o => !o.Inventory.HasReading), operationsCounters?.Id == id ? operationsCounters.PingErrors : -1);
        }
    }
}

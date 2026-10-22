using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>Prepared sequences of an account's life (Domenia 1 New-DomeniaLifecyclePlan, OPE-011).</summary>
public enum LifecycleKind
{
    Arrival,
    ServiceChange,
    Suspension,
}

/// <summary>State of one step: an uncertain or failed step blocks the next ones and is never replayed.</summary>
public enum LifecycleStepState
{
    Pending,
    Verified,
    Failed,
    Uncertain,
    Skipped,
}

/// <param name="WriteKind">Kind of the write of the step (« account.enabled »), or « review » for a check without write.</param>
/// <param name="Sensitive">A sensitive step asks its own confirmation (its own plan, through the write circuit).</param>
public sealed record LifecycleStep(int Id, string Title, string WriteKind, bool Sensitive, LifecycleStepState State, string Note);

/// <param name="Deletes">Always false: a sequence never deletes anything.</param>
/// <param name="Migrates">Always false: a sequence never migrates anything.</param>
public sealed record LifecyclePlan(
    LifecycleKind Kind,
    string Title,
    string Summary,
    ImmutableArray<LifecycleStep> Steps,
    bool Deletes,
    bool Migrates,
    bool Blocked,
    string BlockReason);

/// <summary>Template of a sequence: groups of the model, target OU and whether the description or service attributes change.</summary>
public sealed record LifecycleTemplate(ImmutableArray<string> AddGroups, ImmutableArray<string> RemoveGroups, string? TargetOu, bool Attributes)
{
    public static LifecycleTemplate Empty { get; } = new([], [], null, false);
}

/// <summary>A sequence as Opérations shows it: the plan and, per step, whether its write is served in this mode.</summary>
public sealed record LifecycleView(LifecyclePlan Plan, ImmutableArray<bool> Available, string Note);

/// <summary>
/// Pure model of the life-cycle sequences (Domenia 1 Domenia-Directory.Model.ps1, « règle non raccordée » in Domenia 1). Each step
/// is a write of its own, prepared, confirmed, receipted and re-read through the write circuit; an uncertain step blocks the rest.
/// </summary>
public static class LifecyclePlans
{
    public const string ReviewStep = "review";

    public static LifecyclePlan New(LifecycleKind kind, LifecycleTemplate? template = null)
    {
        template ??= LifecycleTemplate.Empty;
        var steps = new List<LifecycleStep>();
        void Add(string title, string writeKind, bool sensitive) => steps.Add(new LifecycleStep(steps.Count + 1, title, writeKind, sensitive, LifecycleStepState.Pending, ""));
        switch (kind)
        {
            case LifecycleKind.Arrival:
                Add("Vérifier la fiche (service, responsable, bureau)", ReviewStep, false);
                if (template.AddGroups.Length > 0)
                {
                    Add("Ajouter aux groupes du modèle (" + FrenchText.Integer(template.AddGroups.Length) + ")", "object.groups", true);
                }
                Add("Activer le compte", "account.enabled", true);
                break;
            case LifecycleKind.ServiceChange:
                Add("Mettre à jour service, fonction et responsable", "object.update", true);
                if (template.AddGroups.Length > 0 || template.RemoveGroups.Length > 0)
                {
                    Add("Ajuster les groupes choisis", "object.groups", true);
                }
                if (!string.IsNullOrWhiteSpace(template.TargetOu))
                {
                    Add("Déplacer vers la nouvelle OU", "object.move", true);
                }
                break;
            default:
                Add("Désactiver le compte", "account.enabled", true);
                Add("Consigner le motif dans la description", "object.update", true);
                if (!string.IsNullOrWhiteSpace(template.TargetOu))
                {
                    Add("Déplacer vers l’OU des comptes suspendus", "object.move", true);
                }
                break;
        }
        var (title, summary) = kind switch
        {
            LifecycleKind.Arrival => ("Arrivée", "Vérifier la fiche, ajouter les groupes du modèle, puis activer le compte."),
            LifecycleKind.ServiceChange => ("Changement de service", "Mettre à jour la fiche, ajuster les groupes, puis déplacer le compte vers sa nouvelle OU."),
            _ => ("Suspension", "Désactiver le compte, consigner le motif, puis le déplacer vers l’OU des comptes suspendus."),
        };
        return new LifecyclePlan(kind, title, summary, [.. steps], false, false, false, "");
    }

    /// <summary>
    /// Records the outcome of one step. An uncertain outcome blocks the following steps (never replayed); a failure blocks too, until
    /// the operator decides. « Resolved » (a re-read or a review of the uncertain step) unblocks it.
    /// </summary>
    public static LifecyclePlan Record(LifecyclePlan plan, int stepId, LifecycleStepState outcome, string note = "", bool resolved = false)
    {
        ArgumentNullException.ThrowIfNull(plan);
        var index = -1;
        for (var i = 0; i < plan.Steps.Length; i++)
        {
            if (plan.Steps[i].Id == stepId)
            {
                index = i;
                break;
            }
        }
        if (index < 0)
        {
            return plan;
        }
        var step = plan.Steps[index];
        if (resolved)
        {
            return step.State == LifecycleStepState.Uncertain
                ? plan with { Steps = plan.Steps.SetItem(index, step with { State = LifecycleStepState.Verified, Note = note }), Blocked = false, BlockReason = "" }
                : plan;
        }
        var next = plan with { Steps = plan.Steps.SetItem(index, step with { State = outcome, Note = note }) };
        return outcome switch
        {
            LifecycleStepState.Uncertain => next with { Blocked = true, BlockReason = "Étape " + FrenchText.Integer(stepId) + " à vérifier avant de poursuivre. Elle ne sera pas rejouée." },
            LifecycleStepState.Failed => next with { Blocked = true, BlockReason = "Étape " + FrenchText.Integer(stepId) + " en échec : décidez de la reprendre ou d’arrêter." },
            _ => next,
        };
    }

    /// <summary>The next step to prepare, or null when the plan is blocked or finished.</summary>
    public static LifecycleStep? Next(LifecyclePlan plan)
    {
        ArgumentNullException.ThrowIfNull(plan);
        return plan.Blocked ? null : plan.Steps.FirstOrDefault(s => s.State == LifecycleStepState.Pending);
    }

    /// <summary>The three sequences with a sample template, and the availability of each step in this mode.</summary>
    public static ImmutableArray<LifecycleView> Views(IReadOnlyCollection<string> available)
    {
        ArgumentNullException.ThrowIfNull(available);
        var template = new LifecycleTemplate(["GG-Commercial-Lyon", "LD-Lyon"], ["GG-Commercial-Paris"], "OU=Départs", true);
        return
        [
            .. new[] { LifecycleKind.Arrival, LifecycleKind.ServiceChange, LifecycleKind.Suspension }.Select(kind =>
            {
                var plan = New(kind, template);
                ImmutableArray<bool> served = [.. plan.Steps.Select(s => s.WriteKind == ReviewStep || available.Contains(s.WriteKind))];
                var missing = plan.Steps.Count(s => s.WriteKind != ReviewStep && !available.Contains(s.WriteKind));
                var note = missing == 0
                    ? "Chaque étape sensible passe par son propre plan, sa confirmation, son reçu et sa relecture."
                    : FrenchText.Count(missing, "étape attend son écriture", "étapes attendent leur écriture") + " dans ce mode : la séquence se prépare, chaque étape restera une écriture à part entière.";
                return new LifecycleView(plan, served, note);
            }),
        ];
    }
}

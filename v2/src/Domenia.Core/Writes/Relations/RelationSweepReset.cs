using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// Executor of « Oublier les relevés » (Domenia 1 REL-031, BtnParkReset): the memory of the relevés of the parc (which
/// workstation was read when) is emptied, so the next relevé starts again with the workstations never read. Served by the source
/// of the mode: the session memory of the simulation now, the local base in wave 3 (after a verified backup of the base,
/// Domenia 1 FI-13). Associations and Active Directory are never touched.
/// </summary>
public interface IRelationSweepResetExecutor : IWriteExecutor
{
    /// <summary>Plan of the reset, from a fresh read of the relevé memory (write.nothingToDo when it is already empty).</summary>
    Task<WritePlanDraft> PlanSweepResetAsync(CancellationToken cancellationToken);
}

/// <summary>Pure rules of « Oublier les relevés »: draft, precondition (same memory as planned), postcondition (memory empty).</summary>
public static class RelationSweepReset
{
    public const string Kind = "relations.sweepReset";

    /// <summary>Attribute of the only change: the memory of the relevés.</summary>
    public const string Attribute = "releves";

    /// <summary>Identity of the relevé memory as the target of a plan (it is not a directory object).</summary>
    public static readonly Guid MemoryGuid = new("3f7c2a91-0b6e-4d58-a1c4-92e5d0b7f613");

    private static string C => FrenchText.Colon;

    /// <summary>Raw value of the memory in a plan: number of workstations read and the fingerprint of the readings.</summary>
    public static string Value(int count, string fingerprint) => count.ToString(System.Globalization.CultureInfo.InvariantCulture) + "|" + fingerprint;

    /// <summary>
    /// Draft of the reset: one change « Relevés du parc : n postes relevés → aucun ». Not reversible (the dates of the relevés are
    /// not kept), harmless: no association is removed, the workstations are only read again first by the next relevé.
    /// </summary>
    public static WritePlanDraft Draft(int count, string fingerprint, string? oldest, bool simulated, bool backupVerified)
    {
        ArgumentNullException.ThrowIfNull(fingerprint);
        if (count <= 0)
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, "Aucun relevé mémorisé" + C + "rien à oublier.");
        }
        var before = FrenchText.Count(count, "poste relevé", "postes relevés") + (oldest is null ? "" : ", le plus ancien " + oldest);
        var risks = ImmutableArray.CreateBuilder<WriteRisk>();
        risks.Add(new WriteRisk(Tone.Info, "Aucune association n’est retirée et Active Directory n’est pas modifié" + C + "seule la mémoire des relevés est vidée."));
        risks.Add(new WriteRisk(Tone.Warn, "Les dates des relevés ne sont pas gardées" + C + "le prochain relevé reprendra les postes comme jamais relevés, 50 au plus à la fois."));
        risks.Add(backupVerified
            ? new WriteRisk(Tone.Info, "Sauvegarde vérifiée de la base locale avant l’effacement.")
            : new WriteRisk(Tone.Info, simulated ? "Simulation" + C + "mémoire de la session seulement, aucune base ouverte." : "La base locale est sauvegardée et vérifiée avant l’effacement."));
        return new WritePlanDraft(
            Kind,
            "Oublier les relevés",
            "Effacement des relevés du parc",
            "La mémoire des relevés (" + before + ") sera vidée" + C + "le prochain relevé reprendra par les postes jamais relevés. Associations et annuaire non modifiés.",
            new WriteTarget("relevés", "Relevés du parc", "Mémoire des relevés",
                simulated ? "Mémoire de la simulation · relevés des consoles" : "Base locale de Domenia · relevés des consoles", MemoryGuid.ToString("D"), null),
            [new WriteChange(Attribute, "Relevés du parc", WriteChangeKind.Reset, before, "Aucun relevé mémorisé", Value(count, fingerprint), Value(0, ""))],
            risks.ToImmutable(),
            new WriteConfirmation(false, null, "Confirmation simple" + C + "aucune association ni objet de l’annuaire n’est modifié."),
            new WriteReversibility(false, "Non réversible", "Les dates des relevés effacés ne reviennent pas ; un nouveau relevé les reconstitue, poste par poste."),
            null);
    }

    /// <summary>Precondition: the memory is still the one planned (or already empty: nothing to write).</summary>
    public static WritePrecheck Check(WritePlan plan, int count, string fingerprint)
    {
        ArgumentNullException.ThrowIfNull(plan);
        ArgumentNullException.ThrowIfNull(fingerprint);
        var change = plan.Changes.Length == 1 ? plan.Changes[0] : null;
        if (change is null || change.Attribute != Attribute)
        {
            return WritePrecheck.Stale("Plan illisible pour la mémoire des relevés" + C + "rien n’a été envoyé.");
        }
        if (count == 0)
        {
            return WritePrecheck.Valid("Mémoire des relevés déjà vide" + C + "rien ne sera écrit.");
        }
        return change.BeforeValue == Value(count, fingerprint)
            ? WritePrecheck.Valid(FrenchText.Count(count, "poste relevé", "postes relevés") + " à oublier, comme dans le plan.")
            : WritePrecheck.Stale("Un relevé a eu lieu depuis le plan" + C + "préparez de nouveau l’effacement. Rien n’a été envoyé.");
    }

    /// <summary>Postcondition: the memory is empty.</summary>
    public static WriteVerification Verify(int count) => count == 0
        ? new WriteVerification(VerificationState.Verified, "Mémoire des relevés relue" + C + "vide, comme attendu.")
        : new WriteVerification(VerificationState.Mismatch, FrenchText.Count(count, "poste relevé reste", "postes relevés restent") + " en mémoire à la relecture" + C + "un relevé a pu avoir lieu entre-temps.");
}

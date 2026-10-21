namespace Domenia.Core;

/// <summary>Expected failure of an engine operation: a stable code for the page and a French message for the operator.</summary>
public sealed class DomeniaOperationException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}

/// <summary>Error codes and messages of the bridge contract (docs/OPERATIONS.md § 1.4, 6 and 7).</summary>
public static class DomeniaErrors
{
    public const string SourceUnavailable = "source.unavailable";
    public const string SourceUnavailableMessage = "Lecture de l’annuaire indisponible dans cette version : lancez Domenia avec --simulation pour l’essayer sans Active Directory.";

    public const string ScopeTooWide = "scope.tooWide";
    public const string ScopeTooWideMessage = "Choisissez une OU : la mesure des postes n’est jamais lancée sur tout le domaine.";

    public const string WidgetUnknown = "widget.unknown";
    public const string WidgetUnknownReadMessage = "Widget inconnu : rien n’a été lu.";
    public const string WidgetUnknownChangeMessage = "Widget inconnu : rien n’a été changé.";

    public const string WidgetDisabled = "widget.disabled";
    public const string WidgetDisabledMessage = "Ce widget est désactivé : aucune mesure n’est faite. Réactivez « Mesure active » pour l’actualiser.";

    public const string SimulationReadOnly = "simulation.readOnly";
    public const string SimulationReadOnlyMessage = "Écritures désactivées en simulation : aucune écriture tentée.";

    public const string SimulationUnavailable = "simulation.unavailable";
    public const string SimulationUnavailableMessage = "Non disponible en simulation : aucune connexion au poste ni à l’annuaire.";

    public const string ArgumentsInvalid = "arguments.invalid";
}

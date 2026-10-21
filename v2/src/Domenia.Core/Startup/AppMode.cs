using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>Operating mode of the application, decided once at startup.</summary>
public enum AppMode
{
    /// <summary>Fictitious in-memory directory: no network, no local base; writes go to an in-memory overlay only.</summary>
    Simulation,

    /// <summary>Real Active Directory (JSON text "annuaire").</summary>
    Directory,
}

/// <summary>Why the mode was chosen; serialized as its camelCase name.</summary>
public enum ModeReason
{
    Argument,
    Environment,
    EnvironmentOptOut,
    NotDomainJoined,
    JoinStateUnknown,
    DomainJoined,
    /// <summary>Auth.DemoProvider=true in Domenia.config.json (setting of Domenia 1), JSON text "configuration".</summary>
    Configuration,
}

/// <summary>Local join state of the workstation (LSA), read without any network access.</summary>
public enum DomainJoinState
{
    Joined,
    Workgroup,
    Unjoined,
    Unknown,
}

/// <summary>Join state and, when joined, the domain name (DNS name when known, NetBIOS name otherwise).</summary>
public sealed record DomainJoinInfo(DomainJoinState State, string? DomainName);

/// <summary>Result of the startup decision. <see cref="Warnings"/> go to the technical journal only.</summary>
public sealed record ModeDecision(
    AppMode Mode,
    ModeReason Reason,
    string Detail,
    string? Banner,
    string? JoinedDomain,
    ImmutableArray<string> Warnings);

/// <summary>Operator texts of the mode (docs/OPERATIONS.md § 2).</summary>
public static class ModeTexts
{
    public const string SimulationLabel = "Simulation";
    public const string DirectoryLabel = "Annuaire Active Directory";
    public const string Banner = "Simulation : annuaire fictif example.local, aucune connexion à Active Directory ; les écritures ne modifient que cet annuaire fictif, en mémoire.";
    public const string WindowTitleSuffix = " — Simulation";

    public const string DetailArgument = "Lancé avec l’option --simulation.";
    public const string DetailEnvironment = "Variable DOMENIA_SIMULATION=1 présente.";
    public const string DetailEnvironmentOptOut = "Variable DOMENIA_SIMULATION=0 : mode annuaire demandé.";
    public const string DetailNotDomainJoined = "Ce poste n’est joint à aucun domaine : démarrage en simulation.";
    public const string DetailJoinStateUnknown = "Appartenance du poste à un domaine illisible : démarrage en simulation. Pour forcer l’annuaire, définissez DOMENIA_SIMULATION=0.";
    public const string DetailJoinedWithoutName = "Poste joint à un domaine.";
    public const string DetailConfiguration = "Réglage Auth.DemoProvider de Domenia.config.json : démarrage en simulation.";

    public const string WarningVariable = "Valeur de DOMENIA_SIMULATION ignorée : seules 1 et 0 sont admises.";

    public static string DetailDomainJoined(string domainName) => $"Poste joint au domaine {domainName}.";

    public static string WarningArguments(int count) => count == 1
        ? "1 argument de ligne de commande ignoré : seul --simulation est reconnu."
        : $"{count} arguments de ligne de commande ignorés : seul --simulation est reconnu.";
}

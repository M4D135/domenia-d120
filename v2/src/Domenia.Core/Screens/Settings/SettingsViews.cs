using System.Collections.Immutable;
using System.Text.Json;

namespace Domenia.Core;

/// <summary>
/// Connection preferences of the workstation (Domenia 1 PAR-049, HKCU\Software\DOMENIA, now in the local preferences of
/// Domenia 2): « se souvenir de mon identifiant », the last identifier and the identity of the Windows vault entry
/// (domain and account). Never a password. Nothing is remembered in simulation.
/// </summary>
public sealed record ConnectionPreferences(bool RememberLogin, string LastLogin, string VaultDomain, string VaultUser);

/// <summary>The vault entry as shown (names only).</summary>
public sealed record VaultIdentity(string Domain, string User);

/// <summary>Connection preferences as shown and edited by the page.</summary>
public sealed record ConnectionPreferencesView(bool RememberLogin, string? LastLogin, VaultIdentity? Vault, bool Editable, string? Reason, ImmutableArray<string> Rules);

/// <summary>Working OU of the session and the default one of the source (PAR-047).</summary>
public sealed record SettingsScopeView(string? Dn, string? Label, bool Subtree, string? Path, bool WholeDomain, string? DefaultDn, string? DefaultLabel, bool IsDefault);

/// <summary>A section that follows the working OU, or keeps a narrower one of its own (PAR-048).</summary>
public sealed record SectionScopeView(string Id, string Label, bool Follows, string ScopeLabel, string Detail);

/// <summary>Result of settings.connection.</summary>
public sealed record ConnectionView(
    SessionConnection Connection,
    string Mode,
    bool Simulated,
    DomainIdentity? Domain,
    ControllerIdentity? Controller,
    AccountIdentity Account,
    AuthenticationInfo Authentication,
    RightsInfo Rights,
    bool ReadOnly,
    ConnectionPreferencesView Preferences,
    SettingsScopeView Scope,
    ImmutableArray<SectionScopeView> Sections,
    ImmutableArray<string> Safeguards);

/// <summary>One line of the technical journal (one record per line; continuation lines of a stack kept with their record).</summary>
public sealed record LogLine(DateTimeOffset? At, string Level, string Text, ImmutableArray<string> More);

/// <summary>
/// The technical journal file of the host: errors and warnings of the lines read, and those written since the start of this
/// run (<see cref="SessionStart"/>), which alone light the badge of the page (earlier runs are history, not an alarm).
/// </summary>
public sealed record LogFileView(string Label, string? Path, bool Exists, long Bytes, string BytesText, DateTimeOffset? ModifiedAt, bool Truncated, int Records, int Errors, int Warnings,
    DateTimeOffset? SessionStart, int SessionErrors, int SessionWarnings);

/// <summary>Result of settings.logs: the end of the technical journal and the operations journal of the session.</summary>
public sealed record LogsView(LogFileView File, ImmutableArray<LogLine> Lines, ImmutableArray<JournalEntry> Session, ImmutableArray<string> Rules);

/// <summary>A local folder or file of the application (with « Ouvrir » when it is a folder that exists).</summary>
public sealed record AppLocation(string Id, string Label, string Display, string? Path, bool Exists, bool CanOpen);

/// <summary>Identity of the application, of its engines and of the workstation (À propos).</summary>
public sealed record AboutIdentity(
    string Name,
    string Version,
    string? InformationalVersion,
    string Runtime,
    string RuntimeIdentifier,
    bool Process64,
    string WebViewMode,
    string WebViewModeLabel,
    string? WebViewVersion,
    string OperatingSystem,
    string Mode,
    string ModeLabel,
    string ModeDetail);

/// <summary>Result of settings.about.</summary>
public sealed record AboutView(AboutIdentity Identity, CompatibilityVerdict Compatibility, ComponentInventoryView Components, ImmutableArray<AppLocation> Locations, ImmutableArray<string> Commitments);

/// <summary>Result of settings.demo: the facts of the simulation, or why there is none.</summary>
public sealed record SimulationView(bool Active, string Mode, string ModeLabel, ModeReason Reason, string Detail, string? Banner, SimulationFacts? Facts, ImmutableArray<string> Guarantees, ImmutableArray<string> HowTo);

/// <summary>Pure rules of the connection preferences and of the views of the connection and of the simulation.</summary>
public static class SettingsViewRules
{
    /// <summary>Preference key of the connection preferences (screen « settings »).</summary>
    public const string ConnectionKey = "settings.connection";

    public const int MaxLoginLength = 256;

    public static ConnectionPreferences DefaultConnection { get; } = new(false, "", "", "");

    /// <summary>Reads the stored connection preferences; anything unreadable keeps the default (never a guessed identity).</summary>
    public static ConnectionPreferences ReadConnection(JsonElement? stored)
    {
        if (stored is not JsonElement root || root.ValueKind != JsonValueKind.Object)
        {
            return DefaultConnection;
        }
        static string Text(JsonElement root, string name)
        {
            if (!root.TryGetProperty(name, out var v) || v.ValueKind != JsonValueKind.String)
            {
                return "";
            }
            var text = v.GetString()!.Trim();
            return text.Length > MaxLoginLength || text.Any(char.IsControl) ? "" : text;
        }
        var remember = root.TryGetProperty("rememberLogin", out var r) && r.ValueKind == JsonValueKind.True;
        return new ConnectionPreferences(remember, Text(root, "lastLogin"), Text(root, "vaultDomain"), Text(root, "vaultUser"));
    }

    /// <summary>Stored form of the connection preferences (never a password: there is no field for one).</summary>
    public static JsonElement ToJson(ConnectionPreferences preferences)
    {
        ArgumentNullException.ThrowIfNull(preferences);
        using var buffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(buffer))
        {
            writer.WriteStartObject();
            writer.WriteBoolean("rememberLogin", preferences.RememberLogin);
            writer.WriteString("lastLogin", preferences.RememberLogin ? preferences.LastLogin : "");
            writer.WriteString("vaultDomain", preferences.VaultDomain);
            writer.WriteString("vaultUser", preferences.VaultUser);
            writer.WriteEndObject();
        }
        using var document = JsonDocument.Parse(buffer.ToArray());
        return document.RootElement.Clone();
    }

    /// <summary>The connection preferences as shown: read only in simulation (nothing is remembered there).</summary>
    public static ConnectionPreferencesView ConnectionView(ConnectionPreferences preferences, bool simulated)
    {
        ArgumentNullException.ThrowIfNull(preferences);
        return new ConnectionPreferencesView(
            !simulated && preferences.RememberLogin,
            simulated || !preferences.RememberLogin || preferences.LastLogin.Length == 0 ? null : preferences.LastLogin,
            simulated || preferences.VaultUser.Length == 0 ? null : new VaultIdentity(preferences.VaultDomain, preferences.VaultUser),
            !simulated,
            simulated ? "Simulation" + FrenchText.Colon + "aucune saisie d’identifiants, rien n’est mémorisé." : null,
            [
                "Jamais de mot de passe" + FrenchText.Colon + "seuls l’identifiant et le nom du compte du coffre Windows sont mémorisés.",
                "« Se souvenir de mon identifiant » est décoché par défaut ; le décocher oublie aussi le dernier identifiant.",
                "Le coffre Windows n’est jamais lu au démarrage ni en arrière-plan.",
            ]);
    }

    /// <summary>The sections of Domenia 2 that use the working OU as their default (PAR-048).</summary>
    public static ImmutableArray<SectionScopeView> Sections(ScopeSelection? scope)
    {
        var label = scope is null ? "Aucune OU choisie" : scope.Label;
        SectionScopeView Follow(string id, string name, string detail) => new(id, name, true, label, detail);
        return
        [
            Follow("accueil", "Accueil", "Mesures des postes dans l’OU de travail ; comptes sur tout le domaine."),
            Follow("rechercher", "Rechercher", "Périmètre proposé par défaut ; jamais tout le domaine sans garde."),
            Follow("relations", "Utilisateurs et postes", "Périmètre des associations par défaut."),
            Follow("synchro", "Base autonome", "OU mise à jour par défaut dans la base locale."),
        ];
    }

    /// <summary>The simulation view (facts null outside the simulation).</summary>
    public static SimulationView Simulation(ModeDecision decision, SimulationFacts? facts)
    {
        ArgumentNullException.ThrowIfNull(decision);
        var simulation = decision.Mode == AppMode.Simulation;
        return new SimulationView(
            simulation,
            simulation ? AppInfoBuilder.SimulationModeText : AppInfoBuilder.DirectoryModeText,
            simulation ? ModeTexts.SimulationLabel : ModeTexts.DirectoryLabel,
            decision.Reason,
            decision.Detail,
            simulation ? decision.Banner ?? ModeTexts.Banner : null,
            facts,
            [
                "Aucun accès au réseau : ni LDAP, ni WMI, ni DNS, ni ping ; toute requête de la page vers un autre hôte que domenia.local est refusée.",
                "La base locale SQLite n’est jamais ouverte : la base montrée est fictive, en mémoire.",
                "Les écritures ne changent qu’une surcouche en mémoire de l’annuaire fictif, jamais enregistrée ; leurs reçus sont marqués « simulé ».",
                "Aucune saisie d’identifiants, aucun coffre, aucun secret.",
                "Même graine, même date de référence et même fuseau donnent le même annuaire, à l’octet près.",
            ],
            simulation
                ?
                [
                    "Quitter la simulation" + FrenchText.Colon + "relancez Domenia sans l’option --simulation sur un poste joint au domaine.",
                    "Forcer l’annuaire" + FrenchText.Colon + "définissez la variable DOMENIA_SIMULATION=0 avant de lancer Domenia.",
                    "Auth.DemoProvider=true dans Domenia.config.json démarre aussi en simulation.",
                ]
                :
                [
                    "Essayer sans Active Directory" + FrenchText.Colon + "lancez Domenia avec l’option --simulation (annuaire fictif example.local, aucune connexion).",
                    "Ou définissez la variable DOMENIA_SIMULATION=1 avant de lancer Domenia.",
                ]);
    }
}

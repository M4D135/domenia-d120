using System.Collections.Immutable;

namespace Domenia.Core.Poste;

/// <summary>One service of the list (Domenia 1 ConvertTo-DomeniaServiceRows): raw values, French labels and what can be asked.</summary>
public sealed record ServiceRow(
    string Name,
    string DisplayName,
    string State,
    string StateLabel,
    string StartMode,
    string StartLabel,
    bool AutoStopped,
    bool StopExpected,
    string? ExpectedReason,
    bool CanStart,
    bool CanRestart,
    bool CanStop,
    int? ProcessId,
    string? Account,
    int? ExitCode,
    ImmutableArray<string> DependsOn,
    ImmutableArray<string> Dependents,
    bool InProfile,
    string? ProfileReason,
    string? Description);

/// <summary>Deviation of one service of the profile expected on a workstation of the domain (Domenia 1 point 90).</summary>
public sealed record ServiceProfileLine(string Name, string Reason, string State, Tone Tone, string Text);

/// <summary>Result of poste.services: rows (automatic services stopped first), summary, profile and limits.</summary>
public sealed record ServicesResult(
    string Computer,
    DateTimeOffset ReadAt,
    int Total,
    int AutoStopped,
    int StopExpected,
    bool Capped,
    int SecretsRemoved,
    string Summary,
    ImmutableArray<ServiceRow> Rows,
    ImmutableArray<ServiceProfileLine> Profile,
    ImmutableArray<PosteFact> Facts);

/// <summary>A name pattern of a service that may be stopped without fault (trigger or delayed start), with its reason.</summary>
public sealed record ExpectedStopRule(string Pattern, string Reason);

/// <summary>
/// Rules of the services of a workstation (Domenia 1 Domenia-Assist.Model UX-38, Domenia-Workstation.Model MO-06 and
/// Domenia-Readings.Model point 90). Pure: no WMI, no clock.
/// </summary>
public static class PosteServices
{
    /// <summary>Most instances read (Win32_Service is read once, capped).</summary>
    public const int Cap = 500;

    /// <summary>Services that start on a trigger or after a delay: stopped between two uses without fault (decision MO-06).</summary>
    public static ImmutableArray<ExpectedStopRule> ExpectedStops { get; } =
    [
        new("gupdate", "Google Update, démarrage différé"),
        new("GoogleUpdater*", "Google Updater, démarrage sur déclencheur"),
        new("edgeupdate", "Microsoft Edge Update, démarrage différé"),
        new("MapsBroker", "Gestionnaire des cartes téléchargées, démarrage différé"),
        new("sppsvc", "Protection logicielle, démarrage différé sur déclencheur"),
        new("RemoteRegistry", "Registre à distance, démarrage sur déclencheur"),
        new("clr_optimization_*", "Optimisation du runtime .NET, démarrage différé"),
        new("DoSvc", "Optimisation de la distribution, démarrage différé"),
        new("UsoSvc", "Orchestrateur des mises à jour, démarrage différé"),
        new("BITS", "Service de transfert intelligent, démarrage différé"),
        new("wuauserv", "Windows Update, démarrage sur déclencheur"),
        new("WbioSrvc", "Biométrie Windows, démarrage sur déclencheur"),
        new("dmwappushservice", "Routage des messages push, démarrage sur déclencheur"),
        new("WMPNetworkSvc", "Partage réseau du Lecteur Windows Media, démarrage différé"),
        new("OneSyncSvc_*", "Synchronisation de l’hôte, démarrage différé"),
    ];

    /// <summary>Services expected to run on a workstation joined to the domain (Get-DomeniaServiceProfile).</summary>
    public static ImmutableArray<(string Name, string Reason)> Profile { get; } =
    [
        ("Winmgmt", "Instrumentation WMI : nécessaire aux lectures à distance"),
        ("RpcSs", "Appel de procédure distante (RPC)"),
        ("RpcEptMapper", "Mappeur de points de terminaison RPC"),
        ("Dnscache", "Client DNS"),
        ("Dhcp", "Client DHCP (actif même avec une adresse fixe)"),
        ("NlaSvc", "Connaissance des emplacements réseau : choix du profil de pare-feu"),
        ("LanmanWorkstation", "Station de travail : accès aux partages et à SYSVOL"),
        ("Netlogon", "Ouverture de session réseau du domaine"),
        ("gpsvc", "Client de stratégie de groupe"),
        ("EventLog", "Journal d’événements Windows"),
        ("Schedule", "Planificateur de tâches"),
        ("BFE", "Moteur de filtrage de base (pare-feu et IPsec)"),
        ("mpssvc", "Pare-feu Windows Defender"),
        ("CryptSvc", "Services de chiffrement"),
        ("ProfSvc", "Service de profil utilisateur"),
    ];

    /// <summary>True when an automatic service may be stopped without fault, by its short name (wildcard * only).</summary>
    public static bool StopExpected(string? name, out string? reason)
    {
        reason = null;
        var service = (name ?? "").Trim();
        if (service.Length == 0)
        {
            return false;
        }
        foreach (var rule in ExpectedStops)
        {
            var match = rule.Pattern.EndsWith('*')
                ? service.StartsWith(rule.Pattern[..^1], StringComparison.OrdinalIgnoreCase)
                : string.Equals(service, rule.Pattern, StringComparison.OrdinalIgnoreCase);
            if (match)
            {
                reason = rule.Reason;
                return true;
            }
        }
        return false;
    }

    /// <summary>
    /// Key name of a service as it may travel in a WQL filter (Test-DomeniaServiceName): letters, digits, inner spaces and
    /// the signs Windows and editors use. A quote, a backslash or a control character is refused.
    /// </summary>
    public static bool IsValidName(string? name)
    {
        if (string.IsNullOrEmpty(name) || name.Length > 256 || !string.Equals(name, name.Trim(), StringComparison.Ordinal))
        {
            return false;
        }
        return name.All(c => char.IsAsciiLetterOrDigit(c) || " _.$@+#,(){}-".Contains(c, StringComparison.Ordinal));
    }

    /// <summary>Rows sorted as Domenia 1 does: automatic services stopped (not expected) first, then by display name.</summary>
    public static ImmutableArray<ServiceRow> Rows(IEnumerable<ServiceEntry> services)
    {
        ArgumentNullException.ThrowIfNull(services);
        var list = services.Where(s => !string.IsNullOrWhiteSpace(s.Name)).ToList();
        var dependents = list.SelectMany(s => s.DependsOn.Select(d => (Parent: d, Child: s.DisplayName)))
            .GroupBy(p => p.Parent, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.Select(p => p.Child).Order(StringComparer.Ordinal).ToImmutableArray(), StringComparer.OrdinalIgnoreCase);
        var profile = Profile.ToDictionary(p => p.Name, p => p.Reason, StringComparer.OrdinalIgnoreCase);
        return
        [
            .. list.Select(s =>
            {
                var autoStopped = s.StartMode == "Auto" && s.State == "Stopped";
                var expected = StopExpected(s.Name, out var reason);
                return new ServiceRow(
                    s.Name,
                    string.IsNullOrWhiteSpace(s.DisplayName) ? s.Name : s.DisplayName,
                    s.State,
                    PosteLabels.ServiceState(s.State),
                    s.StartMode,
                    PosteLabels.ServiceStart(s.StartMode, s.Delayed),
                    autoStopped && !expected,
                    autoStopped && expected,
                    expected ? reason : null,
                    s.State == "Stopped" && s.StartMode != "Disabled",
                    s.State == "Running",
                    s.State == "Running",
                    s.ProcessId,
                    s.Account,
                    s.ExitCode,
                    s.DependsOn,
                    dependents.TryGetValue(s.Name, out var children) ? children : [],
                    profile.ContainsKey(s.Name),
                    profile.TryGetValue(s.Name, out var why) ? why : null,
                    s.Description);
            })
            .OrderByDescending(r => r.AutoStopped)
            .ThenBy(r => r.DisplayName, PosteText.French)
            .ThenBy(r => r.Name, StringComparer.Ordinal),
        ];
    }

    /// <summary>Comparison with the expected profile: a deviation is a lead to check, never an action.</summary>
    public static ImmutableArray<ServiceProfileLine> CompareProfile(IReadOnlyCollection<ServiceRow> rows)
    {
        ArgumentNullException.ThrowIfNull(rows);
        var byName = rows.ToDictionary(r => r.Name, StringComparer.OrdinalIgnoreCase);
        return
        [
            .. Profile.Select(p =>
            {
                if (!byName.TryGetValue(p.Name, out var row))
                {
                    return new ServiceProfileLine(p.Name, p.Reason, "Absent", Tone.Warn, "Absent de la liste lue" + FrenchText.Colon + "à vérifier.");
                }
                if (row.State == "Running")
                {
                    return new ServiceProfileLine(p.Name, p.Reason, row.StateLabel, Tone.Ok, row.StartLabel + ", en cours.");
                }
                if (row.StartMode == "Disabled")
                {
                    return new ServiceProfileLine(p.Name, p.Reason, row.StateLabel, Tone.Alert, "Désactivé" + FrenchText.Colon + "écart au profil attendu.");
                }
                var code = row.ExitCode is int exit and not 0 ? " (code " + exit.ToString(System.Globalization.CultureInfo.InvariantCulture) + (exit == 1077 ? ", normal pour un démarrage sur déclencheur" : "") + ")" : "";
                return new ServiceProfileLine(p.Name, p.Reason, row.StateLabel, row.StartMode == "Auto" ? Tone.Warn : Tone.Info, row.StartLabel + ", arrêté" + code + ".");
            }),
        ];
    }

    /// <summary>Local filter of the list: « automatiques arrêtés seulement » and a text in the name or the display name.</summary>
    public static bool Matches(ServiceRow row, bool autoStoppedOnly, string? text)
    {
        ArgumentNullException.ThrowIfNull(row);
        if (autoStoppedOnly && !row.AutoStopped)
        {
            return false;
        }
        var needle = (text ?? "").Trim();
        return needle.Length == 0
            || row.DisplayName.Contains(needle, StringComparison.OrdinalIgnoreCase)
            || row.Name.Contains(needle, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>Summary line of the list (Get-DomeniaServiceListSummary), with the limits of the reading.</summary>
    public static string Summary(int total, int autoStopped, int expected, string computer, DateTimeOffset readAt, TimeZoneInfo zone, bool capped)
    {
        var text = FrenchText.Count(total, "service lu", "services lus") + " sur " + computer + " à " + PosteText.LocalTime(readAt, zone)
            + " ; " + FrenchText.Count(autoStopped, "automatique arrêté", "automatiques arrêtés") + " en défaut";
        if (expected > 0)
        {
            text += ", " + FrenchText.Integer(expected) + " sur déclencheur ou différé(s), sans défaut";
        }
        if (capped)
        {
            text += " ; plafond de " + FrenchText.Integer(Cap) + " services atteint";
        }
        return text + ". Lecture seule : la liste ne se relit que sur « Lire les services ».";
    }
}

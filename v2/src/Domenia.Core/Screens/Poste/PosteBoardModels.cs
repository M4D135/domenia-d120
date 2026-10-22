using System.Collections.Frozen;
using System.Collections.Immutable;

namespace Domenia.Core.Poste;

/// <summary>Level of an attention point: critical, to watch, or a plain information (never counted in the score).</summary>
public enum AttentionLevel
{
    Alert,
    Warn,
    Info,
}

/// <summary>
/// One attention point of the workstation (Domenia 1 Add-DomeniaBoardAttention): its level, its text, the health rule that
/// produced it and, when useful, the view that holds the action (navigation only: nothing runs).
/// </summary>
public sealed record AttentionPoint(AttentionLevel Level, string Text, string Rule, PosteRoute? Route, string? Reason);

/// <summary>One threshold of the health policy, as the editor of Domenia 1 names it.</summary>
public sealed record HealthThreshold(string Id, string Label, int Value, string Unit);

/// <summary>One health rule of the catalog (Domenia-HealthRules: identifier and name).</summary>
public sealed record HealthRule(string Id, string Name);

/// <summary>A rule suspended for a while (Domenia 1 Suspensions): until when, why, and the sentence the page shows.</summary>
public sealed record HealthSuspension(string RuleId, string Reason, DateTimeOffset Until, string Text);

/// <summary>
/// A custom alert of the health policy (Domenia 1 CustomRules): free space of C: (« DiskFree »), days since the last start
/// (« UptimeDays ») or used memory (« MemoryUsed »), compared with a threshold; an alert on a saved query is counted in
/// <see cref="PosteHealthPolicy.QueryRules"/> and evaluated by the query workshop, never here.
/// </summary>
public sealed record PosteCustomRule(string Id, string Name, string Measure, string Operator, double Threshold, AttentionLevel Severity, bool Enabled);

/// <summary>
/// Health policy of a workstation (Domenia 1 Domenia-HealthRules): the shared thresholds of the drawings, tiles and attention
/// points, and the rules switched off. <see cref="Default"/> holds the values shipped with Domenia 1.
/// </summary>
public sealed record PosteHealthPolicy(
    int StaleDays,
    int PasswordDays,
    int UptimeDays,
    int DiskFreeAlert,
    int DiskFreeWarn,
    int MemoryUsedWarn,
    int BatteryWarn,
    int HotfixDays,
    FrozenSet<string> DisabledRules,
    string Origin)
{
    public static PosteHealthPolicy Default { get; } = new(90, 60, 30, 10, 20, 90, 20, 60, FrozenSet<string>.Empty, "Seuils livrés avec Domenia 1 : aucune règle de santé enregistrée pour ce domaine");

    /// <summary>Suspensions still running at <see cref="EvaluatedAt"/> (an ended suspension is never applied).</summary>
    public ImmutableArray<HealthSuspension> Suspensions { get; init; } = [];

    /// <summary>Custom alerts on a measure of the workstation (32 at most), evaluated on this board.</summary>
    public ImmutableArray<PosteCustomRule> CustomRules { get; init; } = [];

    /// <summary>Alerts on a saved query: evaluated by the query workshop (screen Requêtes), announced here, never guessed.</summary>
    public int QueryRules { get; init; }

    /// <summary>Instant the suspensions are compared with (null: every listed suspension applies).</summary>
    public DateTimeOffset? EvaluatedAt { get; init; }

    /// <summary>Running suspension of a rule, or null.</summary>
    public HealthSuspension? SuspensionOf(string rule) =>
        Suspensions.FirstOrDefault(s => string.Equals(s.RuleId, rule, StringComparison.Ordinal) && (EvaluatedAt is not DateTimeOffset at || s.Until > at));

    /// <summary>A rule counts when it is switched on and not suspended (Domenia 1 Test-DomeniaHealthRuleEnabled).</summary>
    public bool Counts(string rule) => IsEnabled(rule) && SuspensionOf(rule) is null;

    /// <summary>Rules of Domenia 1, in catalog order (Get-DomeniaHealthRuleCatalog).</summary>
    public static ImmutableArray<HealthRule> Rules { get; } =
    [
        new("eos.ended", "Windows en fin de service"),
        new("eos.soon", "Windows proche de sa fin de service"),
        new("stale", "Connexion au domaine ancienne"),
        new("never", "Date de connexion au domaine absente"),
        new("pwdold", "Mot de passe du compte machine ancien"),
        new("laps.none", "Expiration LAPS non visible"),
        new("laps.expired", "Expiration LAPS dépassée"),
        new("bitlocker.none", "Protection ou clé BitLocker non visible"),
        new("bitlocker.suspended", "Protection BitLocker suspendue"),
        new("secureboot", "Secure Boot désactivé (UEFI)"),
        new("certificates", "Certificats machine expirés ou proches de l’échéance"),
        new("lowdisk", "Disque presque plein"),
        new("disk.tight", "Espace disque à surveiller"),
        new("uptime", "Redémarrage ancien"),
        new("memory", "Mémoire très utilisée"),
        new("battery", "Batterie faible"),
        new("ad.disabled", "Compte ordinateur désactivé"),
        new("clock", "Décalage de l’horloge"),
        new("firewall", "Pare-feu désactivé"),
        new("reboot", "Redémarrage en attente"),
        new("services", "Services automatiques arrêtés"),
        new("devices", "Périphériques en erreur"),
        new("drivers", "Pilotes non signés"),
        new("hotfix", "Correctifs anciens"),
        new("events", "Événements système critiques"),
    ];

    /// <summary>The thresholds as the page lists them (« Seuils de Domenia 1 »).</summary>
    public ImmutableArray<HealthThreshold> Thresholds =>
    [
        new("StaleDays", "Connexion AD ancienne (jours, date approximative)", StaleDays, "j"),
        new("PasswordDays", "Mot de passe machine ancien (jours)", PasswordDays, "j"),
        new("UptimeDays", "Redémarrage ancien (jours)", UptimeDays, "j"),
        new("DiskFreeAlert", "Disque critique : espace libre inférieur à", DiskFreeAlert, "%"),
        new("DiskFreeWarn", "Disque à surveiller : espace libre inférieur à", DiskFreeWarn, "%"),
        new("MemoryUsedWarn", "Mémoire utilisée supérieure à", MemoryUsedWarn, "%"),
        new("BatteryWarn", "Batterie inférieure à", BatteryWarn, "%"),
        new("HotfixDays", "Dernier correctif plus ancien que (jours)", HotfixDays, "j"),
    ];

    public bool IsEnabled(string rule) => !DisabledRules.Contains(rule);

    /// <summary>Free space state of a disk against the shared thresholds (Get-DomeniaThresholdState).</summary>
    public Tone DiskState(double freePercent) => freePercent < DiskFreeAlert ? Tone.Alert : freePercent < DiskFreeWarn ? Tone.Warn : Tone.Ok;
}

/// <summary>
/// Health of the workstation (Domenia 1 Get-DomeniaBoardHealth and Complete-DomeniaBoardData): 100 − 25 per critical point −
/// 10 per point to watch; the verdict follows the state. A score computed without its key checks says so in
/// <see cref="Badge"/>, with the action that fills them (<see cref="BadgeAction"/>); without any point it is withheld.
/// </summary>
public sealed record PosteHealth(
    int? Score,
    string Verdict,
    Tone State,
    int Alerts,
    int Warnings,
    int Information,
    string Title,
    string Detail,
    string? Badge,
    string? BadgeAction,
    ImmutableArray<AttentionPoint> Points,
    ImmutableArray<AttentionPoint> Suppressed,
    ImmutableArray<HealthThreshold> Thresholds,
    string PolicyOrigin,
    ImmutableArray<string> PolicyNotes);

/// <summary>One line of a sheet: what was read, never a guess (« Non lu » greyed for a checklist line not read).</summary>
public sealed record SheetLine(string Key, string Label, string Value, string? Detail, Tone? State, bool Copy);

/// <summary>A sheet of the console (identity, computer account, protection checklist): Domenia 1 UX-11.</summary>
public sealed record PosteSheet(string Key, string Title, string Value, string? Detail, Tone? State, ImmutableArray<SheetLine> Lines);

/// <summary>A gauge value: percentage (null when not measured, never 0), text, detail and state.</summary>
public sealed record MeterValue(double? Percent, string Value, string Detail, Tone State);

public sealed record ResourceGauges(MeterValue? Memory, MeterValue? Cpu, MeterValue? Battery, string? BatteryText, string? Text);

public sealed record DiskGauge(string Name, long? SizeBytes, long? FreeBytes, double? FreePercent, Tone State, string Text);

public sealed record DiskBoard(DiskGauge? System, ImmutableArray<DiskGauge> Others, string OthersText);

public sealed record CountPart(string Key, string Label, int Value, Tone Tone);

public sealed record ProcessBar(string Name, double Value, string Unit, string Text);

public sealed record EventSourceCount(string Source, int Count, AttentionLevel Level);

/// <summary>Activity of the workstation: services ring, busiest processes, System log errors over three days.</summary>
public sealed record ActivityBoard(ImmutableArray<CountPart> Services, int ServicesTotal, ImmutableArray<ProcessBar> Processes, string ProcessesMeasure, ImmutableArray<EventSourceCount> Events, int EventsIgnored, string EventsText, string? Hint);

/// <summary>A count tile of the inventory (devices in error, local admins, shares…): an answered source with no item is « 0 ».</summary>
public sealed record CountTile(string Key, string Label, int? Value, Tone? State, string Detail, string? Category);

/// <summary>A section of the board told with facts (firewall, BitLocker, updates, pending reboot, Secure Boot, certificates).</summary>
public sealed record BoardSection(string Key, string Title, string Value, string Detail, Tone State, ImmutableArray<PosteFact> Facts);

/// <summary>Why a section is empty and the existing action that fills it (Domenia 1 SP-17): run only on its click.</summary>
public sealed record BoardHint(string Section, string Text, string? ActionLabel, string? Action);

/// <summary>The workstation dashboard (Domenia 1 Get-DomeniaComputerBoardData), built from one inventory and the object card.</summary>
public sealed record PosteBoard(
    PosteHealth Health,
    PosteSheet? Identity,
    PosteSheet AdAccount,
    PosteSheet Protection,
    ResourceGauges? Resources,
    DiskBoard? Disks,
    ActivityBoard? Activity,
    ImmutableArray<CountTile> Counts,
    ImmutableArray<BoardSection> Sections,
    ImmutableArray<BoardHint> Hints,
    string Summary,
    DateTimeOffset? InventoryAt,
    bool Deep);

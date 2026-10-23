using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Domenia.Core.Accueil;

/// <summary>One health check of the catalog (Domenia 1, Get-DomeniaHealthRuleCatalog). <see cref="Fleet"/>: evaluated on the fleet board.</summary>
public sealed record HealthRuleDefinition(string Id, string Name, bool Fleet);

/// <summary>One bounded threshold (Get-DomeniaHealthThresholdCatalog).</summary>
public sealed record HealthThresholdDefinition(string Id, string Name, int Default, int Minimum, int Maximum);

/// <summary>The seven thresholds of the health rules.</summary>
public sealed record HealthThresholds(int StaleDays, int PasswordDays, int UptimeDays, int DiskFreeAlert, int DiskFreeWarn, int MemoryUsedWarn, int BatteryWarn)
{
    public static HealthThresholds Default { get; } = new(90, 60, 30, 10, 20, 90, 20);

    public int Get(string id) => id switch
    {
        "StaleDays" => StaleDays,
        "PasswordDays" => PasswordDays,
        "UptimeDays" => UptimeDays,
        "DiskFreeAlert" => DiskFreeAlert,
        "DiskFreeWarn" => DiskFreeWarn,
        "MemoryUsedWarn" => MemoryUsedWarn,
        "BatteryWarn" => BatteryWarn,
        _ => throw new ArgumentOutOfRangeException(nameof(id)),
    };

    public HealthThresholds With(string id, int value) => id switch
    {
        "StaleDays" => this with { StaleDays = value },
        "PasswordDays" => this with { PasswordDays = value },
        "UptimeDays" => this with { UptimeDays = value },
        "DiskFreeAlert" => this with { DiskFreeAlert = value },
        "DiskFreeWarn" => this with { DiskFreeWarn = value },
        "MemoryUsedWarn" => this with { MemoryUsedWarn = value },
        "BatteryWarn" => this with { BatteryWarn = value },
        _ => throw new ArgumentOutOfRangeException(nameof(id)),
    };
}

/// <summary>Custom alert on a workstation measure (DiskFree, UptimeDays, MemoryUsed), at most 32 (point 75).</summary>
public sealed record CustomHealthRule(string Id, string Name, string Measure, string Operator, double Threshold, string Severity, bool Enabled)
{
    public HealthQueryBinding? Query { get; init; }
}

/// <summary>Temporary suspension of one check, with its reason (3 to 240 characters) and its UTC end (point 77).</summary>
public sealed record HealthSuspension(string RuleId, string Reason, DateTimeOffset UntilUtc);

/// <summary>A health policy: thresholds, disabled checks, custom alerts and suspensions.</summary>
public sealed record HealthPolicy(
    HealthThresholds Thresholds,
    ImmutableArray<string> DisabledRules,
    ImmutableArray<CustomHealthRule> CustomRules,
    ImmutableArray<HealthSuspension> Suspensions)
{
    public static HealthPolicy Default { get; } = new(HealthThresholds.Default, [], [], []);
}

/// <summary>Differences of one OU against what it inherits; null lists are inherited whole.</summary>
public sealed record HealthOverrides(
    ImmutableSortedDictionary<string, int> Thresholds,
    ImmutableSortedDictionary<string, bool> RuleStates,
    ImmutableArray<CustomHealthRule>? CustomRules,
    ImmutableArray<HealthSuspension>? Suspensions);

public sealed record HealthScopeRecord(string ScopeDn, HealthOverrides Overrides);

/// <summary>Policies of one domain: defaults and the local exceptions of its OUs (at most 512).</summary>
public sealed record HealthPolicyBook(string DomainDn, HealthPolicy Default, ImmutableArray<HealthScopeRecord> Scopes)
{
    public static HealthPolicyBook Empty(string domainDn) => new(domainDn, HealthPolicy.Default, []);
}

public enum HealthRuleState
{
    On,
    Disabled,
    Suspended,
}

/// <summary>A policy resolved for one scope, and where its settings come from.</summary>
public sealed record ResolvedHealthPolicy(HealthPolicy Policy, string ScopeDn, string? SourceDn, ImmutableArray<string> Ancestors, ImmutableArray<string> OverriddenFields, bool Local);

/// <summary>Origin of one effective setting (point 76).</summary>
public sealed record HealthOriginRow(string Kind, string Id, string Name, string Value, string? SourceDn, bool Local, string Origin);

/// <summary>A local exception of the domain with its readable differences.</summary>
/// <summary>
/// A local exception of the health rules (ACC-026). Missing: the OU is no longer known in the local OU index (deleted, moved or
/// renamed): the exception is kept, said « OU introuvable » and never opened as if the OU still existed.
/// </summary>
public sealed record HealthExceptionRow(string ScopeDn, string Label, string Changes, int Count, bool Missing = false);

/// <summary>A scope offered by the rules editor.</summary>
public sealed record HealthEditorScope(string Name, string? Dn, string Kind);

/// <summary>
/// Health rules of the fleet (Domenia 1, Domenia-HealthRules.Model.ps1): catalog of 25 checks, 7 bounded thresholds, custom
/// alerts, temporary suspensions, policies per domain with exceptions inherited down the OU tree. Pure: the clock is an input.
/// </summary>
public static class HealthRules
{
    public const string InvalidCode = "health.invalid";
    public const int MaxCustomRules = 32;
    public const int MaxSuspensions = 64;
    public const int MaxScopes = 512;
    public const int SuspensionRetentionDays = 30;

    public static ImmutableArray<HealthRuleDefinition> Catalog { get; } =
    [
        new("eos.ended", "Windows en fin de service", true),
        new("eos.soon", "Windows proche de sa fin de service", true),
        new("stale", "Connexion au domaine ancienne", true),
        new("never", "Date de connexion au domaine absente", true),
        new("pwdold", "Mot de passe du compte machine ancien", true),
        new("laps.none", "Expiration LAPS non visible", true),
        new("laps.expired", "Expiration LAPS dépassée", true),
        new("bitlocker.none", "Protection ou clé BitLocker non visible", true),
        new("bitlocker.suspended", "Protection BitLocker suspendue", false),
        new("secureboot", "Secure Boot désactivé (UEFI)", false),
        new("certificates", "Certificats machine expirés ou proches de l’échéance", false),
        new("lowdisk", "Disque presque plein", true),
        new("disk.tight", "Espace disque à surveiller", true),
        new("uptime", "Redémarrage ancien", true),
        new("memory", "Mémoire très utilisée", false),
        new("battery", "Batterie faible", false),
        new("ad.disabled", "Compte ordinateur désactivé", false),
        new("clock", "Décalage de l’horloge", false),
        new("firewall", "Pare-feu désactivé", false),
        new("reboot", "Redémarrage en attente", false),
        new("services", "Services automatiques arrêtés", false),
        new("devices", "Périphériques en erreur", false),
        new("drivers", "Pilotes non signés", false),
        new("hotfix", "Correctifs anciens", false),
        new("events", "Événements système critiques", false),
    ];

    public static ImmutableArray<HealthThresholdDefinition> Thresholds { get; } =
    [
        new("StaleDays", "Connexion AD ancienne (jours, date approximative)", 90, 1, 3650),
        new("PasswordDays", "Mot de passe machine ancien (jours)", 60, 1, 3650),
        new("UptimeDays", "Redémarrage ancien (jours)", 30, 1, 365),
        new("DiskFreeAlert", "Disque critique : espace libre inférieur à (%)", 10, 1, 99),
        new("DiskFreeWarn", "Disque à surveiller : espace libre inférieur à (%)", 20, 1, 100),
        new("MemoryUsedWarn", "Mémoire utilisée supérieure à (%)", 90, 1, 100),
        new("BatteryWarn", "Batterie inférieure à (%)", 20, 1, 100),
    ];

    /// <summary>Durations offered for a suspension, in hours (1 h, 24 h, 7 j, 30 j).</summary>
    public static ImmutableArray<int> SuspensionHours { get; } = [1, 24, 168, 720];

    public static string RuleName(string id) =>
        Catalog.FirstOrDefault(r => r.Id == id)?.Name ?? id;

    public static bool IsKnownRule(string id) => Catalog.Any(r => r.Id == id);

    // ---------------------------------------------------------------- rule state

    /// <summary>Active suspension of a rule at <paramref name="now"/>, or null.</summary>
    public static HealthSuspension? Suspension(HealthPolicy policy, string ruleId, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(policy);
        return policy.Suspensions.FirstOrDefault(s => s.RuleId == ruleId && s.UntilUtc > now);
    }

    /// <summary>Enabled for scoring: not disabled (a custom alert must be enabled) and, unless asked, not suspended.</summary>
    public static bool IsEnabled(HealthPolicy policy, string ruleId, DateTimeOffset now, bool ignoreSuspension = false)
    {
        ArgumentNullException.ThrowIfNull(policy);
        if (!ignoreSuspension && Suspension(policy, ruleId, now) is not null)
        {
            return false;
        }
        if (ruleId.StartsWith("custom.", StringComparison.Ordinal))
        {
            var rule = policy.CustomRules.Where(r => r.Id == ruleId).ToList();
            return rule.Count == 1 && rule[0].Enabled;
        }
        return !policy.DisabledRules.Contains(ruleId, StringComparer.Ordinal);
    }

    /// <summary>On, Disabled or Suspended; a rule both disabled and suspended stays Disabled.</summary>
    public static HealthRuleState State(HealthPolicy policy, string ruleId, DateTimeOffset now)
    {
        if (!IsEnabled(policy, ruleId, now, ignoreSuspension: true))
        {
            return HealthRuleState.Disabled;
        }
        return Suspension(policy, ruleId, now) is null ? HealthRuleState.On : HealthRuleState.Suspended;
    }

    /// <summary>« jusqu’au 14/10/2026 18:00 : motif », local time.</summary>
    public static string SuspensionText(HealthSuspension suspension, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(suspension);
        var local = TimeZoneInfo.ConvertTime(suspension.UntilUtc, zone);
        return "jusqu’au " + local.ToString("dd'/'MM'/'yyyy HH':'mm", CultureInfo.InvariantCulture) + FrenchText.Colon + suspension.Reason;
    }

    /// <summary>Ended suspensions stay listed <see cref="SuspensionRetentionDays"/> days, then leave the policy (point 77).</summary>
    public static ImmutableArray<HealthSuspension> Optimize(IEnumerable<HealthSuspension> suspensions, DateTimeOffset now) =>
        [.. suspensions.Where(s => s.UntilUtc > now - TimeSpan.FromDays(SuspensionRetentionDays))];

    // ---------------------------------------------------------------- validation (strict, French messages)

    /// <summary>Checks a policy as the editor saves it (ConvertTo-DomeniaHealthPolicy -Strict).</summary>
    public static HealthPolicy Validate(HealthPolicy policy)
    {
        ArgumentNullException.ThrowIfNull(policy);
        foreach (var t in Thresholds)
        {
            var value = policy.Thresholds.Get(t.Id);
            if (value < t.Minimum || value > t.Maximum)
            {
                throw Invalid(t.Name + FrenchText.Colon + "valeur attendue de " + FrenchText.Integer(t.Minimum) + " à " + FrenchText.Integer(t.Maximum) + ".");
            }
        }
        if (policy.Thresholds.DiskFreeAlert > policy.Thresholds.DiskFreeWarn)
        {
            throw Invalid("Le seuil disque critique doit être inférieur ou égal au seuil de surveillance.");
        }
        foreach (var id in policy.DisabledRules)
        {
            if (!IsKnownRule(id))
            {
                throw Invalid("Contrôle inconnu dans les règles désactivées.");
            }
        }
        if (policy.CustomRules.Length > MaxCustomRules)
        {
            throw Invalid("Règle personnalisée invalide (32 maximum, seuil selon la mesure).");
        }
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var rule in policy.CustomRules)
        {
            var max = rule.Measure == "UptimeDays" ? 3650 : 100;
            var valid = IsCustomId(rule.Id) && seen.Add(rule.Id) && rule.Name.Length is >= 1 and <= 100 && !rule.Name.Any(char.IsControl)
                && (rule.Measure == "Query" ? rule.Operator == "Matches" && HealthQueryRules.Valid(rule.Query)
                    : rule.Query is null && (rule.Measure is "DiskFree" or "UptimeDays" or "MemoryUsed") && (rule.Operator is "LessThan" or "GreaterThan"))
                && rule.Severity is "Warn" or "Alert" && !double.IsNaN(rule.Threshold) && !double.IsInfinity(rule.Threshold)
                && rule.Threshold >= 0 && rule.Threshold <= max;
            if (!valid)
            {
                throw Invalid("Règle personnalisée invalide (32 maximum, seuil selon la mesure).");
            }
        }
        if (policy.Suspensions.Length > MaxSuspensions)
        {
            throw Invalid(SuspensionMessage);
        }
        var suspended = new HashSet<string>(StringComparer.Ordinal);
        foreach (var s in policy.Suspensions)
        {
            var known = IsKnownRule(s.RuleId) || (IsCustomId(s.RuleId) && policy.CustomRules.Any(r => r.Id == s.RuleId));
            var reason = s.Reason.Trim();
            if (!known || reason.Length is < 3 or > 240 || reason.Any(char.IsControl) || !suspended.Add(s.RuleId) || s.UntilUtc.Year is < 2000 or > 9998)
            {
                throw Invalid(SuspensionMessage);
            }
        }
        return policy with { Suspensions = [.. policy.Suspensions.Select(s => s with { Reason = s.Reason.Trim(), UntilUtc = s.UntilUtc.ToUniversalTime() })] };
    }

    public const string SuspensionMessage = "Suspension invalide : contrôle unique, motif de 3 à 240 caractères et échéance UTC obligatoires (64 maximum).";

    public static bool IsCustomId(string id) => id.Length == 39 && id.StartsWith("custom.", StringComparison.Ordinal) && id[7..].All(c => c is (>= '0' and <= '9') or (>= 'a' and <= 'f'));

    public static DomeniaOperationException Invalid(string message) => new(InvalidCode, message);

    // ---------------------------------------------------------------- scopes and inheritance

    /// <summary>A scope of the domain: the domain itself (empty or the root) or an OU or container inside it.</summary>
    public static bool IsInDomain(string? scopeDn, string domainDn)
    {
        if (string.IsNullOrEmpty(scopeDn) || SameDn(scopeDn, domainDn))
        {
            return true;
        }
        try
        {
            return DistinguishedName.IsWithin(scopeDn, domainDn, subtree: true);
        }
        catch (FormatException)
        {
            return false;
        }
    }

    /// <summary>OUs from the domain down to <paramref name="scopeDn"/> (top first), the scope itself last.</summary>
    public static ImmutableArray<string> Chain(string? scopeDn, string domainDn)
    {
        var chain = new List<string>();
        var cursor = scopeDn;
        for (var depth = 0; !string.IsNullOrEmpty(cursor) && !SameDn(cursor, domainDn) && depth < 128; depth++)
        {
            chain.Insert(0, cursor);
            cursor = DistinguishedName.Parent(cursor);
        }
        return [.. chain];
    }

    /// <summary>
    /// Policy of <paramref name="scopeDn"/>: domain defaults, then each OU from the top; thresholds and rule states inherit one
    /// by one, custom alerts and suspensions as whole lists (Resolve-DomeniaHealthPolicy). <paramref name="skipExact"/> leaves the
    /// exception of the scope itself out (what it inherits).
    /// </summary>
    public static ResolvedHealthPolicy Resolve(HealthPolicyBook book, string? scopeDn, bool skipExact = false)
    {
        ArgumentNullException.ThrowIfNull(book);
        if (!IsInDomain(scopeDn, book.DomainDn))
        {
            throw Invalid("OU de politique hors du domaine.");
        }
        var scope = string.IsNullOrEmpty(scopeDn) || SameDn(scopeDn, book.DomainDn) ? "" : scopeDn;
        var thresholds = book.Default.Thresholds;
        var on = Catalog.ToDictionary(r => r.Id, r => !book.Default.DisabledRules.Contains(r.Id, StringComparer.Ordinal), StringComparer.Ordinal);
        var custom = book.Default.CustomRules;
        var suspensions = book.Default.Suspensions;
        var origins = new List<string>();
        var overridden = new SortedSet<string>(StringComparer.Ordinal);
        foreach (var dn in Chain(scope, book.DomainDn))
        {
            if (skipExact && SameDn(dn, scope))
            {
                continue;
            }
            var record = Find(book, dn);
            if (record is null)
            {
                continue;
            }
            origins.Add(record.ScopeDn);
            foreach (var (id, value) in record.Overrides.Thresholds)
            {
                thresholds = thresholds.With(id, value);
                overridden.Add(id);
            }
            foreach (var (id, value) in record.Overrides.RuleStates)
            {
                on[id] = value;
                overridden.Add(id);
            }
            if (record.Overrides.CustomRules is ImmutableArray<CustomHealthRule> rules)
            {
                custom = rules;
                overridden.Add("CustomRules");
            }
            if (record.Overrides.Suspensions is ImmutableArray<HealthSuspension> list)
            {
                suspensions = list;
                overridden.Add("Suspensions");
            }
        }
        var policy = new HealthPolicy(thresholds, [.. Catalog.Where(r => !on[r.Id]).Select(r => r.Id)], custom, suspensions);
        var local = scope.Length > 0 && !skipExact && Find(book, scope) is not null;
        return new ResolvedHealthPolicy(policy, scope, origins.Count > 0 ? origins[^1] : null, [.. origins], [.. overridden], local);
    }

    /// <summary>
    /// Saves a policy for one scope: the defaults for the domain, else only the differences with what the OU inherits, so later
    /// inherited changes stay inherited (Set-DomeniaHealthScopePolicy). Suspensions are compared after the same purge.
    /// </summary>
    public static HealthPolicyBook SetScopePolicy(HealthPolicyBook book, string? scopeDn, HealthPolicy policy, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(book);
        ArgumentNullException.ThrowIfNull(policy);
        var value = Validate(policy with { Suspensions = Optimize(policy.Suspensions, now) });
        var scope = string.IsNullOrEmpty(scopeDn) || SameDn(scopeDn, book.DomainDn) ? "" : scopeDn;
        if (scope.Length == 0)
        {
            return book with { Default = value };
        }
        if (!IsOu(scope) || !IsInDomain(scope, book.DomainDn))
        {
            throw Invalid("OU de politique invalide.");
        }
        var without = book with { Scopes = [.. book.Scopes.Where(r => !SameDn(r.ScopeDn, scope))] };
        var parent = Resolve(without, scope).Policy;
        var thresholds = ImmutableSortedDictionary.CreateBuilder<string, int>(StringComparer.Ordinal);
        foreach (var t in Thresholds)
        {
            if (value.Thresholds.Get(t.Id) != parent.Thresholds.Get(t.Id))
            {
                thresholds[t.Id] = value.Thresholds.Get(t.Id);
            }
        }
        var states = ImmutableSortedDictionary.CreateBuilder<string, bool>(StringComparer.Ordinal);
        foreach (var r in Catalog)
        {
            var mine = !value.DisabledRules.Contains(r.Id, StringComparer.Ordinal);
            var theirs = !parent.DisabledRules.Contains(r.Id, StringComparer.Ordinal);
            if (mine != theirs)
            {
                states[r.Id] = mine;
            }
        }
        ImmutableArray<CustomHealthRule>? custom = value.CustomRules.SequenceEqual(parent.CustomRules) ? null : value.CustomRules;
        var own = Optimize(value.Suspensions, now);
        var inherited = Optimize(parent.Suspensions, now);
        ImmutableArray<HealthSuspension>? suspensions = own.SequenceEqual(inherited) ? null : value.Suspensions;
        if (thresholds.Count == 0 && states.Count == 0 && custom is null && suspensions is null)
        {
            return without;
        }
        if (without.Scopes.Length >= MaxScopes)
        {
            throw Invalid("Exception d’OU invalide ou dupliquée (512 maximum).");
        }
        var record = new HealthScopeRecord(scope, new HealthOverrides(thresholds.ToImmutable(), states.ToImmutable(), custom, suspensions));
        return without with { Scopes = without.Scopes.Add(record) };
    }

    /// <summary>« Revenir aux règles héritées »: removes the exception of one OU.</summary>
    public static HealthPolicyBook RemoveScope(HealthPolicyBook book, string scopeDn)
    {
        ArgumentNullException.ThrowIfNull(book);
        if (string.IsNullOrEmpty(scopeDn) || SameDn(scopeDn, book.DomainDn))
        {
            throw Invalid("La politique par défaut ne peut pas être supprimée.");
        }
        return book with { Scopes = [.. book.Scopes.Where(r => !SameDn(r.ScopeDn, scopeDn))] };
    }

    /// <summary>Where each effective setting of one scope comes from (Get-DomeniaHealthPolicyOrigins).</summary>
    public static ImmutableArray<HealthOriginRow> Origins(HealthPolicyBook book, string? scopeDn, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(book);
        var scope = string.IsNullOrEmpty(scopeDn) || SameDn(scopeDn, book.DomainDn) ? "" : scopeDn;
        var policy = Resolve(book, scope).Policy;
        var source = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var dn in Chain(scope, book.DomainDn))
        {
            var record = Find(book, dn);
            if (record is null)
            {
                continue;
            }
            foreach (var id in record.Overrides.Thresholds.Keys)
            {
                source["Threshold:" + id] = record.ScopeDn;
            }
            foreach (var id in record.Overrides.RuleStates.Keys)
            {
                source["Rule:" + id] = record.ScopeDn;
            }
            if (record.Overrides.CustomRules is not null)
            {
                source["CustomRules"] = record.ScopeDn;
            }
            if (record.Overrides.Suspensions is not null)
            {
                source["Suspensions"] = record.ScopeDn;
            }
        }
        HealthOriginRow Row(string kind, string id, string name, string value, string key)
        {
            var from = source.GetValueOrDefault(key);
            var local = from is not null && scope.Length > 0 && SameDn(from, scope);
            var origin = local ? "Exception locale" : from is not null ? "Hérité de " + ScopeLabel(from, book.DomainDn) : "Règles par défaut du domaine";
            return new HealthOriginRow(kind, id, name, value, from, local, origin);
        }
        var rows = new List<HealthOriginRow>();
        foreach (var t in Thresholds)
        {
            rows.Add(Row("Seuil", t.Id, t.Name, FrenchText.Integer(policy.Thresholds.Get(t.Id)), "Threshold:" + t.Id));
        }
        foreach (var r in Catalog)
        {
            rows.Add(Row("Contrôle", r.Id, r.Name, IsEnabled(policy, r.Id, now, ignoreSuspension: true) ? "Activé" : "Désactivé", "Rule:" + r.Id));
        }
        rows.Add(Row("Liste", "CustomRules", "Alertes personnalisées", FrenchText.Count(policy.CustomRules.Length, "alerte", "alertes"), "CustomRules"));
        var active = policy.Suspensions.Count(s => s.UntilUtc > now);
        rows.Add(Row("Liste", "Suspensions", "Suspensions", FrenchText.Integer(active) + " active" + (active > 1 ? "s" : "") + " sur " + FrenchText.Integer(policy.Suspensions.Length), "Suspensions"));
        return [.. rows];
    }

    /// <summary>Every local exception of the domain with its differences against what it would inherit.</summary>
    public static ImmutableArray<HealthExceptionRow> Exceptions(HealthPolicyBook book, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(book);
        var rows = new List<HealthExceptionRow>();
        foreach (var record in book.Scopes.OrderBy(r => Depth(r.ScopeDn)).ThenBy(r => r.ScopeDn, StringComparer.Ordinal))
        {
            var inherited = Resolve(book, record.ScopeDn, skipExact: true).Policy;
            var changes = new List<string>();
            foreach (var (id, value) in record.Overrides.Thresholds)
            {
                var name = Thresholds.First(t => t.Id == id).Name;
                var old = inherited.Thresholds.Get(id);
                changes.Add(name + FrenchText.Colon + FrenchText.Integer(value) + (old == value ? " (identique à la valeur héritée)" : " (hérité" + FrenchText.Colon + FrenchText.Integer(old) + ")"));
            }
            foreach (var (id, value) in record.Overrides.RuleStates)
            {
                changes.Add(RuleName(id) + FrenchText.Colon + (value ? "activé" : "désactivé"));
            }
            if (record.Overrides.CustomRules is ImmutableArray<CustomHealthRule> custom)
            {
                changes.Add("Alertes personnalisées propres" + FrenchText.Colon + FrenchText.Integer(custom.Length) + " (remplacent la liste héritée)");
            }
            if (record.Overrides.Suspensions is ImmutableArray<HealthSuspension> list)
            {
                changes.Add("Suspensions propres" + FrenchText.Colon + FrenchText.Integer(list.Length) + " dont " + FrenchText.Integer(list.Count(s => s.UntilUtc > now)) + " active(s)");
            }
            rows.Add(new HealthExceptionRow(record.ScopeDn, ScopeLabel(record.ScopeDn, book.DomainDn), string.Join(" · ", changes), changes.Count));
        }
        return [.. rows];
    }

    /// <summary>Scopes offered by the editor: domain defaults, ancestors of the current OU, the current OU, other exceptions.</summary>
    public static ImmutableArray<HealthEditorScope> EditorScopes(HealthPolicyBook book, string? currentDn)
    {
        ArgumentNullException.ThrowIfNull(book);
        var items = new List<HealthEditorScope> { new("Règles par défaut du domaine", null, "domain") };
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var dn in Chain(currentDn, book.DomainDn).Where(IsOu))
        {
            if (!seen.Add(dn))
            {
                continue;
            }
            var current = currentDn is not null && SameDn(dn, currentDn);
            items.Add(new HealthEditorScope((current ? "Cette OU et ses sous-OU" : "OU parente") + FrenchText.Colon + ScopeLabel(dn, book.DomainDn), dn, current ? "current" : "ancestor"));
        }
        foreach (var record in book.Scopes.OrderBy(r => r.ScopeDn, StringComparer.Ordinal))
        {
            if (seen.Add(record.ScopeDn))
            {
                items.Add(new HealthEditorScope("Autre exception" + FrenchText.Colon + ScopeLabel(record.ScopeDn, book.DomainDn), record.ScopeDn, "exception"));
            }
        }
        return [.. items];
    }

    /// <summary>Short label of a scope: its path without the domain suffix, or the domain defaults.</summary>
    public static string ScopeLabel(string? scopeDn, string domainDn)
    {
        if (string.IsNullOrEmpty(scopeDn) || SameDn(scopeDn, domainDn))
        {
            return "Règles par défaut du domaine";
        }
        var suffix = "," + domainDn;
        return scopeDn.EndsWith(suffix, StringComparison.OrdinalIgnoreCase) ? scopeDn[..^suffix.Length] : scopeDn;
    }

    /// <summary>SHA-256 of the canonical form of the policies of a view, keeping only the active suspensions (point 78).</summary>
    public static string Fingerprint(IEnumerable<(string ScopeDn, HealthPolicy Policy)> policies, DateTimeOffset now)
    {
        var tokens = new List<string>();
        foreach (var (scopeDn, policy) in policies)
        {
            var stable = new
            {
                scopeDn = scopeDn.ToLowerInvariant(),
                thresholds = policy.Thresholds,
                disabledRules = policy.DisabledRules.Order(StringComparer.Ordinal).ToArray(),
                customRules = policy.CustomRules.OrderBy(r => r.Id, StringComparer.Ordinal).ToArray(),
                activeSuspensions = policy.Suspensions.Where(s => s.UntilUtc > now).OrderBy(s => s.RuleId, StringComparer.Ordinal)
                    .Select(s => new { s.RuleId, s.Reason, untilUtc = s.UntilUtc.UtcDateTime.ToString("o", CultureInfo.InvariantCulture) }).ToArray(),
            };
            tokens.Add(JsonSerializer.Serialize(stable));
        }
        return FleetFingerprint.Of(tokens);
    }

    internal static HealthScopeRecord? Find(HealthPolicyBook book, string dn) => book.Scopes.FirstOrDefault(r => SameDn(r.ScopeDn, dn));

    internal static bool IsOu(string dn) => dn.StartsWith("OU=", StringComparison.OrdinalIgnoreCase);

    private static int Depth(string dn)
    {
        try
        {
            return DistinguishedName.Parse(dn).Length;
        }
        catch (FormatException)
        {
            return int.MaxValue;
        }
    }

    internal static bool SameDn(string? left, string? right)
    {
        if (left is null || right is null)
        {
            return false;
        }
        try
        {
            return DistinguishedName.AreEqual(left, right);
        }
        catch (FormatException)
        {
            return string.Equals(left, right, StringComparison.OrdinalIgnoreCase);
        }
    }
}

/// <summary>SHA-256 fingerprints of sorted value lists (Get-DomeniaHealthFingerprint).</summary>
public static class FleetFingerprint
{
    public static string Of(IEnumerable<string> values)
    {
        ArgumentNullException.ThrowIfNull(values);
        var sorted = values.ToArray();
        Array.Sort(sorted, StringComparer.Ordinal);
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(string.Join("\n", sorted))));
    }
}

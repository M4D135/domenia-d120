using System.Collections.Frozen;
using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Domenia.Core.Poste;

/// <summary>
/// The health policy of one workstation (Domenia 1 Resolve-DomeniaHealthPolicy for the OU of the computer, PST-092,
/// PST-093): the domain book of the health rules shared with the Accueil (preference « accueil.health.&lt;SHA-256 of the
/// root&gt; », written by its rules editor), read here only, tolerantly: a damaged part falls back to the defaults, never
/// fatal. The defaults apply, then every ancestor OU of the computer from the top down (thresholds and rule states one by one,
/// custom alerts and suspensions as whole lists), the nearest OU last. Pure: the document, the instant and the zone are given.
/// </summary>
public static class PosteHealthPolicies
{
    /// <summary>Preference key of the shared book of a domain (same key as the Accueil).</summary>
    public static string PreferenceKey(string rootDn)
    {
        ArgumentNullException.ThrowIfNull(rootDn);
        string canonical;
        try
        {
            canonical = DistinguishedName.Format(DistinguishedName.Parse(rootDn)).ToUpperInvariant();
        }
        catch (FormatException)
        {
            canonical = rootDn.ToUpperInvariant();
        }
        return "accueil.health." + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(canonical)));
    }

    /// <summary>The policy of the computer <paramref name="computerDn"/>; the defaults of Domenia 1 without a readable book.</summary>
    public static PosteHealthPolicy Resolve(JsonElement? book, string rootDn, string computerDn, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(rootDn);
        ArgumentNullException.ThrowIfNull(computerDn);
        ArgumentNullException.ThrowIfNull(zone);
        var defaults = PosteHealthPolicy.Default with { EvaluatedAt = now };
        if (book is not JsonElement value || value.ValueKind != JsonValueKind.Object)
        {
            return defaults;
        }
        if (value.TryGetProperty("domainDn", out var saved) && saved.ValueKind == JsonValueKind.String && !SameDn(saved.GetString() ?? "", rootDn))
        {
            return defaults with { Origin = "Seuils livrés avec Domenia 1 : les règles enregistrées appartiennent à un autre domaine" };
        }
        var state = new Builder();
        if (value.TryGetProperty("default", out var root) && root.ValueKind == JsonValueKind.Object)
        {
            state.Apply(root, whole: true, zone);
        }
        var origin = "Règles par défaut du domaine (règles de santé de l’Accueil)";
        if (value.TryGetProperty("scopes", out var scopes) && scopes.ValueKind == JsonValueKind.Array)
        {
            var records = new Dictionary<string, JsonElement>(StringComparer.OrdinalIgnoreCase);
            foreach (var record in scopes.EnumerateArray().Take(512))
            {
                if (record.ValueKind == JsonValueKind.Object && record.TryGetProperty("scopeDn", out var dn) && dn.ValueKind == JsonValueKind.String
                    && record.TryGetProperty("overrides", out var overrides) && overrides.ValueKind == JsonValueKind.Object)
                {
                    records[Canonical(dn.GetString() ?? "")] = overrides;
                }
            }
            var parent = DistinguishedName.Parent(computerDn);
            var nearestOu = parent;
            var chain = new List<string>();
            while (parent is not null && !SameDn(parent, rootDn) && chain.Count < 128)
            {
                chain.Add(parent);
                parent = DistinguishedName.Parent(parent);
            }
            string? source = null;
            for (var i = chain.Count - 1; i >= 0; i--)
            {
                if (records.TryGetValue(Canonical(chain[i]), out var overrides))
                {
                    state.Apply(overrides, whole: false, zone);
                    source = chain[i];
                }
            }
            if (source is not null)
            {
                var label = Label(source, rootDn);
                origin = nearestOu is not null && SameDn(source, nearestOu)
                    ? "Règles de l’OU " + label + " (exception locale)"
                    : "Règles héritées de l’OU " + label;
            }
        }
        return state.Build(origin, now);
    }

    private static string Label(string dn, string rootDn)
    {
        try
        {
            var names = DistinguishedName.Parse(dn);
            var root = DistinguishedName.Parse(rootDn);
            return string.Join(" › ", names.Take(Math.Max(1, names.Length - root.Length)).Reverse().Select(n => n.Value));
        }
        catch (FormatException)
        {
            return dn;
        }
    }

    private static string Canonical(string dn)
    {
        try
        {
            return DistinguishedName.Format(DistinguishedName.Parse(dn)).ToUpperInvariant();
        }
        catch (FormatException)
        {
            return dn.Trim().ToUpperInvariant();
        }
    }

    private static bool SameDn(string left, string right)
    {
        try
        {
            return DistinguishedName.AreEqual(left, right);
        }
        catch (FormatException)
        {
            return false;
        }
    }

    /// <summary>Policy being resolved: thresholds and states one by one, custom alerts and suspensions as whole lists.</summary>
    private sealed class Builder
    {
        private readonly Dictionary<string, int> thresholds = new(StringComparer.Ordinal)
        {
            ["staleDays"] = PosteHealthPolicy.Default.StaleDays,
            ["passwordDays"] = PosteHealthPolicy.Default.PasswordDays,
            ["uptimeDays"] = PosteHealthPolicy.Default.UptimeDays,
            ["diskFreeAlert"] = PosteHealthPolicy.Default.DiskFreeAlert,
            ["diskFreeWarn"] = PosteHealthPolicy.Default.DiskFreeWarn,
            ["memoryUsedWarn"] = PosteHealthPolicy.Default.MemoryUsedWarn,
            ["batteryWarn"] = PosteHealthPolicy.Default.BatteryWarn,
            ["hotfixDays"] = PosteHealthPolicy.Default.HotfixDays,
        };

        private readonly Dictionary<string, bool> states = new(StringComparer.Ordinal);
        private ImmutableArray<PosteCustomRule> custom = [];
        private int queryRules;
        private ImmutableArray<HealthSuspension> suspensions = [];

        private static (int Min, int Max) Bounds(string id) => id switch
        {
            "diskFreeAlert" or "diskFreeWarn" or "memoryUsedWarn" or "batteryWarn" => (1, 99),
            _ => (1, 3650),
        };

        public void Apply(JsonElement policy, bool whole, TimeZoneInfo zone)
        {
            if (policy.TryGetProperty("thresholds", out var t) && t.ValueKind == JsonValueKind.Object)
            {
                foreach (var id in thresholds.Keys.ToList())
                {
                    var (min, max) = Bounds(id);
                    if (t.TryGetProperty(id, out var n) && n.ValueKind == JsonValueKind.Number && n.TryGetInt32(out var v) && v >= min && v <= max)
                    {
                        thresholds[id] = v;
                    }
                }
            }
            if (whole && policy.TryGetProperty("disabledRules", out var disabled) && disabled.ValueKind == JsonValueKind.Array)
            {
                foreach (var id in disabled.EnumerateArray().Where(e => e.ValueKind == JsonValueKind.String).Select(e => e.GetString()!))
                {
                    if (PosteHealthPolicy.Rules.Any(r => r.Id == id))
                    {
                        states[id] = false;
                    }
                }
            }
            if (!whole && policy.TryGetProperty("ruleStates", out var ruleStates) && ruleStates.ValueKind == JsonValueKind.Object)
            {
                foreach (var rule in PosteHealthPolicy.Rules)
                {
                    if (ruleStates.TryGetProperty(rule.Id, out var b) && b.ValueKind is JsonValueKind.True or JsonValueKind.False)
                    {
                        states[rule.Id] = b.GetBoolean();
                    }
                }
            }
            if (policy.TryGetProperty("customRules", out var c) && c.ValueKind == JsonValueKind.Array)
            {
                var list = ImmutableArray.CreateBuilder<PosteCustomRule>();
                var queries = 0;
                foreach (var r in c.EnumerateArray().Take(32))
                {
                    if (r.ValueKind != JsonValueKind.Object)
                    {
                        continue;
                    }
                    var measure = Text(r, "measure");
                    if (measure == "Query")
                    {
                        queries++;
                        continue;
                    }
                    var id = Text(r, "id");
                    var name = Text(r, "name").Trim();
                    var op = Text(r, "operator");
                    var severity = Text(r, "severity") is "Alert" ? AttentionLevel.Alert : AttentionLevel.Warn;
                    var enabled = !r.TryGetProperty("enabled", out var e) || e.ValueKind != JsonValueKind.False;
                    if (!id.StartsWith("custom.", StringComparison.Ordinal) || name.Length is 0 or > 100 || measure is not ("DiskFree" or "UptimeDays" or "MemoryUsed")
                        || op is not ("LessThan" or "GreaterThan") || !r.TryGetProperty("threshold", out var th) || th.ValueKind != JsonValueKind.Number || !th.TryGetDouble(out var threshold)
                        || double.IsNaN(threshold) || threshold < 0 || threshold > (measure == "UptimeDays" ? 3650 : 100))
                    {
                        continue;
                    }
                    list.Add(new PosteCustomRule(id, name, measure, op, threshold, severity, enabled));
                }
                custom = list.ToImmutable();
                queryRules = queries;
            }
            if (policy.TryGetProperty("suspensions", out var s) && s.ValueKind == JsonValueKind.Array)
            {
                var list = ImmutableArray.CreateBuilder<HealthSuspension>();
                foreach (var x in s.EnumerateArray().Take(64))
                {
                    var rule = x.ValueKind == JsonValueKind.Object ? Text(x, "ruleId") : "";
                    var until = Text(x, "untilUtc");
                    if (rule.Length == 0 || !DateTimeOffset.TryParse(until, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var at))
                    {
                        continue;
                    }
                    var reason = Text(x, "reason").Trim();
                    var local = TimeZoneInfo.ConvertTime(at, zone);
                    var text = "jusqu’au " + local.ToString("dd/MM/yyyy HH:mm", CultureInfo.InvariantCulture) + (reason.Length > 0 ? FrenchText.Colon + reason : "");
                    list.Add(new HealthSuspension(rule, reason, at, text));
                }
                suspensions = list.ToImmutable();
            }
        }

        private static string Text(JsonElement e, string name) =>
            e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";

        public PosteHealthPolicy Build(string origin, DateTimeOffset now)
        {
            var alert = thresholds["diskFreeAlert"];
            var warn = thresholds["diskFreeWarn"];
            if (alert > warn)
            {
                alert = PosteHealthPolicy.Default.DiskFreeAlert;
                warn = PosteHealthPolicy.Default.DiskFreeWarn;
            }
            var disabled = states.Where(s => !s.Value).Select(s => s.Key).ToFrozenSet(StringComparer.Ordinal);
            return new PosteHealthPolicy(thresholds["staleDays"], thresholds["passwordDays"], thresholds["uptimeDays"], alert, warn, thresholds["memoryUsedWarn"],
                thresholds["batteryWarn"], thresholds["hotfixDays"], disabled, origin)
            {
                CustomRules = custom,
                QueryRules = queryRules,
                Suspensions = suspensions,
                EvaluatedAt = now,
            };
        }
    }
}

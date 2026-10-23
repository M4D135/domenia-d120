using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;

namespace Domenia.Core.Accueil;

/// <summary>
/// JSON forms of the health policies: the book kept in the local preferences (read tolerantly: a damaged part is left out,
/// never fatal), and the policy sent by the rules editor (read strictly: every error is refused with a French message).
/// </summary>
public static class HealthPolicyJson
{
    private static readonly string[] PolicyNames = ["thresholds", "disabledRules", "customRules", "suspensions"];
    private static readonly string[] CustomNames = ["id", "name", "measure", "operator", "threshold", "severity", "enabled", "query"];
    private static readonly string[] SuspensionNames = ["ruleId", "reason", "untilUtc", "hours", "endNow"];

    /// <summary>Preference value of a book (version 1).</summary>
    public static JsonElement Write(HealthPolicyBook book)
    {
        ArgumentNullException.ThrowIfNull(book);
        var value = new Dictionary<string, object?>
        {
            ["version"] = 1,
            ["domainDn"] = book.DomainDn,
            ["default"] = PolicyValue(book.Default),
            ["scopes"] = book.Scopes.Select(s => new Dictionary<string, object?>
            {
                ["scopeDn"] = s.ScopeDn,
                ["overrides"] = new Dictionary<string, object?>
                {
                    ["thresholds"] = s.Overrides.Thresholds.ToDictionary(p => Camel(p.Key), p => p.Value),
                    ["ruleStates"] = s.Overrides.RuleStates.ToDictionary(p => p.Key, p => p.Value),
                    ["customRules"] = s.Overrides.CustomRules is ImmutableArray<CustomHealthRule> c ? c.Select(CustomValue).ToList() : null,
                    ["suspensions"] = s.Overrides.Suspensions is ImmutableArray<HealthSuspension> l ? l.Select(SuspensionValue).ToList() : null,
                },
            }).ToList(),
        };
        return JsonSerializer.SerializeToElement(value);
    }

    /// <summary>Policy as the page reads it (same names as the editor sends back).</summary>
    public static Dictionary<string, object?> PolicyValue(HealthPolicy policy)
    {
        ArgumentNullException.ThrowIfNull(policy);
        return new Dictionary<string, object?>
        {
            ["thresholds"] = HealthRules.Thresholds.ToDictionary(t => Camel(t.Id), t => policy.Thresholds.Get(t.Id)),
            ["disabledRules"] = policy.DisabledRules.ToList(),
            ["customRules"] = policy.CustomRules.Select(CustomValue).ToList(),
            ["suspensions"] = policy.Suspensions.Select(SuspensionValue).ToList(),
        };
    }

    /// <summary>
    /// Book read back from the preferences, tolerantly (ConvertTo-DomeniaHealthPolicyBook without -Strict): invalid values fall
    /// back to the defaults, invalid exceptions are left out. A book of another domain is refused.
    /// </summary>
    public static HealthPolicyBook ReadBook(JsonElement value, string domainDn, DateTimeOffset now)
    {
        if (value.ValueKind != JsonValueKind.Object)
        {
            throw new JsonException("Health book is not an object.");
        }
        if (value.TryGetProperty("domainDn", out var saved) && saved.ValueKind == JsonValueKind.String && !HealthRules.SameDn(saved.GetString(), domainDn))
        {
            throw new InvalidOperationException("Health book of another domain.");
        }
        var defaults = value.TryGetProperty("default", out var d) ? Tolerant(d, now) : HealthPolicy.Default;
        var scopes = new List<HealthScopeRecord>();
        if (value.TryGetProperty("scopes", out var list) && list.ValueKind == JsonValueKind.Array)
        {
            foreach (var record in list.EnumerateArray())
            {
                if (scopes.Count >= HealthRules.MaxScopes || record.ValueKind != JsonValueKind.Object
                    || !record.TryGetProperty("scopeDn", out var dnValue) || dnValue.ValueKind != JsonValueKind.String)
                {
                    continue;
                }
                var dn = dnValue.GetString()!.Trim();
                if (!HealthRules.IsOu(dn) || !HealthRules.IsInDomain(dn, domainDn) || scopes.Any(s => HealthRules.SameDn(s.ScopeDn, dn)))
                {
                    continue;
                }
                var overrides = record.TryGetProperty("overrides", out var o) && o.ValueKind == JsonValueKind.Object ? o : default;
                var thresholds = ImmutableSortedDictionary.CreateBuilder<string, int>(StringComparer.Ordinal);
                if (overrides.ValueKind == JsonValueKind.Object && overrides.TryGetProperty("thresholds", out var t) && t.ValueKind == JsonValueKind.Object)
                {
                    foreach (var def in HealthRules.Thresholds)
                    {
                        if (t.TryGetProperty(Camel(def.Id), out var n) && n.TryGetInt32(out var v) && v >= def.Minimum && v <= def.Maximum)
                        {
                            thresholds[def.Id] = v;
                        }
                    }
                }
                var states = ImmutableSortedDictionary.CreateBuilder<string, bool>(StringComparer.Ordinal);
                if (overrides.ValueKind == JsonValueKind.Object && overrides.TryGetProperty("ruleStates", out var r) && r.ValueKind == JsonValueKind.Object)
                {
                    foreach (var rule in HealthRules.Catalog)
                    {
                        if (r.TryGetProperty(rule.Id, out var b) && b.ValueKind is JsonValueKind.True or JsonValueKind.False)
                        {
                            states[rule.Id] = b.GetBoolean();
                        }
                    }
                }
                ImmutableArray<CustomHealthRule>? custom = null;
                if (overrides.ValueKind == JsonValueKind.Object && overrides.TryGetProperty("customRules", out var c) && c.ValueKind == JsonValueKind.Array)
                {
                    custom = [.. c.EnumerateArray().Select(TolerantCustom).OfType<CustomHealthRule>().Take(HealthRules.MaxCustomRules)];
                }
                ImmutableArray<HealthSuspension>? suspensions = null;
                if (overrides.ValueKind == JsonValueKind.Object && overrides.TryGetProperty("suspensions", out var s) && s.ValueKind == JsonValueKind.Array)
                {
                    suspensions = [.. s.EnumerateArray().Select(TolerantSuspension).OfType<HealthSuspension>().Take(HealthRules.MaxSuspensions)];
                }
                scopes.Add(new HealthScopeRecord(dn, new HealthOverrides(thresholds.ToImmutable(), states.ToImmutable(), custom, suspensions)));
            }
        }
        return new HealthPolicyBook(domainDn, defaults, [.. scopes]);
    }

    /// <summary>
    /// Policy sent by the editor, read strictly. Thresholds absent keep <paramref name="current"/>; a new custom alert gets an
    /// identifier; a new suspension gives its duration in hours (1, 24, 168 or 720), « endNow » ends one now and keeps its trace.
    /// </summary>
    public static HealthPolicy ReadPolicy(JsonElement value, HealthPolicy current, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(current);
        if (value.ValueKind != JsonValueKind.Object)
        {
            throw HealthRules.Invalid("Règles de santé illisibles : un objet est attendu.");
        }
        foreach (var property in value.EnumerateObject())
        {
            if (!PolicyNames.Contains(property.Name, StringComparer.Ordinal))
            {
                throw HealthRules.Invalid("Règles de santé illisibles : propriété non admise.");
            }
        }
        var thresholds = current.Thresholds;
        if (value.TryGetProperty("thresholds", out var t))
        {
            if (t.ValueKind != JsonValueKind.Object)
            {
                throw HealthRules.Invalid("Seuils illisibles : un objet est attendu.");
            }
            foreach (var property in t.EnumerateObject())
            {
                var def = HealthRules.Thresholds.FirstOrDefault(d => Camel(d.Id) == property.Name) ?? throw HealthRules.Invalid("Seuil inconnu dans les règles de santé.");
                if (!property.Value.TryGetInt32(out var n) || n < def.Minimum || n > def.Maximum)
                {
                    throw HealthRules.Invalid(def.Name + FrenchText.Colon + "valeur attendue de " + FrenchText.Integer(def.Minimum) + " à " + FrenchText.Integer(def.Maximum) + ".");
                }
                thresholds = thresholds.With(def.Id, n);
            }
        }
        var disabled = current.DisabledRules;
        if (value.TryGetProperty("disabledRules", out var dr))
        {
            if (dr.ValueKind != JsonValueKind.Array || dr.EnumerateArray().Any(x => x.ValueKind != JsonValueKind.String || !HealthRules.IsKnownRule(x.GetString()!)))
            {
                throw HealthRules.Invalid("Contrôle inconnu dans les règles désactivées.");
            }
            disabled = [.. dr.EnumerateArray().Select(x => x.GetString()!).Distinct(StringComparer.Ordinal)];
        }
        var custom = current.CustomRules;
        if (value.TryGetProperty("customRules", out var cr))
        {
            if (cr.ValueKind != JsonValueKind.Array)
            {
                throw HealthRules.Invalid("Alertes personnalisées illisibles : une liste est attendue.");
            }
            custom = [.. cr.EnumerateArray().Select(StrictCustom)];
        }
        var suspensions = current.Suspensions;
        if (value.TryGetProperty("suspensions", out var sp))
        {
            if (sp.ValueKind != JsonValueKind.Array)
            {
                throw HealthRules.Invalid(HealthRules.SuspensionMessage);
            }
            suspensions = [.. sp.EnumerateArray().Select(x => StrictSuspension(x, now))];
        }
        // A suspension of a custom alert removed from the list leaves with it.
        suspensions = [.. suspensions.Where(s => !HealthRules.IsCustomId(s.RuleId) || custom.Any(c => c.Id == s.RuleId))];
        return HealthRules.Validate(new HealthPolicy(thresholds, disabled, custom, suspensions));
    }

    private static CustomHealthRule StrictCustom(JsonElement x)
    {
        if (x.ValueKind != JsonValueKind.Object || x.EnumerateObject().Any(p => !CustomNames.Contains(p.Name, StringComparer.Ordinal)))
        {
            throw HealthRules.Invalid("Règle personnalisée invalide (32 maximum, seuil selon la mesure).");
        }
        string Text(string name) => x.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString()! : "";
        var id = Text("id");
        if (id.Length == 0)
        {
            id = "custom." + Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16));
        }
        var threshold = x.TryGetProperty("threshold", out var th) && th.ValueKind == JsonValueKind.Number ? th.GetDouble() : double.NaN;
        var enabled = !x.TryGetProperty("enabled", out var en) || en.ValueKind != JsonValueKind.False;
        if (x.TryGetProperty("enabled", out var check) && check.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
        {
            throw HealthRules.Invalid("Activation de règle personnalisée invalide.");
        }
        return new CustomHealthRule(id, Text("name").Trim(), Text("measure"), Text("operator"), threshold, Text("severity").Length > 0 ? Text("severity") : "Warn", enabled)
        { Query = x.TryGetProperty("query", out var q) && q.ValueKind != JsonValueKind.Null ? HealthQueryRules.Read(q) : null };
    }

    private static HealthSuspension StrictSuspension(JsonElement x, DateTimeOffset now)
    {
        if (x.ValueKind != JsonValueKind.Object || x.EnumerateObject().Any(p => !SuspensionNames.Contains(p.Name, StringComparer.Ordinal)))
        {
            throw HealthRules.Invalid(HealthRules.SuspensionMessage);
        }
        var ruleId = x.TryGetProperty("ruleId", out var r) && r.ValueKind == JsonValueKind.String ? r.GetString()! : "";
        var reason = x.TryGetProperty("reason", out var re) && re.ValueKind == JsonValueKind.String ? re.GetString()! : "";
        DateTimeOffset until;
        if (x.TryGetProperty("hours", out var h))
        {
            if (!h.TryGetInt32(out var hours) || !HealthRules.SuspensionHours.Contains(hours))
            {
                throw HealthRules.Invalid("Durée de suspension invalide : 1 h, 24 h, 7 j ou 30 j.");
            }
            until = now + TimeSpan.FromHours(hours);
        }
        else if (x.TryGetProperty("untilUtc", out var u) && u.ValueKind == JsonValueKind.String && u.GetString()!.EndsWith('Z')
            && DateTimeOffset.TryParse(u.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var parsed))
        {
            until = parsed;
        }
        else
        {
            throw HealthRules.Invalid(HealthRules.SuspensionMessage);
        }
        if (x.TryGetProperty("endNow", out var e) && e.ValueKind == JsonValueKind.True && until > now)
        {
            // « Réactiver maintenant »: the suspension ends now and its reason stays listed (point 77).
            until = now;
        }
        return new HealthSuspension(ruleId, reason, until);
    }

    private static HealthPolicy Tolerant(JsonElement value, DateTimeOffset now)
    {
        if (value.ValueKind != JsonValueKind.Object)
        {
            return HealthPolicy.Default;
        }
        var thresholds = HealthThresholds.Default;
        if (value.TryGetProperty("thresholds", out var t) && t.ValueKind == JsonValueKind.Object)
        {
            foreach (var def in HealthRules.Thresholds)
            {
                if (t.TryGetProperty(Camel(def.Id), out var n) && n.TryGetInt32(out var v) && v >= def.Minimum && v <= def.Maximum)
                {
                    thresholds = thresholds.With(def.Id, v);
                }
            }
            if (thresholds.DiskFreeAlert > thresholds.DiskFreeWarn)
            {
                thresholds = thresholds with { DiskFreeAlert = 10, DiskFreeWarn = 20 };
            }
        }
        var disabled = value.TryGetProperty("disabledRules", out var d) && d.ValueKind == JsonValueKind.Array
            ? d.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String && HealthRules.IsKnownRule(x.GetString()!)).Select(x => x.GetString()!).Distinct(StringComparer.Ordinal).ToImmutableArray()
            : [];
        var custom = value.TryGetProperty("customRules", out var c) && c.ValueKind == JsonValueKind.Array
            ? c.EnumerateArray().Select(TolerantCustom).OfType<CustomHealthRule>().Take(HealthRules.MaxCustomRules).ToImmutableArray()
            : [];
        var suspensions = value.TryGetProperty("suspensions", out var s) && s.ValueKind == JsonValueKind.Array
            ? s.EnumerateArray().Select(TolerantSuspension).OfType<HealthSuspension>().Take(HealthRules.MaxSuspensions).ToImmutableArray()
            : [];
        return new HealthPolicy(thresholds, disabled, custom, HealthRules.Optimize(suspensions, now));
    }

    private static CustomHealthRule? TolerantCustom(JsonElement x)
    {
        try
        {
            var rule = StrictCustom(x);
            return HealthRules.Validate(new HealthPolicy(HealthThresholds.Default, [], [rule], [])).CustomRules[0];
        }
        catch (DomeniaOperationException)
        {
            // A damaged frozen query must stay unknown, never disappear from the health denominator silently.
            if (x.ValueKind == JsonValueKind.Object && x.TryGetProperty("measure", out var measure) && measure.ValueKind == JsonValueKind.String && measure.GetString() == "Query")
            {
                var id = x.TryGetProperty("id", out var storedId) && storedId.ValueKind == JsonValueKind.String ? storedId.GetString()! : "";
                if (!HealthRules.IsCustomId(id)) { id = "custom." + Convert.ToHexStringLower(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(x.GetRawText())))[..32]; }
                var enabled = !x.TryGetProperty("enabled", out var on) || on.ValueKind != JsonValueKind.False;
                return new CustomHealthRule(id, "Référence de requête illisible — à rétablir", "Query", "Matches", 0, "Warn", enabled)
                { Query = new HealthQueryBinding("", 0, "", "") { Problem = "Référence ou empreinte illisible : résultat inconnu, aucune collecte. Retirez ou recréez cette alerte." } };
            }
            return null;
        }
    }

    private static HealthSuspension? TolerantSuspension(JsonElement x)
    {
        try
        {
            var s = StrictSuspension(x, DateTimeOffset.MinValue);
            var reason = s.Reason.Trim();
            return reason.Length is >= 3 and <= 240 && !reason.Any(char.IsControl) ? s with { Reason = reason } : null;
        }
        catch (DomeniaOperationException)
        {
            return null;
        }
    }

    private static Dictionary<string, object?> CustomValue(CustomHealthRule r) => new()
    {
        ["id"] = r.Id,
        ["name"] = r.Name,
        ["measure"] = r.Measure,
        ["operator"] = r.Operator,
        ["threshold"] = r.Threshold,
        ["severity"] = r.Severity,
        ["enabled"] = r.Enabled,
        ["query"] = HealthQueryRules.Write(r.Query),
    };

    private static Dictionary<string, object?> SuspensionValue(HealthSuspension s) => new()
    {
        ["ruleId"] = s.RuleId,
        ["reason"] = s.Reason,
        ["untilUtc"] = s.UntilUtc.UtcDateTime.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", CultureInfo.InvariantCulture),
    };

    /// <summary>« StaleDays » → « staleDays ».</summary>
    public static string Camel(string id) => char.ToLowerInvariant(id[0]) + id[1..];
}

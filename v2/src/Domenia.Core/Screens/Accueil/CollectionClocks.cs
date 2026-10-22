using System.Collections.Immutable;
using System.Globalization;

namespace Domenia.Core.Accueil;

/// <summary>The three explicit collections of an OU and the clock each one owns (Domenia 1, Get-DomeniaCollectionFamilies).</summary>
public enum CollectionFamily
{
    Directory,
    Presence,
    Inventory,
}

public enum CollectionStatus
{
    Success,
    Partial,
    Error,
    Cancelled,
}

/// <summary>
/// One finished OU collection (Domenia.CollectionRun/1): only a run that really started a collection is recorded; a refusal or
/// a cancellation before any network action is not an attempt. Counts are null when not measured.
/// </summary>
public sealed record CollectionRun(
    CollectionFamily Family,
    string DomainDn,
    string ScopeDn,
    bool Subtree,
    CollectionStatus Status,
    DateTimeOffset StartedAt,
    DateTimeOffset FinishedAt,
    string? Error,
    long? Targets,
    long? Done,
    long? Succeeded,
    long? Failed,
    string? Controller,
    string Provider);

/// <summary>One side of a clock (last success or last attempt) with its provenance.</summary>
public sealed record CollectionClockView(
    DateTimeOffset At,
    DateTimeOffset FinishedAt,
    CollectionStatus Status,
    string? Error,
    string ScopeDn,
    bool Inherited,
    string? Controller,
    string Provider,
    long? Targets,
    long? Done,
    long? Failed,
    bool Coherent,
    string? Issues);

/// <summary>Clock of one family for one view: last success and last attempt among the scope and its enclosing subtrees.</summary>
public sealed record CollectionClock(
    CollectionFamily Family,
    string Label,
    string State,
    CollectionClockView? Success,
    CollectionClockView? Attempt,
    bool AttemptFailedAfterSuccess,
    bool Coherent,
    string Text,
    string Detail,
    bool Warning);

/// <summary>Freshness of the local base (AD) for a view: only a complete committed coverage dates it.</summary>
public sealed record DirectoryFreshness(string Status, DateTimeOffset? At, string? SourceDn, DateTimeOffset? AttemptAt, bool Partial, bool ClockInvalid, string Text);

/// <summary>Measurement family of the active workstations of a view (ping, console, inventory).</summary>
public sealed record MeasureFamilyFreshness(
    int Count,
    int Total,
    int Missing,
    DateTimeOffset? Oldest,
    DateTimeOffset? Newest,
    ImmutableSortedDictionary<string, int> States,
    string Text);

/// <summary>
/// Provenance of a view (Format-DomeniaOuFreshnessSummary): three clocks, three labels; the newest measurement is never the
/// freshness of the whole OU and a calculation date never dates the data.
/// </summary>
public sealed record FleetProvenance(
    ScopeSelection Scope,
    string ScopeText,
    DirectoryFreshness Directory,
    MeasureFamilyFreshness Ping,
    MeasureFamilyFreshness Console,
    MeasureFamilyFreshness Inventory,
    ImmutableArray<CollectionClock> Clocks,
    DateTimeOffset ComputedAt,
    string ComputedText,
    string ObservationsText,
    string RunsText,
    bool RunsWarning,
    DateTimeOffset? BitLockerAt);

/// <summary>One row of « Relevés par OU » (ConvertTo-DomeniaCollectionRunListRows).</summary>
public sealed record CollectionRunRow(
    DateTimeOffset At,
    string Ou,
    string OuDn,
    bool Subtree,
    string Type,
    CollectionFamily Family,
    CollectionStatus Status,
    string StateLabel,
    string Postes,
    DateTimeOffset? Success,
    string? Reason);

/// <summary>
/// Collection clocks of the OU views (Domenia 1, Domenia-Collection.Model.ps1): run records, keys of the enclosing subtrees,
/// clocks with incoherent dates named and never corrected, texts. Pure: the clock is an input.
/// </summary>
public static class CollectionClocks
{
    public const int MaxRows = 300;
    public const int MaxErrorLength = 1024;
    public static readonly TimeSpan ClockTolerance = TimeSpan.FromMinutes(2);

    public static string FamilyLabel(CollectionFamily family) => family switch
    {
        CollectionFamily.Directory => "Objets AD",
        CollectionFamily.Presence => "Présence réseau (ping)",
        _ => "Inventaire WMI",
    };

    public static string Provider(CollectionFamily family) => family switch
    {
        CollectionFamily.Directory => "LDAP",
        CollectionFamily.Presence => "ICMP",
        _ => "CIM/DCOM",
    };

    public static string StatusText(CollectionStatus status) => status switch
    {
        CollectionStatus.Success => "réussi",
        CollectionStatus.Partial => "partiel",
        CollectionStatus.Cancelled => "arrêté",
        _ => "en échec",
    };

    /// <summary>
    /// A run in the form the store admits (New-DomeniaCollectionRunChange): scope inside the domain, no future date, end after
    /// start, a success never carries an error, a failure always explains itself, counts coherent.
    /// </summary>
    public static CollectionRun Create(
        CollectionFamily family, string domainDn, string scopeDn, bool subtree, CollectionStatus status, DateTimeOffset startedAt, DateTimeOffset finishedAt,
        string? error, long? targets, long? done, long? succeeded, long? failed, string? controller, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(domainDn);
        ArgumentNullException.ThrowIfNull(scopeDn);
        if (!HealthRules.IsInDomain(scopeDn, domainDn))
        {
            throw new ArgumentException("Périmètre de collecte hors du domaine de connexion.", nameof(scopeDn));
        }
        var latest = now + ClockTolerance;
        if (startedAt > latest || finishedAt > latest)
        {
            throw new ArgumentException("Date de collecte dans le futur : vérifiez l’horloge de ce poste.", nameof(finishedAt));
        }
        if (finishedAt < startedAt)
        {
            throw new ArgumentException("Fin de collecte antérieure à son début.", nameof(finishedAt));
        }
        var message = Clean(error, MaxErrorLength);
        if (status == CollectionStatus.Success)
        {
            message = null;
        }
        else if (string.IsNullOrEmpty(message))
        {
            message = status switch
            {
                CollectionStatus.Partial => "Collecte partielle : certaines lectures ne sont pas confirmées.",
                CollectionStatus.Cancelled => "Collecte arrêtée avant la fin.",
                _ => "Collecte non confirmée.",
            };
        }
        if (targets is long t && done is long d && d > t)
        {
            throw new ArgumentException("Plus de postes traités que de cibles.", nameof(done));
        }
        if (done is long dd && succeeded is long s && failed is long f && s + f > dd)
        {
            throw new ArgumentException("Comptes de réussites et d’échecs incohérents.", nameof(failed));
        }
        return new CollectionRun(family, domainDn, scopeDn, subtree, status, startedAt.ToUniversalTime(), finishedAt.ToUniversalTime(), message,
            targets, done, succeeded, failed, Clean(controller, 256), Provider(family));
    }

    /// <summary>
    /// Keys whose runs may date a view: the exact scope at its own depth, then every enclosing subtree up to the domain. A
    /// direct-children run never dates the descendants of its OU.
    /// </summary>
    public static ImmutableArray<string> Keys(string scopeDn, string domainDn, bool subtree)
    {
        var scope = string.IsNullOrEmpty(scopeDn) ? domainDn : scopeDn;
        if (!HealthRules.IsInDomain(scope, domainDn))
        {
            return [];
        }
        var keys = new List<string> { Key(scope, subtree) };
        var cursor = scope;
        for (var depth = 0; cursor is not null && depth < 512; depth++)
        {
            var key = Key(cursor, true);
            if (!keys.Contains(key))
            {
                keys.Add(key);
            }
            if (HealthRules.SameDn(cursor, domainDn))
            {
                break;
            }
            cursor = DistinguishedName.Parent(cursor);
        }
        return [.. keys];
    }

    public static string Key(string scopeDn, bool subtree)
    {
        string canonical;
        try
        {
            canonical = DistinguishedName.Format(DistinguishedName.Parse(scopeDn)).ToLowerInvariant();
        }
        catch (FormatException)
        {
            canonical = scopeDn.ToLowerInvariant();
        }
        return (subtree ? "subtree:" : "onelevel:") + canonical;
    }

    /// <summary>
    /// Clock of one family: the newest success and the newest attempt of the matching keys. A failed attempt never hides an
    /// older success and never ages it; incoherent dates are reported, never corrected.
    /// </summary>
    public static CollectionClock Clock(IEnumerable<CollectionRun> runs, CollectionFamily family, ScopeSelection scope, string domainDn, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(runs);
        ArgumentNullException.ThrowIfNull(scope);
        var keys = Keys(scope.Dn, domainDn, scope.Subtree);
        CollectionRun? best = null;
        CollectionRun? latest = null;
        foreach (var run in runs)
        {
            if (run.Family != family || !HealthRules.SameDn(run.DomainDn, domainDn) || !keys.Contains(Key(run.ScopeDn, run.Subtree)))
            {
                continue;
            }
            if (run.Status == CollectionStatus.Success && (best is null || run.StartedAt > best.StartedAt))
            {
                best = run;
            }
            if (latest is null || run.StartedAt > latest.StartedAt)
            {
                latest = run;
            }
        }
        var success = best is null ? null : View(best, scope, now);
        var attempt = latest is null ? null : View(latest, scope, now);
        var failedAfter = attempt is not null && attempt.Status != CollectionStatus.Success && (success is null || attempt.At > success.At);
        var coherent = (success?.Coherent ?? true) && (attempt?.Coherent ?? true);
        var state = attempt is null ? "neverRecorded" : !coherent ? "incoherent" : failedAfter && success is not null ? "successThenFailure" : failedAfter ? "failureOnly" : "success";
        var (text, detail, warning) = Describe(family, success, attempt, failedAfter, zone);
        return new CollectionClock(family, FamilyLabel(family), state, success, attempt, failedAfter, coherent, text, detail, warning);
    }

    /// <summary>Freshness of the local base for a view: complete reads of the domain or of an enclosing subtree (Get-DomeniaFleetFreshness).</summary>
    public static DirectoryFreshness Directory(IEnumerable<CollectionRun> runs, StoreStatus store, ScopeSelection scope, string domainDn, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(runs);
        ArgumentNullException.ThrowIfNull(store);
        DateTimeOffset? at = null;
        string? source = null;
        var clockInvalid = false;
        if (store.LastReadAt is DateTimeOffset read)
        {
            if (read > now + ClockTolerance)
            {
                clockInvalid = true;
            }
            else if (store.Complete)
            {
                at = read;
                source = domainDn;
            }
        }
        var keys = Keys(scope.Dn, domainDn, scope.Subtree);
        DateTimeOffset? attemptAt = null;
        var partial = false;
        foreach (var run in runs.Where(r => r.Family == CollectionFamily.Directory && keys.Contains(Key(r.ScopeDn, r.Subtree))))
        {
            if (run.StartedAt > now + ClockTolerance)
            {
                clockInvalid = true;
                continue;
            }
            if (run.Status == CollectionStatus.Success && (at is null || run.FinishedAt > at))
            {
                at = run.FinishedAt;
                source = run.ScopeDn;
            }
            if (attemptAt is null || run.StartedAt > attemptAt)
            {
                attemptAt = run.StartedAt;
                partial = run.Status == CollectionStatus.Partial;
            }
        }
        partial = partial && (at is null || attemptAt >= at);
        var status = partial ? "partial" : at is not null ? "complete" : "missing";
        var text = "Base locale (AD)" + FrenchText.Colon + (at is DateTimeOffset when
            ? "lecture complète le " + Local(when, zone) + " (" + Age(when, now) + ")"
            : "aucune lecture complète couvrant ce périmètre");
        if (partial && attemptAt is DateTimeOffset tried)
        {
            text += " ; tentative incomplète le " + Local(tried, zone);
        }
        if (clockInvalid)
        {
            text += " ; date future ignorée, vérifier l’horloge";
        }
        return new DirectoryFreshness(status, at, source, attemptAt, partial, clockInvalid, text);
    }

    /// <summary>
    /// Ping, console and inventory measures of the active workstations, each counted once with its own date; a workstation
    /// without a usable measure keeps its reason (point 3).
    /// </summary>
    public static MeasureFamilyFreshness Family(string label, IReadOnlyList<(MeasureState State, DateTimeOffset? At)> measures, int total, DateTimeOffset now, int maxDays, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(measures);
        var states = new SortedDictionary<string, int>(StringComparer.Ordinal);
        var count = 0;
        DateTimeOffset? oldest = null;
        DateTimeOffset? newest = null;
        foreach (var (state, at) in measures)
        {
            var effective = state;
            if (state == MeasureState.Known)
            {
                if (at is not DateTimeOffset when || when > now + ClockTolerance)
                {
                    effective = MeasureState.Error;
                }
                else if (now - when > TimeSpan.FromDays(maxDays))
                {
                    effective = MeasureState.Expired;
                }
            }
            if (effective == MeasureState.Known)
            {
                count++;
                oldest = oldest is null || at < oldest ? at : oldest;
                newest = newest is null || at > newest ? at : newest;
            }
            else
            {
                var key = StateKey(effective);
                states[key] = states.GetValueOrDefault(key) + 1;
            }
        }
        var missing = Math.Max(0, total - measures.Count);
        if (missing > 0)
        {
            states["absent"] = states.GetValueOrDefault("absent") + missing;
        }
        var details = new List<string>();
        if (count > 0 && oldest is DateTimeOffset o && newest is DateTimeOffset n)
        {
            details.Add(o == n ? "le " + Local(o, zone) : "du " + Local(o, zone) + " au " + Local(n, zone));
        }
        else
        {
            details.Add("aucun relevé daté utilisable");
        }
        var unknown = StatesText(states);
        if (unknown.Length > 0)
        {
            details.Add(unknown);
        }
        var text = label + " " + FrenchText.Integer(count) + "/" + FrenchText.Integer(total) + " (" + string.Join(" ; ", details) + ")";
        return new MeasureFamilyFreshness(count, total, Math.Max(0, total - count), oldest, newest, states.ToImmutableSortedDictionary(StringComparer.Ordinal), text);
    }

    /// <summary>« 3 jamais relevés, 2 refusés, 1 en erreur »: the reasons of the workstations without a usable measure.</summary>
    public static string StatesText(IReadOnlyDictionary<string, int> states)
    {
        ArgumentNullException.ThrowIfNull(states);
        var parts = new List<string>();
        foreach (var key in new[] { "absent", "notRead", "refused", "expired", "incomplete", "error" })
        {
            if (states.TryGetValue(key, out var n) && n > 0)
            {
                parts.Add(FrenchText.Integer(n) + " " + StateLabel(key, n));
            }
        }
        return string.Join(", ", parts);
    }

    public static string StateKey(MeasureState state) => state switch
    {
        MeasureState.Known => "known",
        MeasureState.Absent => "absent",
        MeasureState.NotRead => "notRead",
        MeasureState.Refused => "refused",
        MeasureState.Expired => "expired",
        MeasureState.Incomplete => "incomplete",
        _ => "error",
    };

    private static string StateLabel(string key, int n)
    {
        var plural = n > 1;
        return key switch
        {
            "absent" => plural ? "jamais relevés" : "jamais relevé",
            "notRead" => plural ? "non lus" : "non lu",
            "refused" => plural ? "refusés" : "refusé",
            "expired" => plural ? "périmés" : "périmé",
            "incomplete" => plural ? "incomplets" : "incomplet",
            _ => "en erreur",
        };
    }

    /// <summary>Rows of « Relevés par OU », newest attempt first, 300 at most.</summary>
    public static ImmutableArray<CollectionRunRow> Rows(IEnumerable<CollectionRun> runs)
    {
        ArgumentNullException.ThrowIfNull(runs);
        var all = runs.ToList();
        return [.. all.OrderByDescending(r => r.StartedAt).Take(MaxRows).Select(run =>
        {
            var name = OuName(run.ScopeDn) + (run.Subtree && !run.ScopeDn.StartsWith("DC=", StringComparison.OrdinalIgnoreCase) ? " et sous-OU" : "");
            var success = all.Where(r => r.Family == run.Family && r.Status == CollectionStatus.Success && Key(r.ScopeDn, r.Subtree) == Key(run.ScopeDn, run.Subtree) && r.StartedAt <= run.StartedAt)
                .Select(r => (DateTimeOffset?)r.StartedAt).Max();
            var reason = run.Error is { Length: > 200 } e ? e[..200] + "…" : run.Error;
            var type = run.Family switch { CollectionFamily.Directory => "Objets AD", CollectionFamily.Presence => "Ping", _ => "WMI" };
            return new CollectionRunRow(run.StartedAt, name, run.ScopeDn, run.Subtree, type, run.Family, run.Status, StatusText(run.Status), Counts(run), success, reason);
        })];
    }

    /// <summary>« 198/200 postes » (« objets AD » for a directory read), only measured counters, failures named.</summary>
    public static string Counts(CollectionRun run)
    {
        ArgumentNullException.ThrowIfNull(run);
        if (run.Done is not long done)
        {
            return "";
        }
        var text = FrenchText.Integer(done) + (run.Targets is long t ? "/" + FrenchText.Integer(t) : "");
        var plural = done > 1;
        text += run.Family == CollectionFamily.Directory ? (plural ? " objets AD" : " objet AD") : (plural ? " postes" : " poste");
        if (run.Failed is long f && f > 0)
        {
            text += ", " + FrenchText.Integer(f) + (f > 1 ? " non confirmés" : " non confirmé");
        }
        return text;
    }

    public static string OuName(string dn)
    {
        try
        {
            var parts = DistinguishedName.Parse(dn);
            if (parts.Length > 0 && !parts[0].Type.Equals("DC", StringComparison.OrdinalIgnoreCase))
            {
                return parts[0].Value;
            }
            return string.Join(".", parts.Where(p => p.Type.Equals("DC", StringComparison.OrdinalIgnoreCase)).Select(p => p.Value));
        }
        catch (FormatException)
        {
            return dn;
        }
    }

    public static string Local(DateTimeOffset at, TimeZoneInfo zone) =>
        TimeZoneInfo.ConvertTime(at, zone).ToString("dd'/'MM'/'yyyy HH':'mm", CultureInfo.InvariantCulture);

    /// <summary>« il y a 5 min », « il y a 3 h », « il y a 2 j » (Format-DomeniaAge).</summary>
    public static string Age(DateTimeOffset from, DateTimeOffset now)
    {
        var span = now - from;
        if (span.TotalMinutes < 1)
        {
            return "à l’instant";
        }
        if (span.TotalHours < 1)
        {
            return "il y a " + FrenchText.Integer((long)Math.Floor(span.TotalMinutes)) + " min";
        }
        if (span.TotalDays < 1)
        {
            return "il y a " + FrenchText.Integer((long)Math.Floor(span.TotalHours)) + " h";
        }
        return "il y a " + FrenchText.Integer((long)Math.Floor(span.TotalDays)) + " j";
    }

    private static CollectionClockView View(CollectionRun run, ScopeSelection scope, DateTimeOffset now)
    {
        var issues = new List<string>();
        if (run.StartedAt > now + ClockTolerance || run.FinishedAt > now + ClockTolerance)
        {
            issues.Add("date future : horloge à vérifier");
        }
        if (run.FinishedAt < run.StartedAt)
        {
            issues.Add("fin de collecte antérieure à son début");
        }
        var inherited = !HealthRules.SameDn(run.ScopeDn, scope.Dn);
        return new CollectionClockView(run.StartedAt, run.FinishedAt, run.Status, run.Error, run.ScopeDn, inherited, run.Controller, run.Provider,
            run.Targets, run.Done, run.Failed, issues.Count == 0, issues.Count == 0 ? null : "Dates incohérentes" + FrenchText.Colon + string.Join(" ; ", issues) + ".");
    }

    private static (string Text, string Detail, bool Warning) Describe(CollectionFamily family, CollectionClockView? success, CollectionClockView? attempt, bool failedAfter, TimeZoneInfo zone)
    {
        var label = FamilyLabel(family);
        if (success is null && attempt is null)
        {
            return ("", label + FrenchText.Colon + "aucun relevé de périmètre enregistré.", false);
        }
        var parts = new List<string>();
        var detail = new List<string> { label };
        var warning = false;
        var partialShown = false;
        if (success is not null)
        {
            if (family != CollectionFamily.Directory)
            {
                var text = "relevé réussi le " + Local(success.At, zone);
                var counts = ViewCounts(success, family);
                if (counts.Length > 0)
                {
                    text += " (" + counts + ")";
                }
                if (success.Inherited)
                {
                    text += " via une OU englobante";
                }
                parts.Add(text);
            }
            detail.Add(Line(success, "Dernière réussite", family, zone));
            if (!success.Coherent && success.Issues is string issues)
            {
                parts.Add(issues);
                warning = true;
            }
        }
        else if (family != CollectionFamily.Directory)
        {
            if (attempt is not null && attempt.Done is > 0)
            {
                // A stopped or incomplete survey stays usable: the workstations it read are named (decision of 19/10/2026).
                var text = "relevé partiel le " + Local(attempt.At, zone) + " (" + ViewCounts(attempt, family) + ", " + StatusText(attempt.Status) + ") ; les postes lus sont exploitables";
                if (attempt.Inherited)
                {
                    text += " via une OU englobante";
                }
                parts.Add(text);
                warning = true;
                partialShown = true;
                detail.Add(Line(attempt, "Relevé partiel (" + StatusText(attempt.Status) + ")", family, zone) + (attempt.Error is string e ? " ; motif" + FrenchText.Colon + e : ""));
            }
            else
            {
                parts.Add("aucun relevé réussi enregistré");
            }
        }
        if (!partialShown && failedAfter && attempt is not null)
        {
            var text = "dernière tentative le " + Local(attempt.At, zone) + FrenchText.Colon + StatusText(attempt.Status);
            if (attempt.Error is string error)
            {
                text += " — " + (error.Length > 160 ? error[..159] + "…" : error);
            }
            if (success is not null)
            {
                text += " ; la dernière réussite reste la référence";
            }
            parts.Add(text);
            warning = true;
            detail.Add(Line(attempt, "Dernière tentative (" + StatusText(attempt.Status) + ")", family, zone) + (attempt.Error is string e ? " ; erreur" + FrenchText.Colon + e : ""));
        }
        return (string.Join(" ; ", parts), string.Join("\n", detail), warning);
    }

    private static string Line(CollectionClockView view, string kind, CollectionFamily family, TimeZoneInfo zone)
    {
        var line = kind + FrenchText.Colon + Local(view.At, zone) + " → " + Local(view.FinishedAt, zone);
        line += " ; périmètre " + view.ScopeDn + (view.Inherited ? " (OU englobante)" : "");
        var source = new List<string> { "fournisseur " + view.Provider };
        if (view.Controller is string c)
        {
            source.Add("contrôleur " + c);
        }
        line += " ; " + string.Join(", ", source);
        var counts = ViewCounts(view, family);
        return counts.Length > 0 ? line + " ; " + counts : line;
    }

    private static string ViewCounts(CollectionClockView view, CollectionFamily family) =>
        Counts(new CollectionRun(family, "", "", true, view.Status, view.At, view.FinishedAt, null, view.Targets, view.Done, null, view.Failed, null, ""));

    private static string? Clean(string? text, int maximum)
    {
        if (text is null)
        {
            return null;
        }
        var value = string.Join(" ", text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)).Trim();
        value = new string([.. value.Where(c => !char.IsControl(c))]);
        if (value.Length == 0)
        {
            return null;
        }
        return value.Length > maximum ? value[..(maximum - 1)] + "…" : value;
    }
}

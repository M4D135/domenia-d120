using System.Collections.Immutable;
using System.Text.RegularExpressions;

namespace Domenia.Core.Poste;

/// <summary>lastLogon of the computer account read on one controller (not replicated: each controller knows its own).</summary>
public sealed record ControllerLogon(string Controller, string? Site, FactState State, DateTimeOffset? LastLogon, string Text);

/// <summary>Result of poste.logonByDc (Domenia 1 PST-114): approximate lastLogonTimestamp and the exact lastLogon per controller.</summary>
public sealed record LogonActivity(string Computer, DateTimeOffset At, DateTimeOffset? Timestamp, string TimestampText, ImmutableArray<ControllerLogon> Controllers, DateTimeOffset? Latest, string Coverage, string Text, ImmutableArray<PosteFact> Facts);

/// <summary>One method of the detection of the last user (Domenia 1 Start-ComputerUserLinkProbe pipeline).</summary>
public sealed record DetectionAttempt(int Order, string Method, string Status, string StatusLabel, Tone Tone, int DurationMs, string Detail, string? Candidate);

/// <summary>Result of poste.lastUser.detect: the attempts, the candidate verified by exact AD identity, the association kept.</summary>
public sealed record LastUserDetection(string Computer, DateTimeOffset At, ImmutableArray<DetectionAttempt> Attempts, UserRef? Candidate, bool Verified, string Verdict, PosteAssociation Association, int BudgetSeconds);

/// <summary>A WMI namespace with whether it has children (root and its direct children are listed).</summary>
public sealed record WmiNamespace(string Name, string Path, bool HasChildren);

public sealed record WmiNamespaces(string Computer, string Parent, ImmutableArray<WmiNamespace> Namespaces, string Status);

public sealed record WmiClassInfo(string Name, bool Blocked, string? Reason);

public sealed record WmiClasses(string Computer, string Namespace, ImmutableArray<WmiClassInfo> Classes, string Status);

/// <summary>One property of the schema of a class: type, key, qualifiers.</summary>
public sealed record WmiProperty(string Name, string Type, bool Key, string Qualifiers);

/// <summary>Result of poste.wmi.query: schema, instances (strings), limit, and the computer that answered (named in exports).</summary>
public sealed record WmiQueryResult(string Computer, string Namespace, string Class, string? Where, int Limit, bool Truncated, ImmutableArray<WmiProperty> Schema, ImmutableArray<ImmutableArray<string?>> Instances, string Status, string Query, int DurationMs);

/// <summary>Validated WMI request (Assert-DomeniaWmiReadQuery): SELECT only, no method, MSI provider classes blocked.</summary>
public sealed record WmiRequest(string Namespace, string Class, string? Where, int Limit);

/// <summary>Rules of the WMI explorer (Domenia 1 Assert-DomeniaWmiReadQuery): names validated, filter bounded, no method.</summary>
public static partial class PosteWmi
{
    public const int DefaultLimit = 25;
    public const int MaxLimit = 500;
    public const int MaxWhere = 2048;

    [GeneratedRegex(@"^[A-Za-z][A-Za-z0-9_]{0,127}$", RegexOptions.CultureInvariant, 200)]
    private static partial Regex ClassName();

    [GeneratedRegex(@"^root(\\[A-Za-z0-9_]{1,64}){0,6}$", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase, 200)]
    private static partial Regex NamespaceName();

    [GeneratedRegex(@"(?i)\b(insert|update|delete|create|drop|exec|execute|associators|references)\b|[;{}]", RegexOptions.CultureInvariant, 200)]
    private static partial Regex Forbidden();

    public static bool IsNamespace(string? name) => !string.IsNullOrWhiteSpace(name) && NamespaceName().IsMatch(name);

    public static bool IsClass(string? name) => !string.IsNullOrWhiteSpace(name) && ClassName().IsMatch(name);

    /// <summary>Validates a request; the reason is a fixed French precision that never copies the operator input.</summary>
    public static (WmiRequest? Request, string? Reason) Validate(string? ns, string? cls, string? where, int? limit)
    {
        if (!IsNamespace(ns))
        {
            return (null, "espace de noms invalide (root, puis des noms de lettres, chiffres et soulignés).");
        }
        if (!IsClass(cls))
        {
            return (null, "nom de classe invalide.");
        }
        if (PosteLabels.MsiProviderClasses.Contains(cls!))
        {
            return (null, "classe du fournisseur MSI bloquée (sa lecture vérifie et peut réparer chaque paquet installé).");
        }
        var filter = (where ?? "").Trim();
        if (filter.Length > MaxWhere)
        {
            return (null, "filtre de plus de 2 048 caractères.");
        }
        if (filter.Length > 0 && (Forbidden().IsMatch(filter) || filter.Any(char.IsControl)))
        {
            return (null, "filtre refusé (mot réservé, accolade, point-virgule ou caractère de contrôle).");
        }
        var bounded = Math.Clamp(limit ?? DefaultLimit, 1, MaxLimit);
        return (new WmiRequest(ns!, cls!, filter.Length == 0 ? null : filter, bounded), null);
    }

    public static string Query(WmiRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        return "SELECT * FROM " + request.Class + (request.Where is null ? "" : " WHERE " + request.Where);
    }
}

using System.Collections.Immutable;
using System.Globalization;

namespace Domenia.Core;

/// <summary>Depth of a membership test (Domenia 1 Test-DomeniaDnInScope).</summary>
public enum ScopeDepth
{
    Base,
    OneLevel,
    Subtree,
}

/// <summary>Meaning of a DN change for a scope (Domenia 1 Get-DomeniaDirectoryMove). The GUID never changes.</summary>
public enum MoveKind
{
    Unknown,
    Unchanged,
    Renamed,
    MovedWithin,
    MovedOut,
    MovedIn,
    MovedOutside,
}

/// <summary>A DN change explained: kind, scope membership before and after, readable locations and the full sentence.</summary>
public sealed record SyncMove(MoveKind Kind, bool Moved, bool InScope, bool WasInScope, string FromLocation, string ToLocation, ImmutableArray<string> Breadcrumb, string Text);

/// <summary>French texts shared by the rules of the screen (no culture of the workstation is read).</summary>
public static class SyncText
{
    /// <summary>« : » with its no-break space.</summary>
    public static string C => FrenchText.Colon;

    /// <summary>« ; » with its no-break space.</summary>
    public const string Semi = " ;";

    /// <summary>Local date and time « 21/10/2026 18:14 » in the zone.</summary>
    public static string LocalDateTime(DateTimeOffset at, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        return TimeZoneInfo.ConvertTime(at, zone).ToString("dd'/'MM'/'yyyy HH':'mm", CultureInfo.InvariantCulture);
    }

    /// <summary>Local date « 21/10 18:14 » (the year only when it differs from <paramref name="now"/>).</summary>
    public static string ShortDateTime(DateTimeOffset at, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(zone);
        var local = TimeZoneInfo.ConvertTime(at, zone);
        var year = TimeZoneInfo.ConvertTime(now, zone).Year;
        return local.ToString(local.Year == year ? "dd'/'MM HH':'mm" : "dd'/'MM'/'yyyy HH':'mm", CultureInfo.InvariantCulture);
    }

    /// <summary>
    /// « à l’instant », « il y a 5 min », « il y a 2 h », « il y a 3 j » between two instants; a date more than five
    /// minutes ahead is named as such (Domenia 1 Get-DomeniaElapsedText).
    /// </summary>
    public static string Elapsed(DateTimeOffset from, DateTimeOffset now)
    {
        var span = now - from;
        if (span.TotalMinutes < -5)
        {
            return "à une date future (horloge à vérifier)";
        }
        if (span.TotalMinutes < 1)
        {
            return "à l’instant";
        }
        if (span.TotalHours < 1)
        {
            return "il y a " + FrenchText.Integer((long)Math.Floor(span.TotalMinutes)) + " min";
        }
        if (span.TotalDays < 1)
        {
            return "il y a " + FrenchText.Integer((long)Math.Floor(span.TotalHours)) + " h";
        }
        return "il y a " + FrenchText.Integer((long)Math.Floor(span.TotalDays)) + " j";
    }

    /// <summary>Duration in plain words: « 850 ms », « 12 s », « 3 min 05 s », « 1 h 20 min ».</summary>
    public static string Duration(long milliseconds)
    {
        if (milliseconds < 1000)
        {
            return FrenchText.Integer(Math.Max(0, milliseconds)) + " ms";
        }
        var seconds = milliseconds / 1000;
        if (seconds < 60)
        {
            return FrenchText.Integer(seconds) + " s";
        }
        var minutes = seconds / 60;
        if (minutes < 60)
        {
            return seconds % 60 == 0
                ? FrenchText.Integer(minutes) + " min"
                : FrenchText.Integer(minutes) + " min " + (seconds % 60).ToString("00", CultureInfo.InvariantCulture) + " s";
        }
        return minutes % 60 == 0
            ? FrenchText.Integer(minutes / 60) + " h"
            : FrenchText.Integer(minutes / 60) + " h " + (minutes % 60).ToString("00", CultureInfo.InvariantCulture) + " min";
    }

    /// <summary>Short form of a fingerprint for the operator (12 characters); the full value stays in the details.</summary>
    public static string ShortHash(string sha256) => string.IsNullOrEmpty(sha256) ? "" : sha256[..Math.Min(12, sha256.Length)];

    /// <summary>One line of text, tabs and line breaks turned into spaces, cut to <paramref name="max"/> characters.</summary>
    public static string Flat(string? text, int max)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return "";
        }
        var flat = string.Join(' ', text.Split(['\t', '\r', '\n'], StringSplitOptions.RemoveEmptyEntries)).Trim();
        return flat.Length <= max ? flat : flat[..max];
    }
}

/// <summary>
/// Pure rules on locations (Domenia 1 Domenia-DirectorySync.Model.ps1, points 23 and 30): RDN-boundary membership, readable
/// paths « Lyon › Postes », and the meaning of a DN change (rename, move within, out of or into a scope). An object keeps its
/// GUID: a move or a rename never makes a second object. No directory read, no clock.
/// </summary>
public static class SyncLocations
{
    /// <summary>Readable location of the domain root itself.</summary>
    public const string RootLocation = "(racine du domaine)";

    /// <summary>RDNs of a DN, from the object up; empty for a missing or malformed DN.</summary>
    public static ImmutableArray<RelativeName> Parts(string? dn)
    {
        if (string.IsNullOrWhiteSpace(dn))
        {
            return [];
        }
        try
        {
            return DistinguishedName.Parse(dn.Trim());
        }
        catch (FormatException)
        {
            return [];
        }
    }

    /// <summary>
    /// RDN-boundary membership of <paramref name="dn"/> in <paramref name="scopeDn"/>: Base is the scope object itself, OneLevel
    /// its direct children, Subtree the scope and everything below it. A suffix that cuts an RDN is never membership.
    /// </summary>
    public static bool InScope(string? dn, string? scopeDn, ScopeDepth depth = ScopeDepth.Subtree)
    {
        var child = Parts(dn);
        var scope = Parts(scopeDn);
        if (child.IsEmpty || scope.IsEmpty || child.Length < scope.Length)
        {
            return false;
        }
        var offset = child.Length - scope.Length;
        for (var i = 0; i < scope.Length; i++)
        {
            if (!string.Equals(child[offset + i].Type, scope[i].Type, StringComparison.OrdinalIgnoreCase)
                || !string.Equals(child[offset + i].Value, scope[i].Value, StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }
        }
        return depth switch
        {
            ScopeDepth.Base => offset == 0,
            ScopeDepth.OneLevel => offset == 1,
            _ => true,
        };
    }

    /// <summary>Same DN, case and escaping ignored; false when one is malformed.</summary>
    public static bool Same(string? left, string? right)
    {
        var a = Parts(left);
        var b = Parts(right);
        return !a.IsEmpty && a.Length == b.Length && InScope(left, right, ScopeDepth.Base);
    }

    /// <summary>Unescaped OU and container names from the domain head down (the DC= components are not part of the path).</summary>
    public static ImmutableArray<string> Path(string? dn, bool excludeSelf = false)
    {
        var parts = Parts(dn);
        var labels = ImmutableArray.CreateBuilder<string>();
        var last = excludeSelf ? 1 : 0;
        for (var i = parts.Length - 1; i >= last; i--)
        {
            if (string.Equals(parts[i].Type, "DC", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            labels.Add(parts[i].Value);
        }
        return labels.ToImmutable();
    }

    /// <summary>Parent OUs and containers of an object, from the domain head down to its direct parent.</summary>
    public static ImmutableArray<string> Breadcrumb(string? dn) => Path(dn, excludeSelf: true);

    /// <summary>Readable location of an object (« Lyon › Postes »), « (racine du domaine) » directly under the head, « » when unknown.</summary>
    public static string Location(string? dn)
    {
        if (Parts(dn).Length < 2)
        {
            return "";
        }
        var trail = Breadcrumb(dn);
        return trail.IsEmpty ? RootLocation : string.Join(FrenchText.PathSeparator, trail);
    }

    /// <summary>Readable path of a scope (« Postes › Lyon »); the domain name for the root.</summary>
    public static string ScopePath(string? dn, string? domainName)
    {
        var path = Path(dn);
        return path.IsEmpty ? (domainName ?? "Domaine entier") : string.Join(FrenchText.PathSeparator, path);
    }

    /// <summary>Unescaped value of the first RDN (« OU=Lyon » gives « Lyon »), « » when malformed.</summary>
    public static string Name(string? dn)
    {
        var parts = Parts(dn);
        return parts.IsEmpty ? "" : parts[0].Value;
    }

    /// <summary>
    /// What a DN change means for a scope (Domenia 1 Get-DomeniaDirectoryMove). An empty scope means every location belongs.
    /// </summary>
    public static SyncMove Move(string? oldDn, string? newDn, string? scopeDn = null, ScopeDepth depth = ScopeDepth.Subtree)
    {
        var old = oldDn?.Trim() ?? "";
        var next = newDn?.Trim() ?? "";
        var scope = scopeDn?.Trim() ?? "";
        var c = SyncText.C;
        if (next.Length == 0)
        {
            return new SyncMove(MoveKind.Unknown, false, false, false, "", "", [], "Nouvel emplacement inconnu" + c + "aucune conclusion.");
        }
        var inScope = scope.Length == 0 || InScope(next, scope, depth);
        var wasInScope = old.Length > 0 && (scope.Length == 0 || InScope(old, scope, depth));
        var to = Location(next);
        var breadcrumb = Breadcrumb(next);
        if (old.Length == 0)
        {
            return new SyncMove(MoveKind.Unknown, false, inScope, wasInScope, "", to, breadcrumb, "Ancien emplacement inconnu" + SyncText.Semi + " emplacement actuel" + c + to + ".");
        }
        var from = Location(old);
        if (Same(old, next) || string.Equals(old, next, StringComparison.OrdinalIgnoreCase))
        {
            return new SyncMove(MoveKind.Unchanged, false, inScope, wasInScope, from, to, breadcrumb, "Emplacement inchangé.");
        }
        var oldParts = Parts(old);
        var newParts = Parts(next);
        var oldParent = DistinguishedName.Parent(old) ?? "";
        var newParent = DistinguishedName.Parent(next) ?? "";
        if (Same(oldParent, newParent) || (oldParent.Length == 0 && newParent.Length == 0))
        {
            var before = oldParts.IsEmpty ? old : oldParts[0].Value;
            var after = newParts.IsEmpty ? next : newParts[0].Value;
            return new SyncMove(MoveKind.Renamed, false, inScope, wasInScope, from, to, breadcrumb, "Renommé au même emplacement" + c + before + " → " + after + ".");
        }
        if (wasInScope && inScope)
        {
            return new SyncMove(MoveKind.MovedWithin, true, inScope, wasInScope, from, to, breadcrumb, "Déplacé dans le périmètre" + c + from + " → " + to + ".");
        }
        if (wasInScope)
        {
            return new SyncMove(MoveKind.MovedOut, true, inScope, wasInScope, from, to, breadcrumb, "Déplacé hors du périmètre affiché" + c + "désormais dans " + to + ".");
        }
        if (inScope)
        {
            return new SyncMove(MoveKind.MovedIn, true, inScope, wasInScope, from, to, breadcrumb, "Entré dans le périmètre" + c + "venant de " + from + ".");
        }
        return new SyncMove(MoveKind.MovedOutside, true, inScope, wasInScope, from, to, breadcrumb, "Déplacé hors du périmètre" + c + from + " → " + to + ".");
    }

    /// <summary>Short state of a moved row in a result list; the full sentence stays in <see cref="SyncMove.Text"/>.</summary>
    public static string MoveStateText(SyncMove move)
    {
        ArgumentNullException.ThrowIfNull(move);
        var c = SyncText.C;
        return move.Kind switch
        {
            MoveKind.Renamed => "Renommé au même emplacement",
            MoveKind.MovedWithin => "Déplacé vers " + move.ToLocation,
            MoveKind.MovedIn => "Entré dans le périmètre" + c + move.ToLocation,
            MoveKind.MovedOut => "Sorti du périmètre" + c + move.ToLocation,
            MoveKind.MovedOutside => "Déplacé" + c + move.ToLocation,
            MoveKind.Unchanged => "AD vérifié",
            _ => "Emplacement à vérifier",
        };
    }
}

using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// One object a complete read did not return, as the base keeps it (Domenia 1 table directory_absence): recorded as not seen,
/// never as deleted; the result of its last verification replaces the status.
/// </summary>
public sealed record AbsenceRecord(
    Guid ObjectGuid,
    string Name,
    IndexObjectType Type,
    string LastDn,
    string? FoundDn,
    AbsenceStatus Status,
    DateTimeOffset NoticedAt,
    DateTimeOffset? CheckedAt,
    string Detail,
    string ScopeDn,
    string? Server);

/// <summary>Whether the domain could be read for a verification (Domenia 1 DomainRead).</summary>
public enum DomainRead
{
    Read,
    Refused,
    Unavailable,
}

/// <summary>
/// What the directory answered for one GUID (Domenia 1 absence check worker): the domain read, the DN found, the deleted-object
/// read with its proof (isDeleted, date, last parent, recycled) and the record of the object when it still exists.
/// </summary>
public sealed record AbsenceCheck(
    DomainRead DomainRead,
    string? FoundDn,
    DeletedProbe DeletedRead,
    bool Deleted,
    DateTimeOffset? DeletedWhen,
    string? LastKnownParent,
    bool Recycled,
    IndexRecord? Record);

/// <summary>A verification turned into what the base keeps: the new status, the detail and the record put back when the object exists.</summary>
public sealed record AbsenceOutcome(AbsenceResolution Resolution, AbsenceStatus Status, string? FoundDn, string Detail, IndexRecord? Keep);

/// <summary>One census gap as the base keeps it: an identity of the last domain census missing from the base.</summary>
public sealed record CensusGapRecord(Guid ObjectGuid, string Dn, DateTimeOffset SeenAt);

/// <summary>What the directory answered for one census gap read by GUID.</summary>
public sealed record GapCheck(DomainRead DomainRead, string? FoundDn, IndexRecord? Record);

/// <summary>A census gap read by GUID turned into what the base keeps (Domenia 1 New-DomeniaCensusGapStoreRow).</summary>
public sealed record GapOutcome(GapResolution Resolution, IndexRecord? Keep, bool LeavesList);

/// <summary>
/// Pure rules of disappeared objects and census gaps (Domenia 1 points 22 and 24, Domenia-DirectorySync.Model.ps1): only a
/// deleted-object entry (isDeleted) read by GUID proves a deletion; a partial read, a filter or a loss of rights only makes an
/// object invisible; an object found elsewhere keeps its identity and takes its new location.
/// </summary>
public static class SyncAbsences
{
    /// <summary>One explicit gesture never reads more identities than this.</summary>
    public const int CheckLimit = 200;

    /// <summary>Identities read in one LDAP request (batches of 24, Domenia 1).</summary>
    public const int BatchSize = 24;

    /// <summary>Time budget of a verification (Domenia 1: 60 seconds).</summary>
    public const int BudgetSeconds = 60;

    /// <summary>Most recent rows shown in the list (the totals stay exact).</summary>
    public const int ShownLimit = 200;

    public static string Label(AbsenceStatus status) => status switch
    {
        AbsenceStatus.NotSeen => "Non revu, à vérifier",
        AbsenceStatus.Visible => "De nouveau visible",
        AbsenceStatus.Moved => "Déplacé",
        AbsenceStatus.Deleted => "Suppression constatée",
        AbsenceStatus.NotFound => "Introuvable",
        AbsenceStatus.Invisible => "Invisible pour ce compte",
        _ => "Vérification impossible",
    };

    public static Tone ToneOf(AbsenceStatus status) => status switch
    {
        AbsenceStatus.NotSeen => Tone.Warn,
        AbsenceStatus.Visible => Tone.Ok,
        AbsenceStatus.Moved => Tone.Info,
        AbsenceStatus.Deleted => Tone.Alert,
        AbsenceStatus.Unconfirmed => Tone.Warn,
        _ => Tone.Off,
    };

    /// <summary>Count and status in words for a summary: « 3 de nouveau visibles », « 1 suppression constatée ».</summary>
    public static string CountText(AbsenceStatus status, int count) => status switch
    {
        AbsenceStatus.NotSeen => FrenchText.Count(count, "à vérifier", "à vérifier"),
        AbsenceStatus.Visible => FrenchText.Count(count, "de nouveau visible", "de nouveau visibles"),
        AbsenceStatus.Moved => FrenchText.Count(count, "déplacé", "déplacés"),
        AbsenceStatus.Deleted => FrenchText.Count(count, "suppression constatée", "suppressions constatées"),
        AbsenceStatus.NotFound => FrenchText.Count(count, "introuvable", "introuvables"),
        AbsenceStatus.Invisible => FrenchText.Count(count, "invisible pour ce compte", "invisibles pour ce compte"),
        _ => FrenchText.Count(count, "vérification impossible", "vérifications impossibles"),
    };

    public static string TypeLabel(IndexObjectType type) => type == IndexObjectType.Computer ? "Poste" : "Utilisateur";

    /// <summary>
    /// Classifies an object a complete read of its scope did not return (Domenia 1 Resolve-DomeniaDirectoryAbsence). Found in
    /// the scope (unchanged, renamed, moved within): visible again; found elsewhere: moved; an isDeleted entry read while the
    /// deleted objects are visible: deletion proven; absent from readable deleted objects: not found, no conclusion; deleted
    /// objects not visible to this account: invisible (a deletion and a loss of rights look the same here).
    /// </summary>
    public static AbsenceOutcome Resolve(AbsenceRecord absence, AbsenceCheck check, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(absence);
        ArgumentNullException.ThrowIfNull(check);
        ArgumentNullException.ThrowIfNull(zone);
        var c = SyncText.C;
        var guid = absence.ObjectGuid.ToString("D");
        var status = AbsenceStatus.Unconfirmed;
        string? found = null;
        var proof = "";
        string text;
        IndexRecord? keep = null;
        if (absence.ObjectGuid == Guid.Empty)
        {
            text = "Identité absente" + c + "aucune vérification possible.";
        }
        else if (check.DomainRead != DomainRead.Read)
        {
            text = check.DomainRead == DomainRead.Refused
                ? "Lecture du domaine refusée pour ce compte" + c + "aucune conclusion sur cet objet."
                : "Domaine non lu (contrôleur indisponible ou délai dépassé)" + c + "aucune conclusion.";
        }
        else if (!string.IsNullOrWhiteSpace(check.FoundDn))
        {
            found = check.FoundDn.Trim();
            var move = SyncLocations.Move(absence.LastDn, found, absence.ScopeDn);
            proof = "Objet lu par son GUID dans le domaine.";
            if (move.InScope && (move.Kind is MoveKind.Unchanged or MoveKind.Renamed or MoveKind.MovedWithin))
            {
                status = AbsenceStatus.Visible;
                text = "Objet de nouveau visible dans le périmètre (" + move.ToLocation + ")" + c + "l’absence venait de la lecture ou des droits du moment, pas d’une suppression.";
            }
            else
            {
                status = AbsenceStatus.Moved;
                text = "Objet présent ailleurs dans le domaine" + c + move.ToLocation + ". Il n’a pas été supprimé" + SyncText.Semi + " son identité (GUID) est conservée.";
            }
            if (check.Record is { } record && record.ObjectGuid == absence.ObjectGuid && SyncLocations.Same(record.Dn, found))
            {
                keep = record;
            }
        }
        else if (check.Deleted && check.DeletedRead == DeletedProbe.Read)
        {
            status = AbsenceStatus.Deleted;
            proof = "Objet lu par son GUID parmi les objets supprimés (isDeleted).";
            text = "Suppression constatée" + c + "l’objet figure parmi les objets supprimés";
            if (check.DeletedWhen is { } when)
            {
                text += ", modifié pour la dernière fois le " + SyncText.LocalDateTime(when, zone);
            }
            if (!string.IsNullOrWhiteSpace(check.LastKnownParent))
            {
                var path = SyncLocations.Path(check.LastKnownParent);
                text += SyncText.Semi + " dernier emplacement connu" + c + (path.IsEmpty ? SyncLocations.RootLocation : string.Join(FrenchText.PathSeparator, path));
            }
            text += ".";
            if (check.Recycled)
            {
                text += " L’objet est recyclé" + c + "la plupart de ses attributs ne sont plus conservés.";
            }
        }
        else if (check.DeletedRead == DeletedProbe.Read)
        {
            status = AbsenceStatus.NotFound;
            text = "Absent du domaine et des objets supprimés lisibles" + c + "suppression plus ancienne que leur durée de conservation, ou objet devenu invisible pour ce compte. Aucune conclusion.";
        }
        else if (check.DeletedRead is DeletedProbe.Empty or DeletedProbe.Refused)
        {
            status = AbsenceStatus.Invisible;
            text = "Absent pour ce compte, et aucun objet supprimé n’est visible avec ce compte" + c + "une suppression et un retrait de droits ne se distinguent pas ici.";
        }
        else
        {
            text = "Objets supprimés non lus" + c + "l’absence dans le domaine ne suffit pas à conclure à une suppression.";
        }
        var location = SyncLocations.Location(found ?? absence.LastDn);
        var resolution = new AbsenceResolution(guid, absence.Name, status, Label(status), ToneOf(status), found, location, proof, text);
        return new AbsenceOutcome(resolution, status, found, SyncText.Flat(text, 600), keep);
    }

    /// <summary>
    /// The objects an explicit check reads, oldest first: never verified, or verified without conclusion because the controller
    /// was unavailable. Bounded: one gesture never reads more than <paramref name="limit"/> identities.
    /// </summary>
    public static ImmutableArray<AbsenceRecord> SelectToCheck(IEnumerable<AbsenceRecord> rows, int limit = CheckLimit)
    {
        ArgumentNullException.ThrowIfNull(rows);
        var bound = Math.Clamp(limit, 1, 500);
        return [.. rows.Where(r => (r.Status is AbsenceStatus.NotSeen or AbsenceStatus.Unconfirmed) && r.ObjectGuid != Guid.Empty)
            .OrderBy(r => r.NoticedAt).ThenBy(r => r.ObjectGuid.ToString("D"), StringComparer.Ordinal).Take(bound)];
    }

    /// <summary>
    /// Display row of one stored absence (Domenia 1 ConvertTo-DomeniaAbsenceRow). <paramref name="scopeDn"/> is the scope of the
    /// screen (null for the domain): the row says whether the object was last seen inside it.
    /// </summary>
    public static AbsenceRow Row(AbsenceRecord record, TimeZoneInfo zone, string? scopeDn = null)
    {
        ArgumentNullException.ThrowIfNull(record);
        ArgumentNullException.ThrowIfNull(zone);
        var place = SyncLocations.Location(record.LastDn);
        if (record.Status == AbsenceStatus.Moved && !string.IsNullOrEmpty(record.FoundDn))
        {
            place += " → " + SyncLocations.Location(record.FoundDn);
        }
        var detail = SyncText.Flat(record.Detail, 600);
        if (detail.Length == 0 && record.Status == AbsenceStatus.NotSeen)
        {
            detail = "Absent de la lecture complète du " + SyncText.LocalDateTime(record.NoticedAt, zone) + SyncText.C + "invisible, déplacé ou supprimé. À vérifier avant toute conclusion.";
        }
        return new AbsenceRow(record.ObjectGuid.ToString("D"), record.Status, Label(record.Status), ToneOf(record.Status), record.Name, record.Type, TypeLabel(record.Type),
            record.LastDn, record.FoundDn, place, record.NoticedAt, record.CheckedAt, detail, record.ScopeDn, record.Server,
            scopeDn is null || SyncLocations.InScope(record.LastDn, scopeDn) || (record.FoundDn is { Length: > 0 } found && SyncLocations.InScope(found, scopeDn)));
    }

    /// <summary>
    /// The list of the screen: exact totals by status, the most recent rows, how many are still to verify, and how many were
    /// last seen inside <paramref name="scopeDn"/> (the absences belong to the domain: a domain read records them too).
    /// </summary>
    public static AbsenceList List(IReadOnlyCollection<AbsenceRecord> records, TimeZoneInfo zone, bool canRead, int shownLimit = ShownLimit, string? scopeDn = null)
    {
        ArgumentNullException.ThrowIfNull(records);
        var rows = records.OrderByDescending(r => r.CheckedAt ?? r.NoticedAt).ThenBy(r => r.Name, StringComparer.OrdinalIgnoreCase)
            .Take(Math.Max(1, shownLimit)).Select(r => Row(r, zone, scopeDn)).ToImmutableArray();
        var inScope = scopeDn is null ? records.Count : records.Count(r => SyncLocations.InScope(r.LastDn, scopeDn) || (r.FoundDn is { Length: > 0 } f && SyncLocations.InScope(f, scopeDn)));
        var counts = Enum.GetValues<AbsenceStatus>()
            .Select(s => new AbsenceCount(s, Label(s), records.Count(r => r.Status == s), ToneOf(s)))
            .ToImmutableArray();
        var pending = SelectToCheck(records).Length;
        return new AbsenceList(records.Count, counts, pending, rows.Length, canRead && pending > 0, Summary(records.Count, counts, rows.Length, pending), rows, inScope);
    }

    /// <summary>One line for the list (Domenia 1 Get-DomeniaAbsenceSummary).</summary>
    public static string Summary(int total, IEnumerable<AbsenceCount> counts, int shown, int pending)
    {
        ArgumentNullException.ThrowIfNull(counts);
        if (total <= 0)
        {
            return "Aucune disparition enregistrée. Un objet qu’une lecture complète ne retrouve plus apparaîtra ici au lieu d’être déclaré supprimé.";
        }
        var parts = counts.Where(x => x.Count > 0).Select(x => CountText(x.Status, x.Count)).ToList();
        var text = FrenchText.Count(total, "objet non revu", "objets non revus") + " par une lecture complète";
        if (parts.Count > 0)
        {
            text += SyncText.C + string.Join(", ", parts);
        }
        text += ".";
        if (shown < total)
        {
            text += " Les " + FrenchText.Integer(shown) + " plus récents sont affichés.";
        }
        if (pending > 0)
        {
            text += pending > CheckLimit
                ? " La vérification relit par leur GUID les " + FrenchText.Integer(CheckLimit) + " premiers des " + FrenchText.Integer(pending) + " objets non revus ou non confirmés."
                : pending == 1
                    ? " La vérification relit par son GUID l’objet non revu ou non confirmé."
                    : " La vérification relit par leur GUID les " + FrenchText.Integer(pending) + " objets non revus ou non confirmés.";
        }
        return text;
    }

    /// <summary>
    /// What the base keeps of one census gap read by GUID (Domenia 1 point 22): found as a user or a computer, its row is added
    /// under its GUID and it leaves the list; read but not returned, it leaves the list without conclusion; not read (controller
    /// unavailable, refusal), it stays to read.
    /// </summary>
    public static GapOutcome ResolveGap(CensusGapRecord gap, GapCheck check)
    {
        ArgumentNullException.ThrowIfNull(gap);
        ArgumentNullException.ThrowIfNull(check);
        var c = SyncText.C;
        var guid = gap.ObjectGuid.ToString("D");
        var name = SyncLocations.Name(gap.Dn);
        if (gap.ObjectGuid == Guid.Empty)
        {
            return new GapOutcome(new GapResolution(guid, name, "unconfirmed", "Non lu", Tone.Warn, null, SyncLocations.Location(gap.Dn), "Identité absente" + c + "aucune lecture possible."), null, false);
        }
        if (check.DomainRead == DomainRead.Read)
        {
            var dn = check.FoundDn?.Trim() ?? "";
            if (dn.Length > 0 && check.Record is { } record && record.ObjectGuid == gap.ObjectGuid && SyncLocations.Same(record.Dn, dn))
            {
                var location = SyncLocations.Location(dn);
                return new GapOutcome(new GapResolution(guid, record.Name, "visible", "Ajouté à la base", Tone.Ok, dn, location,
                    "Objet lu par son GUID et ajouté à la base locale (" + location + ")."), record, true);
            }
            if (dn.Length > 0)
            {
                return new GapOutcome(new GapResolution(guid, SyncLocations.Name(dn), "notFound", "Retiré de la liste", Tone.Off, dn, SyncLocations.Location(dn),
                    "Objet lu par son GUID mais ni utilisateur ni poste" + c + "retiré de la liste, rien n’est ajouté."), null, true);
            }
            return new GapOutcome(new GapResolution(guid, name, "notFound", "Retiré de la liste", Tone.Off, null, SyncLocations.Location(gap.Dn),
                "Objet absent de la lecture par GUID" + c + "il n’est plus visible pour ce compte (supprimé, déplacé ou droits retirés). Retiré de la liste, sans conclusion."), null, true);
        }
        var reason = check.DomainRead == DomainRead.Refused
            ? "Lecture du domaine refusée pour ce compte" + c + "l’objet reste à lire."
            : "Domaine non lu pour cet objet" + c + "il reste à lire.";
        return new GapOutcome(new GapResolution(guid, name, "unconfirmed", "Reste à lire", Tone.Warn, null, SyncLocations.Location(gap.Dn), reason), null, false);
    }

    /// <summary>One line for the census gaps of the domain (Domenia 1 Get-DomeniaCensusGapSummary).</summary>
    public static string GapSummary(int total, int shown)
    {
        if (total <= 0)
        {
            return "Aucun objet recensé ne manque dans la base locale.";
        }
        var head = FrenchText.Count(total, "objet présent dans l’AD manque", "objets présents dans l’AD manquent") + " dans la base locale (dernier recensement du domaine).";
        return total <= CheckLimit
            ? head + " Une lecture par GUID " + (total > 1 ? "les relit tous" : "le relit") + ", sans relire tout le domaine."
            : head + " Une lecture par GUID en relit " + FrenchText.Integer(Math.Min(CheckLimit, Math.Max(0, shown))) + " à la fois, sans relire tout le domaine.";
    }

    /// <summary>The census gap list of the screen.</summary>
    public static CensusGapList Gaps(IReadOnlyCollection<CensusGapRecord> gaps, bool canRead)
    {
        ArgumentNullException.ThrowIfNull(gaps);
        var rows = gaps.OrderBy(g => g.SeenAt).ThenBy(g => g.ObjectGuid.ToString("D"), StringComparer.Ordinal).Take(CheckLimit)
            .Select(g => new CensusGapRow(g.ObjectGuid.ToString("D"), g.Dn, SyncLocations.Name(g.Dn), SyncLocations.Location(g.Dn), g.SeenAt))
            .ToImmutableArray();
        return new CensusGapList(gaps.Count, rows.Length, canRead && gaps.Count > 0, GapSummary(gaps.Count, rows.Length), rows);
    }

    /// <summary>Counts of a verification by status, for its result line.</summary>
    public static ImmutableArray<AbsenceCount> Counts(IEnumerable<AbsenceResolution> rows)
    {
        ArgumentNullException.ThrowIfNull(rows);
        var list = rows.ToList();
        return [.. Enum.GetValues<AbsenceStatus>().Select(s => new AbsenceCount(s, Label(s), list.Count(r => r.Status == s), ToneOf(s))).Where(c => c.Count > 0)];
    }

    /// <summary>Sentence of the deleted-objects probe for the page.</summary>
    public static string ProbeText(DeletedProbe probe) => probe switch
    {
        DeletedProbe.Read => "Objets supprimés lisibles par ce compte" + SyncText.C + "une suppression peut être prouvée.",
        DeletedProbe.Empty => "Aucun objet supprimé visible avec ce compte" + SyncText.C + "une absence ne prouve rien.",
        DeletedProbe.Refused => "Lecture des objets supprimés refusée pour ce compte.",
        DeletedProbe.Unavailable => "Objets supprimés non lus (contrôleur indisponible ou délai dépassé).",
        _ => "Objets supprimés non demandés.",
    };
}

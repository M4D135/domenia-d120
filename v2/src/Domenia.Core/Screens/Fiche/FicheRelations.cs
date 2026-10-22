using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>A link to another object of the directory (opens its fiche).</summary>
public sealed record FicheLink(string Dn, string Name, string Kind, string? Detail);

/// <summary>
/// One association between a user and a workstation (Domenia-Relations): its evidence badge and the rule that produced it, never
/// a percentage (Get-DomeniaEvidenceBadge). <see cref="Primary"/>: the declared one first, else the most recent
/// (Select-DomeniaPrimaryRelation).
/// </summary>
public sealed record FicheAssociation(
    string Name,
    string Dn,
    Guid ObjectGuid,
    string Kind,
    string Evidence,
    string EvidenceLabel,
    string Rule,
    DateTimeOffset? When,
    string Source,
    bool Primary);

/// <summary>Relations of an object (fiche.relations): manager and reports, managedBy and what it manages, associations.</summary>
public sealed record FicheRelations(
    string Dn,
    FicheLink? Manager,
    ImmutableArray<FicheLink> Reports,
    FicheLink? ManagedBy,
    ImmutableArray<FicheLink> Manages,
    ImmutableArray<FicheAssociation> Associations,
    string Note);

/// <summary>Last committed measures of one workstation (local base: presence, console account, quick inventory), no read.</summary>
public sealed record FicheObservation(
    string ComputerDn,
    string Computer,
    MeasureState PresenceState,
    bool? Answered,
    DateTimeOffset? PresenceAt,
    DateTimeOffset? LastOnlineAt,
    string? ConsoleUser,
    DateTimeOffset? ConsoleAt,
    MeasureState InventoryState,
    DateTimeOffset? InventoryAt);

/// <summary>Result of fiche.presence: one ping of the workstation (or the associated workstation of a user).</summary>
public sealed record FichePresenceReading(
    string? ComputerDn,
    string? Computer,
    string State,
    string Label,
    DateTimeOffset CheckedAt,
    DateTimeOffset? LastOnline,
    string? ConsoleUser,
    string Detail,
    string? Via);

/// <summary>One session of a workstation (WTS, consultation only).</summary>
public sealed record FicheSessionRow(string User, string State, string Protocol, string? Opened, string? Idle);

/// <summary>Sessions read on one workstation (reader output).</summary>
public sealed record FicheSessionsReading(string ComputerDn, string Computer, string State, ImmutableArray<FicheSessionRow> Rows, int Unread, DateTimeOffset ReadAt, string? Error);

/// <summary>One volume of a quick inventory.</summary>
public sealed record FicheDisk(string Name, long Size, long Free);

/// <summary>One process of a quick inventory: share of the processor over the sample, memory used.</summary>
public sealed record FicheProcess(string Name, double CpuPercent, double MemoryMb);

/// <summary>Quick inventory of one workstation (ComputerInventory of Assistance poste), committed then read back.</summary>
public sealed record FicheInventoryReading(
    string ComputerDn,
    string Computer,
    string State,
    DateTimeOffset ReadAt,
    double? CpuLoad,
    long? MemoryTotal,
    long? MemoryFree,
    ImmutableArray<FicheDisk> Disks,
    ImmutableArray<FicheProcess> Processes,
    double? SampleSeconds,
    DateTimeOffset? LastBoot,
    string? PendingReboot,
    ImmutableArray<string> RebootReasons,
    string? Model,
    string? Os,
    string? Error);

/// <summary>One attribute change kept by the controller (replication metadata), for the history of a fiche.</summary>
public sealed record FicheAttributeChange(string Attribute, DateTimeOffset At, string Controller, int Version);

/// <summary>One event of the history of a fiche (kit timeline: when, title, text, tone, icon, actor, meta).</summary>
public sealed record FicheHistoryEvent(DateTimeOffset When, string Title, string? Text, string Tone, string Icon, string? Actor, string? Meta, string Kind, string? ReceiptId);

/// <summary>Result of fiche.history.</summary>
public sealed record FicheHistory(string Dn, int Receipts, int Pending, ImmutableArray<FicheHistoryEvent> Events, string Note);

/// <summary>Rules of the relations and of the history of a fiche (pure).</summary>
public static class FicheRelationRules
{
    /// <summary>Badge and rule of an association (Get-DomeniaEvidenceBadge, DS-17 labels).</summary>
    public static (string Label, string Rule) Evidence(string evidence) => evidence switch
    {
        "declared" => ("Déclaré", "Association déclarée (managedBy, ou par un opérateur dans Domenia)."),
        "observed" => ("Observé", "Session console lue sur le poste à la date indiquée. Une observation ne vaut pas affectation."),
        "remote" => ("Observé", "Session distante lue sur le poste à la date indiquée. Une observation ne vaut pas affectation."),
        "history" => ("Historique", "Ouverture de session ancienne relevée dans un journal ou un profil. Historique, pas présence actuelle."),
        "hint" => ("Indice", "Attribut AD ou inventaire qui suggère un lien, sans observation de session."),
        _ => ("Source à vérifier", "Origine non reconnue" + FrenchText.Colon + "à vérifier avant de s’y fier."),
    };

    /// <summary>
    /// The association shown first (Select-DomeniaPrimaryRelation): a declared one, else the most recent; the order of the rows
    /// follows (primary first, then the most recent, then by name).
    /// </summary>
    public static ImmutableArray<FicheAssociation> Order(IEnumerable<FicheAssociation> associations)
    {
        ArgumentNullException.ThrowIfNull(associations);
        var list = associations.ToList();
        var primary = list.Where(a => a.Evidence == "declared").OrderByDescending(a => a.When ?? DateTimeOffset.MinValue).FirstOrDefault()
            ?? list.OrderByDescending(a => a.When ?? DateTimeOffset.MinValue).FirstOrDefault();
        return [.. list.Select(a => a with { Primary = ReferenceEquals(a, primary) })
            .OrderByDescending(a => a.Primary).ThenByDescending(a => a.When ?? DateTimeOffset.MinValue).ThenBy(a => a.Name, StringComparer.Ordinal)];
    }

    /// <summary>
    /// History of an object: dates already read (creation, change, password, lockout, logon, expiry), attribute changes kept by the
    /// controller, Domenia receipts on this object (by GUID) and the group changes seen in this session. Most recent first.
    /// </summary>
    public static FicheHistory History(FicheEntry entry, IReadOnlyList<FicheAttributeChange> changes, IReadOnlyList<ReceiptRow> receipts, FicheGroupBaseline? baseline, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(entry);
        ArgumentNullException.ThrowIfNull(changes);
        ArgumentNullException.ThrowIfNull(receipts);
        ArgumentNullException.ThrowIfNull(zone);
        var c = FrenchText.Colon;
        var events = new List<FicheHistoryEvent>();
        if (entry.Generalized("whenCreated") is DateTimeOffset created)
        {
            events.Add(new FicheHistoryEvent(created, "Objet créé", "whenCreated" + c + FicheValues.LocalDateTime(created, zone), "info", "sparkles", null, "Annuaire", "directory", null));
        }
        if (entry.Generalized("whenChanged") is DateTimeOffset changed)
        {
            events.Add(new FicheHistoryEvent(changed, "Dernière modification", "whenChanged (répliqué)" + c + "date de la dernière écriture connue de l’objet.", "off", "edit", null, "Annuaire", "directory", null));
        }
        if (entry.FileTime("pwdLastSet") is DateTimeOffset pwd)
        {
            events.Add(new FicheHistoryEvent(pwd, entry.Kind == FicheKind.Computer ? "Mot de passe machine renouvelé" : "Mot de passe changé", "pwdLastSet", "info", "key", null, "Annuaire", "directory", null));
        }
        else if (entry.Kind == FicheKind.User && entry.Int64("pwdLastSet") == 0)
        {
            events.Add(new FicheHistoryEvent(now, "Mot de passe à changer", "pwdLastSet vaut 0" + c + "l’utilisateur le changera à sa prochaine ouverture de session.", "warn", "key", null, "Annuaire", "directory", null));
        }
        if (entry.FileTime("lockoutTime") is DateTimeOffset locked)
        {
            events.Add(new FicheHistoryEvent(locked, "Verrouillage du compte", "lockoutTime" + c + "dernier verrouillage enregistré par le contrôleur.", "alert", "lock", null, "Annuaire", "directory", null));
        }
        if (entry.FileTime("badPasswordTime") is DateTimeOffset badAt)
        {
            events.Add(new FicheHistoryEvent(badAt, "Dernier mot de passe erroné", "badPasswordTime (propre au contrôleur interrogé, non répliqué).", "warn", "alert", null, "Annuaire", "directory", null));
        }
        if (entry.FileTime("lastLogonTimestamp") is DateTimeOffset logon)
        {
            events.Add(new FicheHistoryEvent(logon, "Ouverture de session (approximative)", "lastLogonTimestamp, répliqué avec un retard pouvant atteindre 14 jours.", "ok", "user", null, "Annuaire", "directory", null));
        }
        if (entry.FileTime("accountExpires") is DateTimeOffset expires)
        {
            events.Add(new FicheHistoryEvent(expires, expires > now ? "Expiration prévue du compte" : "Compte expiré", "accountExpires", expires > now ? "warn" : "alert", "calendar", null, "Annuaire", "directory", null));
        }
        foreach (var change in changes)
        {
            events.Add(new FicheHistoryEvent(change.At, "Attribut modifié" + c + change.Attribute, "Version " + FrenchText.Integer(change.Version) + ", écrite sur " + change.Controller + ".",
                "off", "history", null, "Métadonnées de réplication", "metadata", null));
        }
        foreach (var receipt in receipts)
        {
            events.Add(new FicheHistoryEvent(receipt.At, receipt.Label + (receipt.Simulated ? " (simulation)" : ""), receipt.Summary, receipt.Tone switch
            {
                Tone.Ok => "ok",
                Tone.Warn => "warn",
                Tone.Alert => "alert",
                _ => "info",
            }, "shield", receipt.Operator, receipt.ResultLabel + " · " + receipt.VerificationLabel, "receipt", receipt.Id));
        }
        if (baseline is not null)
        {
            foreach (var row in baseline.Changes)
            {
                events.Add(new FicheHistoryEvent(row.At, (row.Removed ? "Retiré du groupe " : "Ajouté au groupe ") + row.Name, "Constaté entre deux lectures de cette session (première lecture le " + FicheValues.LocalDateTime(baseline.At, zone) + ").",
                    row.Removed ? "warn" : "info", "group", null, "Lectures de la session", "session", null));
            }
        }
        var ordered = events.OrderByDescending(e => e.When).ToImmutableArray();
        var pending = receipts.Count(r => r.Pending);
        const string note = "Dates lues dans l’annuaire, métadonnées de réplication et reçus d’écriture de Domenia sur cet objet. Aucun historique des appartenances n’existe dans la base locale : seuls les changements vus pendant cette session sont signalés.";
        return new FicheHistory(entry.Dn, receipts.Count, pending, ordered, note);
    }
}

/// <summary>memberOf of the first fiche of an object in this session, and the changes seen since (call sheet, history).</summary>
public sealed record FicheGroupBaseline(DateTimeOffset At, ImmutableArray<string> Groups, ImmutableArray<FicheGroupChange> Changes);

/// <summary>One group added or removed since the first fiche of the session.</summary>
public sealed record FicheGroupChange(string Dn, string Name, bool Removed, DateTimeOffset At);

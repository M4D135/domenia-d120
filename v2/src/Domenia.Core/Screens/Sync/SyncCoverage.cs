using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// One coverage line of the base (Domenia 1 table sync_state): « directory » for the checkpoint of the domain, « ou:&lt;dn&gt; »
/// for a complete read of an OU, « attempt:… » for a pass that stopped early. <see cref="Depth"/> is « Subtree », « OneLevel »
/// or null when the line does not prove its depth (old markers). The checkpoint fields are filled for « directory » only.
/// </summary>
public sealed record SyncStateEntry(
    string Key,
    string BaseDn,
    DateTimeOffset LastSync,
    string? Depth,
    bool Partial,
    int Items,
    string? Server,
    long Usn,
    string? InvocationId,
    string? CutReason,
    long CutLimit)
{
    public const string DirectoryKey = "directory";
    public const string AttemptPrefix = "attempt:";

    /// <summary>Key of a complete read of an OU (lower case DN, as Domenia 1 writes it).</summary>
    public static string OuKey(string dn)
    {
        ArgumentNullException.ThrowIfNull(dn);
        return "ou:" + dn.Trim().ToLowerInvariant();
    }

    public bool IsAttempt => Key.StartsWith(AttemptPrefix, StringComparison.OrdinalIgnoreCase);
}

/// <summary>Whether a checkpoint can be reused (Domenia 1 Test-DomeniaSyncCheckpoint).</summary>
public sealed record SyncCheckpointCheck(bool Usable, string Code, string Reason);

/// <summary>Limits of a pass after the rules of Domenia 1 (Get-DomeniaIndexLimits).</summary>
public sealed record SyncPassLimits(long MaxObjects, int BudgetMs, int TimeoutSeconds);

/// <summary>Result of the verified backup rule (Domenia 1 Get-DomeniaGestureBackupDecision).</summary>
public sealed record SyncBackupDecision(bool Due, string Reason, DateTimeOffset? LastAt, int ReuseMinutes);

/// <summary>
/// Pure rules of the coverage of the base and of the directory passes (Domenia 1 points 16 to 22 and DS-09): committed
/// coverage of a scope, census advice, checkpoint reuse, limits and cuts of a pass, readiness, tiles, notices and the
/// verified backup decision. No directory, no disk, no clock: every « now » is a parameter.
/// </summary>
public static class SyncCoverageRules
{
    /// <summary>Index.MaxObjects of Domenia 1: 0 means no object quota.</summary>
    public const long DefaultMaxObjects = 0;

    /// <summary>Index.BudgetMs of Domenia 1: 20 minutes, shared by the plans of a pass.</summary>
    public const int DefaultBudgetMs = 1_200_000;

    /// <summary>Index.FullRebuildDays: age after which a complete read of the chosen scope is advised.</summary>
    public const int DefaultFullRebuildDays = 7;

    /// <summary>Index.StartupDeltaMaxAgeMinutes: age of the base after which an update is advised at startup (never started).</summary>
    public const int DefaultStartupDeltaMaxAgeMinutes = 30;

    /// <summary>A verified backup younger than this is reused as the point of return of a gesture (Domenia 1 FI-13).</summary>
    public const int BackupReuseMinutes = 30;

    /// <summary>Limits of a pass: no negative quota, a budget of 30 s at least (the old default of 4 min becomes 20 min).</summary>
    public static SyncPassLimits Limits(long? maxObjects, int? budgetMs)
    {
        var max = Math.Max(0, maxObjects ?? DefaultMaxObjects);
        var budget = budgetMs ?? DefaultBudgetMs;
        if (budget == 240_000)
        {
            budget = DefaultBudgetMs;
        }
        budget = Math.Max(30_000, budget);
        return new SyncPassLimits(max, budget, Math.Max(300, budget / 1000 + 120));
    }

    /// <summary>
    /// Committed coverage of a scope (Domenia 1 Get-DomeniaFleetFreshness): only a complete read of the scope or of an ancestor
    /// read with its sub-OUs can date it; old markers without depth do not prove their depth; a date in the future is ignored
    /// and makes the clock doubtful; the latest attempt that stopped early is reported when it is not older than the coverage.
    /// </summary>
    public static SyncCoverage Coverage(string? scopeDn, string domainDn, IEnumerable<SyncStateEntry> entries, DateTimeOffset now, TimeZoneInfo zone, bool subtree = true)
    {
        ArgumentNullException.ThrowIfNull(domainDn);
        ArgumentNullException.ThrowIfNull(entries);
        ArgumentNullException.ThrowIfNull(zone);
        var target = string.IsNullOrWhiteSpace(scopeDn) ? domainDn.Trim() : scopeDn.Trim();
        var ancestors = new List<string>();
        for (var current = target; !string.IsNullOrEmpty(current); current = DistinguishedName.Parent(current))
        {
            ancestors.Add(current);
        }
        DateTimeOffset? at = null;
        DateTimeOffset? attemptAt = null;
        DateTimeOffset? legacyAt = null;
        string? source = null;
        string? sourceDepth = null;
        var partial = false;
        var clockInvalid = false;
        foreach (var entry in entries)
        {
            var baseDn = entry.BaseDn.Trim();
            if (baseDn.Length == 0 || !ancestors.Any(a => SyncLocations.Same(a, baseDn)))
            {
                continue;
            }
            var attempt = entry.IsAttempt;
            var coverageKey = attempt ? entry.Key[SyncStateEntry.AttemptPrefix.Length..] : entry.Key;
            var directory = string.Equals(coverageKey, SyncStateEntry.DirectoryKey, StringComparison.OrdinalIgnoreCase);
            var oneLevelKey = coverageKey.StartsWith("ou:onelevel:", StringComparison.OrdinalIgnoreCase);
            if (directory)
            {
                if (!SyncLocations.Same(baseDn, domainDn))
                {
                    continue;
                }
            }
            else if (!SyncLocations.Same(coverageKey.StartsWith("ou:", StringComparison.OrdinalIgnoreCase) ? coverageKey[(oneLevelKey ? 12 : 3)..] : "", baseDn))
            {
                continue;
            }
            if (entry.LastSync > now)
            {
                clockInvalid = true;
                continue;
            }
            var depth = entry.Depth ?? (directory ? "Subtree" : "Unknown");
            if (oneLevelKey && depth != "OneLevel")
            {
                continue;
            }
            var covers = depth == "Subtree" || (depth == "OneLevel" && !subtree && SyncLocations.Same(baseDn, target));
            if (attempt)
            {
                var overlaps = depth == "Subtree" || SyncLocations.Same(baseDn, target);
                if (overlaps && (attemptAt is null || entry.LastSync > attemptAt))
                {
                    attemptAt = entry.LastSync;
                    partial = entry.Partial;
                }
                continue;
            }
            if (!covers)
            {
                if (depth == "Unknown" && (legacyAt is null || entry.LastSync > legacyAt))
                {
                    legacyAt = entry.LastSync;
                }
                continue;
            }
            if (at is null || entry.LastSync > at)
            {
                at = entry.LastSync;
                source = baseDn;
                sourceDepth = depth;
            }
        }
        partial = partial && (at is null || attemptAt >= at);
        var unknown = legacyAt is not null && (at is null || legacyAt > at);
        var status = partial ? CoverageStatus.Partial : at is not null ? CoverageStatus.Complete : unknown ? CoverageStatus.UnknownDepth : CoverageStatus.Missing;
        var sourceLabel = source is null ? null : SyncLocations.Same(source, domainDn) ? "domaine entier" : SyncLocations.ScopePath(source, null);
        var c = SyncText.C;
        var text = status switch
        {
            CoverageStatus.Complete => "Dernière lecture complète couvrant le périmètre" + c + SyncText.LocalDateTime(at!.Value, zone) + " (" + sourceLabel + ").",
            CoverageStatus.Partial => "Dernière tentative incomplète le " + SyncText.LocalDateTime(attemptAt!.Value, zone) + c + "les données reçues sont conservées, la date de lecture complète reste inchangée.",
            CoverageStatus.UnknownDepth => "Profondeur de la dernière lecture inconnue" + c + "elle ne prouve pas la couverture du périmètre.",
            _ => "Aucune lecture complète couvrant ce périmètre.",
        };
        if (clockInvalid)
        {
            text += " Une lecture datée dans le futur a été ignorée" + c + "vérifiez l’horloge de ce poste.";
        }
        return new SyncCoverage(status, at, source, sourceLabel, sourceDepth, attemptAt, partial, clockInvalid, text);
    }

    /// <summary>
    /// Whether the chosen scope needs a complete census (Domenia 1 Get-DomeniaCensusAdvice). A differential read neither sees
    /// an object that became visible without change nor proves an absence: only a complete read of the scope can. Nothing
    /// is started from here.
    /// </summary>
    public static CensusAdvice Census(SyncCoverage coverage, int gapCount, int maxAgeDays, DateTimeOffset now, bool isDomain)
    {
        ArgumentNullException.ThrowIfNull(coverage);
        var days = Math.Clamp(maxAgeDays, 1, 90);
        var gap = Math.Max(0, gapCount);
        int? age = coverage.At is { } at ? (int)Math.Floor((now - at).TotalDays) : null;
        var c = SyncText.C;
        var gapText = "Recensement du domaine" + c + FrenchText.Count(gap, "objet présent dans l’AD manque", "objets présents dans l’AD manquent")
            + " dans la base locale. « Lire les objets manquants » les relit par leur GUID (200 au plus à la fois)" + SyncText.Semi
            + " la mise à jour des changements continue sans eux.";
        const string clockText = "Recensement daté dans le futur : vérifiez l’horloge de ce poste avant de vous y fier.";
        if (coverage.ClockInvalid)
        {
            return new CensusAdvice(CensusState.Clock, true, age, days, gap, gap > 0 ? clockText + " " + gapText : clockText, Tone.Alert);
        }
        if (gap > 0 && isDomain)
        {
            return new CensusAdvice(CensusState.Gap, true, age, days, gap, gapText, Tone.Warn);
        }
        CensusState state;
        string text;
        Tone tone;
        if (coverage.Partial)
        {
            state = CensusState.Partial;
            tone = Tone.Warn;
            text = "Recensement" + c + "la dernière tentative était incomplète. Aucune disparition n’en est déduite" + SyncText.Semi + " relancez la lecture complète de ce périmètre.";
        }
        else if (coverage.At is null || coverage.Status != CoverageStatus.Complete)
        {
            state = CensusState.Absent;
            tone = Tone.Warn;
            text = "Recensement" + c + "aucune lecture complète de ce périmètre. Seule une lecture complète repère les objets disparus ou devenus visibles sans modification.";
        }
        else if (coverage.At > now.AddMinutes(5))
        {
            state = CensusState.Clock;
            tone = Tone.Alert;
            text = clockText;
        }
        else if ((now - coverage.At.Value).TotalDays > days)
        {
            state = CensusState.Due;
            tone = Tone.Warn;
            text = "Recensement complet daté de " + FrenchText.Count(age ?? 0, "jour", "jours") + " (seuil" + c + FrenchText.Count(days, "jour", "jours")
                + "). Relisez ce périmètre pour repérer ce qu’une lecture différentielle ne voit pas" + c + "objets supprimés, devenus visibles ou invisibles pour ce compte.";
        }
        else
        {
            state = CensusState.Recent;
            tone = Tone.Ok;
            text = "Recensement complet de moins de " + FrenchText.Count(days, "jour", "jours") + c + "les disparitions et déplacements de ce périmètre sont à jour à cette date.";
            if (isDomain)
            {
                text += " Chaque mise à jour des changements du domaine recense aussi toutes les identités.";
            }
        }
        if (gap > 0)
        {
            text += " " + gapText;
        }
        return new CensusAdvice(state, state != CensusState.Recent, age, days, gap, text, tone);
    }

    /// <summary>
    /// Whether the checkpoint of the base can be reused (Domenia 1 point 21): same controller, an invocationID, a USN the
    /// instance really committed, the domain scope, a base that still holds what it counted, and no date in the future. Any
    /// doubt gives a complete read; a USN is never carried over to another controller.
    /// </summary>
    public static SyncCheckpointCheck CheckCheckpoint(SyncCheckpoint? checkpoint, string? server, string? domainDn, long objectCount, long highestCommittedUsn, DateTimeOffset now)
    {
        if (checkpoint is null)
        {
            return new SyncCheckpointCheck(false, "Missing", "Aucun repère de synchronisation : lecture complète.");
        }
        if (checkpoint.Usn <= 0)
        {
            return new SyncCheckpointCheck(false, "NoUsn", "Repère sans USN : lecture complète.");
        }
        if (!Guid.TryParse(checkpoint.InvocationId, out var invocation) || invocation == Guid.Empty)
        {
            return new SyncCheckpointCheck(false, "NoInstance", "Repère sans identifiant d’instance du contrôleur (invocationID) : lecture complète.");
        }
        var controller = checkpoint.Controller.Trim();
        if (controller.Length == 0)
        {
            return new SyncCheckpointCheck(false, "NoServer", "Repère sans contrôleur : lecture complète.");
        }
        var current = server?.Trim() ?? "";
        if (current.Length > 0 && !string.Equals(controller, current, StringComparison.OrdinalIgnoreCase))
        {
            return new SyncCheckpointCheck(false, "OtherController", "Repère pris sur " + controller + ", connexion actuelle sur " + current
                + " : lecture complète, aucun USN reporté d’un contrôleur à l’autre.");
        }
        if (!string.IsNullOrWhiteSpace(domainDn) && checkpoint.ScopeDn.Length > 0 && !SyncLocations.Same(checkpoint.ScopeDn, domainDn))
        {
            return new SyncCheckpointCheck(false, "OtherScope", "Repère d’un autre périmètre que le domaine : lecture complète.");
        }
        if (highestCommittedUsn > 0 && checkpoint.Usn > highestCommittedUsn)
        {
            return new SyncCheckpointCheck(false, "UsnAhead", "Repère au-delà du dernier USN validé par ce contrôleur (restauration ou retour arrière) : lecture complète.");
        }
        if (objectCount == 0)
        {
            return new SyncCheckpointCheck(false, "EmptyBase", "Base locale vide malgré un repère : lecture complète.");
        }
        if (objectCount > 0 && checkpoint.Count >= 100 && objectCount * 2 < checkpoint.Count)
        {
            return new SyncCheckpointCheck(false, "BaseShrunk", "Base locale réduite depuis le repère (" + FrenchText.Count(objectCount, "objet", "objets")
                + " pour " + FrenchText.Integer(checkpoint.Count) + " comptés) : lecture complète.");
        }
        if (checkpoint.At > now.AddMinutes(5))
        {
            return new SyncCheckpointCheck(false, "FutureDate", "Repère daté dans le futur : lecture complète.");
        }
        return new SyncCheckpointCheck(true, "Usable", "");
    }

    /// <summary>The limit that cut a pass in plain words (Domenia 1 Get-DomeniaIndexCut and Get-DomeniaIndexPartialText).</summary>
    public static SyncCut Cut(string reason, long limit, int read)
    {
        ArgumentNullException.ThrowIfNull(reason);
        var c = SyncText.C;
        var readText = FrenchText.Count(read, "objet relu", "objets relus") + " dans la passe";
        var text = reason switch
        {
            "volume" => "Passe coupée par la limite de volume (Index.MaxObjects" + c + FrenchText.Count(limit, "objet", "objets") + ")" + c + readText + ".",
            "temps" => "Passe coupée par la limite de temps (Index.BudgetMs" + c + FrenchText.Integer(limit) + " ms, soit " + SyncText.Duration(limit) + ")" + c + readText + ".",
            "serveur" => "Passe coupée par le contrôleur (ServerTimeLimit" + c + FrenchText.Integer(limit) + " s)" + c + readText + ".",
            "arret" => "Lecture arrêtée à la demande de l’opérateur" + c + readText + ", conservés comme lecture partielle.",
            _ => "Au moins une lecture AD a échoué" + c + readText + ".",
        };
        return new SyncCut(reason, limit, text);
    }

    /// <summary>Warning of the home page when the last update of the domain stopped at a limit (Domenia 1 Get-DomeniaIndexPartialText).</summary>
    public static string PartialText(DateTimeOffset at, int count, string? reason, long limit, TimeZoneInfo zone)
    {
        var detail = FrenchText.Count(count, "objet relu", "objets relus") + " dans la passe";
        if (reason == "erreur")
        {
            detail += SyncText.Semi + " au moins une lecture AD a échoué";
        }
        else if (reason == "arret")
        {
            detail += SyncText.Semi + " lecture arrêtée par l’opérateur";
        }
        else if (!string.IsNullOrEmpty(reason))
        {
            detail += " sur une limite de " + FrenchText.Integer(limit) + (reason == "temps" ? " ms" : reason == "serveur" ? " s" : " objets");
        }
        return "la dernière mise à jour était incomplète le " + SyncText.LocalDateTime(at, zone) + " (" + detail + ").";
    }

    /// <summary>
    /// Whether a new directory pass may start (Domenia 1 Test-DomeniaIndexWriteReady): one pass at a time, never during a
    /// commit of the base, a maintenance, a suspended writer or a nearly full disk. Saved branches are kept.
    /// </summary>
    public static SyncReadiness Readiness(bool passRunning, bool committing, string? storageRefusal)
    {
        if (passRunning)
        {
            return new SyncReadiness(false, "Une lecture de l’annuaire est déjà en cours" + SyncText.C + "attendez sa fin ou arrêtez-la.");
        }
        if (committing)
        {
            return new SyncReadiness(false, "Enregistrement local en cours" + SyncText.C + "attendez sa confirmation avant une nouvelle lecture.");
        }
        if (!string.IsNullOrWhiteSpace(storageRefusal))
        {
            return new SyncReadiness(false, storageRefusal);
        }
        return new SyncReadiness(true, null);
    }

    /// <summary>
    /// The four tiles of the base (Domenia 1 Get-DomeniaIndexTiles): accounts, workstations (active and disabled),
    /// associations, last complete read of the chosen scope. An unreadable base shows « — », never zeros.
    /// </summary>
    public static ImmutableArray<SyncTile> Tiles(int users, int computers, int active, int disabled, int links, DateTimeOffset? lastAt, DateTimeOffset now, TimeZoneInfo zone, bool unreadable = false)
    {
        ArgumentNullException.ThrowIfNull(zone);
        if (unreadable)
        {
            return
            [
                new SyncTile("accounts", "Comptes", "—", null, "base illisible", Tone.Off),
                new SyncTile("computers", "Postes", "—", null, "base illisible", Tone.Off),
                new SyncTile("links", "Associations", "—", null, "base illisible", Tone.Off),
                new SyncTile("updated", "Dernière mise à jour", "—", null, "base illisible", Tone.Off),
            ];
        }
        var updatedValue = "Jamais";
        var updatedDetail = "aucune lecture complète de ce périmètre";
        var updatedTone = Tone.Warn;
        if (lastAt is { } at)
        {
            updatedValue = SyncText.Elapsed(at, now);
            updatedDetail = "le " + SyncText.LocalDateTime(at, zone);
            var age = now - at;
            updatedTone = age < TimeSpan.Zero ? Tone.Alert : age.TotalHours < 24 ? Tone.Ok : age.TotalDays <= DefaultFullRebuildDays ? Tone.Info : Tone.Warn;
        }
        return
        [
            new SyncTile("accounts", "Comptes", FrenchText.Integer(Math.Max(0, users)), Math.Max(0, users), "comptes utilisateurs", Tone.Info),
            new SyncTile("computers", "Postes", FrenchText.Integer(Math.Max(0, computers)), Math.Max(0, computers),
                FrenchText.Count(Math.Max(0, active), "actif", "actifs") + " · " + FrenchText.Count(Math.Max(0, disabled), "désactivé", "désactivés"), Tone.Info),
            new SyncTile("links", "Associations", FrenchText.Integer(Math.Max(0, links)), Math.Max(0, links), "liens utilisateur-poste", Tone.Info),
            new SyncTile("updated", "Dernière mise à jour", updatedValue, null, updatedDetail, updatedTone),
        ];
    }

    /// <summary>
    /// Startup notices on the age of the base (Domenia 1 Request-DomeniaIndexAutoRefresh and Request-DomeniaIndexFirstBuild):
    /// nothing long ever starts on its own, the operator is told and decides.
    /// </summary>
    public static ImmutableArray<SyncNotice> Notices(int objects, SyncCheckpoint? checkpoint, string? partial, DateTimeOffset now, int startupMaxAgeMinutes = DefaultStartupDeltaMaxAgeMinutes)
    {
        var notices = ImmutableArray.CreateBuilder<SyncNotice>();
        var c = SyncText.C;
        if (objects <= 0)
        {
            notices.Add(new SyncNotice(Tone.Info, "Aucune base locale" + c + "construction disponible ici, à la main (« Mettre à jour l’OU choisie »). Aucune lecture automatique au démarrage."));
            return notices.ToImmutable();
        }
        if (checkpoint is null)
        {
            notices.Add(new SyncNotice(Tone.Info, "Base locale" + c + "aucune lecture complète du domaine datée (seules des OU ont été lues). Une lecture complète se lance à la main."));
        }
        else
        {
            var minutes = (now - checkpoint.At).TotalMinutes;
            if (minutes >= Math.Max(1, startupMaxAgeMinutes))
            {
                var age = minutes >= 2880 ? FrenchText.Count((long)(minutes / 1440), "jour", "jours")
                    : minutes >= 120 ? FrenchText.Integer((long)(minutes / 60)) + " h"
                    : FrenchText.Integer((long)minutes) + " min";
                notices.Add(new SyncNotice(Tone.Warn, "Changements du domaine lus il y a " + age + c + "mise à jour recommandée, jamais lancée automatiquement."));
            }
        }
        if (!string.IsNullOrEmpty(partial))
        {
            notices.Add(new SyncNotice(Tone.Warn, "À vérifier" + c + partial));
        }
        return notices.ToImmutable();
    }

    /// <summary>
    /// A verified backup of this base younger than <paramref name="reuseMinutes"/> is the point of return of a gesture;
    /// otherwise a new copy is due first. A date in the future never proves a recent copy (Domenia 1 FI-13).
    /// </summary>
    public static SyncBackupDecision Backup(DateTimeOffset? lastSuccess, DateTimeOffset now, int reuseMinutes = BackupReuseMinutes)
    {
        var minutes = Math.Max(0, reuseMinutes);
        if (lastSuccess is not { } last)
        {
            return new SyncBackupDecision(true, "NoBackup", null, minutes);
        }
        if (last > now.AddMinutes(2))
        {
            return new SyncBackupDecision(true, "InvalidClock", last, minutes);
        }
        return last >= now.AddMinutes(-minutes)
            ? new SyncBackupDecision(false, "Recent", last, minutes)
            : new SyncBackupDecision(true, "Stale", last, minutes);
    }

    /// <summary>The sentence of a confirmation, true to what the gesture will do (Domenia 1 Get-DomeniaGestureBackupNotice).</summary>
    public static string BackupNotice(SyncBackupDecision decision, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(decision);
        ArgumentNullException.ThrowIfNull(zone);
        if (!decision.Due && decision.LastAt is { } last)
        {
            return "Point de retour" + SyncText.C + "la sauvegarde vérifiée de " + TimeZoneInfo.ConvertTime(last, zone).ToString("HH':'mm", System.Globalization.CultureInfo.InvariantCulture)
                + " a moins de " + FrenchText.Integer(decision.ReuseMinutes) + " min" + SyncText.Semi + " aucune nouvelle copie.";
        }
        return "Une sauvegarde vérifiée de la base sera faite avant.";
    }

    /// <summary>
    /// Coverage lines of the base for the page (Domenia 1 « couverture et échecs par OU »), most recent first, with a state
    /// per line: complete, old (beyond the census threshold), stopped early or dated in the future.
    /// </summary>
    public static ImmutableArray<SyncScopeState> ScopeStates(IEnumerable<SyncStateEntry> entries, string domainDn, string? domainName, DateTimeOffset now, TimeZoneInfo zone, int maxAgeDays = DefaultFullRebuildDays)
    {
        ArgumentNullException.ThrowIfNull(entries);
        ArgumentNullException.ThrowIfNull(zone);
        var c = SyncText.C;
        return [.. entries.OrderByDescending(e => e.LastSync).Select(entry =>
        {
            var directory = entry.Key.EndsWith(SyncStateEntry.DirectoryKey, StringComparison.OrdinalIgnoreCase);
            var label = directory ? "Domaine entier (repère)" : SyncLocations.Name(entry.BaseDn);
            var path = directory ? (domainName ?? "Domaine") : SyncLocations.ScopePath(entry.BaseDn, domainName);
            var when = SyncText.LocalDateTime(entry.LastSync, zone);
            string state;
            string stateLabel;
            Tone tone;
            string detail;
            if (entry.LastSync > now)
            {
                (state, stateLabel, tone) = ("clock", "Date future", Tone.Alert);
                detail = "Lecture datée du " + when + c + "horloge à vérifier, cette date ne prouve aucune couverture.";
            }
            else if (entry.IsAttempt)
            {
                (state, stateLabel, tone) = ("partial", "Incomplète", Tone.Warn);
                detail = entry.CutReason is { Length: > 0 } reason
                    ? Cut(reason, entry.CutLimit, entry.Items).Text
                    : "Passe incomplète du " + when + c + FrenchText.Count(entry.Items, "objet reçu", "objets reçus") + ", aucune disparition déduite.";
            }
            else if ((now - entry.LastSync).TotalDays > maxAgeDays)
            {
                (state, stateLabel, tone) = ("stale", "Ancienne", Tone.Warn);
                detail = "Lecture complète du " + when + ", au-delà du seuil de " + FrenchText.Count(maxAgeDays, "jour", "jours") + ".";
            }
            else
            {
                (state, stateLabel, tone) = ("complete", "Complète", Tone.Ok);
                detail = "Lecture complète du " + when + c + FrenchText.Count(entry.Items, "objet", "objets") + (entry.Server is { Length: > 0 } s ? " sur " + s : "") + ".";
            }
            return new SyncScopeState(entry.Key, label, entry.BaseDn, path, entry.Depth ?? "Unknown", entry.LastSync, entry.IsAttempt, entry.Partial, entry.Items, entry.Server, state, stateLabel, tone, detail);
        })];
    }

    /// <summary>Lines under the tiles (Domenia 1 LblIndexFreshness): coverage of the scope, partial attempt, census when due.</summary>
    public static ImmutableArray<string> Freshness(int objects, SyncCoverage coverage, string? partial, CensusAdvice census, DateTimeOffset now, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(coverage);
        ArgumentNullException.ThrowIfNull(census);
        var lines = ImmutableArray.CreateBuilder<string>();
        var c = SyncText.C;
        if (objects == 0)
        {
            lines.Add("Aucun objet enregistré. Choisissez un périmètre, puis lancez sa mise à jour.");
        }
        if (coverage.At is { } at)
        {
            var age = at > now.AddMinutes(5) ? "date future" + c + "vérifier l’horloge" : SyncText.Elapsed(at, now);
            lines.Add("Dernière lecture complète couvrant le périmètre" + c + SyncText.LocalDateTime(at, zone) + " (" + age + ").");
            lines.Add("Source de cette lecture" + c + (coverage.SourceLabel ?? coverage.SourceDn ?? "inconnue") + ".");
        }
        else
        {
            lines.Add("Aucune lecture complète couvrant ce périmètre. Choisissez une OU, puis mettez-la à jour.");
        }
        if (coverage.Partial && coverage.AttemptAt is { } attempt)
        {
            lines.Add("Dernière tentative incomplète le " + SyncText.LocalDateTime(attempt, zone) + ". Les données reçues sont conservées" + SyncText.Semi + " la date de lecture complète reste inchangée.");
        }
        if (!string.IsNullOrEmpty(partial))
        {
            lines.Add("À vérifier" + c + partial);
        }
        if (census.Due)
        {
            lines.Add(census.Text);
        }
        return lines.ToImmutable();
    }
}

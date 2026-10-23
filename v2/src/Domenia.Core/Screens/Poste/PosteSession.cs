using System.Collections.Immutable;
using System.Runtime.CompilerServices;

namespace Domenia.Core.Poste;

/// <summary>Kind of authorization of the session for one workstation (Domenia 1 PST-010 and PST-011).</summary>
public enum ConsentKind
{
    /// <summary>Transports that leave a script, a service or a task (program run) for the voluntary actions that follow.</summary>
    Intervention,

    /// <summary>One single read by PsExec or a scheduled task when CIM does not answer.</summary>
    ReadFallback,
}

/// <summary>A stoppable collection of one workstation (relevé, Domenia 1 PST-052): each kind has its own scope.</summary>
public enum CollectionKind
{
    Inventory,
    Diagnostic,
    Probes,
    Detection,
}

/// <summary>One line of the journal of the authorizations (improvement of PST-010): granted, withdrawn, expired, used.</summary>
public sealed record ConsentEvent(DateTimeOffset At, ConsentKind Kind, string Computer, string Action, string Detail);

/// <summary>A collection running in the session: which workstation, which kind, since when (PST-052, named in the page).</summary>
public sealed record RunningCollection(string Dn, string Computer, CollectionKind Kind, string Label, DateTimeOffset Since);

/// <summary>
/// Authorizations, running collections and sealed program arguments of the session, per workstation, shared by the module of
/// the screen, the readers and the write executors of the same source (a program run checks the intervention again just
/// before sending; a read refused by CIM consumes the single fallback read). Memory only: cleared when the session changes
/// (another account or domain) and with the application (never written to disk), never valid for another workstation.
/// Thread safe.
/// </summary>
public sealed class PosteSession
{
    private static readonly ConditionalWeakTable<IDirectorySource, PosteSession> Sessions = new();

    private readonly Lock gate = new();
    private readonly Dictionary<(ConsentKind Kind, string Dn), (DateTimeOffset Until, string Name, Guid? ComputerGuid)> consents = [];
    private readonly Dictionary<(string Dn, CollectionKind Kind), (CancellationTokenSource Source, string Name, DateTimeOffset Since)> collections = [];
    private readonly Dictionary<string, (string Arguments, DateTimeOffset Until)> runArguments = new(StringComparer.Ordinal);
    private readonly List<ConsentEvent> history = [];
    private string? sessionKey;

    public const int DefaultMinutes = 5;
    public const int MinMinutes = 1;
    public const int MaxMinutes = 15;

    /// <summary>Most program arguments kept waiting for their plan (one per pending plan of the circuit at most).</summary>
    public const int MaxKeptArguments = 16;

    /// <summary>The session of a directory source (one per application session).</summary>
    public static PosteSession For(IDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        return Sessions.GetValue(source, static _ => new PosteSession());
    }

    private static string Key(string dn) => dn.Trim().ToUpperInvariant();

    /// <summary>French label of a kind of collection.</summary>
    public static string Label(CollectionKind kind) => kind switch
    {
        CollectionKind.Inventory => "Inventaire",
        CollectionKind.Diagnostic => "Diagnostic",
        CollectionKind.Probes => "Relevé des sondes",
        _ => "Détection de l’utilisateur",
    };

    /// <summary>
    /// Binds the session to the account and domain of the directory session (Domenia 1: authorizations are cleared when the
    /// session changes). A different key withdraws every authorization, stops every collection and forgets sealed arguments.
    /// </summary>
    public bool EnsureSession(string key, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(key);
        lock (gate)
        {
            if (sessionKey is null)
            {
                sessionKey = key;
                return false;
            }
            if (string.Equals(sessionKey, key, StringComparison.Ordinal))
            {
                return false;
            }
            foreach (var consent in consents)
            {
                history.Add(new ConsentEvent(now, consent.Key.Kind, consent.Value.Name, "Retirée", "Effacée : changement de session (autre compte ou autre domaine)."));
            }
            consents.Clear();
            foreach (var running in collections.Values)
            {
                running.Source.Cancel();
            }
            collections.Clear();
            runArguments.Clear();
            sessionKey = key;
            return true;
        }
    }

    /// <summary>Grants an authorization on one workstation for 1 to 15 minutes (5 by default); replaces the previous one of that kind.</summary>
    public ConsentWindow Grant(ConsentKind kind, string dn, string name, int minutes, DateTimeOffset now, Guid? computerGuid = null)
    {
        ArgumentException.ThrowIfNullOrEmpty(dn);
        ArgumentNullException.ThrowIfNull(name);
        var span = Math.Clamp(minutes, MinMinutes, MaxMinutes);
        lock (gate)
        {
            // One workstation at a time per kind: an authorization granted elsewhere is withdrawn and said.
            foreach (var other in consents.Keys.Where(k => k.Kind == kind && k.Dn != Key(dn)).ToList())
            {
                history.Add(new ConsentEvent(now, kind, consents[other].Name, "Retirée", "Remplacée par une autorisation sur " + name + "."));
                consents.Remove(other);
            }
            consents[(kind, Key(dn))] = (now.AddMinutes(span), name, computerGuid);
            history.Add(new ConsentEvent(now, kind, name, "Accordée", FrenchText.Count(span, "minute", "minutes") + (kind == ConsentKind.ReadFallback ? ", une seule lecture" : "")));
            return Window(kind, dn, now);
        }
    }

    /// <summary>Records a refused grant in the journal (an uncertain write on the workstation holds it back, Domenia 1 PST-010).</summary>
    public void NoteRefusal(ConsentKind kind, string name, string reason, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(name);
        ArgumentNullException.ThrowIfNull(reason);
        lock (gate)
        {
            history.Add(new ConsentEvent(now, kind, name, "Refusée", reason));
        }
    }

    /// <summary>Withdraws an authorization at once (« Retirer »); false when there was none.</summary>
    public bool Revoke(ConsentKind kind, string dn, DateTimeOffset now)
    {
        ArgumentException.ThrowIfNullOrEmpty(dn);
        lock (gate)
        {
            if (!consents.Remove((kind, Key(dn)), out var removed))
            {
                return false;
            }
            history.Add(new ConsentEvent(now, kind, removed.Name, "Retirée", "Retirée par l’opérateur."));
            return true;
        }
    }

    /// <summary>True while an authorization of this kind covers this exact workstation.</summary>
    public bool Covers(ConsentKind kind, string dn, DateTimeOffset now, Guid? computerGuid = null)
    {
        ArgumentException.ThrowIfNullOrEmpty(dn);
        lock (gate)
        {
            return consents.TryGetValue((kind, Key(dn)), out var c) && c.Until > now && (computerGuid is null || c.ComputerGuid == computerGuid);
        }
    }

    /// <summary>
    /// Consumes the single fallback read of a workstation (true when one was granted and still valid). Called by a reader only
    /// when CIM refused: without it the read returns « non lu » instead of switching transport (Domenia 1 PST-011, PST-023).
    /// </summary>
    public bool ConsumeReadFallback(string dn, string reading, DateTimeOffset now, Guid? computerGuid = null)
    {
        ArgumentException.ThrowIfNullOrEmpty(dn);
        ArgumentNullException.ThrowIfNull(reading);
        lock (gate)
        {
            if (!consents.TryGetValue((ConsentKind.ReadFallback, Key(dn)), out var c) || c.Until <= now || computerGuid is not null && c.ComputerGuid != computerGuid)
            {
                return false;
            }
            consents.Remove((ConsentKind.ReadFallback, Key(dn)));
            history.Add(new ConsentEvent(now, ConsentKind.ReadFallback, c.Name, "Utilisée", "Lecture de repli consommée par : " + reading + "."));
            return true;
        }
    }

    public ConsentState State(string dn, DateTimeOffset now) => new(Window(ConsentKind.Intervention, dn, now), Window(ConsentKind.ReadFallback, dn, now));

    public ImmutableArray<ConsentEvent> History(DateTimeOffset now)
    {
        lock (gate)
        {
            foreach (var expired in consents.Where(c => c.Value.Until <= now).ToList())
            {
                history.Add(new ConsentEvent(expired.Value.Until, expired.Key.Kind, expired.Value.Name, "Expirée", "Échéance atteinte."));
                consents.Remove(expired.Key);
            }
            return [.. history.OrderByDescending(h => h.At).Take(50)];
        }
    }

    private ConsentWindow Window(ConsentKind kind, string dn, DateTimeOffset now)
    {
        lock (gate)
        {
            var other = consents.Where(c => c.Key.Kind == kind && c.Key.Dn != Key(dn) && c.Value.Until > now).Select(c => c.Value.Name).FirstOrDefault();
            if (consents.TryGetValue((kind, Key(dn)), out var c) && c.Until > now)
            {
                var remaining = (int)Math.Ceiling((c.Until - now).TotalSeconds);
                var text = kind == ConsentKind.Intervention
                    ? "Intervention autorisée sur ce poste pour " + FrenchText.Integer(remaining / 60) + " min " + FrenchText.Integer(remaining % 60).PadLeft(2, '0') + " s"
                    : "Une lecture de repli autorisée (PsExec ou tâche planifiée) pendant " + FrenchText.Count((int)Math.Ceiling(remaining / 60d), "minute", "minutes") + ", consommée par la prochaine lecture refusée par CIM";
                return new ConsentWindow(true, c.Until, remaining, text, null);
            }
            return new ConsentWindow(false, null, 0,
                kind == ConsentKind.Intervention ? "Aucune autorisation d’intervention : accordez-la (5 min) pour exécuter un programme." : "Aucune lecture de repli autorisée : sans elle, une lecture refusée par CIM rend « non lu ».",
                other);
        }
    }

    // ------------------------------------------------------------------ collections (relevés)

    /// <summary>
    /// Starts a stoppable collection of one workstation and one kind (relevé, PST-052). Each kind has its own scope: a
    /// diagnosis never stops an inventory. A second collection of the same kind on the same workstation is refused with a
    /// clear message (nothing is replaced behind the operator's back).
    /// </summary>
    public CancellationTokenSource BeginCollection(string dn, string name, CollectionKind kind, DateTimeOffset now, CancellationToken outer)
    {
        ArgumentException.ThrowIfNullOrEmpty(dn);
        ArgumentNullException.ThrowIfNull(name);
        lock (gate)
        {
            if (collections.ContainsKey((Key(dn), kind)))
            {
                throw new DomeniaOperationException(PosteErrors.Busy, Label(kind) + " déjà en cours sur " + name + " : attendez sa fin ou arrêtez-le. Rien n’a été relancé.");
            }
            var source = CancellationTokenSource.CreateLinkedTokenSource(outer);
            collections[(Key(dn), kind)] = (source, name, now);
            return source;
        }
    }

    /// <summary>Ends a collection (finished or stopped); disposes its token source.</summary>
    public void EndCollection(string dn, CollectionKind kind, CancellationTokenSource source)
    {
        ArgumentException.ThrowIfNullOrEmpty(dn);
        ArgumentNullException.ThrowIfNull(source);
        lock (gate)
        {
            if (collections.TryGetValue((Key(dn), kind), out var current) && ReferenceEquals(current.Source, source))
            {
                collections.Remove((Key(dn), kind));
            }
        }
        source.Dispose();
    }

    /// <summary>
    /// Asks the running collection of one kind (or of every kind when null) of a workstation to stop; what was already read
    /// is returned as a partial result. Returns the kinds asked to stop (empty when none ran).
    /// </summary>
    public ImmutableArray<CollectionKind> StopCollection(string dn, CollectionKind? kind)
    {
        ArgumentException.ThrowIfNullOrEmpty(dn);
        lock (gate)
        {
            var stopped = ImmutableArray.CreateBuilder<CollectionKind>();
            foreach (var entry in collections.Where(c => c.Key.Dn == Key(dn) && (kind is null || c.Key.Kind == kind)).ToList())
            {
                entry.Value.Source.Cancel();
                stopped.Add(entry.Key.Kind);
            }
            return stopped.ToImmutable();
        }
    }

    /// <summary>Collections running in the session, every workstation (the page names the ones of another workstation).</summary>
    public ImmutableArray<RunningCollection> Running()
    {
        lock (gate)
        {
            return [.. collections.OrderBy(c => c.Value.Since).Select(c => new RunningCollection(c.Key.Dn, c.Value.Name, c.Key.Kind, Label(c.Key.Kind), c.Value.Since))];
        }
    }

    public bool IsCollecting(string dn, CollectionKind kind)
    {
        ArgumentException.ThrowIfNullOrEmpty(dn);
        lock (gate)
        {
            return collections.ContainsKey((Key(dn), kind));
        }
    }

    // ------------------------------------------------------------------ program arguments (sealed in memory, PST-016, PST-028)

    /// <summary>
    /// Keeps the arguments of a program run in memory until its plan expires, under their SHA-256 fingerprint: the plan and the
    /// receipt only carry the fingerprint and the length, never the text (a secret passed as an argument is never kept).
    /// </summary>
    public void KeepRunArguments(string digest, string arguments, DateTimeOffset until, DateTimeOffset now)
    {
        ArgumentException.ThrowIfNullOrEmpty(digest);
        ArgumentNullException.ThrowIfNull(arguments);
        lock (gate)
        {
            foreach (var old in runArguments.Where(a => a.Value.Until <= now).Select(a => a.Key).ToList())
            {
                runArguments.Remove(old);
            }
            while (runArguments.Count >= MaxKeptArguments)
            {
                runArguments.Remove(runArguments.MinBy(a => a.Value.Until).Key);
            }
            runArguments[digest] = (arguments, until);
        }
    }

    /// <summary>Takes (and forgets) the arguments of a sealed plan; null when they expired or were never kept.</summary>
    public string? TakeRunArguments(string digest, DateTimeOffset now)
    {
        ArgumentException.ThrowIfNullOrEmpty(digest);
        lock (gate)
        {
            if (!runArguments.Remove(digest, out var kept) || kept.Until <= now)
            {
                return null;
            }
            return kept.Arguments;
        }
    }

    /// <summary>True when the arguments of a sealed plan are still kept (checked again just before sending).</summary>
    public bool HasRunArguments(string digest, DateTimeOffset now)
    {
        ArgumentException.ThrowIfNullOrEmpty(digest);
        lock (gate)
        {
            return runArguments.TryGetValue(digest, out var kept) && kept.Until > now;
        }
    }
}

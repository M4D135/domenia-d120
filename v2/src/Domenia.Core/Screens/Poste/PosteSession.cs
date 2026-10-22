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

/// <summary>One line of the journal of the authorizations (improvement of PST-010): granted, withdrawn, expired, used.</summary>
public sealed record ConsentEvent(DateTimeOffset At, ConsentKind Kind, string Computer, string Action, string Detail);

/// <summary>
/// Authorizations and running collections of the session, per workstation, shared by the module of the screen and the write
/// executors of the same source (a program run checks the intervention again just before sending). Memory only: cleared with
/// the session (never written to disk), never valid for another workstation. Thread safe.
/// </summary>
public sealed class PosteSession
{
    private static readonly ConditionalWeakTable<IDirectorySource, PosteSession> Sessions = new();

    private readonly Lock gate = new();
    private readonly Dictionary<(ConsentKind Kind, string Dn), (DateTimeOffset Until, string Name)> consents = [];
    private readonly Dictionary<string, CancellationTokenSource> collections = new(StringComparer.OrdinalIgnoreCase);
    private readonly List<ConsentEvent> history = [];

    public const int DefaultMinutes = 5;
    public const int MinMinutes = 1;
    public const int MaxMinutes = 15;

    /// <summary>The session of a directory source (one per application session).</summary>
    public static PosteSession For(IDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        return Sessions.GetValue(source, static _ => new PosteSession());
    }

    private static string Key(string dn) => dn.Trim().ToUpperInvariant();

    /// <summary>Grants an authorization on one workstation for 1 to 15 minutes (5 by default); replaces the previous one of that kind.</summary>
    public ConsentWindow Grant(ConsentKind kind, string dn, string name, int minutes, DateTimeOffset now)
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
            consents[(kind, Key(dn))] = (now.AddMinutes(span), name);
            history.Add(new ConsentEvent(now, kind, name, "Accordée", FrenchText.Count(span, "minute", "minutes") + (kind == ConsentKind.ReadFallback ? ", une seule lecture" : "")));
            return Window(kind, dn, now);
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
    public bool Covers(ConsentKind kind, string dn, DateTimeOffset now)
    {
        ArgumentException.ThrowIfNullOrEmpty(dn);
        lock (gate)
        {
            return consents.TryGetValue((kind, Key(dn)), out var c) && c.Until > now;
        }
    }

    /// <summary>Consumes the single fallback read of a workstation (true when one was granted and still valid).</summary>
    public bool ConsumeReadFallback(string dn, DateTimeOffset now)
    {
        ArgumentException.ThrowIfNullOrEmpty(dn);
        lock (gate)
        {
            if (!consents.TryGetValue((ConsentKind.ReadFallback, Key(dn)), out var c) || c.Until <= now)
            {
                return false;
            }
            consents.Remove((ConsentKind.ReadFallback, Key(dn)));
            history.Add(new ConsentEvent(now, ConsentKind.ReadFallback, c.Name, "Utilisée", "Lecture de repli consommée."));
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
                    ? "Intervention autorisée sur ce poste pour " + FrenchText.Integer(remaining / 60) + " min " + FrenchText.Integer(remaining % 60).PadLeft(2, '0') + " s"
                    : "Une lecture de repli autorisée (PsExec ou tâche planifiée), " + FrenchText.Integer(remaining / 60) + " min restantes";
                return new ConsentWindow(true, c.Until, remaining, text, null);
            }
            return new ConsentWindow(false, null, 0,
                kind == ConsentKind.Intervention ? "Aucune autorisation d’intervention : accordez-la (5 min) pour exécuter un programme." : "Aucune lecture de repli autorisée : sans elle, une lecture refusée par CIM rend « non lu ».",
                other);
        }
    }

    /// <summary>Starts a stoppable collection of one workstation (relevé, PST-052); a previous one of the same workstation is stopped.</summary>
    public CancellationTokenSource BeginCollection(string dn, CancellationToken outer)
    {
        ArgumentException.ThrowIfNullOrEmpty(dn);
        var source = CancellationTokenSource.CreateLinkedTokenSource(outer);
        lock (gate)
        {
            if (collections.Remove(Key(dn), out var previous))
            {
                previous.Cancel();
            }
            collections[Key(dn)] = source;
        }
        return source;
    }

    /// <summary>Ends a collection (finished or stopped); disposes its token source.</summary>
    public void EndCollection(string dn, CancellationTokenSource source)
    {
        ArgumentException.ThrowIfNullOrEmpty(dn);
        ArgumentNullException.ThrowIfNull(source);
        lock (gate)
        {
            if (collections.TryGetValue(Key(dn), out var current) && ReferenceEquals(current, source))
            {
                collections.Remove(Key(dn));
            }
        }
        source.Dispose();
    }

    /// <summary>Asks the running collection of a workstation to stop; values already read are kept. False when none runs.</summary>
    public bool StopCollection(string dn)
    {
        ArgumentException.ThrowIfNullOrEmpty(dn);
        lock (gate)
        {
            if (!collections.TryGetValue(Key(dn), out var source))
            {
                return false;
            }
            source.Cancel();
            return true;
        }
    }

    public bool IsCollecting(string dn)
    {
        ArgumentException.ThrowIfNullOrEmpty(dn);
        lock (gate)
        {
            return collections.ContainsKey(Key(dn));
        }
    }
}

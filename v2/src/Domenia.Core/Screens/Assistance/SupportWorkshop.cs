using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace Domenia.Core;

/// <summary>
/// The support workshop of the session (Domenia 1 $script:SupportState and $script:AssistanceLaunched): last objects read, captures
/// A and B, pins, explained incidents and the launches of the recipe steps. Memory only: nothing is written on disk, nothing
/// survives the application. Isolated by session (TRV-185, Domenia 1 Get-DomeniaSupportSessionKey): a change of domain, of
/// account or of connection generation (<see cref="SessionSnapshot.Epoch"/>, a reconnection with the same account included)
/// empties it. One instance per engine context (<see cref="From"/>), thread safe.
/// </summary>
public sealed class SupportWorkshop
{
    public const int PinLimit = 24;
    private const int ReadLimit = 64;

    private readonly EngineContext context;
    private readonly Lock gate = new();
    private readonly Dictionary<string, (SubjectRecord Record, SupportSnapshot Snapshot)> read = new(StringComparer.OrdinalIgnoreCase);
    private readonly LinkedList<string> readOrder = new();
    private readonly List<PinView> pins = [];
    private readonly List<SupportIncident> incidents = [];
    private readonly HashSet<string> seenIncidents = new(StringComparer.Ordinal);
    private readonly Dictionary<string, StepLaunch> launches = new(StringComparer.OrdinalIgnoreCase);
    private (SupportSnapshot Snapshot, bool Historical)? slotA;
    private (SupportSnapshot Snapshot, bool Historical)? slotB;
    private string? sessionKey;
    private string token = "";
    // After a change of session, the journal entries written before it belong to the former session: never collected again.
    private DateTimeOffset? collectFrom;
    private bool sourceIncidentsLoaded;
    private long revision;

    private SupportWorkshop(EngineContext context) => this.context = context;

    public static SupportWorkshop From(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return context.Shared(static c => new SupportWorkshop(c));
    }

    private DateTimeOffset Now => context.Clock.GetUtcNow();

    private TimeZoneInfo Zone => context.Clock.LocalTimeZone;

    /// <summary>Domain root of the session (lower case), used as the scope of the captures and pins.</summary>
    public string Scope { get; private set; } = "";

    /// <summary>
    /// Fingerprint of the session the workshop belongs to (domain, account, connection generation), for the page: nothing of
    /// the account can be read from it. Empty before the first <see cref="SyncAsync"/>.
    /// </summary>
    public string Token
    {
        get
        {
            lock (gate)
            {
                return token;
            }
        }
    }

    /// <summary>Key of a session: domain root, account and connection generation (Domenia 1 epoch + BaseDn + bind account).</summary>
    public static string SessionKey(SessionSnapshot session)
    {
        ArgumentNullException.ThrowIfNull(session);
        var root = (session.Domain?.RootDn ?? session.Domain?.DnsName ?? "").Trim().ToLowerInvariant();
        return root + "|" + session.Account.Login.ToLowerInvariant() + "|" + session.Epoch.ToString(CultureInfo.InvariantCulture);
    }

    /// <summary>
    /// Empties the workshop when the session changed (other domain, other account, or a new connection with the same account):
    /// data never crosses sessions. Returns the token of the current session.
    /// </summary>
    public async Task<string> SyncAsync(CancellationToken cancellationToken)
    {
        var session = await context.Directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        var root = (session.Domain?.RootDn ?? session.Domain?.DnsName ?? "").Trim().ToLowerInvariant();
        var key = SessionKey(session);
        lock (gate)
        {
            if (sessionKey == key)
            {
                return token;
            }
            if (sessionKey is not null)
            {
                collectFrom = Now;
            }
            sessionKey = key;
            token = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes("domenia-assistance-session|" + key)))[..16];
            Scope = root;
            ResetLocked(all: true);
            return token;
        }
    }

    /// <summary>
    /// A read started in the session <paramref name="startedIn"/> answers: if the session changed meanwhile, its answer is
    /// ignored (Domenia 1 Test-DomeniaOfflineDossierState) and nothing of it is kept.
    /// </summary>
    public async Task EnsureSameSessionAsync(string startedIn, string message, CancellationToken cancellationToken)
    {
        var now = await SyncAsync(cancellationToken).ConfigureAwait(false);
        if (!string.Equals(now, startedIn, StringComparison.Ordinal))
        {
            throw new DomeniaOperationException(AssistanceErrors.SessionChanged, message);
        }
    }

    /// <summary>Keeps the last read of an object: the captures and pins freeze it without a new read.</summary>
    public void Remember(SubjectRecord record, SupportSnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(record);
        ArgumentNullException.ThrowIfNull(snapshot);
        lock (gate)
        {
            var key = record.Dn;
            if (read.ContainsKey(key))
            {
                readOrder.Remove(key);
            }
            read[key] = (record, snapshot);
            readOrder.AddLast(key);
            while (readOrder.Count > ReadLimit)
            {
                read.Remove(readOrder.First!.Value);
                readOrder.RemoveFirst();
            }
        }
    }

    public (SubjectRecord Record, SupportSnapshot Snapshot)? LastRead(string dn)
    {
        lock (gate)
        {
            return read.TryGetValue(dn, out var known) ? known : null;
        }
    }

    // ---------------------------------------------------------------- captures

    /// <summary>Freezes the last read of an object into slot A or B (Domenia 1 Set-DomeniaSupportCapture).</summary>
    public void Capture(string slot, string dn)
    {
        var known = LastRead(dn) ?? throw new DomeniaOperationException(AssistanceErrors.NotRead, AssistanceErrors.NotReadMessage);
        var snapshot = known.Snapshot with { Id = Guid.NewGuid().ToString("N"), CapturedAt = Now };
        lock (gate)
        {
            Set(slot, (snapshot, false));
        }
    }

    public void Load(string slot, SupportSnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        lock (gate)
        {
            Set(slot, (snapshot, true));
        }
    }

    public SupportSnapshot Slot(string slot)
    {
        lock (gate)
        {
            var value = slot == "a" ? slotA : slotB;
            return value?.Snapshot ?? throw new DomeniaOperationException(AssistanceErrors.SlotEmpty, AssistanceErrors.SlotEmptyMessage);
        }
    }

    public void Swap()
    {
        lock (gate)
        {
            (slotA, slotB) = (slotB, slotA);
            revision++;
        }
    }

    public void Clear(string? slot)
    {
        lock (gate)
        {
            if (slot is null or "a")
            {
                slotA = null;
            }
            if (slot is null or "b")
            {
                slotB = null;
            }
            revision++;
        }
    }

    private void Set(string slot, (SupportSnapshot, bool) value)
    {
        if (slot == "a")
        {
            slotA = value;
        }
        else
        {
            slotB = value;
        }
        revision++;
    }

    // ---------------------------------------------------------------- pins

    /// <summary>Pins the last read of an object (Domenia 1 Add-DomeniaSupportPin): no duplicate identity, 24 at most.</summary>
    public void Pin(string dn)
    {
        var known = LastRead(dn) ?? throw new DomeniaOperationException(AssistanceErrors.NotRead, AssistanceErrors.NotReadMessage);
        var snapshot = known.Snapshot;
        lock (gate)
        {
            // A pin belongs to the domain of the session (Domenia 1 Add-DomeniaSupportPin): another scope is refused.
            if (!string.Equals(snapshot.Scope, Scope, StringComparison.OrdinalIgnoreCase))
            {
                throw new DomeniaOperationException(AssistanceErrors.PinOtherScope, AssistanceErrors.PinOtherScopeMessage);
            }
            pins.RemoveAll(p => string.Equals(p.Identity, snapshot.Identity, StringComparison.OrdinalIgnoreCase));
            if (pins.Count >= PinLimit)
            {
                throw new DomeniaOperationException(AssistanceErrors.PinsFull, AssistanceErrors.PinsFullMessage);
            }
            pins.Add(new PinView(snapshot.Identity, snapshot.Name, snapshot.Kind, snapshot.KindLabel, known.Record.Dn, snapshot.Scope, Now));
            revision++;
        }
    }

    public void Unpin(string identity)
    {
        lock (gate)
        {
            if (pins.RemoveAll(p => string.Equals(p.Identity, identity, StringComparison.OrdinalIgnoreCase)) == 0)
            {
                throw new DomeniaOperationException(AssistanceErrors.PinUnknown, AssistanceErrors.PinUnknownMessage);
            }
            revision++;
        }
    }

    /// <summary>A pin of this session's domain; a pin of another scope is refused (Domenia 1 Open-DomeniaSupportPin).</summary>
    public PinView FindPin(string identity)
    {
        lock (gate)
        {
            var pin = pins.FirstOrDefault(p => string.Equals(p.Identity, identity, StringComparison.OrdinalIgnoreCase))
                ?? throw new DomeniaOperationException(AssistanceErrors.PinUnknown, AssistanceErrors.PinUnknownMessage);
            if (!string.Equals(pin.Scope, Scope, StringComparison.OrdinalIgnoreCase))
            {
                throw new DomeniaOperationException(AssistanceErrors.PinOtherScope, AssistanceErrors.PinOtherScopeMessage);
            }
            return pin;
        }
    }

    /// <summary>Records where a pinned object stands now (moved since it was pinned).</summary>
    public void Relocate(string identity, string dn)
    {
        lock (gate)
        {
            var index = pins.FindIndex(p => string.Equals(p.Identity, identity, StringComparison.OrdinalIgnoreCase));
            if (index >= 0 && !string.Equals(pins[index].Dn, dn, StringComparison.OrdinalIgnoreCase))
            {
                pins[index] = pins[index] with { Dn = dn };
                revision++;
            }
        }
    }

    public ImmutableArray<PinView> Pins()
    {
        lock (gate)
        {
            return [.. pins];
        }
    }

    // ---------------------------------------------------------------- incidents

    /// <summary>
    /// Collects the warnings and errors of the session journal, and once those the source recorded earlier, classified by the
    /// fixed rules; identical adjacent messages within 2 seconds are ignored and the list keeps the 200 latest.
    /// </summary>
    public void Collect(IEnumerable<RawIncident> sourceIncidents)
    {
        ArgumentNullException.ThrowIfNull(sourceIncidents);
        var fresh = new List<RawIncident>();
        DateTimeOffset? from;
        lock (gate)
        {
            from = collectFrom;
        }
        foreach (var entry in context.Journal.Snapshot())
        {
            if ((entry.Tone is Tone.Warn or Tone.Alert) && (from is null || entry.At >= from))
            {
                fresh.Add(new RawIncident("journal|" + entry.At.UtcTicks.ToString(CultureInfo.InvariantCulture) + "|" + entry.Label, entry.At, entry.Tone, "Session", entry.Label, "session"));
            }
        }
        lock (gate)
        {
            if (!sourceIncidentsLoaded)
            {
                fresh.AddRange(sourceIncidents);
                sourceIncidentsLoaded = true;
            }
            foreach (var raw in fresh.OrderBy(r => r.At))
            {
                if (!seenIncidents.Add(raw.Key))
                {
                    continue;
                }
                var incident = SupportIncidents.Create(raw, Guid.NewGuid().ToString("N"));
                if (SupportIncidents.IsAdjacentDuplicate(incidents.Count > 0 ? incidents[^1] : null, incident))
                {
                    continue;
                }
                incidents.Add(incident);
                if (incidents.Count > SupportIncidents.Limit)
                {
                    incidents.RemoveRange(0, incidents.Count - SupportIncidents.Limit);
                }
                revision++;
            }
        }
    }

    /// <summary>True while the incidents the source recorded earlier have not been loaded yet.</summary>
    public bool NeedsSourceIncidents
    {
        get
        {
            lock (gate)
            {
                return !sourceIncidentsLoaded;
            }
        }
    }

    public SupportIncident Incident(string id)
    {
        lock (gate)
        {
            return incidents.FirstOrDefault(i => string.Equals(i.Id, id, StringComparison.Ordinal))
                ?? throw new DomeniaOperationException(AssistanceErrors.IncidentUnknown, AssistanceErrors.IncidentUnknownMessage);
        }
    }

    public void ClearIncidents()
    {
        lock (gate)
        {
            incidents.Clear();
            revision++;
        }
    }

    // ---------------------------------------------------------------- steps

    private static string LaunchKey(string dn, string recipe, string step) => dn + "|" + recipe + "|" + step;

    public void RecordLaunch(string dn, string recipe, string step, StepLaunch launch)
    {
        ArgumentNullException.ThrowIfNull(launch);
        lock (gate)
        {
            launches[LaunchKey(dn, recipe, step)] = launch;
            revision++;
        }
    }

    public StepLaunch? Launch(string? dn, string recipe, string step)
    {
        if (dn is null)
        {
            return null;
        }
        lock (gate)
        {
            return launches.TryGetValue(LaunchKey(dn, recipe, step), out var launch) ? launch : null;
        }
    }

    /// <summary>Every launch for one object (ticket report), with its recipe and step.</summary>
    public ImmutableArray<(string Recipe, string Step, StepLaunch Launch)> LaunchesFor(string dn)
    {
        var prefix = dn + "|";
        lock (gate)
        {
            return [.. launches.Where(p => p.Key.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)).Select(p =>
            {
                var parts = p.Key[prefix.Length..].Split('|');
                return (parts[0], parts.Length > 1 ? parts[1] : "", p.Value);
            })];
        }
    }

    public RecipeView Recipe(AssistanceRecipe recipe, string? userDn, string? computerDn)
    {
        ArgumentNullException.ThrowIfNull(recipe);
        var steps = recipe.Steps.Select((step, index) => Step(recipe, step, index + 1, userDn, computerDn)).ToImmutableArray();
        var reads = recipe.Steps.Where(s => s.Action is not null).ToList();
        return new RecipeView(recipe.Id, recipe.Title, recipe.Symptom, recipe.Icon, recipe.Added, AssistanceRecipes.PlanText(recipe), recipe.Steps.Length,
            reads.Count(s => s.Subject == AssistanceSubject.User), reads.Count(s => s.Subject == AssistanceSubject.Computer),
            reads.Count(s => s.Privileged), recipe.Steps.Count(s => s.Optional), steps.Count(s => s.State.Phase == StepPhase.Read), steps);
    }

    public StepView Step(AssistanceRecipe recipe, AssistanceStep step, int order, string? userDn, string? computerDn)
    {
        ArgumentNullException.ThrowIfNull(recipe);
        ArgumentNullException.ThrowIfNull(step);
        var dn = step.Subject == AssistanceSubject.User ? userDn : computerDn;
        var launch = Launch(dn, recipe.Id, step.Id);
        var state = AssistanceRecipes.State(step, dn is not null, launch, Zone);
        var action = AssistanceRecipes.FindAction(step.Action);
        return new StepView(order, step.Id, step.Title, step.Subject, AssistanceRecipes.SubjectLabel(step.Subject), step.Action, action?.Label, action?.Operation,
            step.View, step.Reads, step.Why, step.Cost, step.Optional, step.Privileged,
            new StepStateView(state.Phase, state.CanRun, state.CanOpen, state.Text, state.Tone, state.At),
            launch?.Outcome == StepOutcome.Read ? launch.Reading : null,
            launch is { Outcome: not StepOutcome.Read } ? launch.ErrorMessage : null);
    }

    // ---------------------------------------------------------------- views

    public WorkshopView View()
    {
        lock (gate)
        {
            var comparison = SupportComparison.Compare(slotA?.Snapshot, slotB?.Snapshot);
            var items = incidents.AsEnumerable().Reverse().ToImmutableArray();
            var incidentSummary = items.Length == 0
                ? "Aucun avertissement ni erreur dans cette session."
                : AssistanceText.Count(items.Length, "incident", "incidents") + " en mémoire, plafond de " + FrenchText.Integer(SupportIncidents.Limit)
                  + ". Session complète, toutes cibles confondues" + FrenchText.Colon + "aucun rattachement automatique à une fiche.";
            var captures = (slotA is null ? 0 : 1) + (slotB is null ? 0 : 1);
            var summary = AssistanceText.Count(captures, "capture", "captures") + ", " + AssistanceText.Count(pins.Count, "repère", "repères") + ", "
                + AssistanceText.Count(items.Length, "incident", "incidents") + FrenchText.Nbsp + "; en mémoire seulement, rien n’est écrit sur le disque.";
            return new WorkshopView(SlotView("a", slotA), SlotView("b", slotB), comparison, [.. pins], PinLimit,
                new IncidentsView(items.Length, SupportIncidents.Limit, incidentSummary, items), revision, summary, token);
        }
    }

    /// <summary>Revision, session and number of incidents: what the page compares every second while the screen is shown.</summary>
    public (long Revision, string Session, int Incidents) Poll()
    {
        lock (gate)
        {
            return (revision, token, incidents.Count);
        }
    }

    /// <summary>Incidents of the workshop by level, the same ones the « Incidents expliqués » view lists.</summary>
    public (int Warnings, int Errors) IncidentLevels()
    {
        lock (gate)
        {
            return (incidents.Count(i => i.Tone == Tone.Warn), incidents.Count(i => i.Tone == Tone.Alert));
        }
    }

    public (int Captures, int Pins, int Incidents, int Steps) Counts()
    {
        lock (gate)
        {
            return ((slotA is null ? 0 : 1) + (slotB is null ? 0 : 1), pins.Count, incidents.Count, launches.Values.Count(l => l.Outcome == StepOutcome.Read));
        }
    }

    private static CaptureSlotView? SlotView(string slot, (SupportSnapshot Snapshot, bool Historical)? value)
    {
        if (value is not { } known)
        {
            return null;
        }
        var s = known.Snapshot;
        return new CaptureSlotView(slot, s.Name, s.Kind, s.KindLabel, s.Dn, s.Identity, s.Source, SupportReport.SourceLabel(s.Source), s.ObservedAt, s.CapturedAt, s.FieldCount, known.Historical);
    }

    /// <summary>Empties the captures, pins and incidents (Domenia 1 Reset-DomeniaSupportSession); the directory and the base are untouched.</summary>
    public void Reset()
    {
        lock (gate)
        {
            ResetLocked(all: false);
        }
    }

    private void ResetLocked(bool all)
    {
        slotA = null;
        slotB = null;
        pins.Clear();
        incidents.Clear();
        if (all)
        {
            // A new session forgets everything, the incidents already seen and the step launches included.
            read.Clear();
            readOrder.Clear();
            launches.Clear();
            seenIncidents.Clear();
            sourceIncidentsLoaded = false;
        }
        revision++;
    }

    /// <summary>Coverage of a capture for the page.</summary>
    public static CoverageView CoverageOf(SupportSnapshot snapshot, TimeZoneInfo zone)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        ArgumentNullException.ThrowIfNull(zone);
        var provided = snapshot.Fields.Count(f => f.Coverage == FieldCoverage.Provided);
        var partial = snapshot.Fields.Count(f => f.Coverage == FieldCoverage.Partial);
        var missing = snapshot.Fields.Length - provided - partial;
        var source = snapshot.Source switch
        {
            SnapshotSource.Live => "Lecture de l’annuaire",
            SnapshotSource.Cache => "Cache" + FrenchText.Colon + "âge réel non établi",
            _ => "Origine non confirmée",
        };
        var time = TimeZoneInfo.ConvertTime(snapshot.ObservedAt, zone).ToString("HH':'mm':'ss", CultureInfo.InvariantCulture);
        var text = AssistanceText.Count(snapshot.FieldCount, "attribut fourni", "attributs fournis") + " sur " + FrenchText.Integer(snapshot.Fields.Length)
            + " · " + source + " · lecture à " + time;
        return new CoverageView(provided, partial, missing, snapshot.Fields.Length, source, snapshot.ObservedAt, text);
    }
}

using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

namespace Domenia.Core;

public sealed record IncidentOccurrence(string Code, DateTimeOffset At, string Source, string Type, string Message, int Count);

/// <summary>Bounded session correlation. No operation is retried and no identity is required for a diagnostic.</summary>
public sealed partial class SessionIncidents(ITechnicalJournal log, OperationJournal journal, TimeProvider clock)
{
    public const int Capacity = 200;
    private readonly Lock gate = new();
    private readonly Dictionary<string, IncidentOccurrence> entries = new(StringComparer.Ordinal);
    private readonly Dictionary<string, DateTimeOffset> lastWritten = new(StringComparer.Ordinal);

    public static SessionIncidents From(EngineContext context) => context.Shared(static c => new SessionIncidents(c.Log, c.Journal, c.Clock));

    public string Report(string source, Exception error)
    {
        ArgumentNullException.ThrowIfNull(error);
        var safeSource = ShellFaultTracer.IsPlace(source) ? source : "operation";
        var type = error.GetType().Name;
        var original = error.Message;
        // Hash the existing UTF-16 span directly: even an oversized exception needs no second message allocation.
        var signature = type + "|" + safeSource + "|" + Convert.ToHexString(SHA256.HashData(MemoryMarshal.AsBytes(original.AsSpan())));
        var message = Mask(original);
        return Register(safeSource, type, signature, message, original.Length <= 8192 ? error : new InvalidDataException(message));
    }

    /// <summary>The page supplies a digest only; its exception/message/typed values never enter the host journal.</summary>
    public string ReportOpaque(string source, string fingerprint)
    {
        if (!ShellFaultTracer.IsPlace(source) || fingerprint.Length != 64 || !fingerprint.All(char.IsAsciiHexDigit))
            throw new ArgumentException("Empreinte de diagnostic invalide.");
        var signature = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes("UI\n" + source + "\n" + fingerprint.ToUpperInvariant())));
        const string message = "Erreur affichée par l’interface ; texte disponible dans le journal des notifications de cette fenêtre.";
        return Register(source, "Interface", signature, message, new InvalidOperationException(message));
    }

    private string Register(string safeSource, string type, string signature, string message, Exception error)
    {
        var now = clock.GetUtcNow();
        lock (gate)
        {
            var found = entries.TryGetValue(signature, out var prior);
            if (!found && entries.Count >= Capacity)
            {
                var oldest = entries.MinBy(p => p.Value.At).Key;
                entries.Remove(oldest); lastWritten.Remove(oldest);
            }
            // Full random identifier avoids four-hex-digit collisions over long sessions and across log rotations.
            var item = new IncidentOccurrence(prior?.Code ?? "INC-" + Guid.NewGuid().ToString("N").ToUpperInvariant(), now,
                safeSource, type, message, prior is null ? 1 : Math.Min(int.MaxValue - 1, prior.Count) + 1);
            entries[signature] = item;
            if (!found || now - lastWritten[signature] >= TimeSpan.FromMinutes(1) || now < lastWritten[signature])
            {
                lastWritten[signature] = now;
                var line = item.Code + " · " + safeSource + " · " + type + " · " + item.Count.ToString(CultureInfo.InvariantCulture) + " occurrence(s) · " + message;
                log.Error(line, error);
                journal.Add(new(now, line, Tone.Alert));
            }
            return item.Code;
        }
    }

    public ImmutableArray<IncidentOccurrence> Snapshot() { lock (gate) return [.. entries.Values.OrderByDescending(i => i.At)]; }

    public static string Mask(string? message)
    {
        var text = message ?? "";
        if (text.Length > 8192) return "Message hors limites ; contenu non conservé.";
        try { return SupportSecretMask.Protect(text); }
        catch (RegexMatchTimeoutException) { return "Message non conservé : masquage hors délai."; }
    }

    public static string? CodeIn(string? text) => text is null ? null : CodePattern().Match(text.Length > 8192 ? text[..8192] : text) is { Success: true } match ? match.Value : null;
    [GeneratedRegex(@"\bINC-[0-9A-F]{4,32}\b", RegexOptions.CultureInvariant, 100)]
    private static partial Regex CodePattern();
}

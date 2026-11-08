using System.Collections.Immutable;

namespace Domenia.Core;

public sealed record SwallowedEntry(DateTimeOffset At, string Category, string Operation, string Type, string Message);

/// <summary>Memory only, bounded and thread safe; pure rules can record a handled failure without touching a file.</summary>
public sealed class SwallowedDiagnostics
{
    public const int Capacity = 200;
    public static SwallowedDiagnostics Process { get; } = new();
    private readonly Lock gate = new();
    private readonly Queue<SwallowedEntry> entries = new();

    public void Record(string category, string operation, string type, string? message, DateTimeOffset at)
    {
        var item = new SwallowedEntry(at, Identifier(category), Identifier(operation), Identifier(type), SessionIncidents.Mask(message));
        lock (gate)
        {
            if (entries.Count == Capacity) entries.Dequeue();
            entries.Enqueue(item);
        }
    }
    private static string Identifier(string? value) => ShellFaultTracer.IsPlace(value) ? value! : "inconnu";
    public ImmutableArray<SwallowedEntry> Snapshot() { lock (gate) return [.. entries.Reverse()]; }
}

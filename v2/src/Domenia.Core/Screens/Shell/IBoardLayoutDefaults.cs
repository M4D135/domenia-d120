using System.Collections.Immutable;
using Domenia.Core.Accueil;

namespace Domenia.Core;

public sealed record BoardLayoutDefault(string Board, string SourceSha256, string Source, string Summary, ImmutableArray<FleetLayoutItem> Items);

/// <summary>Explicit local team defaults; hold requalifies under the preference lock and remains held through its commit.</summary>
public interface IBoardLayoutDefaults : IScreenReader
{
    BoardLayoutDefault Read(string board, CancellationToken token);
    IDisposable Hold(string board, string expectedSha256, CancellationToken token);
}

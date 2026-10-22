using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;

namespace Domenia.App;

/// <summary>
/// Host side of the search screen: hands the engine the reading of Domenia.config.json next to the executable, where an
/// administrator turns on the revalidation of the listed objects (Streaming.RevalidateListedObjects, RCH-073) and hides or
/// greys actions of the screen (UI.Elements, GuiElementPolicy of Domenia 1, RCH-067). Read on demand (search.policy), at most
/// 64 Kio, never written; a file absent, too large or unreadable gives the defaults of Domenia 1 and a line of the technical
/// journal. Declares no operation of its own. Public for the composition.
/// </summary>
public sealed class SearchHostOperations : IOperationModule
{
    private const long MaxBytes = 64 * 1024;

    public string Screen => "search";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        var file = Path.Combine(AppPaths.AppDirectory, "Domenia.config.json");
        SearchService.From(context).UseConfiguration(() => Read(file));
        return [];
    }

    /// <summary>Root of the configuration file, or null when it is absent or too large (the caller traces the errors).</summary>
    internal static JsonElement? Read(string file)
    {
        var info = new FileInfo(file);
        if (!info.Exists || info.Length > MaxBytes)
        {
            return null;
        }
        using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        using var document = JsonDocument.Parse(stream, new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true });
        return document.RootElement.Clone();
    }
}

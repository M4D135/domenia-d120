using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>
/// OU tree panel (docs/OPERATIONS.md § 9 and 10): children of an OU and search by name or path. LocalRead in simulation
/// (fictitious directory in memory), NetworkRead in directory mode (the tree is read from the directory, bounded, after the
/// operator opens the panel).
/// </summary>
public sealed class DirectoryTreeOperations : IOperationModule
{
    /// <summary>Most OUs returned by a search.</summary>
    public const int SearchLimit = 50;

    /// <summary>Longest search text.</summary>
    public const int MaxSearchLength = 100;

    private static readonly string[] ChildrenArguments = ["dn"];
    private static readonly string[] SearchArguments = ["text"];

    public string Screen => "directory";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        var readers = context.Readers;
        var readClass = context.Mode == AppMode.Simulation ? OperationClass.LocalRead : OperationClass.NetworkRead;
        return
        [
            new OperationDefinition("directory.ou.children", readClass, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, ChildrenArguments);
                var dn = BridgeArguments.GetOptionalString(values, "dn");
                if (dn is not null)
                {
                    BridgeArguments.RequireDistinguishedName(dn, "dn");
                }
                var tree = readers.Require<IDirectoryTreeReader>();
                return await tree.ChildrenAsync(dn, cancellationToken).ConfigureAwait(false);
            }, "OU enfants d’une OU, ou de la racine du domaine, avec chemin et nombre d’objets."),

            new OperationDefinition("directory.ou.search", readClass, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, SearchArguments);
                var text = BridgeArguments.GetString(values, "text");
                if (text.Length > MaxSearchLength)
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("text") + " doit faire au plus " + FrenchText.Integer(MaxSearchLength) + " caractères.");
                }
                var tree = readers.Require<IDirectoryTreeReader>();
                // The contract answers the OUs themselves (array, same element shape as the children).
                var found = await tree.SearchAsync(text, SearchLimit, cancellationToken).ConfigureAwait(false);
                return found.Results;
            }, "Au plus 50 OU dont le nom ou le chemin contient le texte, sans accent ni casse."),
        ];
    }
}

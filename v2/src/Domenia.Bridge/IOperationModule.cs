using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>
/// The operations of one screen (docs/PLATFORM.md). Each screen implements this interface in its own file; the
/// composition finds every module by reflection (<see cref="OperationModules.Discover"/>), so adding a screen never edits a
/// central list. A module is a public, non-abstract class with a public parameterless constructor; every operation it
/// declares is named « &lt;Screen&gt;.&lt;verb&gt; » (« dashboard.summary », « directory.ou.children »).
/// </summary>
public interface IOperationModule
{
    /// <summary>First segment of every operation of the module, lower camel case (« dashboard », « session »).</summary>
    string Screen { get; }

    /// <summary>
    /// Declares the operations. Runs once at startup, on the UI thread: nothing is read here, services are only kept for
    /// the handlers (they run off the UI thread).
    /// </summary>
    IEnumerable<OperationDefinition> CreateOperations(EngineContext context);
}

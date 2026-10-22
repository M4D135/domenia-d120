using Domenia.Bridge;
using Domenia.Core;
using Domenia.Core.Accueil;

namespace Domenia.App;

/// <summary>
/// Host facts of the home page. « Ouvrir le journal » (Domenia 1, BtnDashOpenLog, ACC-019): the last lines of the technical journal,
/// read by the host that owns it (%LOCALAPPDATA%\Domenia\logs\domenia.log) and shown in the page instead of opening another
/// program; LocalRead, bounded (256 Kio, 200 lines); the journal never holds page input nor secrets by design. The free space of the
/// volume of the data folder, measured just before an OU refresh (ACC-001: new collections stop under 512 Mio in directory mode).
/// Public for the composition.
/// </summary>
public sealed class AccueilJournalOperations : IOperationModule
{
    public string Screen => "accueil";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        AccueilService.From(context).UseStorageProbe(() => AccueilHostFiles.FreeBytes(AppPaths.UserData));
        return
        [
            new OperationDefinition("accueil.log.tail", OperationClass.LocalRead, async (args, _, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                return await AccueilHostFiles.TailAsync(TechnicalLog.FilePath, cancellationToken, context.Log.Warning).ConfigureAwait(false);
            }, "Dernières lignes du journal technique de Domenia (lecture locale, bornée)."),
        ];
    }
}

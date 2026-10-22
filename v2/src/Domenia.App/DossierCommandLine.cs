using System.Collections.Immutable;
using System.Runtime.InteropServices;
using System.Text;
using Domenia.Ad;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Inventory;
using Domenia.Simulation;
using Domenia.Store;

namespace Domenia.App;

/// <summary>
/// « Domenia.exe dossier » (Domenia 1 « Domenia-Automate.ps1 dossier », docs/ops/assistance.md § 6.1): the offline diagnostic
/// dossier from the command line, without opening the window. The arguments are checked by
/// <see cref="OfflineDossierCommand"/>; the rows come from the local index of the mode only (never the network nor the directory),
/// the dossier is the same as the screen writes (<see cref="OfflineDossierRunner"/>), in a new dated folder under the local
/// folder the operator names (a share, a network drive or a link is refused). The summary goes to the standard output in UTF-8;
/// the exit codes are those of Domenia 1: 0 success, 2 invalid command, 3 local base unavailable, 4 refusal, 5 not written.
/// Domenia.exe is a window application: typed in a console, it attaches to the console of its parent so that the summary is
/// shown there; PowerShell waits for it with « Start-Process -Wait -PassThru » (or « cmd /c start /wait ») to read the code.
/// </summary>
internal static partial class DossierCommandLine
{
    private const int AttachParentProcess = -1;

    public static int Run(IReadOnlyList<string> args)
    {
        // A redirected output (pipe, file) is used as is; otherwise the summary goes to the console of the parent, if any.
        if (!Console.IsOutputRedirected && !AttachConsole(AttachParentProcess))
        {
            TechnicalLog.Info("Commande dossier : aucune console parente, le résumé ira à la sortie standard si elle est redirigée.");
        }
        var request = OfflineDossierCommand.Parse(args);
        if (!request.Valid)
        {
            return Refuse(request.Error, request.ExitCode);
        }
        var decision = ModeResolver.Resolve(
            request.Remaining,
            Environment.GetEnvironmentVariable(ModeResolver.SimulationVariable),
            DomainJoin.Read,
            static () => LegacyConfigurationFile.Read(AppPaths.AppDirectory, AppTechnicalJournal.Instance).DemoProvider);
        TechnicalLog.Info($"Commande dossier : mode {decision.Mode}, raison {decision.Reason}.");
        if (FileDocumentStore.CheckLocalFolder(request.Output) is { } folderRefusal)
        {
            return Refuse(folderRefusal, OfflineDossierCommand.WriteFailed);
        }
        var log = AppTechnicalJournal.Instance;
        IDirectorySource source = decision.Mode == AppMode.Simulation
            ? new SimulatedDirectorySource(SimulationOptions.Default, TimeProvider.System)
            : new AdDirectorySource(decision.JoinedDomain, static () => Environment.UserDomainName + "\\" + Environment.UserName, TimeProvider.System, new WmiWorkstationProbe(TimeProvider.System, log));
#pragma warning disable CA1031 // Any failure ends the command with a French reason and an exit code, never a crash dialog.
        try
        {
            return RunAsync(request, source, log).GetAwaiter().GetResult();
        }
        catch (DomeniaOperationException ex)
        {
            TechnicalLog.Warning($"Commande dossier refusée : {ex.Code}.");
            return Refuse(ex.Message, ex.Code switch
            {
                AssistanceErrors.DossierPerimeter => OfflineDossierCommand.Refused,
                DomeniaErrors.SourceUnavailable => OfflineDossierCommand.BaseUnavailable,
                _ => OfflineDossierCommand.WriteFailed,
            });
        }
        catch (Exception ex)
        {
            TechnicalLog.Error("Commande dossier en échec.", ex);
            return Refuse("Dossier non produit" + FrenchText.Colon + "erreur imprévue, le détail technique est dans le journal de l’application.", OfflineDossierCommand.WriteFailed);
        }
#pragma warning restore CA1031
        finally
        {
            (source as IDisposable)?.Dispose();
        }
    }

    private static async Task<int> RunAsync(OfflineDossierRequest request, IDirectorySource source, ITechnicalJournal log)
    {
        var ct = CancellationToken.None;
        var readers = ScreenReaders.Discover(source, OperationModules.LoadDomeniaAssemblies());
        if (readers.Find<IAssistanceIndex>() is not { } index)
        {
            return Refuse("Base locale indisponible dans ce mode" + FrenchText.Colon + "le dossier hors ligne n’est servi qu’en simulation tant que la base locale de cette version n’est pas branchée.",
                OfflineDossierCommand.BaseUnavailable);
        }
        var session = await source.GetSessionAsync(ct).ConfigureAwait(false);
        DossierPerimeter perimeter;
        var unresolved = 0;
        string? single = null;
        if (request.OrganizationalUnit is { } ou)
        {
            var entry = readers.Find<IOrganizationalUnitIndex>() is { } ous ? await ous.FindLocalAsync(ou, ct).ConfigureAwait(false) : null;
            if (entry is null)
            {
                return Refuse("OU inconnue de la base locale" + FrenchText.Colon + FrenchText.Quote(ou) + ".", OfflineDossierCommand.Refused);
            }
            perimeter = OfflineDossiers.Perimeter(DossierScope.Branch, null, null, session.Domain?.RootDn, [], new ScopeSelection(entry.Dn, entry.Name, true));
        }
        else if (request.Names.Length > 0)
        {
            var found = await index.ComputersNamedAsync(request.Names, ct).ConfigureAwait(false);
            var matched = new HashSet<string>(found.Select(f => f.Name), StringComparer.OrdinalIgnoreCase);
            unresolved = request.Names.Count(n => !matched.Contains(n));
            ImmutableArray<OfflineDossiers.Workstation> listed = [.. found.Select(f => new OfflineDossiers.Workstation(f.Guid.ToString("D"), f.Computer.Name))];
            single = listed.Length == 1 ? listed[0].Name : null;
            perimeter = OfflineDossiers.Perimeter(DossierScope.List, null, null, session.Domain?.RootDn, [], listed: listed, unresolved: unresolved);
        }
        else
        {
            perimeter = OfflineDossiers.Perimeter(DossierScope.List, null, null, session.Domain?.RootDn, [],
                listed: request.Guids.Select(g => new OfflineDossiers.Workstation(g, g)));
        }
        if (!perimeter.Valid)
        {
            return Refuse(perimeter.Error ?? "Périmètre du dossier refusé.", OfflineDossierCommand.Refused);
        }
        var store = new FileDocumentStore(Path.GetFullPath(request.Output), log, static (_, _) => { });
        var result = await OfflineDossierRunner.RunAsync(index, store, perimeter, request.Sections, OfflineDossierRunner.FolderSubject(perimeter, single),
            ProductInfo.Version, TimeProvider.System, unresolved, null, ct).ConfigureAwait(false);
        var lines = new List<string> { result.Message, "Dossier" + FrenchText.Colon + result.Path };
        lines.AddRange(result.Files.Select(f => f.Sha256 + "  " + f.Name + " (" + f.Size + ")"));
        Write(string.Join(Environment.NewLine, lines));
        TechnicalLog.Info($"Commande dossier : {result.Files.Length} fichiers écrits, {unresolved} nom(s) inconnu(s).");
        return OfflineDossierCommand.Success;
    }

    private static int Refuse(string reason, int code)
    {
        Write(reason);
        return code;
    }

    /// <summary>
    /// Standard output in UTF-8: a window application has no console code page to follow; the handle belongs to the parent
    /// process and stays open. Nothing secret is ever written (the dossier itself excludes the secrets).
    /// </summary>
    private static void Write(string text)
    {
        try
        {
            using var writer = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(encoderShouldEmitUTF8Identifier: false), bufferSize: -1, leaveOpen: true);
            writer.WriteLine(text);
        }
        catch (IOException ex)
        {
            TechnicalLog.Warning($"Sortie standard non écrite : {ex.GetType().Name}.");
        }
    }

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool AttachConsole(int processId);
}

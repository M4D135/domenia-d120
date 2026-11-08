using System.Collections.Immutable;
using System.Text;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

internal static class RemotePsExecPlan
{
    internal static string ServiceName(RemoteTaskReadPlan plan) => "Domenia2PX_" + plan.Id.ToString("N");
    internal static string ServiceFile(RemoteTaskReadPlan plan) => ServiceName(plan) + ".exe";

    internal static RemoteTaskReadPlan Create(DirectoryComputer computer, string storeId, string account, DateTimeOffset at,
        RemoteTaskReadKind kind, SoftwareRequest? software = null) => RemoteTaskReadProgram.Plan(computer, storeId, account, at, kind, software)
            with { Transport = RemoteReadTransport.PsExec, PsExecSha256 = RemotePsExecBinary.ApprovedSha256 };

    internal static void Validate(RemoteTaskReadPlan plan, RemoteProbeCredential? credential)
    {
        RemoteTaskReadRules.Validate(plan, plan.PreparedAt);
        if (plan.Transport != RemoteReadTransport.PsExec || plan.PsExecSha256 != RemotePsExecBinary.ApprovedSha256
            || RemoteTaskReadProgram.Hash(RemoteTaskReadProgram.Script(plan)) != plan.ScriptSha256)
        { throw new InvalidDataException("Plan PsExec ou binaire non approuvé ; aucun contact."); }
        if (credential is { Session: false } || credential?.Password is not null)
        { throw new DomeniaOperationException("poste.psexec.session", "PsExec exige le contexte Windows intégré ; aucun compte explicite ni mot de passe n’est transmis."); }
    }

    internal static byte[] ProgramBytes(RemoteTaskReadPlan plan)
    {
        Validate(plan, null); var content = new UTF8Encoding(false, true).GetBytes(RemoteTaskReadProgram.Script(plan));
        if (content.Length > 256 * 1024) { throw new InvalidDataException("Programme distant hors limite de 256 Kio."); }
        // Windows PowerShell 5.1 needs a BOM to read UTF-8 script files unambiguously. ScriptSha256 binds the source bytes.
        return [0xef, 0xbb, 0xbf, .. content];
    }

    internal static ImmutableArray<string> Arguments(RemoteTaskReadPlan plan, string windowsFolder)
    {
        Validate(plan, null);
        if (windowsFolder.Length is < 4 or > 200 || windowsFolder[1] != ':' || windowsFolder[2] != '\\' || !char.IsAsciiLetter(windowsFolder[0])
            || windowsFolder.Any(c => char.IsControl(c) || c is '"' or '%' or '/' or '\'') || windowsFolder[3..].Contains(':')
            || System.IO.Path.GetFullPath(windowsFolder) != windowsFolder || windowsFolder.EndsWith('\\'))
        { throw new InvalidDataException("Répertoire Windows distant non qualifié."); }
        var arguments = ImmutableArray.Create(@"\\" + plan.Host, "-accepteula", "-nobanner", "-n", "10", "-r", ServiceName(plan), "-s",
            windowsFolder + @"\System32\WindowsPowerShell\v1.0\powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
            windowsFolder + @"\Temp\" + plan.DirectoryName + @"\read.ps1");
        // This is the native Windows process command-line ceiling, including executable and quoting overhead.
        if (arguments.Sum(a => a.Length + 3) > 30_000) { throw new InvalidDataException("Programme PsExec trop long pour une ligne de commande Windows ; aucun envoi."); }
        return arguments;
    }
}

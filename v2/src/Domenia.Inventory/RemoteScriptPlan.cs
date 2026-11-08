using System.Text;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

/// <summary>A closed program shared by the consented launchers, never operator-supplied script text.</summary>
internal static class RemoteScriptPlan
{
    internal static RemoteTaskReadPlan Create(DirectoryComputer computer, string storeId, string account, DateTimeOffset now,
        RemoteReadTransport transport, RemoteTaskReadKind kind, SoftwareRequest? software = null)
    {
        if (transport is not (RemoteReadTransport.WmiProcess or RemoteReadTransport.WinRmScript)) { throw new ArgumentOutOfRangeException(nameof(transport)); }
        return RemoteTaskReadProgram.Plan(computer, storeId, account, now, kind, software) with { Transport = transport };
    }

    internal static byte[] ProgramBytes(RemoteTaskReadPlan plan)
    {
        RemoteTaskReadRules.Validate(plan, plan.PreparedAt);
        var script = RemoteTaskReadProgram.Script(plan);
        if (RemoteTaskReadProgram.Hash(script) != plan.ScriptSha256) { throw new InvalidDataException("Programme distant différent du plan."); }
        var bytes = new UTF8Encoding(false, true).GetBytes(script);
        if (bytes.Length > 256 * 1024) { throw new InvalidDataException("Programme distant hors limite."); }
        return [0xef, 0xbb, 0xbf, .. bytes];
    }

    internal static string WindowsFolder(string value)
    {
        if (value.Length is < 4 or > 200 || value[1] != ':' || value[2] != '\\' || !char.IsAsciiLetter(value[0])
            || value.Any(c => char.IsControl(c) || c is '"' or '%' or '/' or '\'' or '&' or '|' or '<' or '>' or '^')
            || value[3..].Contains(':') || Path.GetFullPath(value) != value || value.EndsWith('\\'))
        { throw new InvalidDataException("Répertoire Windows distant non qualifié."); }
        return value;
    }

    internal static string Command(RemoteTaskReadPlan plan, string windowsFolder)
    {
        _ = ProgramBytes(plan); WindowsFolder(windowsFolder);
        return "\"" + windowsFolder + "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe\" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \""
            + windowsFolder + "\\Temp\\" + plan.DirectoryName + "\\read.ps1\"";
    }
}

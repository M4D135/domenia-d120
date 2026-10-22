using System.Collections.Immutable;
using System.Text;
using System.Xml;
using System.Xml.Linq;
using Domenia.Core;
using Domenia.Core.Queries;

namespace Domenia.Bridge.Operations.Requetes;

/// <summary>Cmdlets of the installed modules, read from their help files, with the folder they came from.</summary>
internal sealed record InstalledCmdlets(ImmutableArray<QueryCmdlet> Cmdlets, ImmutableArray<string> Modules, ImmutableArray<string> Files, DateTimeOffset ReadAt);

/// <summary>
/// Reference of the ActiveDirectory and LAPS cmdlets installed on the operator's computer (Domenia 1 Load-AdCmdlets and
/// Start-SelectedCmdletHelp): the help files (MAML) of the modules are read locally, never PowerShell itself, never the network.
/// Name, module, verb (write or read), -Credential, synopsis, syntax, parameters, examples and the full help text. Read once
/// per session on the operator's gesture; files over 64 Mio and DTDs are refused.
/// </summary>
internal sealed class QueryCmdletHelp
{
    private const long MaxFileBytes = 64L * 1024 * 1024;
    private const int MaxCmdlets = 2000;
    private static readonly string[] Modules = ["ActiveDirectory", "LAPS", "AdmPwd.PS"];
    private static readonly string[] WriteVerbs = ["Add", "Clear", "Disable", "Enable", "Grant", "Install", "Move", "New", "Remove", "Rename", "Reset", "Restore", "Revoke", "Set", "Sync", "Uninstall", "Unlock", "Update", "Invoke"];
    private static readonly XNamespace Maml = "http://schemas.microsoft.com/maml/2004/10";
    private static readonly XNamespace Command = "http://schemas.microsoft.com/maml/dev/command/2004/10";
    private static readonly XNamespace Dev = "http://schemas.microsoft.com/maml/dev/2004/10";
    private readonly Lock gate = new();
    private readonly ITechnicalJournal log;
    private readonly TimeProvider clock;
    private InstalledCmdlets? cached;

    private QueryCmdletHelp(ITechnicalJournal log, TimeProvider clock)
    {
        this.log = log;
        this.clock = clock;
    }

    public static QueryCmdletHelp From(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return context.Shared(static c => new QueryCmdletHelp(c.Log, c.Clock));
    }

    /// <summary>Folders searched: the Windows PowerShell modules of the system, then those of Program Files.</summary>
    private static IEnumerable<string> ModuleFolders()
    {
        var system = Environment.GetFolderPath(Environment.SpecialFolder.System);
        var programs = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        foreach (var module in Modules)
        {
            if (Path.IsPathFullyQualified(system))
            {
                yield return Path.Combine(system, "WindowsPowerShell", "v1.0", "Modules", module);
            }
            if (Path.IsPathFullyQualified(programs))
            {
                yield return Path.Combine(programs, "WindowsPowerShell", "Modules", module);
            }
        }
    }

    public async Task<InstalledCmdlets> ReadAsync(CancellationToken cancellationToken)
    {
        lock (gate)
        {
            if (cached is not null)
            {
                return cached;
            }
        }
        var result = await Task.Run(() => Read(cancellationToken), cancellationToken).ConfigureAwait(false);
        lock (gate)
        {
            cached ??= result;
            return cached;
        }
    }

    private InstalledCmdlets Read(CancellationToken cancellationToken)
    {
        var cmdlets = new Dictionary<string, QueryCmdlet>(StringComparer.OrdinalIgnoreCase);
        var modules = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
        var files = new List<string>();
        foreach (var folder in ModuleFolders())
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!Directory.Exists(folder))
            {
                continue;
            }
            var module = Path.GetFileName(folder);
            foreach (var file in HelpFiles(folder))
            {
                try
                {
                    var count = 0;
                    foreach (var cmdlet in Parse(file, module))
                    {
                        if (cmdlets.Count >= MaxCmdlets)
                        {
                            break;
                        }
                        cmdlets.TryAdd(cmdlet.Name, cmdlet);
                        count++;
                    }
                    if (count > 0)
                    {
                        modules.Add(module);
                        files.Add(file);
                    }
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or XmlException or InvalidOperationException)
                {
                    log.Warning($"Aide de module {module} illisible ({ex.GetType().Name}) : ignorée.");
                }
            }
        }
        return new InstalledCmdlets([.. cmdlets.Values.OrderBy(c => c.Module, StringComparer.OrdinalIgnoreCase).ThenBy(c => c.Name, StringComparer.OrdinalIgnoreCase)], [.. modules], [.. files], clock.GetUtcNow());
    }

    /// <summary>Help files of a module, French first, then English, then any culture (one culture per module).</summary>
    private static IEnumerable<string> HelpFiles(string folder)
    {
        foreach (var culture in new[] { "fr-FR", "fr", "en-US", "en" })
        {
            var path = Path.Combine(folder, culture);
            if (Directory.Exists(path))
            {
                var found = Directory.EnumerateFiles(path, "*-help.xml", SearchOption.TopDirectoryOnly).ToList();
                if (found.Count > 0)
                {
                    return found;
                }
            }
        }
        return Directory.EnumerateFiles(folder, "*-help.xml", SearchOption.AllDirectories).Take(8).ToList();
    }

    private static IEnumerable<QueryCmdlet> Parse(string file, string module)
    {
        if (new FileInfo(file).Length > MaxFileBytes)
        {
            yield break;
        }
        var settings = new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = MaxFileBytes, IgnoreComments = true };
        XDocument document;
        using (var reader = XmlReader.Create(file, settings))
        {
            document = XDocument.Load(reader);
        }
        foreach (var command in document.Descendants(Command + "command"))
        {
            var details = command.Element(Command + "details");
            var name = details?.Element(Command + "name")?.Value.Trim();
            if (string.IsNullOrEmpty(name) || name.Length > 80)
            {
                continue;
            }
            var verb = details?.Element(Command + "verb")?.Value.Trim() ?? name.Split('-')[0];
            var synopsis = Paragraphs(details?.Element(Maml + "description"));
            var description = Paragraphs(command.Element(Maml + "description"));
            var syntax = command.Element(Command + "syntax")?.Elements(Command + "syntaxItem").Select(Syntax).Where(s => s.Length > 0).ToList() ?? [];
            var parameters = command.Element(Command + "parameters")?.Elements(Command + "parameter")
                .Select(p => (Name: p.Element(Maml + "name")?.Value.Trim() ?? "", Text: Paragraphs(p.Element(Maml + "description")), Type: p.Element(Command + "parameterValue")?.Value.Trim() ?? ""))
                .Where(p => p.Name.Length > 0).ToList() ?? [];
            var examples = command.Element(Command + "examples")?.Elements(Command + "example")
                .Select(e => (Code: Code(e.Element(Dev + "code")?.Value ?? ""), Remarks: Paragraphs(e.Element(Dev + "remarks")))).Where(e => e.Code.Length > 0).Take(6).ToList() ?? [];
            var help = new StringBuilder();
            help.Append(name).Append("\n\n").Append(synopsis).Append("\n\n");
            if (description.Length > 0)
            {
                help.Append("Description\n").Append(description).Append("\n\n");
            }
            if (syntax.Count > 0)
            {
                help.Append("Syntaxe\n").Append(string.Join("\n\n", syntax)).Append("\n\n");
            }
            if (parameters.Count > 0)
            {
                help.Append("Paramètres\n");
                foreach (var (pname, ptext, ptype) in parameters)
                {
                    help.Append("  -").Append(pname).Append(ptype.Length > 0 ? " <" + ptype + ">" : "").Append('\n');
                    if (ptext.Length > 0)
                    {
                        help.Append("      ").Append(ptext.Replace("\n", "\n      ", StringComparison.Ordinal)).Append('\n');
                    }
                }
                help.Append('\n');
            }
            for (var i = 0; i < examples.Count; i++)
            {
                help.Append("Exemple ").Append(i + 1).Append('\n').Append(examples[i].Code).Append('\n');
                if (examples[i].Remarks.Length > 0)
                {
                    help.Append(examples[i].Remarks).Append('\n');
                }
                help.Append('\n');
            }
            yield return new QueryCmdlet(name, module, WriteVerbs.Contains(verb, StringComparer.OrdinalIgnoreCase), parameters.Any(p => p.Name.Equals("Credential", StringComparison.OrdinalIgnoreCase)),
                synopsis.Length > 0 ? synopsis.Split('\n')[0] : "(sans résumé)", syntax.Count > 0 ? string.Join("\n\n", syntax) : name, examples.Count > 0 ? examples[0].Code : name,
                Clip(help.ToString().Trim(), 32_000), [.. parameters.Select(p => p.Name)], "installed");
        }
    }

    private static string Clip(string text, int max) => text.Length > max ? text[..max] + "\n…" : text;

    private static string Paragraphs(XElement? element) =>
        element is null ? "" : string.Join("\n", element.Descendants(Maml + "para").Select(p => p.Value.Trim()).Where(p => p.Length > 0)).Trim();

    private static string Syntax(XElement item)
    {
        var name = item.Element(Maml + "name")?.Value.Trim() ?? "";
        if (name.Length == 0)
        {
            return "";
        }
        var parts = new List<string> { name };
        foreach (var parameter in item.Elements(Command + "parameter"))
        {
            var pname = parameter.Element(Maml + "name")?.Value.Trim();
            if (string.IsNullOrEmpty(pname))
            {
                continue;
            }
            var value = parameter.Element(Command + "parameterValue")?.Value.Trim();
            var text = "-" + pname + (string.IsNullOrEmpty(value) || value.Equals("SwitchParameter", StringComparison.OrdinalIgnoreCase) ? "" : " <" + value + ">");
            parts.Add((string?)parameter.Attribute("required") == "true" ? text : "[" + text + "]");
        }
        return string.Join(" ", parts);
    }

    private static string Code(string code)
    {
        var lines = code.Replace("\r", "", StringComparison.Ordinal).Split('\n').Select(l => l.TrimEnd()).ToList();
        for (var i = 0; i < lines.Count; i++)
        {
            foreach (var prompt in new[] { "PS C:\\>", "C:\\PS>", "PS>" })
            {
                if (lines[i].StartsWith(prompt, StringComparison.OrdinalIgnoreCase))
                {
                    lines[i] = lines[i][prompt.Length..].TrimStart();
                }
            }
        }
        return string.Join("\n", lines).Trim();
    }
}

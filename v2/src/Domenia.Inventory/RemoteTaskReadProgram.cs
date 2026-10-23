using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Xml;
using System.Xml.Linq;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

/// <summary>Closed task program: no script, path, argument or executable supplied by the bridge.</summary>
internal static class RemoteTaskReadProgram
{
    internal const int MaximumOutput = 1_048_576;
    internal const string Executable = @"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe";
    internal const string TaskAcl = "D:P(A;;FA;;;SY)(A;;FA;;;BA)";
    internal const string DirectoryAcl = "D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)";
    private static readonly XNamespace Ns = "http://schemas.microsoft.com/windows/2004/02/mit/task";
    internal static string Marker(RemoteTaskReadPlan plan) => "Domenia.RemoteRead/1:" + plan.Id.ToString("N") + ":" + plan.Nonce;
    internal static string Hash(string script) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(script)));

    internal static RemoteTaskReadPlan Plan(DirectoryComputer computer, string storeId, string account, DateTimeOffset now,
        RemoteTaskReadKind kind = RemoteTaskReadKind.UserIdentity, SoftwareRequest? software = null)
    {
        if (WorkstationIdentity.ExpectedName(computer) is null || (computer.UserAccountControl & AdValues.ServerTrustAccount) != 0)
        { throw new InvalidDataException("Identité machine incompatible avec une lecture par tâche."); }
        var plan = new RemoteTaskReadPlan(Guid.NewGuid(), storeId, computer.ObjectGuid, computer.DistinguishedName, computer.DnsHostName!,
            computer.WhenCreated, now, account, kind, Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(32)), new('0', 64)) { Software = software };
        RemoteTaskReadRules.Validate(plan, now);
        return plan with { ScriptSha256 = Hash(Script(plan)) };
    }

    internal static string Script(RemoteTaskReadPlan plan)
    {
        RemoteTaskReadRules.Validate(plan, plan.PreparedAt);
        var body = plan.Kind switch
        {
            RemoteTaskReadKind.UserIdentity => WsmanReadChannel.UserIdentityBody,
            RemoteTaskReadKind.Software => RemoteTaskReadSoftware.Body(plan.Software!),
            _ => RemoteTaskReadInventory.Body(plan.Kind),
        };
        // All substituted strings have closed ASCII grammars validated above. No operator or AD display text enters PowerShell.
        var script = """
            $ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
            """ + "\nif([Environment]::MachineName -ine '" + plan.Host.Split('.')[0] + "'){exit 80}\n"
            + "$domeniaFolder=Join-Path ([Environment]::GetFolderPath('Windows')) 'Temp\\" + plan.DirectoryName + "'\n"
            + "$domeniaMarker='" + Marker(plan) + "'\n"
            + """
            $domeniaInfo=Get-Item -LiteralPath $domeniaFolder -Force -ErrorAction Stop
            if(-not $domeniaInfo.PSIsContainer -or ($domeniaInfo.Attributes -band [IO.FileAttributes]::ReparsePoint)){exit 81}
            $domeniaManifest=Join-Path $domeniaFolder 'owner.txt'
            $domeniaOwner=Get-Item -LiteralPath $domeniaManifest -Force -ErrorAction Stop
            if($domeniaOwner.PSIsContainer -or $domeniaOwner.Length -gt 256 -or ($domeniaOwner.Attributes -band [IO.FileAttributes]::ReparsePoint)){exit 82}
            if([IO.File]::ReadAllText($domeniaManifest) -cne $domeniaMarker){exit 83}
            $domeniaRole=@(Get-CimInstance -ClassName Win32_ComputerSystem -Property Name,DomainRole -OperationTimeoutSec 2 -ErrorAction Stop)
            if($domeniaRole.Count -ne 1 -or $domeniaRole[0].Name -ine [Environment]::MachineName -or $null -eq $domeniaRole[0].DomainRole -or [int]$domeniaRole[0].DomainRole -gt 3){exit 84}
            """ + "\n" + body + "\n"
            + "$domeniaEnvelope=[pscustomobject]@{Format='Domenia.RemoteRead/1';Id='" + plan.Id.ToString("N") + "';Nonce='" + plan.Nonce + "';Payload=$domeniaResult}\n"
            + """
            $domeniaBytes=[Text.UTF8Encoding]::new($false).GetBytes(($domeniaEnvelope | ConvertTo-Json -Depth 6 -Compress))
            if($domeniaBytes.Length -gt 131072){exit 85}
            $domeniaTemp=Join-Path $domeniaFolder 'result.tmp'
            $domeniaOutput=Join-Path $domeniaFolder 'result.json'
            $domeniaStream=[IO.File]::Open($domeniaTemp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try {$domeniaStream.Write($domeniaBytes,0,$domeniaBytes.Length);$domeniaStream.Flush($true)} finally {$domeniaStream.Dispose()}
            [IO.File]::Move($domeniaTemp,$domeniaOutput)
            exit 0
            """;
        // Historical UserIdentity bytes remain unchanged so their pending cleanup stays provable.
        return plan.Kind == RemoteTaskReadKind.UserIdentity ? script : script.Replace("ConvertTo-Json -Depth 6", "ConvertTo-Json -Depth 8", StringComparison.Ordinal)
            .Replace("-gt 131072", "-gt 1048576", StringComparison.Ordinal)
            .Replace("-or [int]$domeniaRole[0].DomainRole -gt 3", "-or [int]$domeniaRole[0].DomainRole -lt 0 -or [int]$domeniaRole[0].DomainRole -gt 3", StringComparison.Ordinal);
    }

    internal static string Arguments(RemoteTaskReadPlan plan) => "-NoProfile -NonInteractive -EncodedCommand " + Convert.ToBase64String(Encoding.Unicode.GetBytes(Script(plan)));
    internal static string Xml(RemoteTaskReadPlan plan)
    {
        if (Hash(Script(plan)) != plan.ScriptSha256) { throw new InvalidDataException("Programme distant différent du plan préparé."); }
        XElement E(string name, object content) => new(Ns + name, content);
        return new XElement(Ns + "Task", new XAttribute("version", "1.2"),
            E("RegistrationInfo", E("Description", Marker(plan) + ":" + plan.ScriptSha256)), E("Triggers", ""),
            // ServiceAccount is a COM logon type, not a valid XML LogonType value. RegisterTask receives 5 separately.
            E("Principals", new XElement(Ns + "Principal", new XAttribute("id", "System"), E("UserId", "S-1-5-18"), E("RunLevel", "HighestAvailable"))),
            E("Settings", new object[] { E("MultipleInstancesPolicy", "IgnoreNew"), E("DisallowStartIfOnBatteries", false), E("StopIfGoingOnBatteries", false),
                E("AllowHardTerminate", true), E("StartWhenAvailable", false), E("RunOnlyIfNetworkAvailable", false), E("AllowStartOnDemand", true),
                E("Enabled", true), E("Hidden", false), E("ExecutionTimeLimit", "PT30S"), E("Priority", 7) }),
            new XElement(Ns + "Actions", new XAttribute("Context", "System"), E("Exec", new object[] { E("Command", Executable), E("Arguments", Arguments(plan)) })))
            .ToString(SaveOptions.DisableFormatting);
    }

    internal static bool OwnsTask(string xml, RemoteTaskReadPlan plan)
    {
        if (xml.Length > 65_536) { return false; }
        try
        {
            using var reader = XmlReader.Create(new StringReader(xml), new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = 65_536 });
            var root = XElement.Load(reader);
            XElement? Single(XElement? parent, string name) => parent?.Elements(Ns + name).Take(2).ToArray() is [var one] ? one : null;
            var info = Single(root, "RegistrationInfo"); var actions = Single(root, "Actions"); var exec = Single(actions, "Exec");
            var principals = Single(root, "Principals"); var principal = Single(principals, "Principal"); var triggers = Single(root, "Triggers"); var settings = Single(root, "Settings");
            return root.Name == Ns + "Task" && (string?)Single(info, "Description") == Marker(plan) + ":" + plan.ScriptSha256
                && actions?.Elements().Count() == 1 && (string?)Single(exec, "Command") == Executable && (string?)Single(exec, "Arguments") == Arguments(plan)
                && exec?.Elements().All(e => e.Name == Ns + "Command" || e.Name == Ns + "Arguments") == true
                && principals?.Elements().Count() == 1 && (string?)Single(principal, "UserId") is "S-1-5-18" or "SYSTEM" or @"NT AUTHORITY\SYSTEM"
                && principal?.Elements(Ns + "LogonType").Any() == false && principal.Elements(Ns + "GroupId").Any() == false
                && (string?)Single(principal, "RunLevel") == "HighestAvailable" && (string?)actions.Attribute("Context") == (string?)principal.Attribute("id")
                && root.Elements(Ns + "Triggers").Count() <= 1 && (triggers is null || !triggers.HasElements)
                && (string?)Single(settings, "ExecutionTimeLimit") == "PT30S" && (string?)Single(settings, "MultipleInstancesPolicy") == "IgnoreNew"
                && settings?.Elements(Ns + "RestartOnFailure").Any() == false;
        }
        catch (XmlException) { return false; }
    }

    internal sealed record Parsed(WorkstationUserReading Reading, InventorySnapshot? Inventory = null, WorkstationSoftwareReading? Software = null);
    internal static Parsed ParseResult(string json, RemoteTaskReadPlan plan, DateTimeOffset now)
    {
        if (plan.Kind == RemoteTaskReadKind.UserIdentity) { return new(Parse(json, plan, now)); }
        if (Encoding.UTF8.GetByteCount(json) > MaximumOutput) { throw new JsonException(); }
        using var doc = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 10 }); var root = doc.RootElement;
        RemoteTaskReadJson.Object(root, "Format", "Id", "Nonce", "Payload");
        if (RemoteTaskReadJson.Text(root, "Format") != "Domenia.RemoteRead/1" || RemoteTaskReadJson.Text(root, "Id") != plan.Id.ToString("N")
            || RemoteTaskReadJson.Text(root, "Nonce") != plan.Nonce) { throw new JsonException(); }
        var payload = root.GetProperty("Payload");
        var inventory = plan.Kind == RemoteTaskReadKind.Software ? null : RemoteTaskReadInventory.Parse(payload, plan, now);
        var software = plan.Kind == RemoteTaskReadKind.Software ? RemoteTaskReadSoftware.Parse(payload, plan, now) : null;
        var statuses = inventory?.Access.Select(a => a.Status).ToArray() ?? software!.Access.Select(a => a.Status).ToArray();
        var status = statuses.All(s => s is SourceStatus.Ok or SourceStatus.Empty or SourceStatus.Skipped) ? SourceStatus.Ok : SourceStatus.Partial;
        return new(new(plan.Host.Split('.')[0], new("TaskFallback", status, "Programme ponctuel sous SYSTEM ; consulter chaque source et le nettoyage séparément.", 0,
            inventory?.Access.Sum(a => a.Items) ?? software!.Entries.Length, InventoryTransport.ScheduledTask), []), inventory, software);
    }

    internal static WorkstationUserReading Parse(string json, RemoteTaskReadPlan plan, DateTimeOffset now)
    {
        if (plan.Kind != RemoteTaskReadKind.UserIdentity || Encoding.UTF8.GetByteCount(json) > 131_072) { throw new JsonException(); }
        using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 8 }); var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object || root.EnumerateObject().Count() != 4
            || root.EnumerateObject().Select(p => p.Name).Distinct(StringComparer.OrdinalIgnoreCase).Count() != 4
            || !root.TryGetProperty("Format", out var format) || format.ValueKind != JsonValueKind.String || format.GetString() != "Domenia.RemoteRead/1"
            || !root.TryGetProperty("Id", out var id) || id.ValueKind != JsonValueKind.String || id.GetString() != plan.Id.ToString("N")
            || !root.TryGetProperty("Nonce", out var nonce) || nonce.ValueKind != JsonValueKind.String || nonce.GetString() != plan.Nonce
            || !root.TryGetProperty("Payload", out var payload) || payload.ValueKind != JsonValueKind.Object) { throw new JsonException(); }
        var parsed = CimSession.ParseUserIdentity(payload.GetRawText(), plan.Host, now);
        return parsed with { Access = parsed.Access with { Category = "TaskFallback", Transport = InventoryTransport.ScheduledTask,
            Detail = "Lecture ponctuelle sous SYSTEM par tâche planifiée ; résultat lié à cette opération. " + parsed.Access.Detail },
            Candidates = [.. parsed.Candidates.Select(c => c with { Origin = c.Origin.Replace("WinRM ·", "Tâche SYSTEM ·", StringComparison.Ordinal) })] };
    }
}

using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace Domenia.WebTests;

/// <summary>Runs the existing browser test page in the VM's fixed WebView2, without an HTTP server or application bridge.
/// This executable belongs only to the test tree and is never published with Domenia.</summary>
internal static class Program
{
    private const string Host = "domenia-tests.invalid";
    private static int code = 2;

    [STAThread]
    private static int Main(string[] args)
    {
        try { return Run(args); }
#pragma warning disable CA1031 // Command boundary: invalid paths and startup failures are explicit failures of the test host.
        catch (Exception ex) { Console.Error.WriteLine(ex); return 2; }
#pragma warning restore CA1031
    }

    private static int Run(string[] args)
    {
        if (args.Length is not (6 or 7) || args.Length == 7 && args[6] != "--critical" || args[0] != "--root" || args[2] != "--runtime" || args[4] != "--out") { return 2; }
        var critical = args.Length == 7;
        var root = LocalDirectory(args[1]); var runtime = LocalDirectory(args[3]); var output = LocalDirectory(args[5]);
        if (!File.Exists(Path.Combine(root, "tests", "web", "run.html")) || !File.Exists(Path.Combine(runtime, "msedgewebview2.exe"))) { return 2; }
        var run = Path.Combine(output, "web-" + DateTimeOffset.UtcNow.ToString("yyyyMMddTHHmmss", System.Globalization.CultureInfo.InvariantCulture) + "-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(run);
        ApplicationConfiguration.Initialize();
        using var form = new Form { Text = "Domenia — tests des modules web", Width = 1440, Height = 900 };
        using var browser = new WebView2 { Dock = DockStyle.Fill };
        form.Controls.Add(browser);
        using var stopping = new CancellationTokenSource(TimeSpan.FromMinutes(10));
        form.FormClosing += (_, _) => stopping.Cancel();
        form.Shown += async (_, _) =>
        {
            try
            {
                var environment = await CoreWebView2Environment.CreateAsync(runtime, Path.Combine(run, "profile"),
                    new CoreWebView2EnvironmentOptions("--disable-background-networking --disable-component-update --disable-domain-reliability"));
                await browser.EnsureCoreWebView2Async(environment);
                var core = browser.CoreWebView2;
                core.Settings.AreDevToolsEnabled = false;
                core.Settings.AreDefaultContextMenusEnabled = false;
                core.Settings.IsWebMessageEnabled = false;
                core.SetVirtualHostNameToFolderMapping(Host, root, CoreWebView2HostResourceAccessKind.Deny);
                core.PermissionRequested += (_, e) => e.State = CoreWebView2PermissionState.Deny;
                core.NewWindowRequested += (_, e) => e.Handled = true;
                core.NavigationStarting += (_, e) => e.Cancel = !Allowed(e.Uri);
                core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All);
                core.WebResourceRequested += (_, e) =>
                {
                    if (!Allowed(e.Request.Uri))
                    { e.Response = environment.CreateWebResourceResponse(null, 403, "Tests locaux uniquement", "Content-Type: text/plain"); }
                };
                await core.AddScriptToExecuteOnDocumentCreatedAsync("""
                    globalThis.__domeniaWebTestError = '';
                    globalThis.__domeniaNativeVisualCapture = true;
                    addEventListener('error', e => {
                        let detail = e.message;
                        if (!detail) {
                            const target = e.target;
                            const source = target?.src || target?.href?.baseVal || target?.href || '';
                            let path = '';
                            try { path = new URL(source, location.href).pathname; } catch { path = '[URL non valide]'; }
                            detail = `Ressource non chargée : ${target?.tagName || 'inconnue'} ${path}`;
                        }
                        globalThis.__domeniaWebTestError ||= String(detail);
                    }, true);
                    addEventListener('unhandledrejection', e => { globalThis.__domeniaWebTestError ||= String(e.reason?.stack || e.reason || 'Promesse rejetée'); });
                    """);
                // Preserve connect-src 'none': sources and shared vectors enter only this dedicated test process.
                await core.AddScriptToExecuteOnDocumentCreatedAsync("globalThis.__domeniaWebTestFiles = Object.freeze(" +
                    JsonSerializer.Serialize(ReadFixtures(root)) + ");");
                core.Navigate("https://" + Host + (critical ? "/tests/web/critical.html" : "/tests/web/run.html"));
                while (true)
                {
                    await Task.Delay(200, stopping.Token);
                    var json = await core.ExecuteScriptAsync("JSON.stringify({status:document.documentElement.dataset.result??'',text:document.getElementById('out')?.textContent??'',error:globalThis.__domeniaWebTestError??'',report:globalThis.__domeniaWebTestsReport??null,visual:globalThis.__domeniaVisualCapture??null})");
                    var decoded = JsonSerializer.Deserialize<string>(json);
                    if (decoded is null) { continue; }
                    using var status = JsonDocument.Parse(decoded);
                    if (status.RootElement.TryGetProperty("visual", out var visual) && visual.ValueKind == JsonValueKind.Object)
                    {
                        var name = visual.GetProperty("name").GetString() ?? "";
                        if (!System.Text.RegularExpressions.Regex.IsMatch(name, "^[a-z0-9][a-z0-9-]{0,79}$", System.Text.RegularExpressions.RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1)))
                        { throw new InvalidDataException("Nom de capture de recette invalide."); }
                        using (var shot = new FileStream(Path.Combine(run, "visual-" + name + ".png"), FileMode.CreateNew, FileAccess.Write))
                        { await core.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, shot); }
                        using (var proof = new FileStream(Path.Combine(run, "visual-" + name + ".json"), FileMode.CreateNew, FileAccess.Write))
                        { JsonSerializer.Serialize(proof, visual); }
                        await core.ExecuteScriptAsync("globalThis.__domeniaVisualCapture = null;");
                    }
                    var result = status.RootElement.GetProperty("status").GetString();
                    var error = status.RootElement.GetProperty("error").GetString();
                    if (result is not ("passed" or "failed") && string.IsNullOrEmpty(error)) { continue; }
                    code = result == "passed" && string.IsNullOrEmpty(error) && AllPassed(status.RootElement.GetProperty("report")) ? 0 : 1;
                    File.WriteAllText(Path.Combine(run, "report.json"), decoded);
                    File.WriteAllText(Path.Combine(run, "report.txt"), status.RootElement.GetProperty("text").GetString());
                    if (code != 0)
                    {
                        // Hosted CI can refuse artifact uploads when its quota is exhausted. Keep the failed
                        // synthetic checks in the job log as well; this never substitutes for the full evidence.
                        var report = status.RootElement.GetProperty("report");
                        var failures = report.ValueKind == JsonValueKind.Object && report.TryGetProperty("results", out var rows) && rows.ValueKind == JsonValueKind.Array
                            ? rows.EnumerateArray().Where(row => row.ValueKind != JsonValueKind.Object || !row.TryGetProperty("passed", out var success) || success.ValueKind != JsonValueKind.True).Take(20).ToArray()
                            : [];
                        var summary = JsonSerializer.Serialize(new { status = result, error, failures });
                        Console.Error.WriteLine(summary.Length <= 32768 ? summary : summary[..32768]);
                    }
                    using (var image = new FileStream(Path.Combine(run, "page.png"), FileMode.CreateNew, FileAccess.Write))
                    { await core.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, image); }
                    break;
                }
            }
#pragma warning disable CA1031 // Test-host boundary: persist infrastructure failures instead of silently losing the run.
            catch (Exception ex)
            {
                code = 1;
                File.WriteAllText(Path.Combine(run, "failure.txt"), ex.ToString());
                var message = ex.ToString();
                Console.Error.WriteLine(message.Length <= 32768 ? message : message[..32768]);
            }
#pragma warning restore CA1031
            finally { if (!form.IsDisposed) { form.Close(); } }
        };
        Application.Run(form);
        return code;
    }

    private static bool AllPassed(JsonElement report)
    {
        if (report.ValueKind != JsonValueKind.Object || !report.TryGetProperty("passed", out var passed)
            || !passed.TryGetInt32(out var count) || count <= 0 || !report.TryGetProperty("failed", out var failed)
            || !failed.TryGetInt32(out var failures) || failures != 0 || !report.TryGetProperty("results", out var results)
            || results.ValueKind != JsonValueKind.Array || results.GetArrayLength() != count) { return false; }
        return results.EnumerateArray().All(r => r.ValueKind == JsonValueKind.Object
            && r.TryGetProperty("name", out var name) && name.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(name.GetString())
            && r.TryGetProperty("passed", out var success) && success.ValueKind == JsonValueKind.True);
    }

    private static bool Allowed(string address) => Uri.TryCreate(address, UriKind.Absolute, out var uri)
        && uri.Scheme == Uri.UriSchemeHttps && uri.Host == Host && uri.IsDefaultPort && uri.UserInfo.Length == 0;

    private static Dictionary<string, string> ReadFixtures(string root)
    {
        var folder = LocalDirectory(Path.Combine(root, "web", "js", "pages", "parametres"));
        var paths = Directory.EnumerateFiles(folder, "*.js", SearchOption.TopDirectoryOnly).Take(65).ToList();
        if (paths.Count is 0 or > 64) { throw new InvalidDataException("Sources Paramètres absentes ou trop nombreuses."); }
        paths.Add(Path.Combine(root, "web", "js", "pages", "parametres.js"));
        paths.Add(Path.Combine(root, "tests", "vectors", "search-text.json"));
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        long total = 0;
        foreach (var path in paths)
        {
            _ = LocalDirectory(Path.GetDirectoryName(path)!);
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            { throw new IOException("Fixture redirigée interdite."); }
            using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            total += file.Length;
            if (file.Length > 2 * 1024 * 1024 || total > 4 * 1024 * 1024)
            { throw new InvalidDataException("Fixtures de tests trop volumineuses."); }
            using var reader = new StreamReader(file, new System.Text.UTF8Encoding(false, true));
            result.Add(Path.GetRelativePath(root, path).Replace('\\', '/'), reader.ReadToEnd());
        }
        return result;
    }

    private static string LocalDirectory(string path)
    {
        if (!Path.IsPathFullyQualified(path) || path.StartsWith("\\\\", StringComparison.Ordinal) || !Directory.Exists(path))
        { throw new ArgumentException("Un dossier local absolu existant est requis.", nameof(path)); }
        var full = Path.GetFullPath(path);
        for (var current = full; current is not null; current = Path.GetDirectoryName(current))
        {
            if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
            { throw new IOException("Redirection de dossier interdite pour le harnais local."); }
        }
        return full;
    }
}

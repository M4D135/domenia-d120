using System.Collections.Immutable;
using System.Diagnostics;
using System.Reflection;
using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.App;

internal sealed record StartupModuleCheck(int Assemblies, int Modules, long Milliseconds);
internal sealed record StartupSelfTestResult(string Format, string Build, bool Passed, StartupModuleCheck? Modules,
    ImmutableArray<EngineSelfTestCheck> Checks, string? Error, long Milliseconds);

/// <summary>Runs before composition: no profile, seed, browser, authentication, provider or application timer.</summary>
internal static class StartupPreflight
{
    internal static bool Requested(IReadOnlyList<string> args) => args.Any(a => a.Equals("--selftest", StringComparison.OrdinalIgnoreCase)
        || a.Equals("-DomeniaSelfTest", StringComparison.OrdinalIgnoreCase) || a.Equals("-MegADSelfTest", StringComparison.OrdinalIgnoreCase));

    internal static string? Parse(IReadOnlyList<string> args)
    {
        if (args.Count == 0 || !Requested([args[0]]) || args.Count is not (1 or 3)
            || args.Count == 3 && !args[1].Equals("--selftest-output", StringComparison.OrdinalIgnoreCase)
                && !args[1].Equals("-DomeniaSelfTestResultPath", StringComparison.OrdinalIgnoreCase)
                && !args[1].Equals("-MegADSelfTestResultPath", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("Utilisez --selftest seul ou --selftest --selftest-output CHEMIN_LOCAL_NEUF.");
        return args.Count == 3 ? QualifyOutput(args[2]) : null;
    }

    internal static StartupModuleCheck CheckModules(IEnumerable<Assembly> assemblies)
    {
        var start = Stopwatch.GetTimestamp();
        var list = assemblies.Distinct().ToArray();
        var plan = PrepareModules(list);
        return new(list.Length, plan.Ordered.Length, (long)Stopwatch.GetElapsedTime(start).TotalMilliseconds);
    }

    internal static RuntimeModulePlan PrepareModules(IEnumerable<Assembly> assemblies, bool requireFullProduct = false)
    {
        var list = assemblies.Distinct().ToArray();
        if (list.Length == 0) throw new InvalidDataException("Aucun assemblage Domenia chargé.");
        RuntimeLibraryPlan.ValidateLoaded(list, AppContext.BaseDirectory, requireFullProduct);
        // Unlike best-effort UI discovery, a partially loadable assembly makes this check fail.
        foreach (var assembly in list)
            foreach (var type in assembly.GetExportedTypes())
            {
                _ = type.BaseType;
                _ = type.GetInterfaces();
                foreach (var method in type.GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.Static | BindingFlags.DeclaredOnly))
                { _ = method.ReturnType; foreach (var parameter in method.GetParameters()) _ = parameter.ParameterType; }
            }
        // The immutable graph is admitted before any constructor/factory can create a business service or startup notice.
        return RuntimeModulePlan.Read(list);
    }

    internal static async Task<StartupSelfTestResult> DiagnoseAsync(IEnumerable<Assembly> assemblies, CancellationToken token)
    {
        var start = Stopwatch.GetTimestamp(); StartupModuleCheck? modules = null;
        var checks = ImmutableArray.CreateBuilder<EngineSelfTestCheck>(); string? error = null;
        try
        {
            modules = CheckModules(assemblies);
            checks.AddRange(await EngineSelfTest.RunAsync(token).ConfigureAwait(false));
            var source = new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None, UseReservedDomain = true }, TimeProvider.System);
            var session = await source.GetSessionAsync(token).ConfigureAwait(false);
            var state = await source.ReadLocalAsync(token).ConfigureAwait(false);
            checks.Add(new("simulation.reserved-domain", session.Connection == ConnectionState.Simulated && session.Domain?.DnsName?.EndsWith(".invalid", StringComparison.Ordinal) == true));
            checks.Add(new("simulation.read-only-start", state.Directory.ObjectCount > 0 && source.Overlay.Version == 0));
            using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
            var refused = false;
            try { await source.ReadLocalAsync(cancelled.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) { refused = true; }
            checks.Add(new("simulation.cancellation", refused));
        }
#pragma warning disable CA1031 // Isolated diagnostic: report a closed error type, never arbitrary source text or arguments.
        catch (Exception failure) { error = failure.GetType().Name; }
#pragma warning restore CA1031
        return new("Domenia.SelfTest/1", ProductInfo.Version, error is null && checks.Count > 0 && checks.All(c => c.Passed),
            modules, checks.ToImmutable(), error, (long)Stopwatch.GetElapsedTime(start).TotalMilliseconds);
    }

    internal static void Save(string path, StartupSelfTestResult result)
    {
        path = QualifyOutput(path);
        var bytes = JsonSerializer.SerializeToUtf8Bytes(result, new JsonSerializerOptions { WriteIndented = true });
        using var file = new FileStream(path, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None);
        file.Write(bytes); file.Flush(flushToDisk: true); file.Position = 0;
        var actual = new byte[bytes.Length]; file.ReadExactly(actual);
        if (!actual.AsSpan().SequenceEqual(bytes) || file.Length != bytes.Length) throw new IOException("Résultat de diagnostic non confirmé après écriture.");
    }

    private static string QualifyOutput(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path) || path.StartsWith(@"\\", StringComparison.Ordinal)
            || path.Any(char.IsControl) || path.IndexOf(':', 2) >= 0) throw new ArgumentException("Un fichier local absolu neuf est requis pour le résultat.");
        var full = Path.GetFullPath(path);
        var root = Path.GetPathRoot(full)!;
        if (new DriveInfo(root).DriveType is not (DriveType.Fixed or DriveType.Removable or DriveType.Ram))
            throw new IOException("Le résultat doit rester sur un volume local.");
        var parent = Path.GetDirectoryName(full)!;
        var current = root;
        var components = Path.GetRelativePath(root, parent).Split([Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar], StringSplitOptions.RemoveEmptyEntries);
        foreach (var component in components.Prepend(string.Empty))
        {
            if (component != ".") current = Path.Combine(current, component);
            var attributes = File.GetAttributes(current);
            if ((attributes & FileAttributes.ReparsePoint) != 0 || (attributes & FileAttributes.Directory) == 0)
                throw new IOException("Dossier de résultat absent ou redirigé refusé.");
        }
        if (File.Exists(full) || Directory.Exists(full)) throw new IOException("Le résultat existe déjà ; aucun remplacement.");
        return full;
    }
}

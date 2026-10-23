using System.Reflection;

namespace Domenia.Tests;

/// <summary>Marks a test method: public, static or instance, no parameters, returns void or Task.</summary>
[AttributeUsage(AttributeTargets.Method)]
internal sealed class TestAttribute : Attribute
{
}

/// <summary>Failure raised by <see cref="Check"/>.</summary>
internal sealed class TestFailureException(string message) : Exception(message)
{
}

internal static class Check
{
    public static void True(bool condition, string message)
    {
        if (!condition) throw new TestFailureException(message);
    }

    public static void Equal<T>(T expected, T actual, string message)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new TestFailureException($"{message} (attendu {expected}, obtenu {actual})");
    }

    public static void False(bool condition, string message) => True(!condition, message);

    public static void NotNull(object? value, string message) => True(value is not null, message);

    public static void Null(object? value, string message) => True(value is null, message);

    public static void Contains(string expectedPart, string? actual, string message)
    {
        if (actual is null || !actual.Contains(expectedPart, StringComparison.Ordinal)) throw new TestFailureException($"{message} (« {expectedPart} » absent de « {actual} »)");
    }

    public static T Throws<T>(Action action, string message) where T : Exception
    {
        ArgumentNullException.ThrowIfNull(action);
        try
        {
            action();
        }
        catch (T expected)
        {
            return expected;
        }
        throw new TestFailureException($"{message} (aucune exception {typeof(T).Name})");
    }

    public static async Task<T> ThrowsAsync<T>(Func<Task> action, string message) where T : Exception
    {
        ArgumentNullException.ThrowIfNull(action);
        try
        {
            await action().ConfigureAwait(false);
        }
        catch (T expected)
        {
            return expected;
        }
        throw new TestFailureException($"{message} (aucune exception {typeof(T).Name})");
    }
}

/// <summary>Minimal dependency-free test runner: finds [Test] methods by reflection, runs them, prints a summary.</summary>
internal static class TestRunner
{
    private static async Task<int> Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "--native-acceptance") { return await NativeAcceptance.RunAsync(args).ConfigureAwait(false); }
        var filter = args.Length > 0 ? args[0] : null;
        var tests = typeof(TestRunner).Assembly.GetTypes()
            .SelectMany(t => t.GetMethods(BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static | BindingFlags.Instance)
                .Where(m => m.GetCustomAttribute<TestAttribute>() is not null)
                .Select(m => (Type: t, Method: m)))
            .Where(x => filter is null || $"{x.Type.Name}.{x.Method.Name}".Contains(filter, StringComparison.OrdinalIgnoreCase))
            .OrderBy(x => x.Type.Name).ThenBy(x => x.Method.Name).ToList();
        int passed = 0, failed = 0;
        foreach (var (type, method) in tests)
        {
            var name = $"{type.Name}.{method.Name}";
            try
            {
                var instance = method.IsStatic ? null : Activator.CreateInstance(type);
                if (method.Invoke(instance, null) is Task task) await task.ConfigureAwait(false);
                passed++;
                Console.WriteLine($"OK    {name}");
            }
            catch (Exception ex)
            {
                failed++;
                var inner = ex is TargetInvocationException tie && tie.InnerException is not null ? tie.InnerException : ex;
                Console.WriteLine($"ECHEC {name} : {inner.Message}");
            }
        }
        Console.WriteLine($"{passed} réussis, {failed} en échec, {tests.Count} au total.");
        return failed == 0 ? 0 : 1;
    }
}

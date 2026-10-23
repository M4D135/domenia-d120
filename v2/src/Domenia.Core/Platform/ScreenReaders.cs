using System.Collections.Frozen;
using System.Reflection;

namespace Domenia.Core;

/// <summary>
/// Screen readers usable with the directory source of the session, found by reflection: no central list to edit. A
/// reader is a public, non-abstract class implementing one or more <see cref="IScreenReader"/> interfaces, with exactly
/// one public constructor taking a single parameter that accepts the source (its concrete type, a base type or
/// <see cref="IDirectorySource"/>). Readers for another source type are ignored. Constructors must stay cheap: nothing is
/// read before the first call of a handler.
/// </summary>
public sealed class ScreenReaders : IDisposable
{
    private readonly FrozenDictionary<Type, IScreenReader> readers;

    private ScreenReaders(FrozenDictionary<Type, IScreenReader> readers) => this.readers = readers;

    /// <summary>No reader at all (directory mode while Domenia.Ad is not wired, tests).</summary>
    public static ScreenReaders None { get; } = new(FrozenDictionary<Type, IScreenReader>.Empty);

    /// <summary>Read interfaces served, by name (journal and tests).</summary>
    public IReadOnlyCollection<string> Interfaces => [.. readers.Keys.Select(k => k.Name).Order(StringComparer.Ordinal)];

    /// <summary>
    /// Builds the readers matching <paramref name="source"/>. Two implementations of the same interface for the same source
    /// are a programming error (InvalidOperationException), never a silent choice.
    /// </summary>
    public static ScreenReaders Discover(IDirectorySource source, IEnumerable<Assembly> assemblies)
    {
        ArgumentNullException.ThrowIfNull(source);
        ArgumentNullException.ThrowIfNull(assemblies);
        var found = new Dictionary<Type, (Type Implementation, IScreenReader Instance)>();
        foreach (var type in assemblies.Distinct().SelectMany(ExportedTypes).OrderBy(t => t.FullName, StringComparer.Ordinal))
        {
            if (!type.IsClass || type.IsAbstract || type.ContainsGenericParameters || !typeof(IScreenReader).IsAssignableFrom(type))
            {
                continue;
            }
            var constructors = type.GetConstructors(BindingFlags.Public | BindingFlags.Instance);
            if (constructors.Length != 1)
            {
                continue;
            }
            var parameters = constructors[0].GetParameters();
            if (parameters.Length != 1 || !parameters[0].ParameterType.IsInstanceOfType(source))
            {
                continue;
            }
            var screenInterfaces = type.GetInterfaces().Where(i => i != typeof(IScreenReader) && typeof(IScreenReader).IsAssignableFrom(i)).ToList();
            if (screenInterfaces.Count == 0)
            {
                continue;
            }
            var instance = (IScreenReader)constructors[0].Invoke([source]);
            foreach (var screen in screenInterfaces)
            {
                if (found.TryGetValue(screen, out var other))
                {
                    throw new InvalidOperationException($"Two readers implement {screen.FullName} for the same source: {other.Implementation.FullName} and {type.FullName}.");
                }
                found.Add(screen, (type, instance));
            }
        }
        return new ScreenReaders(found.ToFrozenDictionary(p => p.Key, p => p.Value.Instance));
    }

    /// <summary>Reader of a screen, or null when the source of this mode has none.</summary>
    public T? Find<T>() where T : class, IScreenReader => readers.TryGetValue(typeof(T), out var reader) ? (T)reader : null;

    /// <summary>
    /// Reader of a screen; without one, the operation is refused as the directory read of this version is (source.unavailable).
    /// </summary>
    public T Require<T>() where T : class, IScreenReader =>
        Find<T>() ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, DomeniaErrors.SourceUnavailableMessage);

    public void Dispose()
    {
        foreach (var reader in readers.Values.Distinct(ReferenceEqualityComparer.Instance).OfType<IDisposable>()) { reader.Dispose(); }
    }

    private static IEnumerable<Type> ExportedTypes(Assembly assembly)
    {
        try
        {
            return assembly.GetExportedTypes();
        }
        catch (ReflectionTypeLoadException ex)
        {
            // A type that cannot load is skipped; the others stay usable.
            return ex.Types.OfType<Type>().Where(t => t.IsPublic);
        }
    }
}

using System.Text.Json;

namespace Domenia.Core;

public sealed record LoginAppearance(string Theme, Func<string, CancellationToken, Task>? SaveTheme = null);

/// <summary>Presentation wraps the same single authentication callback. It neither stores nor observes its secret.</summary>
public interface IAccountsValidationWindow : IScreenReader
{
    Task<T> RunAsync<T>(LoginAppearance appearance, Func<CancellationToken, Task<T>> validate, CancellationToken token);
}

public static class LoginPresentation
{
    public const string ThemeKey = "accounts.loginTheme";
    public static LoginAppearance Appearance(EngineContext context, string? fallback)
    {
        // A deliberate login preference wins. Otherwise share the GUI choice, including Windows at first launch.
        var theme = context.Preferences.TryGet(ThemeKey, out var saved) ? Theme(saved) : null;
        if (theme is null && (fallback is "light" or "dark" or "contrast" or "system")) theme = fallback;
        if (theme is null && context.Preferences.TryGet(ShellInterfaceRules.InterfaceKey, out var shell)
            && shell.ValueKind == JsonValueKind.Object && shell.TryGetProperty("theme", out var current)) theme = Theme(current);
        return new(theme ?? "system", (next, token) =>
        {
            if (next is not ("light" or "dark" or "contrast" or "system")) throw new InvalidDataException("Thème de connexion inconnu.");
            return context.Preferences.SetAsync(ThemeKey, JsonSerializer.SerializeToElement(next), token);
        });
    }
    private static string? Theme(JsonElement value) => value.ValueKind == JsonValueKind.String
        && (value.GetString() is "light" or "dark" or "contrast" or "system") ? value.GetString() : null;
    public static Task<T> RunAsync<T>(EngineContext context, string? theme, Func<CancellationToken, Task<T>> validate, CancellationToken token) =>
        context.Mode != AppMode.Simulation && context.Readers.Find<IAccountsValidationWindow>() is { } window
            ? window.RunAsync(Appearance(context, theme), validate, token) : validate(token);
}

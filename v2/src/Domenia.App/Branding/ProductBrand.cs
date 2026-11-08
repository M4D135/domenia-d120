namespace Domenia.App;

/// <summary>One embedded identity for the executable, native login and window chrome.</summary>
internal static class ProductBrand
{
    private static readonly Lazy<Icon> WindowIcon = new(() =>
    {
        using var stream = typeof(ProductBrand).Assembly.GetManifestResourceStream("Domenia.Brand.Icon")
            ?? throw new InvalidDataException("Icône Domenia absente du programme.");
        using var loaded = new Icon(stream);
        return (Icon)loaded.Clone();
    });
    private static readonly Lazy<Bitmap> Logo = new(() =>
    {
        using var stream = typeof(ProductBrand).Assembly.GetManifestResourceStream("Domenia.Brand.Mark")
            ?? throw new InvalidDataException("Logo Domenia absent du programme.");
        using var loaded = new Bitmap(stream);
        return new Bitmap(loaded);
    });
    internal static Bitmap Mark => Logo.Value;
    internal static void Apply(Form form)
    {
        var icon = (Icon)WindowIcon.Value.Clone();
        form.Icon = icon;
        form.Disposed += (_, _) => icon.Dispose();
    }
}

using System.Runtime.InteropServices;
using Domenia.Core;

namespace Domenia.App.Secrets;

/// <summary>One UI-thread owner for generated passwords, LAPS and BitLocker. Clearing compares under the
/// native clipboard lock, so another application's copy cannot race the comparison and EmptyClipboard.</summary>
internal static partial class ClipboardGuard
{
    private static SecretClipboardOwnership? owned;
    private static NativeWindow? clipboardOwner;
    private static System.Windows.Forms.Timer? timer;
    private static int retries;

    internal static void Copy(string text, int seconds, bool bitLocker = false)
    {
        SecretClipboardPolicy.Require(text.AsSpan(), bitLocker);
        // Publish and capture the sequence while still owning the native lock. No other copy can
        // slip between SetDataObject and the sequence read, including a copy of identical text.
        var exclude = RegisterClipboardFormat("ExcludeClipboardContentFromMonitorProcessing");
        var history = RegisterClipboardFormat("CanIncludeInClipboardHistory");
        var cloud = RegisterClipboardFormat("CanUploadToCloudClipboard");
        if (exclude == 0 || history == 0 || cloud == 0) throw new ExternalException("Formats du presse-papiers indisponibles.");
        clipboardOwner ??= new NativeWindow();
        if (clipboardOwner.Handle == IntPtr.Zero) clipboardOwner.CreateHandle(new CreateParams { Parent = new IntPtr(-3) });
        if (!OpenClipboard(clipboardOwner.Handle)) throw new ExternalException("Presse-papiers occupé.");
        try
        {
            if (!EmptyClipboard()) throw new ExternalException("Presse-papiers indisponible.");
            Span<byte> zero = stackalloc byte[4]; zero.Clear();
            Publish(exclude, zero); Publish(history, zero); Publish(cloud, zero);
            Publish(13, MemoryMarshal.AsBytes(text.AsSpan()), terminatorBytes: 2);
            owned?.Dispose();
            owned = new(text, GetClipboardSequenceNumber());
        }
        catch
        {
            // Still under our lock: discard any partially published secret, never another application's copy.
            _ = EmptyClipboard();
            throw;
        }
        finally { _ = CloseClipboard(); }
        timer?.Dispose(); timer = null; retries = 0;
        timer = new System.Windows.Forms.Timer { Interval = Math.Clamp(seconds, 5, 300) * 1000 };
        timer.Tick += (_, _) =>
        {
            if (TryClear()) { Forget(); return; }
            if (++retries <= 5) { timer!.Interval = 1000; return; }
            TechnicalLog.Warning("Effacement du presse-papiers non confirmé : occupé par une autre application.");
            Forget();
        };
        timer.Start();
    }

    private static unsafe void Publish(uint format, ReadOnlySpan<byte> bytes, int terminatorBytes = 0)
    {
        var memory = GlobalAlloc(0x0042, checked((nuint)(bytes.Length + terminatorBytes))); // movable + zero initialized
        if (memory == IntPtr.Zero) throw new ExternalException("Mémoire du presse-papiers indisponible.");
        try
        {
            var pointer = GlobalLock(memory);
            if (pointer == IntPtr.Zero) throw new ExternalException("Mémoire du presse-papiers inaccessible.");
            try { bytes.CopyTo(new Span<byte>((void*)pointer, bytes.Length)); }
            finally { _ = GlobalUnlock(memory); }
            if (SetClipboardData(format, memory) == IntPtr.Zero) throw new ExternalException("Copie protégée refusée.");
            memory = IntPtr.Zero; // Ownership transferred to Windows only on success.
        }
        finally
        {
            if (memory != IntPtr.Zero)
            {
                var pointer = GlobalLock(memory);
                if (pointer != IntPtr.Zero)
                {
                    try { new Span<byte>((void*)pointer, bytes.Length + terminatorBytes).Clear(); }
                    finally { _ = GlobalUnlock(memory); }
                }
                _ = GlobalFree(memory);
            }
        }
    }

    internal static void ClearOwned()
    {
        try
        {
            if (!TryClear()) TechnicalLog.Warning("Fermeture : effacement du presse-papiers non confirmé (accès occupé).");
        }
        finally { Forget(); }
    }

    private static bool TryClear()
    {
        if (owned is null) return true;
        if (!OpenClipboard(IntPtr.Zero)) return false;
        try
        {
            var handle = GetClipboardData(13); // CF_UNICODETEXT
            if (handle == IntPtr.Zero) return true;
            var size = GlobalSize(handle);
            if (size is 0 or > 2 * 1024 * 1024 || (size & 1) != 0) return true;
            var pointer = GlobalLock(handle);
            if (pointer == IntPtr.Zero) return false;
            string text;
            try
            {
                text = Marshal.PtrToStringUni(pointer, checked((int)size / 2)) ?? "";
                var end = text.IndexOf('\0');
                if (end >= 0) text = text[..end];
            }
            finally { _ = GlobalUnlock(handle); }
            return !owned.Matches(text, GetClipboardSequenceNumber()) || EmptyClipboard();
        }
        finally { _ = CloseClipboard(); }
    }
    private static void Forget()
    {
        timer?.Dispose(); timer = null; retries = 0;
        owned?.Dispose(); owned = null;
        clipboardOwner?.DestroyHandle(); clipboardOwner = null;
    }

    [LibraryImport("user32.dll", EntryPoint = "RegisterClipboardFormatW", StringMarshalling = StringMarshalling.Utf16)] private static partial uint RegisterClipboardFormat(string name);
    [LibraryImport("user32.dll")] private static partial IntPtr SetClipboardData(uint format, IntPtr memory);
    [LibraryImport("kernel32.dll")] private static partial IntPtr GlobalAlloc(uint flags, nuint bytes);
    [LibraryImport("kernel32.dll")] private static partial IntPtr GlobalFree(IntPtr memory);
    [LibraryImport("user32.dll")] private static partial uint GetClipboardSequenceNumber();
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static partial bool OpenClipboard(IntPtr owner);
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static partial bool CloseClipboard();
    [LibraryImport("user32.dll")] private static partial IntPtr GetClipboardData(uint format);
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static partial bool EmptyClipboard();
    [LibraryImport("kernel32.dll")] private static partial IntPtr GlobalLock(IntPtr memory);
    [LibraryImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static partial bool GlobalUnlock(IntPtr memory);
    [LibraryImport("kernel32.dll")] private static partial nuint GlobalSize(IntPtr memory);
}

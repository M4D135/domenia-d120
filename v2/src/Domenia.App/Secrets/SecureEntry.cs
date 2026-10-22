using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security;

namespace Domenia.App.Secrets;

/// <summary>
/// Password field of the secure window: what the operator types goes straight into a <see cref="SecureString"/>, one character at a
/// time; the native edit control only ever holds bullets, unless the operator asks to reveal the value (then it shows it, as the
/// « Afficher » button of Domenia 1 did). Copy, cut, undo and the context menu are refused; paste appends the text of the
/// clipboard. Editing is append-only (Backspace removes the last character, a full selection is replaced), so the secret never
/// needs to be rebuilt from the control.
/// </summary>
internal sealed class SecureEntry : TextBox
{
    private const int WmCut = 0x0300;
    private const int WmCopy = 0x0301;
    private const int WmPaste = 0x0302;
    private const int WmClear = 0x0303;
    private const int WmUndo = 0x0304;
    private const int MaxSecretLength = 256;

    private readonly SecureString secret = new();
    private bool revealed;

    public SecureEntry()
    {
        ShortcutsEnabled = false;
        ContextMenuStrip = new ContextMenuStrip();
        ImeMode = ImeMode.Disable;
        MaxLength = MaxSecretLength;
    }

    /// <summary>Raised after every change of the secret (typed, removed, pasted, replaced).</summary>
    public event EventHandler? SecretChanged;

    public int SecretLength => secret.Length;

    /// <summary>Shows the value in clear (true) or bullets (false).</summary>
    [Browsable(false)]
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public bool Revealed
    {
        get => revealed;
        set
        {
            revealed = value;
            Render();
        }
    }

    /// <summary>A read-only copy of the secret, owned by the caller.</summary>
    public SecureString CopySecret()
    {
        var copy = secret.Copy();
        copy.MakeReadOnly();
        return copy;
    }

    /// <summary>Replaces the secret by a copy of <paramref name="value"/> (generated password).</summary>
    public void Assign(SecureString value)
    {
        ArgumentNullException.ThrowIfNull(value);
        secret.Clear();
        WithChars(value, c =>
        {
            secret.AppendChar(c);
            return true;
        });
        Changed();
    }

    /// <summary>Empties the secret and the control.</summary>
    public void Wipe()
    {
        secret.Clear();
        revealed = false;
        Text = "";
    }

    /// <summary>True when both fields hold exactly the same characters (compared in unmanaged memory, never as strings).</summary>
    public bool SameAs(SecureEntry other)
    {
        ArgumentNullException.ThrowIfNull(other);
        if (secret.Length != other.secret.Length)
        {
            return false;
        }
        var a = Marshal.SecureStringToGlobalAllocUnicode(secret);
        var b = Marshal.SecureStringToGlobalAllocUnicode(other.secret);
        try
        {
            var same = true;
            for (var i = 0; i < secret.Length; i++)
            {
                same &= Marshal.ReadInt16(a, i * 2) == Marshal.ReadInt16(b, i * 2);
            }
            return same;
        }
        finally
        {
            Marshal.ZeroFreeGlobalAllocUnicode(a);
            Marshal.ZeroFreeGlobalAllocUnicode(b);
        }
    }

    /// <summary>Classes of characters present (upper, lower, digit, other), counted without exposing the value.</summary>
    public int Classes()
    {
        var found = new bool[4];
        WithChars(secret, c =>
        {
            if (char.IsUpper(c))
            {
                found[0] = true;
            }
            else if (char.IsLower(c))
            {
                found[1] = true;
            }
            else if (char.IsDigit(c))
            {
                found[2] = true;
            }
            else
            {
                found[3] = true;
            }
            return true;
        });
        return found.Count(f => f);
    }

    protected override void OnKeyPress(KeyPressEventArgs e)
    {
        ArgumentNullException.ThrowIfNull(e);
        e.Handled = true;
        if (ReadOnly)
        {
            return;
        }
        if (e.KeyChar == '\b')
        {
            if (AllSelected())
            {
                secret.Clear();
            }
            else if (secret.Length > 0)
            {
                secret.RemoveAt(secret.Length - 1);
            }
            Changed();
            return;
        }
        if (char.IsControl(e.KeyChar))
        {
            return;
        }
        if (AllSelected())
        {
            secret.Clear();
        }
        if (secret.Length < MaxSecretLength)
        {
            secret.AppendChar(e.KeyChar);
        }
        Changed();
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        ArgumentNullException.ThrowIfNull(e);
        if (e.KeyCode == Keys.Delete)
        {
            e.SuppressKeyPress = true;
            if (AllSelected())
            {
                secret.Clear();
                Changed();
            }
            return;
        }
        if (e.Control && e.KeyCode == Keys.V)
        {
            e.SuppressKeyPress = true;
            PasteSecret();
            return;
        }
        if (e.Control && e.KeyCode == Keys.A)
        {
            e.SuppressKeyPress = true;
            SelectAll();
            return;
        }
        if (e.Control && e.KeyCode is Keys.C or Keys.X or Keys.Z)
        {
            e.SuppressKeyPress = true;
            return;
        }
        base.OnKeyDown(e);
    }

    protected override void WndProc(ref Message m)
    {
        switch (m.Msg)
        {
            case WmPaste:
                PasteSecret();
                return;
            case WmCut or WmCopy or WmClear or WmUndo:
                return;
            default:
                base.WndProc(ref m);
                return;
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            secret.Dispose();
            ContextMenuStrip?.Dispose();
        }
        base.Dispose(disposing);
    }

    private bool AllSelected() => SelectionLength > 0 && SelectionLength == TextLength;

    private void PasteSecret()
    {
        if (ReadOnly || !Clipboard.ContainsText())
        {
            return;
        }
        if (AllSelected())
        {
            secret.Clear();
        }
        foreach (var c in Clipboard.GetText())
        {
            if (!char.IsControl(c) && secret.Length < MaxSecretLength)
            {
                secret.AppendChar(c);
            }
        }
        Changed();
    }

    private void Changed()
    {
        Render();
        SecretChanged?.Invoke(this, EventArgs.Empty);
    }

    private void Render()
    {
        Text = revealed ? Clear(secret) : new string('●', secret.Length);
        SelectionStart = TextLength;
        SelectionLength = 0;
    }

    /// <summary>The value in clear, for the reveal only (the operator asked to see it).</summary>
    private static string Clear(SecureString value)
    {
        var pointer = Marshal.SecureStringToGlobalAllocUnicode(value);
        try
        {
            return Marshal.PtrToStringUni(pointer, value.Length);
        }
        finally
        {
            Marshal.ZeroFreeGlobalAllocUnicode(pointer);
        }
    }

    /// <summary>Visits the characters of a secret in unmanaged memory, zeroed afterwards.</summary>
    internal static void WithChars(SecureString value, Func<char, bool> visit)
    {
        var pointer = Marshal.SecureStringToGlobalAllocUnicode(value);
        try
        {
            for (var i = 0; i < value.Length; i++)
            {
                if (!visit((char)Marshal.ReadInt16(pointer, i * 2)))
                {
                    break;
                }
            }
        }
        finally
        {
            Marshal.ZeroFreeGlobalAllocUnicode(pointer);
        }
    }
}

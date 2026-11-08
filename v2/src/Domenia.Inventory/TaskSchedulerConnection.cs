using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using Domenia.Core;

namespace Domenia.Inventory;

/// <summary>Only TaskService.Connect, with a temporary native BSTR for the selected password; no managed secret string.</summary>
internal static class TaskSchedulerConnection
{
    internal static void Connect(object service, string host, RemoteProbeCredential? credential)
    {
        if (!CimQuery.IsHostName(host)) { throw new ArgumentException("Nom de poste invalide.", nameof(host)); }
        var dispatch = (IDispatch)service; var iid = Guid.Empty;
        var names = new[] { "Connect" }; var ids = new int[1];
        Check(dispatch.GetIdsOfNames(ref iid, names, 1, 0, ids));
        var size = IntPtr.Size == 8 ? 24 : 16;
        var arguments = Marshal.AllocCoTaskMem(size * 4);
        var exception = Marshal.AllocCoTaskMem(Marshal.SizeOf<NativeException>());
        var strings = new List<IntPtr>();
        try
        {
            Marshal.Copy(new byte[size * 4], 0, arguments, size * 4);
            Marshal.Copy(new byte[Marshal.SizeOf<NativeException>()], 0, exception, Marshal.SizeOf<NativeException>());
            void Bstr(int index, IntPtr pointer)
            {
                strings.Add(pointer);
                var variant = IntPtr.Add(arguments, size * index);
                Marshal.WriteInt16(variant, 8); // VT_BSTR; VARIANT payload begins at offset 8 on x86 and x64.
                Marshal.WriteIntPtr(variant, 8, pointer);
            }
            // IDispatch stores positional arguments in reverse order. All omitted credentials remain VT_EMPTY.
            Bstr(3, Marshal.StringToBSTR(host));
            if (credential is { Session: false })
            {
                if (credential.Password is null) { throw new ArgumentException("Secret du compte choisi absent."); }
                var name = CredentialRules.Parse(credential.Account!);
                Bstr(2, Marshal.StringToBSTR(name.Form == AccountNameForm.Upn ? credential.Account! : name.Name));
                Bstr(1, Marshal.StringToBSTR(name.Form == AccountNameForm.Upn ? "" : name.Authority));
                Bstr(0, Marshal.SecureStringToBSTR(credential.Password));
            }
            var parameters = new DISPPARAMS { rgvarg = arguments, cArgs = 4 };
            var code = dispatch.Invoke(ids[0], ref iid, 0, 1, ref parameters, IntPtr.Zero, exception, IntPtr.Zero);
            if (code == unchecked((int)0x80020009))
            { var detail = Marshal.PtrToStructure<NativeException>(exception); if (detail.Scode < 0) { code = detail.Scode; } }
            Check(code);
        }
        finally
        {
            var detail = Marshal.PtrToStructure<NativeException>(exception);
            foreach (var pointer in new[] { detail.Source, detail.Description, detail.HelpFile }) { if (pointer != IntPtr.Zero) { Marshal.ZeroFreeBSTR(pointer); } }
            foreach (var pointer in strings) { Marshal.ZeroFreeBSTR(pointer); }
            Marshal.Copy(new byte[size * 4], 0, arguments, size * 4);
            Marshal.FreeCoTaskMem(arguments); Marshal.FreeCoTaskMem(exception);
        }
    }

    private static void Check(int code)
    { if (code < 0) { throw new COMException("Connexion au planificateur refusée ou indisponible.", code); } }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeException
    {
        internal ushort Code; internal ushort Reserved; internal IntPtr Source; internal IntPtr Description; internal IntPtr HelpFile;
        internal uint HelpContext; internal IntPtr ReservedPointer; internal IntPtr DeferredFill; internal int Scode;
    }

    [ComImport, Guid("00020400-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDispatch
    {
        [PreserveSig] int GetTypeInfoCount(out uint count);
        [PreserveSig] int GetTypeInfo(uint index, uint locale, out IntPtr info);
        [PreserveSig] int GetIdsOfNames(ref Guid iid, [MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.LPWStr, SizeParamIndex = 2)] string[] names, uint count, uint locale, [Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 2)] int[] ids);
        [PreserveSig] int Invoke(int id, ref Guid iid, uint locale, ushort flags, ref DISPPARAMS parameters, IntPtr result, IntPtr exception, IntPtr error);
    }
}

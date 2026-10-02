Option Explicit
Dim sh,fso,root,exe
Set sh=CreateObject("WScript.Shell")
Set fso=CreateObject("Scripting.FileSystemObject")
root=fso.GetParentFolderName(WScript.ScriptFullName)
exe=fso.BuildPath(root,"Domenia.exe")
If Not fso.FileExists(exe) Then MsgBox "Domenia.exe introuvable",16,"Domenia":WScript.Quit 1
sh.Run Chr(34) & exe & Chr(34),1,False

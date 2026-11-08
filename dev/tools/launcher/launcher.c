/* DOMENIA launcher. Fixed Windows PowerShell path; no shell evaluation or embedded engine. */
#include <stddef.h>
typedef unsigned long DWORD;
typedef int BOOL;
typedef void *HANDLE;
typedef unsigned short WORD;
typedef unsigned char BYTE;
typedef wchar_t WCHAR;
typedef struct { DWORD cb; WCHAR *reserved,*desktop,*title; DWORD x,y,xsize,ysize,xchars,ychars,fill,flags; WORD show,reserved2; BYTE *reserved3; HANDLE in,out,err; } STARTUPINFOW;
typedef struct { HANDLE process,thread; DWORD processId,threadId; } PROCESS_INFORMATION;
#define API __declspec(dllimport)
API DWORD __stdcall GetModuleFileNameW(HANDLE,WCHAR*,DWORD);
API DWORD __stdcall GetSystemDirectoryW(WCHAR*,DWORD);
API DWORD __stdcall GetFileAttributesW(const WCHAR*);
API WCHAR* __stdcall GetCommandLineW(void);
API BOOL __stdcall CreateProcessW(const WCHAR*,WCHAR*,void*,void*,BOOL,DWORD,void*,const WCHAR*,STARTUPINFOW*,PROCESS_INFORMATION*);
API DWORD __stdcall WaitForSingleObject(HANDLE,DWORD);
API BOOL __stdcall GetExitCodeProcess(HANDLE,DWORD*);
API BOOL __stdcall CloseHandle(HANDLE);
API DWORD __stdcall GetLastError(void);
API HANDLE __stdcall CreateFileW(const WCHAR*,DWORD,DWORD,void*,DWORD,DWORD,HANDLE);
API void __stdcall ExitProcess(DWORD);
API int __stdcall MessageBoxW(HANDLE,const WCHAR*,const WCHAR*,unsigned int);
static WCHAR root[32768],engine[32768],shell[32768],args[32768],lockpath[32768],marker[32768];
static STARTUPINFOW si;
static PROCESS_INFORMATION pi;
static size_t len(const WCHAR *p){size_t n=0;while(p[n])n++;return n;}
static int equal(const WCHAR*a,const WCHAR*b){while(*a&&*a==*b){a++;b++;}return *a==*b;}
static int append(WCHAR*d,const WCHAR*s){size_t n=len(d),m=len(s);if(n+m>=32767)return 0;for(size_t i=0;i<=m;i++)d[n+i]=s[i];return 1;}
static void fail(const WCHAR*text,DWORD code){MessageBoxW(0,text,L"DOMENIA | Demarrage",0x10);ExitProcess(code?code:1);}
static WCHAR *parameters(void){WCHAR*p=GetCommandLineW();if(*p==L'"'){p++;while(*p&&*p!=L'"')p++;if(*p)p++;}else{while(*p&&*p!=L' '&&*p!=L'\t')p++;}while(*p==L' '||*p==L'\t')p++;return p;}
void mainCRTStartup(void){
    DWORD n=GetModuleFileNameW(0,root,32768);
    if(!n||n>=32767)fail(L"Chemin du lanceur introuvable ou trop long.",2);
    while(n&&root[n-1]!=L'\\')n--;
    if(!n)fail(L"Dossier du lanceur introuvable.",2);
    /* Preserve the backslash of a drive root (C:\). */
    if(n==3 && root[1]==L':')root[n]=0;else root[n-1]=0;
    if(!append(engine,root)||!append(engine,(root[len(root)-1]==L'\\')?L"wad\\Domenia-Start.ps1":L"\\wad\\Domenia-Start.ps1"))fail(L"Chemin trop long.",2);
    if(!append(lockpath,root)||!append(lockpath,(root[len(root)-1]==L'\\')?L"wad\\Support\\.lifecycle.lock":L"\\wad\\Support\\.lifecycle.lock"))fail(L"Chemin de verrou trop long.",2);
    HANDLE lifecycle=CreateFileW(lockpath,0x80000000,1,0,3,0x80,0);
    if(lifecycle==(HANDLE)(ptrdiff_t)-1)fail(L"Paquet absent, mise a jour en cours ou dossier inaccessible. Ne pas supprimer les verrous. Utiliser l installateur DEV.",7);
    if(!append(marker,root)||!append(marker,(root[len(root)-1]==L'\\')?L"wad\\Support\\.update.pending":L"\\wad\\Support\\.update.pending"))fail(L"Chemin trop long.",2);
    if(GetFileAttributesW(marker)!=0xFFFFFFFF)fail(L"Une installation interrompue doit etre restauree ou terminee avant de lancer Domenia.",8);
    DWORD a=GetFileAttributesW(engine);
    if(a==0xFFFFFFFF||(a&0x10))fail(L"wad\\Domenia-Start.ps1 est absent. Extraire tout le dossier prod ou dev.",3);
    n=GetSystemDirectoryW(shell,32768);
    if(!n||n>=32767||!append(shell,L"\\WindowsPowerShell\\v1.0\\powershell.exe"))fail(L"Windows PowerShell introuvable.",4);
    if(GetFileAttributesW(shell)==0xFFFFFFFF)fail(L"Windows PowerShell 5.1 x64 est requis.",4);
    WCHAR*p=parameters();int check=equal(p,L"--check"),diag=equal(p,L"--diagnostic");
    if(*p&&!check&&!diag)fail(L"Arguments acceptes : --check ou --diagnostic. Le lancement normal ne prend aucun argument.",5);
    if(!append(args,L"\"")||!append(args,shell)||!append(args,L"\" -NoLogo -NoProfile -STA -File \"")||!append(args,engine)||!append(args,L"\""))fail(L"Commande trop longue.",6);
    if(check&&!append(args,L" -CheckOnly"))fail(L"Commande trop longue.",6);
    if(diag&&!append(args,L" -Diagnostic"))fail(L"Commande trop longue.",6);
    si.cb=sizeof(si);si.flags=1;si.show=(check||diag)?1:0;
    if(!CreateProcessW(shell,args,0,0,0,(check||diag)?0x10:0x08000000,0,root,&si,&pi))fail(L"Windows a refuse le lancement. Conserver les politiques de securite et faire verifier le paquet.",GetLastError());
    CloseHandle(pi.thread);
    WaitForSingleObject(pi.process,0xFFFFFFFF);
    DWORD code=1;GetExitCodeProcess(pi.process,&code);CloseHandle(pi.process);
    if(code&&!check&&!diag)MessageBoxW(0,L"DOMENIA s'est arrete sur une erreur. Lancer Domenia.exe --diagnostic pour la voir. Les journaux restent sous wad\\data\\Logs ou le dossier utilisateur.",L"DOMENIA",0x10);
    CloseHandle(lifecycle);
    ExitProcess(code);
}

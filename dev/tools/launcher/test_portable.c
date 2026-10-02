/* Portable tests of actual string helpers only. Not a Windows process/UAC test. */
#define __declspec(x)
#define __stdcall
#define mainCRTStartup unused_windows_entry
#include "launcher.c"
#include <assert.h>
#include <stdio.h>
#include <wchar.h>
static WCHAR *fake_command;
WCHAR *GetCommandLineW(void){return fake_command;}
int main(void){
    WCHAR command[800], expected[100], buffer[32768];
    unsigned int cases=0;
    for(int n=0;n<6000;n++){
        swprintf(command,800,L"\"C:\\Dossier %d é\\Domenia.exe\"\t  --check",n);
        fake_command=command;assert(equal(parameters(),L"--check"));cases++;
        swprintf(command,800,L"C:\\Domenia.exe   --diagnostic");
        fake_command=command;assert(equal(parameters(),L"--diagnostic"));cases++;
        swprintf(expected,100,L"base-%d",n);buffer[0]=0;
        assert(append(buffer,L"base-"));WCHAR number[40];swprintf(number,40,L"%d",n);assert(append(buffer,number));assert(equal(buffer,expected));cases++;
    }
    fake_command=L"\"C:\\App X\\Domenia.exe\"";assert(equal(parameters(),L""));cases++;
    fake_command=L"Domenia.exe --check & evil";assert(!equal(parameters(),L"--check"));cases++;
    for(int i=0;i<32766;i++)buffer[i]=L'a';buffer[32766]=0;
    assert(!append(buffer,L"b"));assert(len(buffer)==32766);cases++;
    buffer[32765]=0;assert(append(buffer,L"b"));assert(len(buffer)==32766);cases++;
    printf("{\"portable_helper_assertions\":%u,\"failed\":0,\"windows_execution\":false}\n",cases);
    return 0;
}

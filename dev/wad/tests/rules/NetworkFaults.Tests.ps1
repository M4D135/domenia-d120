# Point 127 : pannes reseau. Une coupure, un refus de connexion ou un nom non resolu reste une panne reseau :
# jamais une question de compte, relecture possible. Exceptions .NET reelles, aucun reseau.
. (Join-Path $modules 'Domenia-Guard.Model.ps1')
Test-Case 'P127' 'Pannes reseau : resolution, refus, coupure et appel RPC interrompu restent des pannes reseau' {
    foreach($native in @(11001,11002,11003,11004,10051,10053,10054,10060,10061,10064,10065)){
        $d=Get-DomeniaErrorDecision (Get-DomeniaStructuredError ([Net.Sockets.SocketException]::new($native)) 'Lecture' 'CIM' 'pc1')
        Assert-Equal 'Network' $d.Category ('Code socket '+$native)
        Assert-False $d.OfferCredential ('Autre compte propose pour le code '+$native)
        Assert-True $d.Retryable ('Relecture refusee pour le code '+$native)
    }
    foreach($hresult in @(-2147023170,-2147023169)){
        $rpc=Get-DomeniaErrorDecision (Get-DomeniaStructuredError ([Runtime.InteropServices.COMException]::new('Appel de procedure distante interrompu (fixture).',$hresult)))
        Assert-Equal 'Network' $rpc.Category ('Appel RPC coupe '+$hresult);Assert-False $rpc.OfferCredential
    }
    Assert-Equal 'Network' (Get-DomeniaErrorDecision (Get-DomeniaStructuredError ([ComponentModel.Win32Exception]::new(1726)))).Category
    Assert-Equal 'AccessDenied' (Get-DomeniaErrorDecision (Get-DomeniaStructuredError ([UnauthorizedAccessException]::new('Acces refuse (fixture).')))).Category 'Un refus d acces reste un refus'
}

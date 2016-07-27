function Get-TargetResource
{
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    param
    (
        [parameter(Mandatory = $true)]
        [System.String]
        $Subject,

        [parameter(Mandatory = $true)]
        [System.String]
        $CAServerFQDN,

        [parameter(Mandatory = $true)]
        [System.String]
        $CARootName
    )

    $Cert = Get-Childitem Cert:\LocalMachine\My | ? {$_.Subject -eq "CN=$Subject" -and $_.Issuer.split(',')[0] -eq "CN=$CARootName"}
    
    # If multiple certs have the same subject and were issued by the CA, return the newest
    $Cert = $Cert | Sort-Object NotBefore -Descending | Select -first 1

    $returnValue = @{
        Subject = if ($Cert){[System.String]$Cert.Subject};
        CAServerFQDN = if ($Cert){'Issued By: '+[System.String]$Cert.Issuer};
        CARootName = if ($Cert){[System.String]$Cert.Issuer.split(',')[0].replace('CN=','')}
    }

    $returnValue
}
# Get-TargetResource 'test.domain.com' -CAServerFQDN 'dc01.test.net' -CARootName 'test-dc01-ca'


function Set-TargetResource
{
    [CmdletBinding()]
    param
    (
        [parameter(Mandatory = $true)]
        [System.String]
        $Subject,

        [parameter(Mandatory = $true)]
        [System.String]
        $CAServerFQDN,

        [parameter(Mandatory = $true)]
        [System.String]
        $CARootName,

        [parameter(Mandatory = $false)]
        [System.String]
        $TemplateName,

        [parameter(Mandatory = $false)]
        [System.String]
        $KeyKength = '1024',

        [parameter(Mandatory = $false)]
        [System.String]
        $Exportable = 'TRUE',

        [parameter(Mandatory = $false)]
        [System.String]
        $ProviderName = '"Microsoft RSA SChannel Cryptographic Provider""',

        [parameter(Mandatory = $false)]
        [System.String]
        $OID,

        [parameter(Mandatory = $false)]
        [System.String]
        $KeyUsage,

        [System.Management.Automation.PSCredential]
        $Credential,

        [System.Boolean]
        $AutoRenew
    )
# If the Subject does not contain a full X500 path, construct just the CN
if (($Subject.split('=').count) -eq 1)
{
    [System.String]$Subject = "CN=$Subject"
}

# If we should look for renewals, check for existing certs
if ($AutoRenew) {
    $Cert = Get-Childitem Cert:\LocalMachine\My | ? {$_.Subject -eq $Subject -and $_.Issuer.split(',')[0] -eq "CN=$CARootName" -and $_.NotAfter -lt (get-date).AddDays(-30)}
        
    # If multiple certs have the same subject and were issued by the CA and are 30 days from expiration, return the newest
    $Thumprint = $Cert | Sort-Object NotBefore -Descending | Select -first 1 | foreach {$_.Thumbprint}
}

# Information that will be used in the INF file to generate the certificate request
# In future versions, select variables from the list below could be moved to parameters!
[System.String]$Subject               = "`"$Subject`""
[System.String]$KeySpec               = '1'
[System.String]$MachineKeySet         = 'TRUE'
[System.String]$SMIME                 = 'False'
[System.String]$PrivateKeyArchive     = 'FALSE'
[System.String]$UserProtected         = 'FALSE'
[System.String]$UseExistingKeySet     = 'FALSE'
[System.String]$ProviderType          = '12'
[System.String]$RequestType           = 'CMC'
[System.String]$KeyUsage              = '0xa0'
[System.String]$OID                   = '1.3.6.1.5.5.7.3.1'
[System.String]$CertificateTemplate   = 'WebServer'

# A unique identifier for temporary files that will be used when interacting with the command line utility
[system.guid]$GUID = [system.guid]::NewGuid().guid
[System.String]$INF = "$env:Temp\$GUID.inf"
[System.String]$REQ = "$env:Temp\$GUID.req"
[System.String]$CER = "$env:Temp\$GUID.cer"
[System.String]$RSP = "$env:Temp\$GUID.rsp"

# The certificate authority, accessible on the local area network
[System.String]$CA = "'$CAServerFQDN\$CARootName'"

# Create INF file
$requestDetails = @"
[NewRequest]
Subject              = $Subject
KeySpec              = $KeySpec
KeyLength            = $KeyLength
Exportable           = $Exportable
MachineKeySet        = $MachineKeySet
SMIME                = $SMIME
PrivateKeyArchive    = $PrivateKeyArchive
UserProtected        = $UserProtected
UseExistingKeySet    = $UseExistingKeySet
ProviderName         = $ProviderName
ProviderType         = $ProviderType
RequestType          = $RequestType
KeyUsage             = $KeyUsage
[RequestAttributes]
CertificateTemplate  = $CertificateTemplate
[EnhancedKeyUsageExtension]
OID=$OID
"@ 
if ($Thumbprint) {$requestDetails += "RenewalCert = $Thumbprint"}

$requestDetails| out-file $INF

# NEW: Create a new request as directed by PolicyFileIn
$createRequest = C:\windows\system32\certreq.exe -new -q $INF $REQ

# SUBMIT: Submit a request to a Certification Authority.
# DSC runs in the context of LocalSystem, which uses the Computer account in Active Directory to authenticate to network resources
# The Credential paramter with xPDT is used to impersonate a user making the request
if (test-path $REQ) {
    if ($Credential) {
        Import-Module $PSScriptRoot\..\..\xPDT.psm1
        $Process = StartWin32Process `
                        -Path 'C:\windows\system32\certreq.exe' `
                        -Arguments "-submit -q -config $CA $REQ $CER" `
                        -Credential $Credential
        Write-Verbose -Messsage $Process
        WaitForWin32ProcessEnd `
            -Path 'C:\windows\system32\certreq.exe' `
            -Arguments "-submit -q -config $CA $REQ $CER" `
            -Credential $Credential
        }
    else {
        $submitRequest = C:\windows\system32\certreq.exe -submit -q -config $CA $REQ $CER
        Write-Verbose -Messsage $submitRequest[2]}
    }

# Accept request
if (test-path $CER) {
    Write-Verbose -Messsage 'Accepting certificate'
    $acceptRequest = C:\windows\system32\certreq.exe -accept -machine -q $CER
    }

Write-Verbose -Message 'Cleaning up files'
#foreach ($file in @($INF,$REQ,$CER,$RSP)) {if (test-path $file) {Remove-Item $file -force}}

# Syntax: https://technet.microsoft.com/en-us/library/cc736326.aspx
# Reference: https://support2.microsoft.com/default.aspx?scid=kb;EN-US;321051

}
# Set-TargetResource 'test.domain.com' -CAServerFQDN 'dc01.test.net' -CARootName 'test-dc01-ca' -credential (get-credential)


function Test-TargetResource
{
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param
    (
        [parameter(Mandatory = $true)]
        [System.String]
        $Subject,

        [parameter(Mandatory = $true)]
        [System.String]
        $CAServerFQDN,

        [parameter(Mandatory = $true)]
        [System.String]
        $CARootName,

        [System.Management.Automation.PSCredential]
        $Credential,

        [System.Boolean]
        $AutoRenew
    )

    # If the Subject does not contain a full X500 path, construct just the CN
    if (($Subject.split('=').count) -eq 1)
    {
        [System.String]$Subject = "CN=$Subject"
    }

    $Cert = Get-Childitem Cert:\LocalMachine\My | ? {$_.Subject -eq $Subject -and $_.Issuer.split(',')[0] -eq "CN=$CARootName"}
    
    # If multiple certs have the same subject and were issued by the CA, return the newest
    $Cert = $Cert | Sort-Object NotBefore -Descending | Select -first 1

    Write-Verbose -Messsage "Checking Certificates"
    if ($AutoRenew) {
        if ($Cert.NotAfter -gt (get-date).AddDays(-30)) {
            [boolean]$true
            }
        else {
            [boolean]$false
            Write-Verbose -Messsage "No valid certificate found with subject $Subject from CA $CARootName, or certificate is about to expire"
            }
        }
    else {
        if ($Cert.NotAfter -gt (get-date)) {
            [boolean]$true
            }
        else {
            [boolean]$false
            Write-Verbose -Messsage "No valid certificate found with subject $Subject from CA $CARootName"
            }
        }
}
# Test-TargetResource 'test.domain.com' -CAServerFQDN 'dc01.test.net' -CARootName 'test-dc01-ca'


Export-ModuleMember -Function *-TargetResource
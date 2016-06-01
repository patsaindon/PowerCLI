#############################################################################################################################
#
# ESXi-Customizer-PS.ps1 - a script to build a customized ESXi installation ISO using ImageBuilder
#
# Version:       2.4.3
# Author:        Andreas Peetz (ESXi-Customizer-PS@v-front.de)
# Info/Tutorial: http://esxi-customizer-ps.v-front.de/
#
# License:
#
# This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty
# of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
#
# A copy of the GNU General Public License is available at http://www.gnu.org/licenses/.
#
#############################################################################################################################
#
# NOTE: This script is SIGNED. Please remove the signature block at the end of the file before modifying it!
#
#############################################################################################################################

param(
    [string]$iZip = "",
    [string]$pkgDir = "",
    [string]$outDir = $(Split-Path $MyInvocation.MyCommand.Path),
    [string]$ipname = "",
    [string]$ipvendor = "",
    [string]$ipdesc = "",
    [switch]$vft = $false,
    [string[]]$dpt = @(),
    [string[]]$load = @(),
    [string[]]$remove = @(),
    [switch]$test = $false,
    [switch]$sip = $false,
    [switch]$nsc = $false,
    [switch]$help = $false,
    [switch]$ozip = $false,
    [switch]$v50 = $false,
    [switch]$v51 = $false,
    [switch]$v55 = $false,
    [switch]$v60 = $false,
    [switch]$update = $false,
    [string]$log = ($env:TEMP + "\ESXi-Customizer-PS.log")
)

# Constants
$ScriptName = "ESXi-Customizer-PS"
$ScriptVersion = "2.4.1"
$ScriptURL = "http://ESXi-Customizer-PS.v-front.de"

$AccLevel = @{"VMwareCertified" = 1; "VMwareAccepted" = 2; "PartnerSupported" = 3; "CommunitySupported" = 4}

# Online depot URLs
$vmwdepotURL = "https://hostupdate.vmware.com/software/VUM/PRODUCTION/main/vmw-depot-index.xml"
$vftdepotURL = "http://vibsdepot.v-front.de/"

# Function to update/add VIB package
function AddVIB2Profile($vib) {
    $AddVersion = $vib.Version
    $ExVersion = ($MyProfile.VibList | where { $_.Name -eq $vib.Name }).Version
    if ($AccLevel[$vib.AcceptanceLevel.ToString()] -gt $AccLevel[$MyProfile.AcceptanceLevel.ToString()]) {
        write-host -ForegroundColor Yellow -nonewline (" [New AcceptanceLevel: " + $vib.AcceptanceLevel + "]")
        $MyProfile.AcceptanceLevel = $vib.AcceptanceLevel
    }
    If ($MyProfile.VibList -contains $vib) {
        write-host -ForegroundColor Yellow " [IGNORED, already added]"
    } else {
        Add-EsxSoftwarePackage -SoftwarePackage $vib -Imageprofile $MyProfile -force -ErrorAction SilentlyContinue | Out-Null 
        if ($?) {
            if ($ExVersion -eq $null) {
                write-host -ForegroundColor Green " [OK, added]"
            } else {
                write-host -ForegroundColor Yellow (" [OK, replaced " + $ExVersion + "]")
            }
        } else {
            write-host -ForegroundColor Red " [FAILED, invalid package?]"
        }
    }
}

# Function to test if entered string is numeric
function isNumeric ($x) {
    $x2 = 0
    $isNum = [System.Int32]::TryParse($x, [ref]$x2)
    return $isNum
}

# Clean-up function
function cleanup() {
    try { Remove-EsxSoftwaredepot $DefaultSoftwaredepots } catch {}
    Stop-Transcript | Out-Null
}

# Set up the screen
$pswindow = (get-host).ui.rawui
$newsize = $pswindow.buffersize
if ( $newsize.height -lt 3000) { $newsize.height = 3000 }
if ( $newsize.width -lt 120) { $newsize.width = 120 }
$pswindow.buffersize = $newsize
$newsize = $pswindow.windowsize
if ( $newsize.height -lt 50) { $newsize.height = 50 }
if ( $newsize.width -lt 120) { $newsize.width = 120 }
$pswindow.windowsize = $newsize
$pswindow.windowtitle = $ScriptName + " " + $ScriptVersion + " - " + $ScriptUrl
$pswindow.foregroundcolor = "White"
$pswindow.backgroundcolor = "Black"

# Write info and help if requested
write-host "`nScript to build a customized ESXi installation ISO or Offline bundle using the VMware PowerCLI ImageBuilder snapin"
if ($help) {
    write-host "`nUsage:"
    write-host "   ESXi-Customizer-PS [-help] | [-izip <bundle> [-update]] [-sip] [-v50|-v51|-v55|-v60] [-ozip] [-pkgDir <dir>]"
    write-host "                                [-outDir <dir>] [-vft] [-dpt depot1[,...]] [-load vib1[,...]] [-remove vib1[,...]]"
    write-host "                                [-log <file>] [-ipname <name>] [-ipdesc <desc>] [-ipvendor <vendor>] [-nsc] [-test]"
    write-host "`nOptional parameters:"
    write-host "   -help              : display this help"
    write-host "   -izip <bundle>     : use the VMware Offline bundle <bundle> as input instead of the Online depot"
    write-host "   -update            : only with -izip, updates a local bundle with an ESXi patch from the VMware Online depot,"
    write-host "                        combine this with the matching ESXi version selection switch"
    write-host "   -pkgDir <dir>      : local directory of Offline bundles and/or VIB files to add (if any, no default)"
    write-host "   -ozip              : output an Offline bundle instead of an installation ISO"
    write-host "   -outDir <dir>      : directory to store the customized ISO or Offline bundle"
    write-host "                        (the default is the script directory)"
    write-host "   -vft               : connect the V-Front Online depot"
	write-host "   -dpt depot1[,...]  : connect additional Online depots by URL or local Offline bundles by file name"
    write-host "   -load vib1[,...]   : load additional packages from connected depots or Offline bundles"
    write-host "   -remove vib1[,...] : remove named VIB packages from the custom Imageprofile"
    write-host "   -sip               : select an Imageprofile from the current list"
    write-host "                        (default = auto-select latest available standard profile)"
    write-host "   -v50 | -v51 |"
    write-host "   -v55 | -v60        : Use only ESXi 5.0/5.1/5.5/6.0 Imageprofiles as input, ignore other versions"
    write-host "   -nsc               : use -NoSignatureCheck with export"
    write-host "   -log <file>        : write log to <file> (default is %TEMP%\ESXi-Customizer-PS.log)"
    write-host "   -ipname <name>"
    write-host "   -ipdesc <desc>"
    write-host "   -ipvendor <vendor> : provide a name, description and/or vendor for the customized"
    write-host "                        Imageprofile (the default is derived from the cloned input Imageprofile)"
    write-host "   -test              : skip package download and image build (for testing)`n"
    exit
} else {
    write-host "(Call with -help for instructions)"
    write-host ("`nLogging to " + $log + " ...")
    # Stop active transcript
    try { Stop-Transcript | out-null } catch {}
    # Start own transcript
    try { Start-Transcript -Path $log -Force -Confirm:$false | Out-Null } catch {
        write-host -ForegroundColor Red "`nFATAL ERROR: Log file cannot be opened. Bad file path or missing permission?`n"
        exit
    }
}

# The main try ...
try {

if (Get-PSSnapin -Registered -Name VMware.ImageBuilder -ErrorAction:SilentlyContinue) {
    # Okay, PowerCLI 5 or 6 is installed.
    if (!(Get-PSSnapin -name VMware.ImageBuilder -ErrorAction:SilentlyContinue)) {
        # ImageBuilder snapin not already added ... do it:
        if (Add-PSSnapin -PassThru VMware.ImageBuilder) {
            # Check if this is PowerCLI 6, and the core module already loaded:
            if (!(Get-Module VMware.VimAutomation.Core -ErrorAction:SilentlyContinue)) {
                # PowerCLI 5, not 6. Need to check for core snapin.
                if (!(Get-PSSnapin -name VMware.VimAutomation.Core -ErrorAction:SilentlyContinue)) {
                    # PowerCLI 5 core snapin not already added ... do it:
                    if (!(Add-PSSnapin -PassThru VMware.VimAutomation.Core)) {
                        write-host -ForegroundColor Red "`nFATAL ERROR: Cannot add the PowerCLI 5 Core Snapin!`n"
                        exit
                    }
                }
            }
        } else {
            # Error out if loading fails
            write-host -ForegroundColor Red "`nFATAL ERROR: Cannot add the PowerCLI ImageBuilder Snapin!`n"
            exit
        }
    }
} else {
    write-host -ForegroundColor Red "`nFATAL ERROR: It looks like there is no compatible version of PowerCLI installed!`n"
    exit
}

# Parameter sanity check
if ( ($v50 -and ($v51 -or $v55 -or $v60)) -or ($v51 -and ($v55 -or $v60)) -or ($v55 -and $v60) ) {
    write-host -ForegroundColor Yellow "`nWARNING: Multiple ESXi versions specified. Highest version will take precedence!"
}
if ($update -and ($izip -eq "")) {
    write-host -ForegroundColor Red "`nFATAL ERROR: -update requires -izip!`n"
    exit
}

# Check PowerShell and PowerCLI version
if (!(Test-Path variable:PSVersionTable)) {
    write-host -ForegroundColor Red "`nFATAL ERROR: This script requires at least PowerShell version 2.0!`n"
    exit
}
$psv = $PSVersionTable.PSVersion | select Major,Minor
$pcv = Get-PowerCLIVersion | select major,minor,UserFriendlyVersion
write-host ("`nRunning with PowerShell version " + $psv.Major + "." + $psv.Minor + " and " + $pcv.UserFriendlyVersion)

if ( ($pcv.major -lt 5) -or (($pcv.major -eq 5) -and ($pcv.minor -eq 0)) ) {
    write-host -ForegroundColor Red "`nFATAL ERROR: This script requires at least PowerCLI version 5.1 !`n"
    exit
}

if ($update) {
    # Try to add Offline bundle specified by -izip
    write-host -nonewline "`nAdding Base Offline bundle $izip (to be updated)..."
    if ($upddepot = Add-EsxSoftwaredepot $izip) {
        write-host -ForegroundColor Green " [OK]"
    } else {
        write-host -ForegroundColor Red "`nFATAL ERROR: Cannot add Base Offline bundle!`n"
        exit
    }
    if (!($CloneIP = Get-EsxImageprofile -Softwaredepot $upddepot)) {
        write-host -ForegroundColor Red "`nFATAL ERROR: No Imageprofiles found in Base Offline bundle!`n"
        exit
    }
    if ($CloneIP -is [system.array]) {
        # Input Offline bundle includes multiple Imageprofiles. Pick only the latest standard profile:
        write-host -ForegroundColor Yellow "Warning: Input Offline Bundle contains multiple Imageprofiles. Will pick the latest standard profile!"
        $CloneIP = @( $CloneIP | Sort-Object -Descending -Property @{Expression={$_.Name.Substring(0,10)}},@{Expression={$_.CreationTime.Date}},Name )[0]
    }
}

if (($izip -eq "") -or $update) {
    # Connect the VMware ESXi base depot
    write-host -nonewline "`nConnecting the VMware ESXi Online depot ..."
    if ($basedepot = Add-EsxSoftwaredepot $vmwdepotURL) {
        write-host -ForegroundColor Green " [OK]"
    } else {
        write-host -ForegroundColor Red "`nFATAL ERROR: Cannot add VMware ESXi Online depot. Please check your Internet connectivity and/or proxy settings!`n"
        exit
    }
} else {
    # Try to add Offline bundle specified by -izip
    write-host -nonewline "`nAdding base Offline bundle $izip ..."
    if ($basedepot = Add-EsxSoftwaredepot $izip) {
        write-host -ForegroundColor Green " [OK]"
    } else {
        write-host -ForegroundColor Red "`nFATAL ERROR: Cannot add VMware base Offline bundle!`n"
        exit
    }
}

if ($vft) {
    # Connect the V-Front Online depot
    write-host -nonewline "`nConnecting the V-Front Online depot ..."
    if ($vftdepot = Add-EsxSoftwaredepot $vftdepotURL) {
        write-host -ForegroundColor Green " [OK]"
    } else {
        write-host -ForegroundColor Red "`nFATAL ERROR: Cannot add the V-Front Online depot. Please check your internet connectivity and/or proxy settings!`n"
        exit
    }
}

if ($dpt -ne @()) {
	# Connect additional depots (Online depot or Offline bundle)
	$AddDpt = @()
	for ($i=0; $i -lt $dpt.Length; $i++ ) {
		write-host -nonewline ("`nConnecting additional depot " + $dpt[$i] + " ...")
		if ($AddDpt += Add-EsxSoftwaredepot $dpt[$i]) {
			write-host -ForegroundColor Green " [OK]"
		} else {
			write-host -ForegroundColor Red "`nFATAL ERROR: Cannot add Online depot or Offline bundle. In case of Online depot check your Internet"
            write-host -ForegroundColor Red "connectivity and/or proxy settings! In case of Offline bundle check file name, format and permissions!`n"
			exit
		}
	}

}

write-host -NoNewLine "`nGetting Imageprofiles, please wait ..."
$iplist = @()
if ($iZip -and !($update)) {
    Get-EsxImageprofile -Softwaredepot $basedepot | foreach { $iplist += $_ }
} else {
    if ($v60) {
        Get-EsxImageprofile "ESXi-6.0*" -Softwaredepot $basedepot | foreach { $iplist += $_ }
    } else {
        if ($v55) {
            Get-EsxImageprofile "ESXi-5.5*" -Softwaredepot $basedepot | foreach { $iplist += $_ }
        } else {
            if ($v51) {
                Get-EsxImageprofile "ESXi-5.1*" -Softwaredepot $basedepot | foreach { $iplist += $_ }
            } else {
                if ($v50) {
                    Get-EsxImageprofile "ESXi-5.0*" -Softwaredepot $basedepot | foreach { $iplist += $_ }
                } else {
                    # Workaround for http://kb.vmware.com/kb/2089217
                    Get-EsxImageprofile "ESXi-5.0*" -Softwaredepot $basedepot | foreach { $iplist += $_ }
                    Get-EsxImageprofile "ESXi-5.1*" -Softwaredepot $basedepot | foreach { $iplist += $_ }
                    Get-EsxImageprofile "ESXi-5.5*" -Softwaredepot $basedepot | foreach { $iplist += $_ }
                    Get-EsxImageprofile "ESXi-6.0*" -Softwaredepot $basedepot | foreach { $iplist += $_ }
                }
            }
        }
    }
}

if ($iplist.Length -eq 0) {
    write-host -ForegroundColor Red " [FAILED]`n`nFATAL ERROR: No valid Imageprofile(s) found!"
    if ($iZip) {
        write-host -ForegroundColor Red "The input file is probably not a full ESXi base bundle.`n"
    }
    exit
} else {
    write-host -ForegroundColor Green " [OK]"
    $iplist = @( $iplist | Sort-Object -Descending -Property @{Expression={$_.Name.Substring(0,10)}},@{Expression={$_.CreationTime.Date}},Name )
}

# if -sip then display menu of available image profiles ...
if ($sip) {
    if ($update) {
        write-host "`nSelect Imageprofile to use for update:"
    } else {
        write-host "`nSelect Base Imageprofile:"
    }
    write-host "-------------------------------------------"
    for ($i=0; $i -lt $iplist.Length; $i++ ) {
        write-host ($i+1): $iplist[$i].Name
    }
    write-host "-------------------------------------------"
    do {
        $sel = read-host "Enter selection"
        if (isNumeric $sel) {
            if (([int]$sel -lt 1) -or ([int]$sel -gt $iplist.Length)) { $sel = $null }
        } else {
            $sel = $null
        }
    } until ($sel)
    $idx = [int]$sel-1
} else {
    $idx = 0
}
if ($update) {
    $updIP = $iplist[$idx]
} else {
    $CloneIP = $iplist[$idx]
}

write-host ("`nUsing Imageprofile " + $CloneIP.Name + " ...")
write-host ("(dated " + $CloneIP.CreationTime + ", AcceptanceLevel: " + $CloneIP.AcceptanceLevel + ",")
write-host ($CloneIP.Description + ")")

# If customization is required ...
if (($pkgDir -ne "") -or $update -or ($load -ne @())) {

    # Create your own Imageprofile
    if ($ipname -eq "") { $ipname = $CloneIP.Name + "-customized" }
    if ($ipvendor -eq "") { $ipvendor = $CloneIP.Vendor }
    if ($ipdesc -eq "") { $ipdesc = $CloneIP.Description + " (customized)" }
    $MyProfile = New-EsxImageprofile -CloneProfile $CloneIP -Vendor $ipvendor -Name $ipname -Description $ipdesc

    # Update from Online depot profile
    if ($update) {
        write-host ("`nUpdating with the VMware Imageprofile " + $UpdIP.Name + " ...")
        write-host ("(dated " + $UpdIP.CreationTime + ", AcceptanceLevel: " + $UpdIP.AcceptanceLevel + ",")
        write-host ($UpdIP.Description + ")")
        $diff = Compare-EsxImageprofile $MyProfile $UpdIP
        $diff.UpgradeFromRef | foreach {
            $uguid = $_
            $uvib = Get-EsxSoftwarePackage | where { $_.Guid -eq $uguid }
            write-host -nonewline "   Add VIB" $uvib.Name $uvib.Version
            AddVIB2Profile $uvib
        }
    }

    # Loop over Offline bundles and VIB files
    if ($pkgDir -ne "") {
        write-host "`nLoading Offline bundles and VIB files from" $pkgDir ...
        foreach ($obundle in Get-Item $pkgDir\*.zip) {
            write-host -nonewline "   Loading" $obundle ...
            if ($ob = Add-EsxSoftwaredepot $obundle -ErrorAction SilentlyContinue) {
                write-host -ForegroundColor Green " [OK]"
                $ob | Get-EsxSoftwarePackage | foreach {
                    write-host -nonewline "      Add VIB" $_.Name $_.Version
                    AddVIB2Profile $_
                }
            } else {
                write-host -ForegroundColor Red " [FAILED]`n      Probably not a valid Offline bundle, ignoring."
            }
        }
        foreach ($vibFile in Get-Item $pkgDir\*.vib) {
            write-host -nonewline "   Loading" $vibFile ...
            try {
                $vib1 = Get-EsxSoftwarePackage -PackageUrl $vibFile -ErrorAction SilentlyContinue
                write-host -ForegroundColor Green " [OK]"
                write-host -nonewline "      Add VIB" $vib1.Name $vib1.Version
                AddVIB2Profile $vib1
            } catch {
                write-host -ForegroundColor Red " [FAILED]`n      Probably not a valid VIB file, ignoring."
            }
        }
    }
    # Load additional packages from Online depots or Offline bundles
    if ($load -ne @()) {
        write-host "`nLoad additional VIBs from Online depots ..."
        for ($i=0; $i -lt $load.Length; $i++ ) {
            if ($ovib = Get-ESXSoftwarePackage $load[$i] -Newest) {
                write-host -nonewline "   Add VIB" $ovib.Name $ovib.Version
                AddVIB2Profile $ovib
            } else {
                write-host -ForegroundColor Red "   [ERROR] Cannot find VIB named" $load[$i] "!"
            }
        }
    }
    # Remove selected VIBs
    if ($remove -ne @()) {
        write-host "`nRemove selected VIBs from Imageprofile ..."
        for ($i=0; $i -lt $remove.Length; $i++ ) {
            write-host -nonewline "      Remove VIB" $remove[$i]
            try {
                Remove-EsxSoftwarePackage -ImageProfile $MyProfile -SoftwarePackage $remove[$i] | Out-Null
                write-host -ForegroundColor Green " [OK]"
            } catch {
                write-host -ForegroundColor Red " [FAILED]`n      VIB does probably not exist or cannot be removed without breaking dependencies."
            }
        }
    }

} else {
    $MyProfile = $CloneIP
}


# Build the export command:
$cmd = "Export-EsxImageprofile -Imageprofile " + "`'" + $MyProfile.Name + "`'"

if ($ozip) {
    $outFile = "`'" + $outDir + "\" + $MyProfile.Name + ".zip" + "`'"
    $cmd = $cmd + " -ExportTobundle"
} else {
    $outFile = "`'" + $outDir + "\" + $MyProfile.Name + ".iso" + "`'"
    $cmd = $cmd + " -ExportToISO"
}
$cmd = $cmd + " -FilePath " + $outFile
if ($nsc) { $cmd = $cmd + " -NoSignatureCheck" }
$cmd = $cmd + " -Force"

# Run the export:
write-host -nonewline ("`nExporting the Imageprofile to " + $outFile + ". Please be patient ...")
if ($test) {
    write-host -ForegroundColor Yellow " [Skipped]"
} else {
    write-host "`n"
    Invoke-Expression $cmd
}

write-host -ForegroundColor Green "`nAll done.`n"

# The main catch ...
} catch {
    write-host -ForegroundColor Red ("`n`nAn unexpected error occured:`n" + $Error[0])
    write-host -ForegroundColor Red ("`nIf requesting support please be sure to include the log file`n   " + $log + "`n`n")

# The main cleanup
} finally {
    cleanup
}

# SIG # Begin signature block
# MIIaLwYJKoZIhvcNAQcCoIIaIDCCGhwCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUNbO+C/NAM5VrYQ2fSBYbwDw6
# c/ygghVQMIID7jCCA1egAwIBAgIQfpPr+3zGTlnqS5p31Ab8OzANBgkqhkiG9w0B
# AQUFADCBizELMAkGA1UEBhMCWkExFTATBgNVBAgTDFdlc3Rlcm4gQ2FwZTEUMBIG
# A1UEBxMLRHVyYmFudmlsbGUxDzANBgNVBAoTBlRoYXd0ZTEdMBsGA1UECxMUVGhh
# d3RlIENlcnRpZmljYXRpb24xHzAdBgNVBAMTFlRoYXd0ZSBUaW1lc3RhbXBpbmcg
# Q0EwHhcNMTIxMjIxMDAwMDAwWhcNMjAxMjMwMjM1OTU5WjBeMQswCQYDVQQGEwJV
# UzEdMBsGA1UEChMUU3ltYW50ZWMgQ29ycG9yYXRpb24xMDAuBgNVBAMTJ1N5bWFu
# dGVjIFRpbWUgU3RhbXBpbmcgU2VydmljZXMgQ0EgLSBHMjCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBALGss0lUS5ccEgrYJXmRIlcqb9y4JsRDc2vCvy5Q
# WvsUwnaOQwElQ7Sh4kX06Ld7w3TMIte0lAAC903tv7S3RCRrzV9FO9FEzkMScxeC
# i2m0K8uZHqxyGyZNcR+xMd37UWECU6aq9UksBXhFpS+JzueZ5/6M4lc/PcaS3Er4
# ezPkeQr78HWIQZz/xQNRmarXbJ+TaYdlKYOFwmAUxMjJOxTawIHwHw103pIiq8r3
# +3R8J+b3Sht/p8OeLa6K6qbmqicWfWH3mHERvOJQoUvlXfrlDqcsn6plINPYlujI
# fKVOSET/GeJEB5IL12iEgF1qeGRFzWBGflTBE3zFefHJwXECAwEAAaOB+jCB9zAd
# BgNVHQ4EFgQUX5r1blzMzHSa1N197z/b7EyALt0wMgYIKwYBBQUHAQEEJjAkMCIG
# CCsGAQUFBzABhhZodHRwOi8vb2NzcC50aGF3dGUuY29tMBIGA1UdEwEB/wQIMAYB
# Af8CAQAwPwYDVR0fBDgwNjA0oDKgMIYuaHR0cDovL2NybC50aGF3dGUuY29tL1Ro
# YXd0ZVRpbWVzdGFtcGluZ0NBLmNybDATBgNVHSUEDDAKBggrBgEFBQcDCDAOBgNV
# HQ8BAf8EBAMCAQYwKAYDVR0RBCEwH6QdMBsxGTAXBgNVBAMTEFRpbWVTdGFtcC0y
# MDQ4LTEwDQYJKoZIhvcNAQEFBQADgYEAAwmbj3nvf1kwqu9otfrjCR27T4IGXTdf
# plKfFo3qHJIJRG71betYfDDo+WmNI3MLEm9Hqa45EfgqsZuwGsOO61mWAK3ODE2y
# 0DGmCFwqevzieh1XTKhlGOl5QGIllm7HxzdqgyEIjkHq3dlXPx13SYcqFgZepjhq
# IhKjURmDfrYwggSjMIIDi6ADAgECAhAOz/Q4yP6/NW4E2GqYGxpQMA0GCSqGSIb3
# DQEBBQUAMF4xCzAJBgNVBAYTAlVTMR0wGwYDVQQKExRTeW1hbnRlYyBDb3Jwb3Jh
# dGlvbjEwMC4GA1UEAxMnU3ltYW50ZWMgVGltZSBTdGFtcGluZyBTZXJ2aWNlcyBD
# QSAtIEcyMB4XDTEyMTAxODAwMDAwMFoXDTIwMTIyOTIzNTk1OVowYjELMAkGA1UE
# BhMCVVMxHTAbBgNVBAoTFFN5bWFudGVjIENvcnBvcmF0aW9uMTQwMgYDVQQDEytT
# eW1hbnRlYyBUaW1lIFN0YW1waW5nIFNlcnZpY2VzIFNpZ25lciAtIEc0MIIBIjAN
# BgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAomMLOUS4uyOnREm7Dv+h8GEKU5Ow
# mNutLA9KxW7/hjxTVQ8VzgQ/K/2plpbZvmF5C1vJTIZ25eBDSyKV7sIrQ8Gf2Gi0
# jkBP7oU4uRHFI/JkWPAVMm9OV6GuiKQC1yoezUvh3WPVF4kyW7BemVqonShQDhfu
# ltthO0VRHc8SVguSR/yrrvZmPUescHLnkudfzRC5xINklBm9JYDh6NIipdC6Anqh
# d5NbZcPuF3S8QYYq3AhMjJKMkS2ed0QfaNaodHfbDlsyi1aLM73ZY8hJnTrFxeoz
# C9Lxoxv0i77Zs1eLO94Ep3oisiSuLsdwxb5OgyYI+wu9qU+ZCOEQKHKqzQIDAQAB
# o4IBVzCCAVMwDAYDVR0TAQH/BAIwADAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAO
# BgNVHQ8BAf8EBAMCB4AwcwYIKwYBBQUHAQEEZzBlMCoGCCsGAQUFBzABhh5odHRw
# Oi8vdHMtb2NzcC53cy5zeW1hbnRlYy5jb20wNwYIKwYBBQUHMAKGK2h0dHA6Ly90
# cy1haWEud3Muc3ltYW50ZWMuY29tL3Rzcy1jYS1nMi5jZXIwPAYDVR0fBDUwMzAx
# oC+gLYYraHR0cDovL3RzLWNybC53cy5zeW1hbnRlYy5jb20vdHNzLWNhLWcyLmNy
# bDAoBgNVHREEITAfpB0wGzEZMBcGA1UEAxMQVGltZVN0YW1wLTIwNDgtMjAdBgNV
# HQ4EFgQURsZpow5KFB7VTNpSYxc/Xja8DeYwHwYDVR0jBBgwFoAUX5r1blzMzHSa
# 1N197z/b7EyALt0wDQYJKoZIhvcNAQEFBQADggEBAHg7tJEqAEzwj2IwN3ijhCcH
# bxiy3iXcoNSUA6qGTiWfmkADHN3O43nLIWgG2rYytG2/9CwmYzPkSWRtDebDZw73
# BaQ1bHyJFsbpst+y6d0gxnEPzZV03LZc3r03H0N45ni1zSgEIKOq8UvEiCmRDoDR
# EfzdXHZuT14ORUZBbg2w6jiasTraCXEQ/Bx5tIB7rGn0/Zy2DBYr8X9bCT2bW+IW
# yhOBbQAuOA2oKY8s4bL0WqkBrxWcLC9JG9siu8P+eJRRw4axgohd8D20UaF5Mysu
# e7ncIAkTcetqGVvP6KUwVyyJST+5z3/Jvz4iaGNTmr1pdKzFHTx/kuDDvBzYBHUw
# ggY/MIIFJ6ADAgECAgcSunjQWTjOMA0GCSqGSIb3DQEBCwUAMIGMMQswCQYDVQQG
# EwJJTDEWMBQGA1UEChMNU3RhcnRDb20gTHRkLjErMCkGA1UECxMiU2VjdXJlIERp
# Z2l0YWwgQ2VydGlmaWNhdGUgU2lnbmluZzE4MDYGA1UEAxMvU3RhcnRDb20gQ2xh
# c3MgMiBQcmltYXJ5IEludGVybWVkaWF0ZSBPYmplY3QgQ0EwHhcNMTUwODI5MjAx
# MDQzWhcNMTcwODMwMTYwNjM1WjBzMQswCQYDVQQGEwJERTEPMA0GA1UECBMGSGVz
# c2VuMRIwEAYDVQQHEwlGcmFua2Z1cnQxFjAUBgNVBAMTDUFuZHJlYXMgUGVldHox
# JzAlBgkqhkiG9w0BCQEWGHN0YXJ0Y29tQHBlZXR6LW9ubGluZS5kZTCCASIwDQYJ
# KoZIhvcNAQEBBQADggEPADCCAQoCggEBAKEAzY1pBVZ2tQ3ooHJomCHPi0+f91Ic
# onaPL3nvWhXWCyq/2fsEpKXsmGZIPWRZstJNWwIiGFftxHvzzG8n/rTeuY7md9DB
# K/iORfixMvYhSZHlxxqownSjhiReIW7s/n4bTPWtTvCF/wcO8t+oDRHdUEiBVslf
# +8BVv8jetWbdiuQHlG3kYwEedMrUlVqEzKqoH/xxGnTeEKDdXkQ4rqtLmI0E3voU
# Rb8R3KDCBi+ii+HSnYswhMINlSpcA/Wpd0j6Gnh4s4rWyz3P69fu7B74Ny7yxyI+
# 5tE/UKRRGN9Hso6LC8kst4L8Z84ys9nXISEveVQAvk+3cti/PJSS3ZMCAwEAAaOC
# ArwwggK4MAkGA1UdEwQCMAAwDgYDVR0PAQH/BAQDAgeAMCIGA1UdJQEB/wQYMBYG
# CCsGAQUFBwMDBgorBgEEAYI3CgMNMB0GA1UdDgQWBBSUlyd5r/Zh4DodtnsSZosE
# EvMEzjAfBgNVHSMEGDAWgBTQTg9AmWy4SxlvOyi44OOIBzSqtzCCAUwGA1UdIASC
# AUMwggE/MIIBOwYLKwYBBAGBtTcBAgMwggEqMC4GCCsGAQUFBwIBFiJodHRwOi8v
# d3d3LnN0YXJ0c3NsLmNvbS9wb2xpY3kucGRmMIH3BggrBgEFBQcCAjCB6jAnFiBT
# dGFydENvbSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTADAgEBGoG+VGhpcyBjZXJ0
# aWZpY2F0ZSB3YXMgaXNzdWVkIGFjY29yZGluZyB0byB0aGUgQ2xhc3MgMiBWYWxp
# ZGF0aW9uIHJlcXVpcmVtZW50cyBvZiB0aGUgU3RhcnRDb20gQ0EgcG9saWN5LCBy
# ZWxpYW5jZSBvbmx5IGZvciB0aGUgaW50ZW5kZWQgcHVycG9zZSBpbiBjb21wbGlh
# bmNlIG9mIHRoZSByZWx5aW5nIHBhcnR5IG9ibGlnYXRpb25zLjA2BgNVHR8ELzAt
# MCugKaAnhiVodHRwOi8vY3JsLnN0YXJ0c3NsLmNvbS9jcnRjMi1jcmwuY3JsMIGJ
# BggrBgEFBQcBAQR9MHswNwYIKwYBBQUHMAGGK2h0dHA6Ly9vY3NwLnN0YXJ0c3Ns
# LmNvbS9zdWIvY2xhc3MyL2NvZGUvY2EwQAYIKwYBBQUHMAKGNGh0dHA6Ly9haWEu
# c3RhcnRzc2wuY29tL2NlcnRzL3N1Yi5jbGFzczIuY29kZS5jYS5jcnQwIwYDVR0S
# BBwwGoYYaHR0cDovL3d3dy5zdGFydHNzbC5jb20vMA0GCSqGSIb3DQEBCwUAA4IB
# AQAGMNDPul7mCPcws9ioEpZqgcbY52dxrJZZavmKxjJ08Co+sNkKHudDm3uqAo0h
# nrC6rzRC++2AC7wY7DxgJytimQGqCLA+5AyIRuRkdOzocOThHJfkM7hCUftUMBbP
# QWckR6EX8voLcWCR0llPcllawXBTz7HEsoRmG9ukmhAfoi2RE7BFfHA3c0/J2ZJE
# zypVlD6cMO4GWuXivFMX32jtJjHWQtRAsykfWgQ7xZpYol0D0ty+QaOflEytMcYP
# ki0JiHuECWAUHfyClma1qZJ1oxVB5+qvFhf75rNcre9aUx19p3SdSvyQqLWkTNN3
# mdU8G9UgHumCCMlJtkxGCArbMIIGcDCCBFigAwIBAgIBJDANBgkqhkiG9w0BAQUF
# ADB9MQswCQYDVQQGEwJJTDEWMBQGA1UEChMNU3RhcnRDb20gTHRkLjErMCkGA1UE
# CxMiU2VjdXJlIERpZ2l0YWwgQ2VydGlmaWNhdGUgU2lnbmluZzEpMCcGA1UEAxMg
# U3RhcnRDb20gQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkwHhcNMDcxMDI0MjIwMTQ2
# WhcNMTcxMDI0MjIwMTQ2WjCBjDELMAkGA1UEBhMCSUwxFjAUBgNVBAoTDVN0YXJ0
# Q29tIEx0ZC4xKzApBgNVBAsTIlNlY3VyZSBEaWdpdGFsIENlcnRpZmljYXRlIFNp
# Z25pbmcxODA2BgNVBAMTL1N0YXJ0Q29tIENsYXNzIDIgUHJpbWFyeSBJbnRlcm1l
# ZGlhdGUgT2JqZWN0IENBMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA
# yiOLIjUemqAbPJ1J0D8MlzgWKbr4fYlbRVjvhHDtfhFN6RQxq0PjTQxRgWzwFQNK
# JCdU5ftKoM5N4YSjId6ZNavcSa6/McVnhDAQm+8H3HWoD030NVOxbjgD/Ih3HaV3
# /z9159nnvyxQEckRZfpJB2Kfk6aHqW3JnSvRe+XVZSufDVCe/vtxGSEwKCaNrsLc
# 9pboUoYIC3oyzWoUTZ65+c0H4paR8c8eK/mC914mBo6N0dQ512/bkSdaeY9YaQpG
# tW/h/W/FkbQRT3sCpttLVlIjnkuY4r9+zvqhToPjxcfDYEf+XD8VGkAqle8Aa8hQ
# +M1qGdQjAye8OzbVuUOw7wIDAQABo4IB6TCCAeUwDwYDVR0TAQH/BAUwAwEB/zAO
# BgNVHQ8BAf8EBAMCAQYwHQYDVR0OBBYEFNBOD0CZbLhLGW87KLjg44gHNKq3MB8G
# A1UdIwQYMBaAFE4L7xqkQFulF2mHMMo0aEPQQa7yMD0GCCsGAQUFBwEBBDEwLzAt
# BggrBgEFBQcwAoYhaHR0cDovL3d3dy5zdGFydHNzbC5jb20vc2ZzY2EuY3J0MFsG
# A1UdHwRUMFIwJ6AloCOGIWh0dHA6Ly93d3cuc3RhcnRzc2wuY29tL3Nmc2NhLmNy
# bDAnoCWgI4YhaHR0cDovL2NybC5zdGFydHNzbC5jb20vc2ZzY2EuY3JsMIGABgNV
# HSAEeTB3MHUGCysGAQQBgbU3AQIBMGYwLgYIKwYBBQUHAgEWImh0dHA6Ly93d3cu
# c3RhcnRzc2wuY29tL3BvbGljeS5wZGYwNAYIKwYBBQUHAgEWKGh0dHA6Ly93d3cu
# c3RhcnRzc2wuY29tL2ludGVybWVkaWF0ZS5wZGYwEQYJYIZIAYb4QgEBBAQDAgAB
# MFAGCWCGSAGG+EIBDQRDFkFTdGFydENvbSBDbGFzcyAyIFByaW1hcnkgSW50ZXJt
# ZWRpYXRlIE9iamVjdCBTaWduaW5nIENlcnRpZmljYXRlczANBgkqhkiG9w0BAQUF
# AAOCAgEAcnMLA3VaN4OIE9l4QT5OEtZy5PByBit3oHiqQpgVEQo7DHRsjXD5H/Iy
# TivpMikaaeRxIv95baRd4hoUcMwDj4JIjC3WA9FoNFV31SMljEZa66G8RQECdMSS
# ufgfDYu1XQ+cUKxhD3EtLGGcFGjjML7EQv2Iol741rEsycXwIXcryxeiMbU2TPi7
# X3elbwQMc4JFlJ4By9FhBzuZB1DV2sN2irGVbC3G/1+S2doPDjL1CaElwRa/T0qk
# q2vvPxUgryAoCppUFKViw5yoGYC+z1GaesWWiP1eFKAL0wI7IgSvLzU3y1Vp7vsY
# axOVBqZtebFTWRHtXjCsFrrQBngt0d33QbQRI5mwgzEp7XJ9xu5d6RVWM4TPRUsd
# +DDZpBHm9mszvi9gVFb2ZG7qRRXCSqys4+u/NLBPbXi/m/lU00cODQTlC/euwjk9
# HQtRrXQ/zqsBJS6UJ+eLGw1qOfj+HVBl/ZQpfoLk7IoWlRQvRL1s7oirEaqPZUIW
# Y/grXq9r6jDKAp3LZdKQpPOnnogtqlU4f7/kLjEJhrrc98mrOWmVMK/BuFRAfQ5o
# DUMnVmCzAzLMjKfGcVW/iMew41yfhgKbwpfzm3LBr1Zv+pEBgcgW6onRLSAn3XHM
# 0eNtz+AkxH6rRf6B2mYhLEEGLapH8R1AMAo4BbVFOZR5kXcMCwoxggRJMIIERQIB
# ATCBmDCBjDELMAkGA1UEBhMCSUwxFjAUBgNVBAoTDVN0YXJ0Q29tIEx0ZC4xKzAp
# BgNVBAsTIlNlY3VyZSBEaWdpdGFsIENlcnRpZmljYXRlIFNpZ25pbmcxODA2BgNV
# BAMTL1N0YXJ0Q29tIENsYXNzIDIgUHJpbWFyeSBJbnRlcm1lZGlhdGUgT2JqZWN0
# IENBAgcSunjQWTjOMAkGBSsOAwIaBQCgeDAYBgorBgEEAYI3AgEMMQowCKACgACh
# AoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcCAQsxDjAM
# BgorBgEEAYI3AgEVMCMGCSqGSIb3DQEJBDEWBBRGUpozgkCEfdcrifLrdoYZjmlO
# nDANBgkqhkiG9w0BAQEFAASCAQAqyf6JeUbaSMcoZefu1XGsRAabhwos2Bg7A5an
# 1iXqDKXq5Y7GKE42uKugoz9sf6weKTtl2f+0b8SExxvcaSTw+5j7fIYrD4HjVGn5
# CmmG2ATBMNy+uTyoRlSx6inDfUgerVk8NFPu+aVTxPH1LhgYPiDpeCoJMWnG9Ctd
# 2L9RJIHIgXXZaaL0OFYCD34R7pRYxRpjJ5xEWNuCrMsajm9KvlJuHiJ5IMkRdg7o
# 8Qw6/T3roAniKxnCwqxgHJZgYj09coXHH7dYDH5MyZBDkz6WfpQ9iy/5aOSNXbyu
# ZPGO8PaBmxjDg+QaaZB0sFhNc/0z0JLGHuVlt1KfL5SqN6/6oYICCzCCAgcGCSqG
# SIb3DQEJBjGCAfgwggH0AgEBMHIwXjELMAkGA1UEBhMCVVMxHTAbBgNVBAoTFFN5
# bWFudGVjIENvcnBvcmF0aW9uMTAwLgYDVQQDEydTeW1hbnRlYyBUaW1lIFN0YW1w
# aW5nIFNlcnZpY2VzIENBIC0gRzICEA7P9DjI/r81bgTYapgbGlAwCQYFKw4DAhoF
# AKBdMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTE1
# MDkxMTA2MTExN1owIwYJKoZIhvcNAQkEMRYEFLL82iQghQE+dMAWZ+EzAFQ/iKAX
# MA0GCSqGSIb3DQEBAQUABIIBAHSUMm227g2l5o+J8KL1P4CWzdc6o5qAVdjI6PNq
# k8sMIcWoWDdxD26fZR5QFoPlC88ltamNsMjvF73qxEGnyLZf3OSUA5e9nf8Ju2pg
# XOQyp+hSSPhQJqoWKjVojfQLLbPZhGFTvKltW6rWFJ6Qzkvv6LdQ88DRbEn81ZpX
# d5fGNQuTtwSjafvWK/IQrnmN9oErWiUNnXKG+s3+d4QBjqA2HxboBKHgVgxEfQgj
# gqvQBqaFUI72C7bvYxhbI5xf3Tq7qq2PXLh8yzQ092Q0D5z8cfOsfnQYJ+2fPAyD
# mbxYt7rX9x+3T9+9s+EcAHzHuNYQ8Gg1TknYQSbjlPwcQnU=
# SIG # End signature block

<#
.SYNOPSIS
    Prüft Exchange Server nach den Windows Oktober 2026 Updates.

.DESCRIPTION
    Fragt per Invoke-Command auf jedem Server ab:
    - Letzter Boot, Uptime und Phase im kritischen Zeitfenster (24 bis 36 Stunden nach dem Boot)
    - Registry-Wert HKLM:\SOFTWARE\Microsoft\Rpc\EpmapSavedContextCap (Sollwert 65536)
    - Ob KB5126651 installiert ist
    - Anzahl Event 1006 mit MapiExceptionMdbOffline bzw. ec=1142 seit dem Boot

    Das Ergebnis wird als Tabelle angezeigt, pro Server bewertet und als CSV exportiert.
    Das Skript ändert nichts an den Servern.

.PARAMETER ComputerName
    Die zu prüfenden Exchange Server.

.PARAMETER OutputPath
    Ordner für den CSV-Export. Standard: C:\Admin\Scripts\Check-WinOctUpdate

.EXAMPLE
    .\Check-WinOctUpdate.ps1 -ComputerName EX-Server01, EX-Server02, EX-Server03, EX-Server04

.EXAMPLE
    .\Check-WinOctUpdate.ps1 -ComputerName (Get-ExchangeServer).Name

.NOTES
    Author:  iTrain GmbH, info@itrain.ch
    Created: 21.10.2026
    Version: 1.1
    Voraussetzung: PowerShell Remoting (WinRM) auf den Servern, Leserechte auf Registry und Application Log.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$ComputerName,

    [string]$OutputPath = 'C:\Admin\Scripts\Check-WinOctUpdate'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptBlock = {
    $boot   = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
    $uptime = ((Get-Date) - $boot).TotalHours
    $epmap  = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Rpc' -Name EpmapSavedContextCap -ErrorAction SilentlyContinue).EpmapSavedContextCap
    $kb     = [bool](Get-HotFix -Id KB5126651 -ErrorAction SilentlyContinue)
    $ev     = @(Get-WinEvent -FilterHashtable @{LogName = 'Application'; Id = 1006; StartTime = $boot} -ErrorAction SilentlyContinue |
                Where-Object { $_.Message -match 'MapiExceptionMdbOffline|ec=1142' })

    $phase = if     ($uptime -lt 24) { 'vor 24h' }
             elseif ($uptime -lt 36) { 'KRITISCH (24-36h)' }
             else                    { 'nach 36h' }

    [PSCustomObject]@{
        Server    = $env:COMPUTERNAME
        LastBoot  = $boot.ToString('dd.MM.yyyy HH:mm')
        Uptime_h  = [math]::Round($uptime, 1)
        Phase     = $phase
        Mark24h   = $boot.AddHours(24).ToString('dd.MM. HH:mm')
        Mark36h   = $boot.AddHours(36).ToString('dd.MM. HH:mm')
        KB5126651 = $kb
        EpmapCap  = $epmap
        Event1006 = $ev.Count
        LastEvent = if ($ev.Count -gt 0) { $ev[0].TimeCreated.ToString('dd.MM.yyyy HH:mm') } else { '' }
    }
}

# Nicht erreichbare Server landen in $RemoteErrors statt das Skript abzubrechen
$RemoteErrors = @()
$Result = @(Invoke-Command -ComputerName $ComputerName -ScriptBlock $ScriptBlock -ErrorAction SilentlyContinue -ErrorVariable RemoteErrors |
    Sort-Object -Property Server |
    Select-Object -Property PSComputerName, Server, LastBoot, Uptime_h, Phase, Mark24h, Mark36h, KB5126651, EpmapCap, Event1006, LastEvent)

$Result | Select-Object -Property * -ExcludeProperty PSComputerName | Format-Table -AutoSize

# Nicht erreichbare Server melden
$Reached = @($Result | ForEach-Object { $_.PSComputerName })
$Missing = @($ComputerName | Where-Object { $_ -notin $Reached })
if ($Missing.Count -gt 0) {
    Write-Host "Nicht erreichbar: $($Missing -join ', ')" -ForegroundColor Red
    foreach ($e in $RemoteErrors) { Write-Host "  $($e.TargetObject): $($e.Exception.Message)" -ForegroundColor Red }
}

# Bewertung
foreach ($r in $Result) {
    if ($r.Event1006 -gt 0) {
        Write-Host "$($r.Server): $($r.Event1006)x MapiExceptionMdbOffline seit dem Boot, letzter um $($r.LastEvent). Server prüfen!" -ForegroundColor Red
    }
    elseif ($r.EpmapCap -ne 65536) {
        Write-Host "$($r.Server): EpmapSavedContextCap ist nicht 65536 (Wert: $($r.EpmapCap))." -ForegroundColor Yellow
    }
    else {
        Write-Host "$($r.Server): OK" -ForegroundColor Green
    }
}

# Export
if ($Result.Count -gt 0) {
    try {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
        $CsvFile = Join-Path -Path $OutputPath -ChildPath ('Check-WinOctUpdate_{0}.csv' -f (Get-Date -Format 'yyyyMMdd_HHmm'))
        $Result | Export-Csv -Path $CsvFile -NoTypeInformation -Encoding UTF8 -Delimiter ';'
        Write-Host "Export: $CsvFile"
    }
    catch {
        Write-Warning "CSV-Export fehlgeschlagen: $($_.Exception.Message)"
    }
}

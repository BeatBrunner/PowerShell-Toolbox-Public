<#
.SYNOPSIS
    Prüft Exchange Server nach den Windows Oktober 2026 Updates.

.DESCRIPTION
    Fragt per Invoke-Command auf jedem Server ab:
    - Letzter Boot, Uptime und Phase im kritischen Zeitfenster (24 bis 36 Stunden nach dem Boot)
    - Registry-Wert HKLM:\SOFTWARE\Microsoft\Rpc\EpmapSavedContextCap (Sollwert 65536)
    - Windows Server Version und ob das betroffene Oktober 2026 Update dieser Version installiert ist:
      2016 KB5126868 (noch nicht von Microsoft bestätigt), 2019 KB5126651, 2022 KB5126655, 2025 KB5126646
    - Anzahl Event 1006 mit MapiExceptionMdbOffline bzw. ec=1142 seit dem Boot

    Hinweis: Die Prüfung läuft über Get-HotFix. Ersetzt ein späteres kumulatives Update das
    Oktober-Update, kann KBInstalled wieder False anzeigen.

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
    Version: 1.3
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

# Betroffenes Oktober 2026 Update pro Windows Server Build
$KBByBuild = @{
    '14393' = @{ OS = 'Server 2016'; KB = 'KB5126868' }   # noch nicht von Microsoft bestätigt
    '17763' = @{ OS = 'Server 2019'; KB = 'KB5126651' }
    '20348' = @{ OS = 'Server 2022'; KB = 'KB5126655' }
    '26100' = @{ OS = 'Server 2025'; KB = 'KB5126646' }
}

$ScriptBlock = {
    param($KBByBuild)

    $os     = Get-CimInstance -ClassName Win32_OperatingSystem
    $boot   = $os.LastBootUpTime
    $uptime = ((Get-Date) - $boot).TotalHours
    $epmap  = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Rpc' -Name EpmapSavedContextCap -ErrorAction SilentlyContinue).EpmapSavedContextCap
    $ubr    = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name UBR -ErrorAction SilentlyContinue).UBR

    $map = $KBByBuild["$($os.BuildNumber)"]
    if ($map) {
        $osName = $map.OS
        $kbId   = $map.KB
        $kb     = [bool](Get-HotFix -Id $kbId -ErrorAction SilentlyContinue)
    }
    else {
        $osName = "Build $($os.BuildNumber)"
        $kbId   = '-'
        $kb     = 'unbekannt'
    }
    $ev     = @(Get-WinEvent -FilterHashtable @{LogName = 'Application'; Id = 1006; StartTime = $boot} -ErrorAction SilentlyContinue |
                Where-Object { $_.Message -match 'MapiExceptionMdbOffline|ec=1142' })

    $phase = if     ($uptime -lt 24) { 'vor 24h' }
             elseif ($uptime -lt 36) { 'KRITISCH (24-36h)' }
             else                    { 'nach 36h' }

    [PSCustomObject]@{
        Server      = $env:COMPUTERNAME
        LastBoot    = $boot.ToString('dd.MM.yyyy HH:mm')
        Uptime_h    = [math]::Round($uptime, 1)
        Phase       = $phase
        Mark24h     = $boot.AddHours(24).ToString('dd.MM. HH:mm')
        Mark36h     = $boot.AddHours(36).ToString('dd.MM. HH:mm')
        OS          = $osName
        Build       = "$($os.BuildNumber).$ubr"
        KB          = $kbId
        KBInstalled = $kb
        EpmapCap    = $epmap
        Event1006   = $ev.Count
        LastEvent   = if ($ev.Count -gt 0) { $ev[0].TimeCreated.ToString('dd.MM.yyyy HH:mm') } else { '' }
    }
}

# Nicht erreichbare Server landen in $RemoteErrors statt das Skript abzubrechen
$RemoteErrors = @()
$Result = @(Invoke-Command -ComputerName $ComputerName -ScriptBlock $ScriptBlock -ArgumentList $KBByBuild -ErrorAction SilentlyContinue -ErrorVariable RemoteErrors |
    Sort-Object -Property Server |
    Select-Object -Property PSComputerName, Server, LastBoot, Uptime_h, Phase, Mark24h, Mark36h, OS, Build, KB, KBInstalled, EpmapCap, Event1006, LastEvent)

# Zwei Tabellen, damit alles in ein normales Konsolenfenster passt (CSV enthält alle Spalten)
$Result | Format-Table -Property Server, LastBoot, Uptime_h, Phase, Mark24h, Mark36h -AutoSize | Out-Host
$Result | Format-Table -Property Server, OS, Build, KB, KBInstalled, EpmapCap, Event1006, LastEvent -AutoSize | Out-Host

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

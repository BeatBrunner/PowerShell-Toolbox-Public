<#
.SYNOPSIS
    Überwacht Exchange Server auf das Problem mit den Windows Oktober 2026 Updates und allgemeine Störungen.

.DESCRIPTION
    Für die Ausführung als geplante Aufgabe alle 15 Minuten auf einem Exchange Server gedacht.
    Pro Server werden geprüft:
    1. Event 1006 MapiExceptionMdbOffline bzw. ec=1142 in den letzten 20 Minuten
    2. Transport Queues über dem Schwellwert
    3. Exchange Dienste (Test-ServiceHealth)
    4. Status der Datenbankkopien
    5. MAPI Test (erkennt Datenbanken, die mounted sind, aber nicht antworten)

    Mails werden gesendet beim ersten Problem, danach stündlich solange das Problem besteht,
    bei Erholung und zu den Stunden aus -HeartbeatHour als Lebenszeichen. Der letzte Status steht in state.txt im
    Arbeitsordner, das Protokoll in ExMonitor_JJJJMM.log.

    Läuft das Skript als SYSTEM, wird das lokale Exchange Snap-in geladen (kein Remote
    PowerShell Aufbau nötig), sonst wird die Exchange Management Shell verbunden.

.PARAMETER Servers
    Die zu überwachenden Exchange Server.

.PARAMETER To
    Empfänger der Alarm-Mails.

.PARAMETER From
    Absender der Alarm-Mails.

.PARAMETER SmtpHosts
    SMTP Server für den Mailversand, werden der Reihe nach versucht. Standard: die Werte aus -Servers.

.PARAMETER QueueMax
    Alarm ab so vielen Mails in einer Queue. Standard: 50

.PARAMETER HeartbeatHour
    Stunde(n) für das Lebenszeichen, mehrere mit Komma getrennt (z.B. 7, 12, 17). Standard: 7

.PARAMETER WorkDir
    Ordner für Statusdatei und Log. Standard: C:\Admin\Scripts\ExMonitor

.PARAMETER Test
    Sendet unabhängig vom Status eine Testmail mit dem aktuellen Ergebnis.

.EXAMPLE
    .\ExMonitor.ps1 -Servers EX-Server01, EX-Server02 -To admin@contoso.com -From exmonitor@contoso.com -Test

.EXAMPLE
    .\ExMonitor.ps1 -Servers EX-Server01, EX-Server02 -To admin@contoso.com -From exmonitor@contoso.com -WhatIf
    Führt alle Prüfungen aus, sendet aber keine Mail und schreibt keine Statusdatei.

.EXAMPLE
    .\Register-ExMonitorTask.ps1 -Servers EX-Server01, EX-Server02 -To admin@contoso.com -From exmonitor@contoso.com
    Richtet die geplante Aufgabe ein (als SYSTEM, alle 15 Minuten). Bei manueller Einrichtung
    powershell.exe mit -Command aufrufen, nicht mit -File, sonst kommt -Servers als ein String an.

.NOTES
    Author:  iTrain GmbH, info@itrain.ch
    Created: 21.10.2026
    Version: 1.6
    Läuft in Windows PowerShell 5.1 auf einem Exchange Server (Exchange Cmdlets nötig).
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string[]]$Servers,

    [Parameter(Mandatory)]
    [string[]]$To,

    [Parameter(Mandatory)]
    [string]$From,

    [string[]]$SmtpHosts,

    [int]$QueueMax = 50,

    # Mehrere Stunden als Standard nur in @(), z.B. @(7, 12, 17)
    [ValidateRange(0, 23)]
    [int[]]$HeartbeatHour = @(7),

    [string]$WorkDir = 'C:\Admin\Scripts\ExMonitor',

    [switch]$Test
)

if (-not $SmtpHosts) { $SmtpHosts = $Servers }
$MailParams = @{ From = $From; To = $To; Encoding = 'UTF8'; ErrorAction = 'Stop' }

$StateFile = Join-Path -Path $WorkDir -ChildPath 'state.txt'
$LogFile   = Join-Path -Path $WorkDir -ChildPath ('ExMonitor_{0}.log' -f (Get-Date -Format 'yyyyMM'))
New-Item -ItemType Directory -Path $WorkDir -Force -WhatIf:$false | Out-Null
$Now = Get-Date
$Ts  = $Now.ToString('dd.MM.yyyy HH:mm:ss')

function Write-Log {
    param([string]$Text)
    Add-Content -Path $LogFile -Value "$Ts $Text" -Encoding UTF8 -WhatIf:$false
}

function Send-Alert {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Subject, [string]$Body)

    if (-not $PSCmdlet.ShouldProcess(($MailParams.To -join ', '), "Mail senden: $Subject")) { return }
    foreach ($h in $SmtpHosts) {
        try {
            Send-MailMessage -SmtpServer $h -Subject $Subject -Body $Body @MailParams
            Write-Log "  Mail via $h gesendet: $Subject"
            return
        }
        catch {
            Write-Log "  Mail via $h fehlgeschlagen: $($_.Exception.Message)"
        }
    }
    Write-Log "  Mail konnte über keinen SMTP Server gesendet werden: $Subject"
}

Write-Log "Start als $env:USERDOMAIN\$env:USERNAME"

# Exchange Cmdlets laden, falls nicht schon vorhanden (z.B. Aufruf aus der Exchange Management Shell)
# Als SYSTEM über das lokale Snap-in (kein Remote PowerShell Aufbau), sonst über RemoteExchange.ps1
# -WhatIf gilt nur für Mails und Statusdatei, nicht für das Laden der Cmdlets
if (Get-Command -Name Get-Queue -ErrorAction SilentlyContinue) {
    Write-Log "  Exchange Cmdlets bereits geladen"
}
else {
    $SavedWhatIf = $WhatIfPreference
    $WhatIfPreference = $false
    try {
        if ($env:USERNAME -eq "$env:COMPUTERNAME`$") {
            Add-PSSnapin -Name Microsoft.Exchange.Management.PowerShell.SnapIn -ErrorAction Stop
            Write-Log "  Exchange Snap-in geladen"
        }
        else {
            . "$env:ExchangeInstallPath\bin\RemoteExchange.ps1" *> $null
            Connect-ExchangeServer -auto -ClientApplication:ManagementShell *> $null
            Write-Log "  Exchange Management Shell verbunden"
        }
    }
    catch {
        Write-Log "  Exchange Cmdlets konnten nicht geladen werden: $($_.Exception.Message)"
    }
    finally {
        $WhatIfPreference = $SavedWhatIf
    }
}
if (-not (Get-Command -Name Get-Queue -ErrorAction SilentlyContinue)) {
    Write-Log "  Get-Queue nicht verfügbar, Exchange Prüfungen schlagen fehl"
}

# Erst nach dem Laden der Exchange Cmdlets, RemoteExchange.ps1 ist nicht StrictMode-fest.
# Exchange Cmdlets über die Remote-Session ignorieren $ErrorActionPreference, darum unten überall -ErrorAction Stop
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Problems = @()
$Summary  = @()
$Since    = $Now.AddMinutes(-20)

foreach ($s in $Servers) {
    $evCount = 0; $qMax = 0; $svc = 'OK'; $db = 'OK'; $mapi = 'OK'
    Write-Log "  Prüfe $s"

    # 1. Event 1006 MapiExceptionMdbOffline (Symptom Windows Oktober Update)
    try {
        $ev = @(Get-WinEvent -ComputerName $s -FilterHashtable @{LogName = 'Application'; Id = 1006; StartTime = $Since} -ErrorAction Stop |
              Where-Object { $_.Message -match 'MapiExceptionMdbOffline|ec=1142' })
        $evCount = $ev.Count
        if ($evCount -gt 0) { $Problems += "$s : $evCount x Event 1006 MapiExceptionMdbOffline" }
    }
    catch {
        if ($_.FullyQualifiedErrorId -notmatch 'NoMatchingEventsFound') {
            $evCount = 'Fehler'
            $Problems += "$s : Eventlog nicht erreichbar ($($_.Exception.Message))"
        }
    }

    # 2. Queues
    try {
        $q = @(Get-Queue -Server $s -ErrorAction Stop)
        if ($q.Count -gt 0) { $qMax = ($q | Measure-Object -Property MessageCount -Maximum).Maximum }
        foreach ($item in $q | Where-Object { $_.MessageCount -gt $QueueMax }) {
            $Problems += "$s : Queue $($item.Identity) hat $($item.MessageCount) Mails (Status $($item.Status))"
        }
    }
    catch { $qMax = 'Fehler'; $Problems += "$s : Get-Queue fehlgeschlagen ($($_.Exception.Message))" }

    # 3. Exchange Dienste
    try {
        foreach ($item in Test-ServiceHealth -Server $s -ErrorAction Stop | Where-Object { -not $_.RequiredServicesRunning }) {
            $svc = 'PROBLEM'
            $Problems += "$s : Dienste gestoppt ($($item.Role)): $($item.ServicesNotRunning -join ', ')"
        }
    }
    catch { $svc = 'Fehler'; $Problems += "$s : Test-ServiceHealth fehlgeschlagen ($($_.Exception.Message))" }

    # 4. Datenbankkopien
    try {
        $copies = @(Get-MailboxDatabaseCopyStatus -Server $s -ErrorAction Stop)
        $db = ($copies | ForEach-Object { "$($_.DatabaseName)=$($_.Status)" }) -join ' '
        foreach ($item in $copies | Where-Object { "$($_.Status)" -notin 'Mounted', 'Healthy' }) {
            $Problems += "$s : DB Kopie $($item.Name) Status $($item.Status)"
        }
    }
    catch { $db = 'Fehler'; $Problems += "$s : Get-MailboxDatabaseCopyStatus fehlgeschlagen ($($_.Exception.Message))" }

    # 5. MAPI Test (erkennt Datenbanken, die mounted sind, aber nicht antworten)
    try {
        foreach ($item in Test-MAPIConnectivity -Server $s -ErrorAction Stop | Where-Object { "$($_.Result)" -ne 'Success' }) {
            $mapi = 'PROBLEM'
            $Problems += "$s : MAPI Test $($item.Database) $($item.Result) $($item.Error)"
        }
    }
    catch { $mapi = 'Fehler'; $Problems += "$s : Test-MAPIConnectivity fehlgeschlagen ($($_.Exception.Message))" }

    $Summary += "{0}: Event1006={1}, MaxQueue={2}, Dienste={3}, MAPI={4}, DB: {5}" -f $s, $evCount, $qMax, $svc, $mapi, $db
}

$State = if ($Problems.Count -gt 0) { 'PROBLEM' } else { 'OK' }
$Prev  = if (Test-Path -Path $StateFile) { Get-Content -Path $StateFile -TotalCount 1 } else { 'OK' }
$Dauer = [int]((Get-Date) - $Now).TotalSeconds

Write-Log "Status $State (vorher $Prev), Dauer $Dauer s"
$Summary  | ForEach-Object { Write-Log "  $_" }
$Problems | ForEach-Object { Write-Log "  PROBLEM: $_" }

if ($Problems.Count -gt 0) { $Detail = "Probleme:`r`n" + ($Problems -join "`r`n") + "`r`n`r`n" }
else                       { $Detail = "Alle Prüfungen OK.`r`n`r`n" }
$Detail += "Übersicht:`r`n" + ($Summary -join "`r`n")

if ($Test) {
    Send-Alert -Subject "ExMonitor: TEST ($State)" -Body "Testmail ExMonitor, $Ts`r`n`r`n$Detail"
}
elseif ($State -eq 'PROBLEM') {
    # Erster Alarm sofort, danach stündliche Erinnerung solange das Problem besteht
    if ($Prev -ne 'PROBLEM' -or $Now.Minute -lt 15) {
        Send-Alert -Subject 'ExMonitor: PROBLEM' -Body "Problem erkannt am $Ts`r`n`r`n$Detail"
    }
}
elseif ($Prev -eq 'PROBLEM') {
    Send-Alert -Subject 'ExMonitor: wieder OK' -Body "Alle Prüfungen sind seit $Ts wieder OK.`r`n`r`n$Detail"
}
elseif ($Now.Hour -in $HeartbeatHour -and $Now.Minute -lt 15) {
    Send-Alert -Subject 'ExMonitor: OK (Lebenszeichen)' -Body "ExMonitor läuft, $Ts`r`n`r`n$Detail"
}

# Statusdatei: Zeile 1 = Status (wird beim nächsten Lauf gelesen), danach Details
$StateLines = @($State, "Letzte Prüfung: $Ts (Dauer $Dauer s)", '') + $Summary
if ($Problems.Count -gt 0) { $StateLines += @('') + $Problems }
if ($PSCmdlet.ShouldProcess($StateFile, 'Statusdatei schreiben')) {
    try {
        Set-Content -Path $StateFile -Value $StateLines -Encoding UTF8
    }
    catch {
        Write-Log "  Statusdatei konnte nicht geschrieben werden: $($_.Exception.Message)"
    }
}

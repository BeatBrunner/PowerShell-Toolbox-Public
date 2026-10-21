<#
.SYNOPSIS
    Erstellt oder aktualisiert die geplante Aufgabe für ExMonitor.ps1.

.DESCRIPTION
    Registriert auf dem lokalen Exchange Server eine geplante Aufgabe, die ExMonitor.ps1 alle
    15 Minuten als SYSTEM ausführt. Das Intervall ist fix, weil ExMonitor die stündliche
    Erinnerung und das tägliche Lebenszeichen auf Läufe im 15-Minuten-Takt abstimmt.

    Der erste Lauf startet zur nächsten Viertelstunde. Eine bereits vorhandene Aufgabe mit
    demselben Namen wird vorher als XML gesichert und danach überschrieben.

    Als SYSTEM lädt ExMonitor das lokale Exchange Snap-in. Für die Remote-Abfrage der
    Eventlogs braucht das Computerkonto Leserechte auf den anderen Servern (auf Exchange
    Servern über die Gruppe Exchange Trusted Subsystem in der Regel gegeben).

.PARAMETER ScriptPath
    Pfad zu ExMonitor.ps1 auf diesem Server. Standard: C:\Admin\Scripts\ExMonitor\ExMonitor.ps1

.PARAMETER Servers
    Die zu überwachenden Exchange Server (wird an ExMonitor.ps1 übergeben).

.PARAMETER To
    Empfänger der Alarm-Mails (wird an ExMonitor.ps1 übergeben).

.PARAMETER From
    Absender der Alarm-Mails (wird an ExMonitor.ps1 übergeben).

.PARAMETER SmtpHosts
    Optionale SMTP Server für den Mailversand (wird an ExMonitor.ps1 übergeben).

.PARAMETER TaskName
    Name der geplanten Aufgabe. Standard: ExMonitor

.PARAMETER TaskPath
    Ordner in der Aufgabenplanung. Standard: \iTrain\

.PARAMETER OutputPath
    Ordner für Backup der bestehenden Aufgabe und Fehlerlog. Standard: C:\Admin\Scripts\Register-ExMonitorTask

.EXAMPLE
    .\Register-ExMonitorTask.ps1 -Servers EX-Server01, EX-Server02 -To admin@contoso.com -From exmonitor@contoso.com

.EXAMPLE
    .\Register-ExMonitorTask.ps1 -Servers EX-Server01, EX-Server02 -To admin@contoso.com -From exmonitor@contoso.com -WhatIf
    Zeigt nur an, welche Aufgabe registriert würde.

.EXAMPLE
    Start-ScheduledTask -TaskPath '\iTrain\' -TaskName 'ExMonitor'
    Startet die Aufgabe nach der Registrierung sofort einmal; Ergebnis im Log von ExMonitor prüfen.

.NOTES
    Author:  iTrain GmbH, info@itrain.ch
    Created: 21.10.2026
    Version: 1.1
    Als Administrator auf dem Exchange Server ausführen, der die Überwachung übernimmt.
    Windows Server 2016 oder neuer (Wiederholung ohne Enddatum).
#>
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ScriptPath = 'C:\Admin\Scripts\ExMonitor\ExMonitor.ps1',

    [Parameter(Mandatory)]
    [string[]]$Servers,

    [Parameter(Mandatory)]
    [string[]]$To,

    [Parameter(Mandatory)]
    [string]$From,

    [string[]]$SmtpHosts,

    [string]$TaskName = 'ExMonitor',

    [string]$TaskPath = '\iTrain\',

    [string]$OutputPath = 'C:\Admin\Scripts\Register-ExMonitorTask'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Wert als PowerShell-Literal in einfachen Anführungszeichen
function ConvertTo-Literal {
    param([string[]]$Value)
    ($Value | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
}

New-Item -ItemType Directory -Path $OutputPath -Force -WhatIf:$false | Out-Null
$Stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$ErrorLog = Join-Path -Path $OutputPath -ChildPath "Register-ExMonitorTask_Errors_$Stamp.log"

if (-not (Test-Path -Path $ScriptPath -PathType Leaf)) {
    Write-Warning "ExMonitor.ps1 nicht gefunden: $ScriptPath. Die Aufgabe wird trotzdem registriert, schlägt aber fehl, bis das Skript dort liegt."
}

# Mit -Command statt -File, sonst kommen Listen wie 'EX1,EX2' als ein einziger String an
$Command = "& $(ConvertTo-Literal $ScriptPath) -Servers $(ConvertTo-Literal $Servers) -To $(ConvertTo-Literal $To) -From $(ConvertTo-Literal $From)"
if ($SmtpHosts) { $Command += " -SmtpHosts $(ConvertTo-Literal $SmtpHosts)" }
$Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command `"$Command`""

# Erster Lauf zur nächsten Viertelstunde
$Now   = Get-Date
$Start = $Now.Date.AddHours($Now.Hour).AddMinutes(([math]::Floor($Now.Minute / 15) + 1) * 15)

$Action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $Arguments -WorkingDirectory (Split-Path -Path $ScriptPath -Parent)
$Trigger   = New-ScheduledTaskTrigger -Once -At $Start -RepetitionInterval (New-TimeSpan -Minutes 15)
$Principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$Settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew -StartWhenAvailable

Write-Host "Aufgabe:   $TaskPath$TaskName"
Write-Host "Erster Lauf: $($Start.ToString('dd.MM.yyyy HH:mm')), danach alle 15 Minuten als SYSTEM"
Write-Host "Befehl:    powershell.exe $Arguments"

try {
    $Existing = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if ($Existing) {
        $BackupFile = Join-Path -Path $OutputPath -ChildPath "${TaskName}_Backup_$Stamp.xml"
        Export-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop | Set-Content -Path $BackupFile -Encoding UTF8 -WhatIf:$false
        Write-Host "Bestehende Aufgabe gesichert: $BackupFile"
    }

    if ($PSCmdlet.ShouldProcess("$TaskPath$TaskName", 'Geplante Aufgabe registrieren')) {
        Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings `
            -Description 'Exchange Überwachung (ExMonitor.ps1), alle 15 Minuten' -Force -ErrorAction Stop | Out-Null
        Write-Host "Aufgabe registriert. Test: Start-ScheduledTask -TaskPath '$TaskPath' -TaskName '$TaskName'" -ForegroundColor Green
    }
}
catch {
    "$(Get-Date -Format 'dd.MM.yyyy HH:mm:ss') $($_.Exception.Message)" | Add-Content -Path $ErrorLog -Encoding UTF8 -WhatIf:$false
    Write-Error "Registrierung fehlgeschlagen: $($_.Exception.Message) (Log: $ErrorLog)" -ErrorAction Continue
    exit 1
}

# PowerShell Toolbox (Public)

PowerShell-Skripte für die Administration von Microsoft Server- und Cloud-Umgebungen, bereitgestellt von der iTrain GmbH.

Die Skripte laufen unter Windows PowerShell 5.1 und PowerShell 7, sofern im Header nicht anders angegeben. Jedes Skript enthält eine Hilfe:

```powershell
Get-Help .\Skript.ps1 -Full
```

## Skripte

### Exchange\Oct-Win-Update-Check

- **Check-WinOctUpdate.ps1** – Prüft Exchange Server nach den Windows Oktober 2026 Updates: Uptime und kritisches Zeitfenster (24 bis 36 Stunden), EpmapSavedContextCap, KB5126651 und Event 1006 MapiExceptionMdbOffline seit dem Boot, mit CSV-Export.
- **ExMonitor.ps1** – Überwacht Exchange Server (Event 1006, Queues, Dienste, DB-Kopien, MAPI) als geplante Aufgabe und sendet Mails bei Problem, Erholung und täglich ein Lebenszeichen; Testlauf mit -Test, -WhatIf unterdrückt Mailversand.
- **Register-ExMonitorTask.ps1** – Erstellt oder aktualisiert die geplante Aufgabe für ExMonitor.ps1 (als SYSTEM, alle 15 Minuten), sichert eine bestehende Aufgabe vorher als XML.

Download einzelner Skripte über den Button "Download raw file" in der Dateiansicht oder per PowerShell:

```powershell
Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/BeatBrunner/PowerShell-Toolbox-Public/main/Exchange/Oct-Win-Update-Check/Check-WinOctUpdate.ps1' -OutFile .\Check-WinOctUpdate.ps1
Unblock-File -Path .\Check-WinOctUpdate.ps1
```

## Hinweise

- Skripte vor dem Einsatz in einer Testumgebung prüfen. Ändernde Skripte unterstützen `-WhatIf`.
- Verwendung auf eigene Verantwortung, siehe [LICENSE](LICENSE).

## Kontakt

iTrain GmbH, info@itrain.ch

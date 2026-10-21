# Exchange: Prüfung und Überwachung nach den Windows Oktober 2026 Updates

Drei Skripte für Exchange Server on-premises:

| Skript | Zweck |
|---|---|
| `Check-WinOctUpdate.ps1` | Einmalige Prüfung aller Exchange Server: Uptime, kritisches Zeitfenster 24 bis 36 Stunden nach dem Boot, Registry-Wert EpmapSavedContextCap, betroffenes Oktober-Update je Windows Server Version, Event 1006 MapiExceptionMdbOffline |
| `ExMonitor.ps1` | Laufende Überwachung (Event 1006, Queues, Dienste, Datenbankkopien, MAPI) mit Mail bei Problem, bei Erholung und täglich als Lebenszeichen |
| `Register-ExMonitorTask.ps1` | Richtet ExMonitor als geplante Aufgabe ein (als SYSTEM, alle 15 Minuten) |

Die Skripte ändern nichts an der Exchange Konfiguration. Sie lesen nur, senden Mails und schreiben Logs nach `C:\Admin\Scripts\`.

## 1. Voraussetzungen

- Exchange Server 2016, 2019 oder Subscription Edition auf Windows Server 2016 oder neuer
- Ausführung auf einem der Exchange Server, in einer PowerShell **als Administrator**
- Konto mit Exchange Rolle Organization Management bzw. View-Only Organization Management (für die manuellen Tests)
- PowerShell Remoting (WinRM) zwischen den Exchange Servern, für `Check-WinOctUpdate.ps1`
- Remote-Eventlog-Zugriff zwischen den Exchange Servern (Firewall-Regel "Remote Event Log Management"), für `ExMonitor.ps1`
- Mailversand: ExMonitor sendet anonym über SMTP Port 25 an die Exchange Server. Die Absenderadresse sollte aus einer Accepted Domain sein. In der Standardkonfiguration nimmt Exchange anonym nur Mails an interne Empfänger an; externe Empfänger gehen nur, wenn ein Receive Connector das Relay erlaubt. Am einfachsten mit `-Test` ausprobieren.

## 2. Download

Auf dem Exchange Server, der die Überwachung übernimmt, in einer PowerShell als Administrator:

```powershell
$Ziel = 'C:\Admin\Scripts\ExMonitor'
New-Item -ItemType Directory -Path $Ziel -Force | Out-Null

# Auf Windows Server 2016 nötig, damit GitHub erreichbar ist
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Basis = 'https://raw.githubusercontent.com/BeatBrunner/PowerShell-Toolbox-Public/main/Exchange/Oct-Win-Update-Check'
foreach ($Datei in 'Check-WinOctUpdate.ps1', 'ExMonitor.ps1', 'Register-ExMonitorTask.ps1') {
    Invoke-WebRequest -Uri "$Basis/$Datei" -OutFile (Join-Path -Path $Ziel -ChildPath $Datei) -UseBasicParsing
}
Get-ChildItem -Path $Ziel -Filter *.ps1 | Unblock-File
Set-Location -Path $Ziel
```

### Download blockiert (Proxy) oder kein Internetzugang

Proxies wie Zscaler sperren `raw.githubusercontent.com` oft (Kategorie "FileHost"). `Invoke-WebRequest` gibt dann statt des Skripts eine HTML-Seite des Proxys als Fehler aus, z.B. mit dem Text "Not allowed to browse FileHost category". In diesem Fall:

1. Den Download-Block oben auf dem eigenen PC oder Laptop ausführen, `$Ziel` dabei auf einen lokalen Ordner setzen. Alternativ in der GitHub Dateiansicht jedes Skript über "Download raw file" speichern.
2. Die drei Dateien über die RDP-Sitzung auf den Server kopieren (im Explorer Ctrl+C auf dem PC, Ctrl+V in `C:\Admin\Scripts\ExMonitor` auf dem Server).
3. Ist das Kopieren von Dateien über RDP gesperrt: Skript lokal öffnen, gesamten Text kopieren, auf dem Server in Notepad einfügen und mit der Kodierung **UTF-8 mit BOM** speichern (sonst zeigt Windows PowerShell 5.1 Umlaute falsch an).
4. Auf dem Server die Dateien freigeben:

```powershell
Get-ChildItem -Path C:\Admin\Scripts\ExMonitor -Filter *.ps1 | Unblock-File
Set-Location -Path C:\Admin\Scripts\ExMonitor
```

Kontrolle, ob alle drei Skripte vorhanden und gültig sind:

```powershell
Get-ChildItem -Path C:\Admin\Scripts\ExMonitor -Filter *.ps1 | ForEach-Object { '{0}: {1}' -f $_.Name, (Get-Help $_.FullName).Synopsis }
```

Pro Skript muss eine Zeile mit der Kurzbeschreibung erscheinen.

Hilfe zu jedem Skript:

```powershell
Get-Help .\ExMonitor.ps1 -Full
```

## 3. Check-WinOctUpdate.ps1: einmalige Prüfung

```powershell
.\Check-WinOctUpdate.ps1 -ComputerName EX-Server01, EX-Server02, EX-Server03, EX-Server04
```

Alternativ alle Exchange Server aus der Organisation (in der Exchange Management Shell):

```powershell
.\Check-WinOctUpdate.ps1 -ComputerName (Get-ExchangeServer).Name
```

Ausgabe in zwei Tabellen (Zeitfenster und Update-Stand), die CSV enthält alle Spalten:

| Spalte | Bedeutung |
|---|---|
| `LastBoot`, `Uptime_h` | Letzter Neustart und Laufzeit in Stunden |
| `Phase` | `vor 24h`, `KRITISCH (24-36h)` oder `nach 36h` seit dem Boot |
| `Mark24h`, `Mark36h` | Zeitpunkte, an denen das kritische Zeitfenster beginnt und endet |
| `OS`, `Build` | Windows Server Version und Build inkl. Update-Stand, z.B. 17763.1234 |
| `KB`, `KBInstalled` | Betroffenes Oktober 2026 Update dieser Version und ob es installiert ist: 2016 KB5126868, 2019 KB5126651, 2022 KB5126655, 2025 KB5126646. `unbekannt` bei einer anderen Windows Version. Ersetzt ein späteres kumulatives Update das Oktober-Update, kann hier wieder `False` stehen. |
| `EpmapCap` | Registry-Wert `HKLM:\SOFTWARE\Microsoft\Rpc\EpmapSavedContextCap`, erwartet wird 65536 |
| `Event1006`, `LastEvent` | Anzahl Event 1006 MapiExceptionMdbOffline seit dem Boot und Zeitpunkt des letzten |

Darunter folgt pro Server eine Bewertung: rot bei Event 1006, gelb wenn EpmapSavedContextCap nicht 65536 ist, sonst grün. Nicht erreichbare Server werden mit Fehlermeldung aufgeführt. Das Ergebnis wird zusätzlich als CSV nach `C:\Admin\Scripts\Check-WinOctUpdate\` geschrieben.

## 4. ExMonitor.ps1: manuell testen

In der **Exchange Management Shell** (als Administrator) ausführen. Die Beispielwerte `EX-Server01`, `admin@contoso.com` usw. durch die eigenen Servernamen und Adressen ersetzen. Alle Exchange Server der Organisation lassen sich direkt übergeben:

```powershell
.\ExMonitor.ps1 -Servers (Get-ExchangeServer).Name -To admin@contoso.com -From exmonitor@contoso.com -WhatIf
```

Mit falschen Servernamen meldet jede Prüfung einen Fehler ("Exchange server ... wasn't found") und der Status ist PROBLEM.

Schritt 1, nur prüfen, ohne Mail:

```powershell
.\ExMonitor.ps1 -Servers EX-Server01, EX-Server02 -To admin@contoso.com -From exmonitor@contoso.com -WhatIf
```

Das Ergebnis steht im Log `C:\Admin\Scripts\ExMonitor\ExMonitor_JJJJMM.log`:

```powershell
Get-Content -Path "C:\Admin\Scripts\ExMonitor\ExMonitor_$(Get-Date -Format 'yyyyMM').log" -Tail 20
```

Pro Server steht dort eine Zeile wie `EX-Server01: Event1006=0, MaxQueue=0, Dienste=OK, MAPI=OK, DB: DB01=Mounted ...`, bei Problemen zusätzlich Zeilen mit `PROBLEM:`.

Schritt 2, Testmail senden:

```powershell
.\ExMonitor.ps1 -Servers EX-Server01, EX-Server02 -To admin@contoso.com -From exmonitor@contoso.com -Test
```

Es kommt eine Mail mit dem Betreff `ExMonitor: TEST (OK)` bzw. `ExMonitor: TEST (PROBLEM)` und der Übersicht aller Server.

Weitere Parameter:

| Parameter | Standard | Bedeutung |
|---|---|---|
| `-SmtpHosts` | Werte aus `-Servers` | SMTP Server für den Mailversand, werden der Reihe nach versucht |
| `-QueueMax` | 50 | Alarm ab so vielen Mails in einer Queue |
| `-HeartbeatHour` | 7 | Stunde für das tägliche Lebenszeichen |
| `-WorkDir` | `C:\Admin\Scripts\ExMonitor` | Ordner für Log und Statusdatei |

## 5. Register-ExMonitorTask.ps1: geplante Aufgabe einrichten

In einer PowerShell **als Administrator** (keine Exchange Management Shell nötig). In der Exchange Management Shell geht auch `-Servers (Get-ExchangeServer).Name`. Die Serverliste wird beim Einrichten fest in die Aufgabe geschrieben. Kommt ein Server dazu, das Skript erneut ausführen.

Schritt 1, anzeigen was eingerichtet würde:

```powershell
.\Register-ExMonitorTask.ps1 -Servers EX-Server01, EX-Server02 -To admin@contoso.com -From exmonitor@contoso.com -WhatIf
```

Schritt 2, einrichten:

```powershell
.\Register-ExMonitorTask.ps1 -Servers EX-Server01, EX-Server02 -To admin@contoso.com -From exmonitor@contoso.com
```

Die Aufgabe heisst `ExMonitor` im Ordner `\iTrain\` der Aufgabenplanung und läuft ab der nächsten Viertelstunde alle 15 Minuten als SYSTEM. Liegt ExMonitor.ps1 nicht in `C:\Admin\Scripts\ExMonitor`, den Pfad mit `-ScriptPath` angeben. Eine bereits vorhandene Aufgabe wird vorher als XML nach `C:\Admin\Scripts\Register-ExMonitorTask\` gesichert und dann überschrieben. Für geänderte Empfänger oder Server das Skript einfach erneut ausführen.

Schritt 3, sofort einmal starten und prüfen:

```powershell
Start-ScheduledTask -TaskPath '\iTrain\' -TaskName 'ExMonitor'
Get-ScheduledTaskInfo -TaskPath '\iTrain\' -TaskName 'ExMonitor' | Select-Object -Property LastRunTime, LastTaskResult, NextRunTime
Get-Content -Path "C:\Admin\Scripts\ExMonitor\ExMonitor_$(Get-Date -Format 'yyyyMM').log" -Tail 20
```

Erwartet:

- `LastTaskResult` ist `0` (während des Laufs `267009`, dann kurz warten)
- Im Log steht `Start als DOMAIN\SERVERNAME$` und `Exchange Snap-in geladen`
- Pro Server eine Übersichtszeile ohne `Fehler`

Die Statusdatei `C:\Admin\Scripts\ExMonitor\state.txt` zeigt jederzeit das Ergebnis der letzten Prüfung.

## 6. Wann kommen Mails

| Situation | Mail |
|---|---|
| Problem neu erkannt | Sofort `ExMonitor: PROBLEM` |
| Problem besteht weiter | Einmal pro Stunde (Lauf in den ersten 15 Minuten der Stunde) erneut `ExMonitor: PROBLEM` |
| Problem behoben | `ExMonitor: wieder OK` |
| Alles OK | Täglich um 07:00 `ExMonitor: OK (täglich)` |
| Aufruf mit `-Test` | Immer `ExMonitor: TEST (...)` |

Geprüft wird pro Server:

1. Event 1006 MapiExceptionMdbOffline bzw. ec=1142 in den letzten 20 Minuten
2. Transport Queues mit mehr als 50 Mails
3. Exchange Dienste (`Test-ServiceHealth`)
4. Status der Datenbankkopien (erwartet Mounted oder Healthy)
5. MAPI Test (`Test-MAPIConnectivity`), erkennt Datenbanken, die mounted sind, aber nicht antworten

Kommt das tägliche Lebenszeichen nicht, läuft die Überwachung nicht oder der Mailversand funktioniert nicht.

## 7. Fehlersuche

| Meldung im Log | Ursache und Lösung |
|---|---|
| `Mail via ... fehlgeschlagen` | SMTP Server lehnt ab oder ist nicht erreichbar. Prüfen, ob `-To` richtig geschrieben ist, ob `-From` eine Accepted Domain verwendet und bei externen Empfängern, ob Relay erlaubt ist (mit einem internen Postfach gegentesten). Test: `Send-MailMessage -SmtpServer EX-Server01 -From exmonitor@contoso.com -To admin@contoso.com -Subject Test` |
| `Eventlog nicht erreichbar (Der RPC-Server ist nicht verfügbar)` | Firewall-Regel "Remote Event Log Management" auf dem Zielserver aktivieren |
| `Exchange Cmdlets konnten nicht geladen werden` | Skript nicht auf einem Exchange Server gestartet oder bei manuellem Lauf nicht in der Exchange Management Shell |
| `Get-Queue fehlgeschlagen`, `Test-ServiceHealth fehlgeschlagen` | Folge des vorherigen Punkts, oder fehlende Exchange Berechtigung |
| Keine Logdatei, `LastTaskResult` nicht 0 | Pfad in der Aufgabe prüfen (`-ScriptPath`), Dateien mit `Unblock-File` freigeben |

Bei `Check-WinOctUpdate.ps1` bedeutet "Nicht erreichbar" meist, dass WinRM auf dem Zielserver nicht läuft. Test: `Test-WSMan -ComputerName EX-Server01`

## 8. Entfernen

```powershell
Unregister-ScheduledTask -TaskPath '\iTrain\' -TaskName 'ExMonitor' -Confirm:$false
```

Danach können die Ordner `C:\Admin\Scripts\ExMonitor`, `C:\Admin\Scripts\Check-WinOctUpdate` und `C:\Admin\Scripts\Register-ExMonitorTask` gelöscht werden.

## Kontakt

iTrain GmbH, info@itrain.ch

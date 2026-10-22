# Exchange: checks and monitoring after the Windows October 2026 updates

[Deutsche Version](README.md)

Three scripts for Exchange Server on-premises:

| Script | Purpose |
|---|---|
| `Check-WinOctUpdate.ps1` | One-time check of all Exchange servers: uptime, critical time window 24 to 36 hours after boot, registry value EpmapSavedContextCap, affected October update per Windows Server version, event 1006 MapiExceptionMdbOffline |
| `ExMonitor.ps1` | Continuous monitoring (event 1006, queues, services, database copies, MAPI) with email on problem, on recovery and a heartbeat at set hours |
| `Register-ExMonitorTask.ps1` | Sets up ExMonitor as a scheduled task (as SYSTEM, every 15 minutes) |

The scripts do not change the Exchange configuration. They only read, send emails and write logs to `C:\Admin\Scripts\`.

Note: Console output, log entries and email texts of the scripts are in German. The tables below explain the most important terms.

## 1. Prerequisites

- Exchange Server 2016, 2019 or Subscription Edition on Windows Server 2016 or later
- Run on one of the Exchange servers, in a PowerShell **as Administrator**
- Account with the Exchange role Organization Management or View-Only Organization Management (for the manual tests)
- PowerShell Remoting (WinRM) between the Exchange servers, for `Check-WinOctUpdate.ps1`
- Remote event log access between the Exchange servers (firewall rule "Remote Event Log Management"), for `ExMonitor.ps1`
- Email: ExMonitor sends anonymously via SMTP port 25 to the Exchange servers. The sender address should belong to an accepted domain. In the default configuration Exchange accepts anonymous mail only for internal recipients; external recipients only work if a receive connector allows relaying. The easiest way to find out is a run with `-Test`.

## 2. Download

On the Exchange server that will do the monitoring, in a PowerShell as Administrator:

```powershell
$Target = 'C:\Admin\Scripts\ExMonitor'
New-Item -ItemType Directory -Path $Target -Force | Out-Null

# Required on Windows Server 2016 to reach GitHub
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Base = 'https://raw.githubusercontent.com/BeatBrunner/PowerShell-Toolbox-Public/main/Exchange/Oct-Win-Update-Check'
foreach ($File in 'Check-WinOctUpdate.ps1', 'ExMonitor.ps1', 'Register-ExMonitorTask.ps1') {
    Invoke-WebRequest -Uri "$Base/$File" -OutFile (Join-Path -Path $Target -ChildPath $File) -UseBasicParsing
}
Get-ChildItem -Path $Target -Filter *.ps1 | Unblock-File
Set-Location -Path $Target
```

### Download blocked (proxy) or no internet access

Proxies such as Zscaler often block `raw.githubusercontent.com` (category "FileHost"). `Invoke-WebRequest` then returns an HTML page from the proxy as an error instead of the script, e.g. with the text "Not allowed to browse FileHost category". In that case:

1. Run the download block above on your own PC or laptop, with `$Target` set to a local folder. Alternatively, save each script via "Download raw file" in the GitHub file view.
2. Copy the three files to the server through the RDP session (Ctrl+C in Explorer on the PC, Ctrl+V into `C:\Admin\Scripts\ExMonitor` on the server).
3. If copying files via RDP is blocked: open the script locally, copy the entire text, paste it into Notepad on the server and save it with the encoding **UTF-8 with BOM** (otherwise Windows PowerShell 5.1 displays umlauts incorrectly).
4. Unblock the files on the server:

```powershell
Get-ChildItem -Path C:\Admin\Scripts\ExMonitor -Filter *.ps1 | Unblock-File
Set-Location -Path C:\Admin\Scripts\ExMonitor
```

Check that all three scripts are present and valid:

```powershell
Get-ChildItem -Path C:\Admin\Scripts\ExMonitor -Filter *.ps1 | ForEach-Object { '{0}: {1}' -f $_.Name, (Get-Help $_.FullName).Synopsis }
```

One line with the short description must appear for each script.

Help for each script:

```powershell
Get-Help .\ExMonitor.ps1 -Full
```

## 3. Check-WinOctUpdate.ps1: one-time check

```powershell
.\Check-WinOctUpdate.ps1 -ComputerName EX-Server01, EX-Server02, EX-Server03, EX-Server04
```

Alternatively all Exchange servers of the organization (in the Exchange Management Shell):

```powershell
.\Check-WinOctUpdate.ps1 -ComputerName (Get-ExchangeServer).Name
```

Output in two tables (time window and update status), the CSV contains all columns:

| Column | Meaning |
|---|---|
| `LastBoot`, `Uptime_h` | Last restart and uptime in hours |
| `Phase` | `vor 24h` (before 24h), `KRITISCH (24-36h)` (critical) or `nach 36h` (after 36h) since boot |
| `Mark24h`, `Mark36h` | Times at which the critical window starts and ends |
| `OS`, `Build` | Windows Server version and build including update level, e.g. 17763.1234 |
| `KB`, `KBInstalled` | Affected October 2026 update for this version and whether it is installed: 2016 KB5126868, 2019 KB5126651, 2022 KB5126655, 2025 KB5126646. `unbekannt` (unknown) for any other Windows version. If a later cumulative update supersedes the October update, this can show `False` again. |
| `EpmapCap` | Registry value `HKLM:\SOFTWARE\Microsoft\Rpc\EpmapSavedContextCap`, expected value 65536 |
| `Event1006`, `LastEvent` | Number of events 1006 MapiExceptionMdbOffline since boot and time of the last one |

Below that, each server is rated: red for event 1006, yellow if EpmapSavedContextCap is not 65536, otherwise green (`OK`). Unreachable servers are listed with the error message (`Nicht erreichbar`). The result is also written as CSV to `C:\Admin\Scripts\Check-WinOctUpdate\`.

## 4. ExMonitor.ps1: manual test

Run in the **Exchange Management Shell** (as Administrator). Replace the sample values `EX-Server01`, `admin@contoso.com` etc. with your own server names and addresses. All Exchange servers of the organization can be passed directly with `-Servers (Get-ExchangeServer).Name`. With wrong server names every check reports an error ("Exchange server ... wasn't found") and the status is PROBLEM.

Step 1, check only, no email:

```powershell
.\ExMonitor.ps1 -Servers (Get-ExchangeServer).Name -To admin@contoso.com -From exmonitor@contoso.com -WhatIf
```

The result is written to the log `C:\Admin\Scripts\ExMonitor\ExMonitor_YYYYMM.log`:

```powershell
Get-Content -Path "C:\Admin\Scripts\ExMonitor\ExMonitor_$(Get-Date -Format 'yyyyMM').log" -Tail 20
```

For each server there is a line such as `EX-Server01: Event1006=0, MaxQueue=0, Dienste=OK, MAPI=OK, DB: DB01=Mounted ...` (`Dienste` = services), plus lines starting with `PROBLEM:` if something is wrong.

Step 2, send a test email:

```powershell
.\ExMonitor.ps1 -Servers (Get-ExchangeServer).Name -To admin@contoso.com -From exmonitor@contoso.com -Test
```

You receive an email with the subject `ExMonitor: TEST (OK)` or `ExMonitor: TEST (PROBLEM)` and an overview of all servers.

Further parameters:

| Parameter | Default | Meaning |
|---|---|---|
| `-SmtpHosts` | Values of `-Servers` | SMTP servers for sending email, tried in order |
| `-QueueMax` | 50 | Alert when a queue holds more messages than this |
| `-HeartbeatHour` | 7 | Hour(s) of the heartbeat, several separated by commas, e.g. `7, 12, 17` |
| `-WorkDir` | `C:\Admin\Scripts\ExMonitor` | Folder for log and status file |

## 5. Register-ExMonitorTask.ps1: set up the scheduled task

In a PowerShell **as Administrator** (no Exchange Management Shell required). In the Exchange Management Shell `-Servers (Get-ExchangeServer).Name` works as well. The server list is stored in the task when it is set up. If a server is added, run the script again.

Step 1, show what would be set up:

```powershell
.\Register-ExMonitorTask.ps1 -Servers EX-Server01, EX-Server02 -To admin@contoso.com -From exmonitor@contoso.com -WhatIf
```

Step 2, set it up:

```powershell
.\Register-ExMonitorTask.ps1 -Servers EX-Server01, EX-Server02 -To admin@contoso.com -From exmonitor@contoso.com
```

The task is called `ExMonitor` in the folder `\iTrain\` of Task Scheduler and runs as SYSTEM every 15 minutes, starting at the next quarter hour. If ExMonitor.ps1 is not located in `C:\Admin\Scripts\ExMonitor`, specify the path with `-ScriptPath`. An existing task is first backed up as XML to `C:\Admin\Scripts\Register-ExMonitorTask\` and then overwritten. To change recipients or servers, simply run the script again. For several heartbeats per day use `-HeartbeatHour`, e.g. `-HeartbeatHour 7, 17` for 07:00 and 17:00.

Step 3, start it once right away and check:

```powershell
Start-ScheduledTask -TaskPath '\iTrain\' -TaskName 'ExMonitor'
Get-ScheduledTaskInfo -TaskPath '\iTrain\' -TaskName 'ExMonitor' | Select-Object -Property LastRunTime, LastTaskResult, NextRunTime
Get-Content -Path "C:\Admin\Scripts\ExMonitor\ExMonitor_$(Get-Date -Format 'yyyyMM').log" -Tail 20
```

Expected:

- `LastTaskResult` is `0` (`267009` while the task is still running, wait a moment)
- The log shows `Start als DOMAIN\SERVERNAME$` and `Exchange Snap-in geladen` (snap-in loaded)
- One overview line per server without `Fehler` (error)

The status file `C:\Admin\Scripts\ExMonitor\state.txt` always shows the result of the last check.

## 6. When emails are sent

| Situation | Email |
|---|---|
| New problem detected | Immediately `ExMonitor: PROBLEM` |
| Problem persists | Once per hour (run within the first 15 minutes of the hour) another `ExMonitor: PROBLEM` |
| Problem resolved | `ExMonitor: wieder OK` (OK again) |
| Everything OK | At every hour in `-HeartbeatHour` (default 07:00) `ExMonitor: OK (Lebenszeichen)` (heartbeat) |
| Run with `-Test` | Always `ExMonitor: TEST (...)` |

Checked for each server:

1. Event 1006 MapiExceptionMdbOffline or ec=1142 in the last 20 minutes
2. Transport queues with more than 50 messages
3. Exchange services (`Test-ServiceHealth`)
4. Status of the database copies (Mounted or Healthy expected)
5. MAPI test (`Test-MAPIConnectivity`), detects databases that are mounted but do not respond

If the heartbeat does not arrive, either the monitoring is not running or sending email does not work.

## 7. Troubleshooting

| Log message | Cause and solution |
|---|---|
| `Mail via ... fehlgeschlagen` (failed) | SMTP server rejects or is not reachable. Check that `-To` is spelled correctly, that `-From` uses an accepted domain and, for external recipients, that relaying is allowed (cross-check with an internal mailbox). Test: `Send-MailMessage -SmtpServer EX-Server01 -From exmonitor@contoso.com -To admin@contoso.com -Subject Test` |
| `Eventlog nicht erreichbar (...)` (event log not reachable, e.g. "The RPC server is unavailable") | Enable the firewall rule "Remote Event Log Management" on the target server |
| `Exchange Cmdlets konnten nicht geladen werden` (could not be loaded) | Script not started on an Exchange server, or a manual run outside the Exchange Management Shell |
| `Get-Queue fehlgeschlagen`, `Test-ServiceHealth fehlgeschlagen` | Consequence of the previous item, or missing Exchange permissions |
| No log file, `LastTaskResult` not 0 | Check the path in the task (`-ScriptPath`), unblock the files with `Unblock-File` |

For `Check-WinOctUpdate.ps1`, "Nicht erreichbar" (not reachable) usually means WinRM is not running on the target server. Test: `Test-WSMan -ComputerName EX-Server01`

## 8. Removal

```powershell
Unregister-ScheduledTask -TaskPath '\iTrain\' -TaskName 'ExMonitor' -Confirm:$false
```

Afterwards the folders `C:\Admin\Scripts\ExMonitor`, `C:\Admin\Scripts\Check-WinOctUpdate` and `C:\Admin\Scripts\Register-ExMonitorTask` can be deleted.

## Contact

iTrain GmbH, info@itrain.ch

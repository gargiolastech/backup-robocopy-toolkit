# backup-robocopy-toolkit

## Scopo
- Script PowerShell per backup e schedulazione su Windows (utilizzo di **Scheduled Tasks**).
- Copia incrementale/robusta con **Robocopy** (log, retry, mirror).
- Registrazione automatica di attività pianificate con **Register-ScheduledTask**.

Questo repository fornisce script e configurazioni per automatizzare backup su Windows con **PowerShell**.
L'obiettivo è offrire un flusso ripetibile: preparazione, esecuzione, log, schedulazione.

## Prerequisiti
- Windows 10/11 o Server con PowerShell 5.1+ (o PowerShell 7+).
- Permessi amministrativi per la registrazione delle Attività Pianificate.
- Execution Policy compatibile (es. `RemoteSigned`).

## Installazione / Setup
1. Clona o scarica il repository.
2. Personalizza i file in `/config` (percorsi sorgente/destinazione, politiche di retention, ecc.).
3. Esegui lo script di registrazione della schedulazione (esempio):
   ```powershell
   ./scripts/Register-BackupWatchdog.ps1 -DestRoot "D:\Backups"
   ```

## Utilizzo
- **Esecuzione manuale**:
  ```powershell
  ./scripts/Run-Backup.ps1 -Profile "default" -Verbose
  ```
- **Schedulazione**: pianificare l'esecuzione giornaliera/notturna con `Register-ScheduledTask`.

 Ad esempio se abbiamo clonato il repos nel percorso C:\Scripts\backup-robocopy-toolkit

 ```powershell
  .\Register-BackupWatchdog.ps1 `
  -ConfigPath "C:\Scripts\backup-robocopy-toolkit\backup.config.json" `
  -WatchdogPath "C:\Scripts\backup-robocopy-toolkit\Backup-Watchdog.ps1" `
  -TaskName "Lavoro Backup Sync" `
  -RepeatMinutes 20 `
  -RunAs SYSTEM `
  -RunNow -Verbose
 ```

## Log e Troubleshooting
- I log (se abilitati) sono salvati in `/logs` o nel percorso configurato.
- Verifica gli eventi del *Task Scheduler* in caso di errori (codici `0x1`, ecc.).
- Consigli:
  - Testa gli script interattivamente prima della schedulazione.
  - Verifica i permessi dell'account che esegue il task.

## Sicurezza
- Evita di committare credenziali o token.
- Proteggi le cartelle di destinazione e i log con ACL adeguate.
- Se necessario, usa il *Windows Credential Manager* o secret store sicuri.

## Manutenzione
- Aggiorna regolarmente gli script e la documentazione.
- Pianifica test periodici di restore dei backup.
- Valuta la rotazione/cleanup dei log e degli archivi.

---

> **Nota:** Adatta nomi di script e parametri in base ai file effettivamente presenti nel repository.

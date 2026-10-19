' Lanza el widget ai-progress sin mostrar ninguna ventana de consola.
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
psScript = scriptDir & "\ai-progress.ps1"

' pwsh (PowerShell 7+), no powershell.exe (Windows PowerShell 5.1) - el widget
' usa ConvertFrom-Json -AsHashtable, parametro que solo existe desde PowerShell 6.
Set shell = CreateObject("WScript.Shell")
comando = "pwsh.exe -NoProfile -ExecutionPolicy Bypass -STA -File """ & psScript & """"
shell.Run comando, 0, False

Option Explicit

Dim shell
Dim scriptPath
Dim command

scriptPath = "C:\ProgramData\AGAutoRetry\ag-auto-retry.ps1"
command = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptPath & """"

Set shell = CreateObject("WScript.Shell")
shell.Run command, 0, False

' JihuaTai silent launcher.
' Runs launch-jihuatai.ps1 with a hidden window so nothing flashes,
' and bypasses Explorer's SmartScreen check for the unsigned exe.
Option Explicit
Dim sh, fso, scriptPath
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptPath = fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), "launch-jihuatai.ps1")

sh.CurrentDirectory = "D:\JihuaTai"
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptPath & """", 0, False

' esp-term — double-click this to start with NO console window.
' Equivalent to: start hidden pythonw esp_term.py
Option Explicit
Dim sh, fso, dir, py, candidates, i
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)

candidates = Array( _
  "C:\Espressif\tools\python\v5.5.4\venv\Scripts\pythonw.exe", _
  "C:\Espressif\tools\python\pythonw.exe", _
  "C:\Espressif\tools\python\v5.5.4\venv\Scripts\python.exe" _
)
py = ""
For i = 0 To UBound(candidates)
  If fso.FileExists(candidates(i)) Then
    py = candidates(i)
    Exit For
  End If
Next

If py = "" Then
  MsgBox "pythonw.exe not found. Install Python 3 or ESP-IDF.", 16, "esp-term"
  WScript.Quit 1
End If

' 0 = hidden window; False = don't wait
sh.Run """" & py & """ """ & dir & "\esp_term.py""", 0, False

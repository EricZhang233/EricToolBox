# EricColorCanvas

A native Windows color picker with synchronized RGB and HEX controls, an eyedropper, and a separate borderless color canvas.

## Run

Double-click `EricColorCanvas.exe`. It uses Windows Forms and the Windows .NET Framework, with no third-party packages or installation step.

## Use

- All color controls update one another immediately. A leading `#` is removed automatically when pasted into the HEX field.
- Click the eyedropper icon, then click anywhere on screen to sample a color. Press Esc to cancel.
- Drag inside the canvas to move it. Drag within 9 pixels of an edge or corner to resize it. Right-click for HEX copy, preset sizes, or close.

## Rebuild

Use the Windows .NET Framework C# compiler and the icon file in this folder:

```text
csc /nologo /target:winexe /platform:anycpu /out:EricColorCanvas.exe /win32icon:EricColorCanvas.ico /reference:System.Windows.Forms.dll /reference:System.Drawing.dll EricColorCanvas.cs
```

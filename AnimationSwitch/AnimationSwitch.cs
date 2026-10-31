using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

public static class AnimationSwitch
{
    [DllImport("user32.dll", EntryPoint="SystemParametersInfoW", SetLastError=true)]
    static extern bool Spi(uint action, uint param, IntPtr value, uint flags);
    [DllImport("user32.dll", EntryPoint="SystemParametersInfoW", SetLastError=true)]
    static extern bool Read(uint action, uint param, out int value, uint flags);
    [StructLayout(LayoutKind.Sequential)]
    struct AnimationInfo { public uint size; public int enabled; }
    [DllImport("user32.dll", EntryPoint="SystemParametersInfoW", SetLastError=true)]
    static extern bool Animation(uint action, uint param, ref AnimationInfo value, uint flags);
    static readonly uint[] Gets = {0x103E,0x1042,0x1002,0x1004,0x1006,0x1012,0x1014,0x1016,0x1018};
    static readonly string[] Names = {"UIEffects (reference only)","ClientAreaAnimation","MenuAnimation","ComboBoxAnimation","ListBoxSmoothScrolling","MenuFade","SelectionFade","TooltipAnimation","TooltipFade"};
    static void Check(bool ok, string operation) { if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error(), operation); }
    static int Get(uint action) { int value; Check(Read(action,0,out value,0),"Read 0x"+action.ToString("X")); return value; }
    public static string Status()
    {
        var b = new StringBuilder();
        for(int i=0;i<Gets.Length;i++) b.AppendLine(Names[i]+"="+(Get(Gets[i])!=0?"on":"off"));
        var a=new AnimationInfo {size=8}; Check(Animation(0x48,8,ref a,0),"Read window animation");
        b.AppendLine("WindowAnimation="+(a.enabled!=0?"on":"off")); return b.ToString();
    }
    static void Set(uint get, bool on, uint flags)
    {
        Check(Spi(get+1,0,new IntPtr(on?1:0),flags),"Set 0x"+(get+1).ToString("X"));
        if ((Get(get)!=0)!=on) throw new InvalidOperationException("Readback mismatch: 0x"+get.ToString("X"));
    }
    public static void Apply(bool on)
    {
        uint flags=3u; // SPIF_SENDCHANGE, optionally SPIF_UPDATEINIFILE
        // UIEffects includes non-animation effects; on some systems clearing it reads back as enabled.
        // Enable it when enabling animations; disable animations individually.
        if(on) Set(0x103E,true,flags);
        Set(0x1042,on,flags);
        {
            for(int i=2;i<Gets.Length;i++) Set(Gets[i],on,flags);
            var a=new AnimationInfo {size=8,enabled=on?1:0};
            Check(Animation(0x49,8,ref a,flags),"Set window animation");
            a.enabled=-1; Check(Animation(0x48,8,ref a,0),"Verify window animation");
            if(a.enabled!=(on?1:0)) throw new InvalidOperationException("Window animation readback mismatch");
        }
    }
    [STAThread]
    public static int Main(string[] args)
    {
        try {
            if(args.Length==0) { Gui(); return 0; }
            if(args.Length!=1) return 2;
            string command=args[0].ToLowerInvariant();
            if(command=="check") {
                bool disabled=false;
                for(int i=0;i<Gets.Length;i++) if(Get(Gets[i])==0) disabled=true;
                var a=new AnimationInfo {size=8};
                Check(Animation(0x48,8,ref a,0),"Read window animation");
                if(disabled || a.enabled==0) Apply(true);
                return 0;
            }
            if(command!="on" && command!="off") return 2;
            Apply(command=="on");
            return 0;
        } catch { return 1; }
    }
    static void Gui()
    {
        Application.EnableVisualStyles();
        var f=new Form {Text="Windows 动画效果 · 系统 API",Width=550,Height=440,StartPosition=FormStartPosition.CenterScreen};
        var status=new TextBox {Left=20,Top=110,Width=490,Height=245,Multiline=true,ReadOnly=true,ScrollBars=ScrollBars.Vertical};
        var label=new Label {Left=20,Top=15,Width=490,Height=40,Text="通过 Windows API 开启或关闭全部动画，并通知应用。"};
        f.Controls.Add(label); f.Controls.Add(status);
        Action refresh=()=> {try {status.Text=Status();}catch(Exception e){status.Text=e.Message;}};
        string[] captions={"开启动画","关闭动画","刷新"};
        for(int i=0;i<3;i++) {int index=i;var button=new Button {Left=20+i*125,Top=65,Width=115,Height=32,Text=captions[i]};
            button.Click+=(s,e)=>{try {if(index<2) Apply(index==0);refresh();}catch(Exception ex){MessageBox.Show(f,ex.Message,"操作失败（可能已部分应用）",MessageBoxButtons.OK,MessageBoxIcon.Error);refresh();}};f.Controls.Add(button);}
        refresh(); Application.Run(f);
    }
}

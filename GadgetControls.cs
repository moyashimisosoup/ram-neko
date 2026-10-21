using System;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;

public class NekoGadgetButton : Button {
    bool held, hover, latched;
    public bool Latched { get { return latched; } set { latched=value; Invalidate(); } }
    public NekoGadgetButton() {
        SetStyle(ControlStyles.UserPaint|ControlStyles.AllPaintingInWmPaint|ControlStyles.OptimizedDoubleBuffer, true);
        FlatStyle=FlatStyle.Flat;
    }
    protected override void OnMouseDown(MouseEventArgs e) { if(e.Button==MouseButtons.Left) held=true; base.OnMouseDown(e); Invalidate(); }
    protected override void OnMouseUp(MouseEventArgs e) { held=false; base.OnMouseUp(e); Invalidate(); }
    protected override void OnMouseCaptureChanged(EventArgs e) { held=false; base.OnMouseCaptureChanged(e); Invalidate(); }
    protected override void OnMouseEnter(EventArgs e) { hover=true; base.OnMouseEnter(e); Invalidate(); }
    protected override void OnMouseLeave(EventArgs e) { hover=false; held=false; base.OnMouseLeave(e); Invalidate(); }
    protected override void OnKeyDown(KeyEventArgs e) { if(e.KeyCode==Keys.Space) held=true; base.OnKeyDown(e); Invalidate(); }
    protected override void OnKeyUp(KeyEventArgs e) { held=false; base.OnKeyUp(e); Invalidate(); }
    protected override void OnPaint(PaintEventArgs e) {
        bool down=held||latched;
        Color face=Enabled && hover ? ControlPaint.Light(BackColor,0.15f) : BackColor;
        Color light=ControlPaint.LightLight(face), shadow=ControlPaint.Dark(face,0.38f);
        using(var brush=new SolidBrush(face)) e.Graphics.FillRectangle(brush,ClientRectangle);
        using(var border=new Pen(ControlPaint.Dark(face,0.6f))) e.Graphics.DrawRectangle(border,0,0,Width-1,Height-1);
        using(var a=new Pen(down?shadow:light,3)) {
            e.Graphics.DrawLine(a,2,2,Width-4,2); e.Graphics.DrawLine(a,2,2,2,Height-4);
        }
        using(var b=new Pen(down?light:shadow,3)) {
            e.Graphics.DrawLine(b,3,Height-3,Width-3,Height-3); e.Graphics.DrawLine(b,Width-3,3,Width-3,Height-3);
        }
        var text=new Rectangle(down?3:1,down?3:1,Width-3,Height-3);
        if(Image!=null) {
            int offset=down?2:0;
            e.Graphics.DrawImageUnscaled(Image,9+offset,(Height-Image.Height)/2+offset);
            text.X+=Image.Width+8;text.Width-=Image.Width+8;
        }
        TextRenderer.DrawText(e.Graphics,Text,Font,text,Enabled?ForeColor:ControlPaint.Dark(BackColor),TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter|TextFormatFlags.SingleLine);
        if(Focused && ShowFocusCues) ControlPaint.DrawFocusRectangle(e.Graphics,new Rectangle(6,6,Width-12,Height-12));
    }
}

public class NekoGadgetForm : Form {
    public bool DesktopPinned { get; set; }
    public NekoGadgetForm() { DoubleBuffered=true; }
    protected override void WndProc(ref Message m) {
        if(DesktopPinned && m.Msg==0x21) { m.Result=(IntPtr)3; return; } // mouse without activation
        base.WndProc(ref m);
    }
    [DllImport("user32.dll",SetLastError=true)] static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int cx,int cy,uint flags);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h,int index);
    public void SetDesktopLayer() {
        if(!SetWindowPos(Handle,(IntPtr)1,0,0,0,0,0x13)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
    public bool NativeTopmost { get { return (GetWindowLong(Handle,-20)&8)!=0; } }
}

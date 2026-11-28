using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Globalization;
using System.Windows.Forms;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        using (var editor = new ColorEditorForm())
            Application.Run(editor);
    }
}

internal static class AppIdentity
{
    public static Icon LoadIcon()
    {
        return Icon.ExtractAssociatedIcon(Application.ExecutablePath) ?? SystemIcons.Application;
    }
}

internal static class ColorMath
{
    public static Color FromHsv(double hue, double saturation, double value)
    {
        double chroma = value * saturation;
        double h = (hue % 360.0) / 60.0;
        double x = chroma * (1.0 - Math.Abs(h % 2.0 - 1.0));
        double r = 0, g = 0, b = 0;
        if (h < 1) { r = chroma; g = x; }
        else if (h < 2) { r = x; g = chroma; }
        else if (h < 3) { g = chroma; b = x; }
        else if (h < 4) { g = x; b = chroma; }
        else if (h < 5) { r = x; b = chroma; }
        else { r = chroma; b = x; }
        double m = value - chroma;
        return Color.FromArgb((int)Math.Round((r + m) * 255), (int)Math.Round((g + m) * 255), (int)Math.Round((b + m) * 255));
    }

    public static void ToHsv(Color color, out double hue, out double saturation, out double value)
    {
        double r = color.R / 255.0, g = color.G / 255.0, b = color.B / 255.0;
        double max = Math.Max(r, Math.Max(g, b)), min = Math.Min(r, Math.Min(g, b));
        double delta = max - min;
        if (delta == 0) hue = 0;
        else if (max == r) hue = 60.0 * (((g - b) / delta) % 6.0);
        else if (max == g) hue = 60.0 * (((b - r) / delta) + 2.0);
        else hue = 60.0 * (((r - g) / delta) + 4.0);
        if (hue < 0) hue += 360.0;
        saturation = max == 0 ? 0 : delta / max;
        value = max;
    }
}

internal sealed class ColorEditorForm : Form
{
    private readonly ColorWheelControl wheel = new ColorWheelControl();
    private readonly TrackBar valueBar = new TrackBar();
    private readonly TrackBar[] rgbBars = new TrackBar[3];
    private readonly Label[] rgbValues = new Label[3];
    private readonly TextBox hexBox = new TextBox();
    private readonly Button eyedropperButton = new Button();
    private readonly ColorCanvasForm canvas = new ColorCanvasForm();
    private Color selected = Color.FromArgb(70, 194, 167);
    private double hue, saturation, value;
    private bool changing;

    public ColorEditorForm()
    {
        Text = "EricColorCanvas";
        Icon = AppIdentity.LoadIcon();
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        MinimizeBox = true;
        ClientSize = new Size(340, 500);
        Font = new Font("Segoe UI", 9F);
        BackColor = Color.FromArgb(247, 248, 250);
        BuildUi();
        ColorMath.ToHsv(selected, out hue, out saturation, out value);
        SyncUi();
        Shown += delegate
        {
            var area = Screen.FromControl(this).WorkingArea;
            canvas.Location = new Point(Math.Min(Right + 18, area.Right - canvas.Width), Math.Max(area.Top, Top + 35));
            canvas.Show(this);
        };
        FormClosing += delegate { if (!canvas.IsDisposed) canvas.Close(); };
    }

    private void BuildUi()
    {
        var heading = new Label { Text = "Color Settings", Font = new Font(Font, FontStyle.Bold), ForeColor = Color.FromArgb(31, 41, 55), AutoSize = true, Location = new Point(18, 12) };
        Controls.Add(heading);
        wheel.Location = new Point(60, 52);
        wheel.Size = new Size(220, 220);
        wheel.Hue = hue;
        wheel.Saturation = saturation;
        wheel.Value = value;
        wheel.ColorSelected += delegate(double h, double s) { hue = h; saturation = s; ApplyHsv(); };
        Controls.Add(wheel);

        Controls.Add(MakeLabel("Brightness", 14, 295, true));
        valueBar.Minimum = 0; valueBar.Maximum = 100; valueBar.TickFrequency = 20; valueBar.SmallChange = 1; valueBar.LargeChange = 10;
        valueBar.Location = new Point(98, 285); valueBar.Size = new Size(228, 38); valueBar.AutoSize = false;
        valueBar.ValueChanged += delegate { if (!changing) { value = valueBar.Value / 100.0; ApplyHsv(); } };
        Controls.Add(valueBar);

        var rgbHeader = MakeLabel("RGB", 14, 328, true);
        Controls.Add(rgbHeader);
        var names = new[] { "R", "G", "B" };
        for (int i = 0; i < 3; i++)
        {
            int y = 348 + i * 36;
            var name = MakeLabel(names[i], 14, y + 5, true);
            name.ForeColor = new[] { Color.FromArgb(205, 64, 64), Color.FromArgb(48, 150, 80), Color.FromArgb(57, 112, 205) }[i];
            Controls.Add(name);
            var bar = new TrackBar { Minimum = 0, Maximum = 255, TickFrequency = 51, SmallChange = 1, LargeChange = 16, Location = new Point(39, y), Size = new Size(212, 32), AutoSize = false };
            bar.ValueChanged += delegate { if (!changing) SetColor(Color.FromArgb(rgbBars[0].Value, rgbBars[1].Value, rgbBars[2].Value)); };
            rgbBars[i] = bar;
            Controls.Add(bar);
            var number = new Label { TextAlign = ContentAlignment.MiddleRight, Location = new Point(254, y + 3), Size = new Size(38, 23), ForeColor = Color.FromArgb(75, 85, 99) };
            rgbValues[i] = number;
            Controls.Add(number);
        }

        Controls.Add(MakeLabel("HEX", 14, 465, true));
        var hash = new Label { Text = "#", Location = new Point(51, 460), Size = new Size(16, 30), Font = new Font(Font, FontStyle.Bold), TextAlign = ContentAlignment.MiddleCenter, ForeColor = Color.FromArgb(55, 65, 81) };
        Controls.Add(hash);
        hexBox.Location = new Point(67, 462); hexBox.Size = new Size(77, 27); hexBox.MaxLength = 64;
        hexBox.CharacterCasing = CharacterCasing.Upper;
        hexBox.BorderStyle = BorderStyle.FixedSingle;
        hexBox.TextChanged += HexTextChanged;
        hexBox.Leave += delegate { if (hexBox.Text.Length != 6) hexBox.Text = Hex(selected); };
        Controls.Add(hexBox);
        eyedropperButton.Text = "\uEF3C";
        eyedropperButton.Font = GetEyedropperFont();
        eyedropperButton.Location = new Point(150, 461);
        eyedropperButton.Size = new Size(30, 28);
        eyedropperButton.AccessibleName = "Eyedropper";
        eyedropperButton.AccessibleDescription = "Pick a color from the screen. Press Escape to cancel.";
        eyedropperButton.UseVisualStyleBackColor = true;
        eyedropperButton.Click += delegate { BeginEyedropper(); };
        Controls.Add(eyedropperButton);
        var tip = new ToolTip();
        tip.SetToolTip(eyedropperButton, "Pick a color from the screen. Press Esc to cancel.");
        var swatch = new Panel { Location = new Point(187, 462), Size = new Size(139, 27), BorderStyle = BorderStyle.FixedSingle };
        swatch.BackColor = selected;
        Controls.Add(swatch);
        ColorChanged += delegate { swatch.BackColor = selected; };
    }

    private Label MakeLabel(string text, int x, int y, bool bold)
    {
        return new Label { Text = text, Location = new Point(x, y), AutoSize = true, ForeColor = Color.FromArgb(55, 65, 81), Font = bold ? new Font(Font, FontStyle.Bold) : Font };
    }

    private static Font GetEyedropperFont()
    {
        using (var fonts = new InstalledFontCollection())
        {
            foreach (FontFamily family in fonts.Families)
                if (String.Equals(family.Name, "Segoe Fluent Icons", StringComparison.OrdinalIgnoreCase))
                    return new Font(family, 16F, FontStyle.Regular, GraphicsUnit.Point);
            foreach (FontFamily family in fonts.Families)
                if (String.Equals(family.Name, "Segoe MDL2 Assets", StringComparison.OrdinalIgnoreCase))
                    return new Font(family, 16F, FontStyle.Regular, GraphicsUnit.Point);
        }
        return new Font("Segoe UI Symbol", 16F, FontStyle.Regular, GraphicsUnit.Point);
    }

    private void HexTextChanged(object sender, EventArgs e)
    {
        if (changing) return;
        string raw = hexBox.Text;
        string cleaned = raw.Replace("#", "");
        var valid = new System.Text.StringBuilder(6);
        foreach (char ch in cleaned)
            if ((ch >= '0' && ch <= '9') || (ch >= 'A' && ch <= 'F') || (ch >= 'a' && ch <= 'f'))
                if (valid.Length < 6) valid.Append(ch);
        cleaned = valid.ToString().ToUpperInvariant();
        if (raw != cleaned)
        {
            changing = true;
            int caret = Math.Min(cleaned.Length, hexBox.SelectionStart);
            hexBox.Text = cleaned;
            hexBox.SelectionStart = caret;
            changing = false;
        }
        if (cleaned.Length == 6)
        {
            int rgb;
            if (int.TryParse(cleaned, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out rgb))
                SetColor(Color.FromArgb((rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255));
        }
    }

    private static string Hex(Color color) { return color.R.ToString("X2") + color.G.ToString("X2") + color.B.ToString("X2"); }

    private void SetColor(Color color)
    {
        selected = color;
        ColorMath.ToHsv(color, out hue, out saturation, out value);
        SyncUi();
        canvas.SetColor(color);
        OnColorChanged(EventArgs.Empty);
    }

    private void ApplyHsv() { SetColor(ColorMath.FromHsv(hue, saturation, value)); }

    private void BeginEyedropper()
    {
        canvas.Hide();
        Hide();
        var picker = new ScreenPickerForm();
        picker.ColorPicked += delegate(Color color)
        {
            SetColor(color);
            canvas.Show(this);
            Show();
            Activate();
        };
        picker.PickCancelled += delegate
        {
            canvas.Show(this);
            Show();
            Activate();
        };
        picker.Show();
    }

    private void SyncUi()
    {
        changing = true;
        valueBar.Value = Math.Max(valueBar.Minimum, Math.Min(valueBar.Maximum, (int)Math.Round(value * 100)));
        rgbBars[0].Value = selected.R; rgbBars[1].Value = selected.G; rgbBars[2].Value = selected.B;
        rgbValues[0].Text = selected.R.ToString(); rgbValues[1].Text = selected.G.ToString(); rgbValues[2].Text = selected.B.ToString();
        hexBox.Text = Hex(selected);
        wheel.Hue = hue; wheel.Saturation = saturation; wheel.Value = value;
        wheel.Invalidate();
        changing = false;
    }

    private event EventHandler ColorChanged;
    private void OnColorChanged(EventArgs e) { var handler = ColorChanged; if (handler != null) handler(this, e); }
}

internal sealed class ColorWheelControl : Control
{
    private Bitmap bitmap;
    private int bitmapValue = -1;
    private bool dragging;
    public double Hue { get; set; }
    public double Saturation { get; set; }
    public double Value { get; set; }
    public event Action<double, double> ColorSelected;

    public ColorWheelControl()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent;
        Cursor = Cursors.Hand;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        int v = (int)Math.Round(Value * 100);
        if (bitmap == null || bitmap.Width != ClientSize.Width || bitmap.Height != ClientSize.Height || bitmapValue != v)
        {
            if (bitmap != null) bitmap.Dispose();
            bitmap = new Bitmap(Math.Max(1, ClientSize.Width), Math.Max(1, ClientSize.Height));
            double cx = (bitmap.Width - 1) / 2.0, cy = (bitmap.Height - 1) / 2.0;
            double radius = Math.Max(1, Math.Min(bitmap.Width, bitmap.Height) / 2.0 - 5);
            for (int y = 0; y < bitmap.Height; y++)
                for (int x = 0; x < bitmap.Width; x++)
                {
                    double dx = x - cx, dy = y - cy;
                    double distance = Math.Sqrt(dx * dx + dy * dy);
                    if (distance > radius) bitmap.SetPixel(x, y, Color.Transparent);
                    else
                    {
                        double h = Math.Atan2(dx, -dy) * 180.0 / Math.PI;
                        if (h < 0) h += 360.0;
                        bitmap.SetPixel(x, y, ColorMath.FromHsv(h, Math.Min(1.0, distance / radius), v / 100.0));
                    }
                }
            bitmapValue = v;
        }

        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        e.Graphics.DrawImageUnscaled(bitmap, 0, 0);
        float radiusEdge = (float)(Math.Min(Width, Height) / 2.0 - 5);
        float centerX = (Width - 1) / 2f, centerY = (Height - 1) / 2f;
        using (var border = new Pen(Color.FromArgb(110, 31, 41, 55), 1.5f))
            e.Graphics.DrawEllipse(border, centerX - radiusEdge, centerY - radiusEdge, radiusEdge * 2, radiusEdge * 2);
        double angle = Hue * Math.PI / 180.0;
        float markerX = centerX + (float)(Math.Sin(angle) * Saturation * radiusEdge);
        float markerY = centerY - (float)(Math.Cos(angle) * Saturation * radiusEdge);
        using (var dark = new Pen(Color.Black, 3)) e.Graphics.DrawEllipse(dark, markerX - 7, markerY - 7, 14, 14);
        using (var light = new Pen(Color.White, 1)) e.Graphics.DrawEllipse(light, markerX - 7, markerY - 7, 14, 14);
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button == MouseButtons.Left) { dragging = true; SelectAt(e.Location); }
    }
    protected override void OnMouseMove(MouseEventArgs e) { base.OnMouseMove(e); if (dragging) SelectAt(e.Location); }
    protected override void OnMouseUp(MouseEventArgs e) { base.OnMouseUp(e); dragging = false; }
    protected override void Dispose(bool disposing) { if (disposing && bitmap != null) bitmap.Dispose(); base.Dispose(disposing); }

    private void SelectAt(Point p)
    {
        double cx = (Width - 1) / 2.0, cy = (Height - 1) / 2.0;
        double dx = p.X - cx, dy = p.Y - cy;
        double radius = Math.Max(1, Math.Min(Width, Height) / 2.0 - 5);
        double distance = Math.Sqrt(dx * dx + dy * dy);
        double s = Math.Min(1.0, distance / radius);
        double h = Hue;
        if (distance > 0.5)
        {
            h = Math.Atan2(dx, -dy) * 180.0 / Math.PI;
            if (h < 0) h += 360.0;
        }
        var handler = ColorSelected;
        if (handler != null) handler(h, s);
    }
}

internal sealed class ColorCanvasForm : Form
{
    private readonly DragSurface surface;
    private readonly ContextMenuStrip menu;
    private Color current = Color.FromArgb(70, 194, 167);

    public ColorCanvasForm()
    {
        Text = "EricColorCanvas";
        Icon = AppIdentity.LoadIcon();
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = true;
        StartPosition = FormStartPosition.Manual;
        ClientSize = new Size(420, 300);
        MinimumSize = new Size(160, 120);
        BackColor = current;
        AutoScaleMode = AutoScaleMode.Dpi;
        surface = new DragSurface { Dock = DockStyle.Fill, BackColor = current };
        Controls.Add(surface);
        menu = new ContextMenuStrip();
        var copy = new ToolStripMenuItem("Copy HEX");
        copy.Click += delegate { Clipboard.SetText("#" + current.R.ToString("X2") + current.G.ToString("X2") + current.B.ToString("X2")); };
        menu.Items.Add(copy);
        var sizes = new ToolStripMenuItem("Canvas size");
        AddSize(sizes, "Small  320 × 220", 320, 220);
        AddSize(sizes, "Medium  420 × 300", 420, 300);
        AddSize(sizes, "Large  560 × 400", 560, 400);
        menu.Items.Add(sizes);
        menu.Items.Add(new ToolStripSeparator());
        var close = new ToolStripMenuItem("Close canvas");
        close.Click += delegate { Close(); };
        menu.Items.Add(close);
        surface.ContextMenuStrip = menu;
        KeyPreview = true;
        KeyDown += delegate(object sender, KeyEventArgs e) { if (e.KeyCode == Keys.Escape) Close(); };
    }

    private void AddSize(ToolStripMenuItem parent, string label, int width, int height)
    {
        var item = new ToolStripMenuItem(label);
        item.Click += delegate { ClientSize = new Size(width, height); };
        parent.DropDownItems.Add(item);
    }

    public void SetColor(Color color) { current = color; BackColor = color; surface.BackColor = color; }

    private sealed class DragSurface : Panel
    {
        [Flags]
        private enum ResizeEdges { None = 0, Left = 1, Right = 2, Top = 4, Bottom = 8 }
        private const int EdgeWidth = 9;
        private bool pressed;
        private ResizeEdges edges;
        private Point startPoint;
        private Rectangle startBounds;
        private Form owner;

        public DragSurface() { SetStyle(ControlStyles.Selectable, false); TabStop = false; Cursor = Cursors.SizeAll; }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (e.Button != MouseButtons.Left) return;
            owner = FindForm();
            if (owner == null) return;
            edges = GetEdges(e.Location);
            startPoint = Cursor.Position;
            startBounds = owner.Bounds;
            pressed = true;
            Capture = true;
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            if (!pressed || owner == null)
            {
                edges = GetEdges(e.Location);
                Cursor = CursorFor(edges);
                return;
            }

            Point point = Cursor.Position;
            int dx = point.X - startPoint.X, dy = point.Y - startPoint.Y;
            int left = startBounds.Left, top = startBounds.Top;
            int width = startBounds.Width, height = startBounds.Height;
            if ((edges & ResizeEdges.Left) != 0) { left += dx; width -= dx; }
            if ((edges & ResizeEdges.Right) != 0) width += dx;
            if ((edges & ResizeEdges.Top) != 0) { top += dy; height -= dy; }
            if ((edges & ResizeEdges.Bottom) != 0) height += dy;

            int minWidth = owner.MinimumSize.Width, minHeight = owner.MinimumSize.Height;
            if (width < minWidth) { if ((edges & ResizeEdges.Left) != 0) left = startBounds.Right - minWidth; width = minWidth; }
            if (height < minHeight) { if ((edges & ResizeEdges.Top) != 0) top = startBounds.Bottom - minHeight; height = minHeight; }
            if (edges == ResizeEdges.None) { left = startBounds.Left + dx; top = startBounds.Top + dy; }
            owner.SetBounds(left, top, width, height, BoundsSpecified.All);
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            pressed = false;
            Capture = false;
        }

        private ResizeEdges GetEdges(Point point)
        {
            ResizeEdges result = ResizeEdges.None;
            if (point.X < EdgeWidth) result |= ResizeEdges.Left;
            else if (point.X >= Width - EdgeWidth) result |= ResizeEdges.Right;
            if (point.Y < EdgeWidth) result |= ResizeEdges.Top;
            else if (point.Y >= Height - EdgeWidth) result |= ResizeEdges.Bottom;
            return result;
        }

        private static Cursor CursorFor(ResizeEdges value)
        {
            bool left = (value & ResizeEdges.Left) != 0, right = (value & ResizeEdges.Right) != 0;
            bool top = (value & ResizeEdges.Top) != 0, bottom = (value & ResizeEdges.Bottom) != 0;
            if ((left || right) && (top || bottom)) return left == top ? Cursors.SizeNWSE : Cursors.SizeNESW;
            if (left || right) return Cursors.SizeWE;
            if (top || bottom) return Cursors.SizeNS;
            return Cursors.SizeAll;
        }
    }
}

internal sealed class ScreenPickerForm : Form
{
    private readonly Timer captureTimer = new Timer();
    private Point samplePoint;
    private bool completed;
    public event Action<Color> ColorPicked;
    public event Action PickCancelled;

    public ScreenPickerForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        BackColor = Color.Black;
        Opacity = 0.015;
        Cursor = Cursors.Cross;
        KeyPreview = true;
        Shown += delegate { Activate(); };
        Rectangle bounds = Screen.AllScreens[0].Bounds;
        foreach (Screen screen in Screen.AllScreens) bounds = Rectangle.Union(bounds, screen.Bounds);
        Bounds = bounds;
        captureTimer.Interval = 80;
        captureTimer.Tick += CaptureAfterHide;
        MouseDown += HandleMouseDown;
        KeyDown += delegate(object sender, KeyEventArgs e) { if (e.KeyCode == Keys.Escape) CancelPicking(); };
        FormClosing += delegate
        {
            if (!completed)
            {
                completed = true;
                var handler = PickCancelled;
                if (handler != null) handler();
            }
        };
        FormClosed += delegate { captureTimer.Dispose(); };
    }

    private void HandleMouseDown(object sender, MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left || completed) return;
        samplePoint = Cursor.Position;
        Hide();
        captureTimer.Start();
    }

    private void CaptureAfterHide(object sender, EventArgs e)
    {
        captureTimer.Stop();
        Color color;
        using (var pixel = new Bitmap(1, 1))
        using (var graphics = Graphics.FromImage(pixel))
        {
            graphics.CopyFromScreen(samplePoint, Point.Empty, new Size(1, 1), CopyPixelOperation.SourceCopy);
            color = pixel.GetPixel(0, 0);
        }
        completed = true;
        var handler = ColorPicked;
        if (handler != null) handler(color);
        Close();
    }

    private void CancelPicking()
    {
        if (completed) return;
        completed = true;
        captureTimer.Stop();
        var handler = PickCancelled;
        if (handler != null) handler();
        Close();
    }
}



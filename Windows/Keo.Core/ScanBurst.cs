namespace Keo;

public enum ScanBurstKind
{
    Pass,
    Hold,
    Capture,
    Commit,
    CommitIdle,
    FlushPending,
    TypeBurst,
    DropBurst
}

public readonly record struct ScanBurstStep(ScanBurstKind Kind, bool FlushPending = false, string Text = "");

/// Štítek z čtečky je víc řádků oddělených Enterem. Celý štítek je jeden sken, uzavře ho pauza.
public sealed class ScanBurstAssembler
{
    private char? held;
    private double heldTime;
    private readonly List<char> burst = new();
    private bool capturing;
    private bool sawTerminator;
    private double lastTime = double.NegativeInfinity;

    public double Gap { get; set; } = 0.1;
    public double Idle { get; set; } = 0.55;
    public int MinimumIdleCount { get; set; } = 3;

    public List<ScanBurstStep> Push(char character, double time)
    {
        if (capturing)
        {
            if (time - lastTime > Idle)
            {
                var finished = Finish();
                held = character;
                heldTime = time;
                lastTime = time;
                return new() { finished, new(ScanBurstKind.Hold) };
            }
            burst.Add(character);
            lastTime = time;
            return new() { new(ScanBurstKind.Capture) };
        }
        if (held != null && time - heldTime <= Gap)
        {
            capturing = true;
            burst.Clear();
            burst.Add(held.Value);
            burst.Add(character);
            held = null;
            lastTime = time;
            return new() { new(ScanBurstKind.Capture) };
        }
        var flush = held != null;
        held = character;
        heldTime = time;
        lastTime = time;
        return new() { new(ScanBurstKind.Hold, flush) };
    }

    public List<ScanBurstStep> PushForced(char character, double time)
    {
        var steps = new List<ScanBurstStep>();
        if (capturing && time - lastTime > Idle) steps.Add(Finish());
        if (held != null)
        {
            burst.Add(held.Value);
            held = null;
        }
        burst.Add(character);
        capturing = true;
        lastTime = time;
        steps.Add(new(ScanBurstKind.Capture));
        return steps;
    }

    public List<ScanBurstStep> PushTerminator(double time)
    {
        var fast = time - lastTime <= Gap;
        if (capturing || (held != null && fast))
        {
            if (held != null)
            {
                burst.Add(held.Value);
                held = null;
            }
            if (burst.Count > 0) burst.Add('\n');
            capturing = true;
            sawTerminator = true;
            lastTime = time;
            return new() { new(ScanBurstKind.Capture) };
        }
        var flush = held != null;
        held = null;
        lastTime = time;
        return new() { new(ScanBurstKind.Pass, flush) };
    }

    public List<ScanBurstStep> Interrupt()
    {
        if (capturing || burst.Count > 0)
        {
            burst.Clear();
            capturing = false;
            sawTerminator = false;
            held = null;
            return new() { new(ScanBurstKind.DropBurst) };
        }
        var flush = held != null;
        held = null;
        return flush ? new() { new(ScanBurstKind.FlushPending) } : new();
    }

    public List<ScanBurstStep> Tick(double time)
    {
        if (capturing && time - lastTime >= Idle) return new() { Finish() };
        if (held != null && time - heldTime >= Gap)
        {
            held = null;
            return new() { new(ScanBurstKind.FlushPending) };
        }
        return new();
    }

    public double? NextWake(double time)
    {
        double? wake = capturing ? lastTime + Idle : held != null ? heldTime + Gap : null;
        return wake is > 0 && wake > time ? wake : null;
    }

    private ScanBurstStep Finish()
    {
        var text = new string(burst.ToArray()).Trim();
        var finishedByEnter = sawTerminator;
        burst.Clear();
        capturing = false;
        sawTerminator = false;
        if (finishedByEnter || text.Length >= MinimumIdleCount)
            return text.Length == 0 ? new(ScanBurstKind.DropBurst) : new(ScanBurstKind.CommitIdle, Text: text);
        return new(ScanBurstKind.TypeBurst);
    }
}

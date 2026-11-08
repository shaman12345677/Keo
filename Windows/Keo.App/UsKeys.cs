using Avalonia.Input;

namespace Keo;

/// Čtečka posílá polohy kláves americké klávesnice. Česká klávesnice z nich nesmí udělat jiné znaky.
public static class UsKeys
{
    public static char? FromScanCode(uint scanCode, bool shifted, bool extended)
    {
        if (extended && scanCode == 0x1C) return '\n';
        return scanCode switch
        {
            0x02 => shifted ? '!' : '1',
            0x03 => shifted ? '@' : '2',
            0x04 => shifted ? '#' : '3',
            0x05 => shifted ? '$' : '4',
            0x06 => shifted ? '%' : '5',
            0x07 => shifted ? '^' : '6',
            0x08 => shifted ? '&' : '7',
            0x09 => shifted ? '*' : '8',
            0x0A => shifted ? '(' : '9',
            0x0B => shifted ? ')' : '0',
            0x0C => shifted ? '_' : '-',
            0x0D => shifted ? '+' : '=',
            0x10 => Shift('q', shifted),
            0x11 => Shift('w', shifted),
            0x12 => Shift('e', shifted),
            0x13 => Shift('r', shifted),
            0x14 => Shift('t', shifted),
            0x15 => Shift('y', shifted),
            0x16 => Shift('u', shifted),
            0x17 => Shift('i', shifted),
            0x18 => Shift('o', shifted),
            0x19 => Shift('p', shifted),
            0x1A => shifted ? '{' : '[',
            0x1B => shifted ? '}' : ']',
            0x1E => Shift('a', shifted),
            0x1F => Shift('s', shifted),
            0x20 => Shift('d', shifted),
            0x21 => Shift('f', shifted),
            0x22 => Shift('g', shifted),
            0x23 => Shift('h', shifted),
            0x24 => Shift('j', shifted),
            0x25 => Shift('k', shifted),
            0x26 => Shift('l', shifted),
            0x27 => shifted ? ':' : ';',
            0x28 => shifted ? '"' : '\'',
            0x29 => shifted ? '~' : '`',
            0x2B => shifted ? '|' : '\\',
            0x2C => Shift('z', shifted),
            0x2D => Shift('x', shifted),
            0x2E => Shift('c', shifted),
            0x2F => Shift('v', shifted),
            0x30 => Shift('b', shifted),
            0x31 => Shift('n', shifted),
            0x32 => Shift('m', shifted),
            0x33 => shifted ? '<' : ',',
            0x34 => shifted ? '>' : '.',
            0x35 => shifted ? '?' : '/',
            0x39 => ' ',
            0x47 => '7',
            0x48 => '8',
            0x49 => '9',
            0x4B => '4',
            0x4C => '5',
            0x4D => '6',
            0x4F => '1',
            0x50 => '2',
            0x51 => '3',
            0x52 => '0',
            0x4A => '-',
            0x4E => '+',
            0x53 => '.',
            0x37 => '*',
            _ => null
        };
    }

    public static bool IsTerminator(uint scanCode, bool extended) =>
        scanCode == 0x1C || scanCode == 0x0F;

    public static char? FromAvalonia(Key key, bool shifted) => key switch
    {
        >= Key.A and <= Key.Z => shifted ? char.ToUpperInvariant((char)('a' + (key - Key.A))) : (char)('a' + (key - Key.A)),
        >= Key.D0 and <= Key.D9 => Digit((char)('0' + (key - Key.D0)), shifted),
        Key.OemMinus => shifted ? '_' : '-',
        Key.OemPlus => shifted ? '+' : '=',
        Key.OemOpenBrackets => shifted ? '{' : '[',
        Key.OemCloseBrackets => shifted ? '}' : ']',
        Key.OemSemicolon => shifted ? ':' : ';',
        Key.OemQuotes => shifted ? '"' : '\'',
        Key.OemComma => shifted ? '<' : ',',
        Key.OemPeriod => shifted ? '>' : '.',
        Key.Oem2 => shifted ? '?' : '/',
        Key.Oem5 => shifted ? '|' : '\\',
        Key.Oem3 => shifted ? '~' : '`',
        Key.Space => ' ',
        >= Key.NumPad0 and <= Key.NumPad9 => (char)('0' + (key - Key.NumPad0)),
        Key.Add => '+',
        Key.Subtract => '-',
        Key.Decimal => '.',
        Key.Divide => '/',
        Key.Multiply => '*',
        _ => null
    };

    public static bool IsAvaloniaTerminator(Key key) => key is Key.Enter or Key.Return or Key.Tab;

    private static char Shift(char lower, bool shifted) => shifted ? char.ToUpperInvariant(lower) : lower;

    private static char Digit(char digit, bool shifted)
    {
        if (!shifted) return digit;
        return digit switch
        {
            '1' => '!',
            '2' => '@',
            '3' => '#',
            '4' => '$',
            '5' => '%',
            '6' => '^',
            '7' => '&',
            '8' => '*',
            '9' => '(',
            '0' => ')',
            _ => digit
        };
    }
}

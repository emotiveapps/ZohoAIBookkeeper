import Foundation

/// Terminal handling for raw mode input and ANSI escape code output
public final class Terminal {
    private var originalTermios: termios?

    // ANSI escape codes
    public static let esc = "\u{001B}["
    public static let clearScreen = "\(esc)2J"
    public static let clearLine = "\(esc)2K"
    public static let cursorHome = "\(esc)H"
    public static let cursorHide = "\(esc)?25l"
    public static let cursorShow = "\(esc)?25h"
    public static let bold = "\(esc)1m"
    public static let dim = "\(esc)2m"
    public static let reset = "\(esc)0m"

    // Colors
    public static let red = "\(esc)31m"
    public static let green = "\(esc)32m"
    public static let yellow = "\(esc)33m"
    public static let blue = "\(esc)34m"
    public static let magenta = "\(esc)35m"
    public static let cyan = "\(esc)36m"
    public static let white = "\(esc)37m"
    public static let brightRed = "\(esc)91m"
    public static let brightGreen = "\(esc)92m"
    public static let brightYellow = "\(esc)93m"
    public static let brightBlue = "\(esc)94m"
    public static let brightMagenta = "\(esc)95m"
    public static let brightCyan = "\(esc)96m"

    // Background colors
    public static let bgBlue = "\(esc)44m"
    public static let bgCyan = "\(esc)46m"
    public static let bgWhite = "\(esc)47m"

    /// Box drawing characters
    public static let boxTopLeft = "┌"
    public static let boxTopRight = "┐"
    public static let boxBottomLeft = "└"
    public static let boxBottomRight = "┘"
    public static let boxHorizontal = "─"
    public static let boxVertical = "│"
    public static let boxTeeRight = "├"
    public static let boxTeeLeft = "┤"

    public init() {}

    /// Enable raw mode for character-by-character input
    public func enableRawMode() {
        var raw = termios()
        tcgetattr(STDIN_FILENO, &raw)
        originalTermios = raw

        raw.c_lflag &= ~(UInt(ECHO | ICANON | ISIG | IEXTEN))
        raw.c_iflag &= ~(UInt(IXON | ICRNL | BRKINT | INPCK | ISTRIP))
        raw.c_oflag &= ~(UInt(OPOST))
        raw.c_cflag |= UInt(CS8)

        // Set timeout for read
        raw.c_cc.16 = 0  // VMIN
        raw.c_cc.17 = 1  // VTIME (0.1 sec)

        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        print(Terminal.cursorHide, terminator: "")
        fflush(stdout)
    }

    /// Disable raw mode and restore terminal settings
    public func disableRawMode() {
        if var orig = originalTermios {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &orig)
        }
        print(Terminal.cursorShow, terminator: "")
        fflush(stdout)
    }

    /// Clear the screen
    public func clearScreen() {
        print("\(Terminal.clearScreen)\(Terminal.cursorHome)", terminator: "")
        fflush(stdout)
    }

    /// Move cursor to position
    public func moveTo(row: Int, col: Int) {
        print("\(Terminal.esc)\(row);\(col)H", terminator: "")
        fflush(stdout)
    }

    /// Read a single keypress
    public func readKey() -> KeyPress {
        var buffer = [UInt8](repeating: 0, count: 8)
        let bytesRead = read(STDIN_FILENO, &buffer, buffer.count)

        guard bytesRead > 0 else {
            return .none
        }

        // Check for escape sequences
        if buffer[0] == 27 { // ESC
            if bytesRead == 1 {
                return .escape
            }
            if buffer[1] == 91 { // [
                switch buffer[2] {
                case 65: return .up
                case 66: return .down
                case 67: return .right
                case 68: return .left
                case 90: return .shiftTab  // Shift+Tab
                default: break
                }
            }
            return .escape
        }

        switch buffer[0] {
        case 9: return .tab
        case 10, 13: return .enter
        case 127: return .backspace
        case 3: return .ctrlC
        case 17: return .ctrlQ
        default:
            if buffer[0] >= 32 && buffer[0] < 127 {
                return .char(Character(UnicodeScalar(buffer[0])))
            }
        }

        return .none
    }

    /// Get terminal size
    public func getSize() -> (rows: Int, cols: Int) {
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 {
            return (Int(size.ws_row), Int(size.ws_col))
        }
        return (24, 80)  // Default fallback
    }

    /// Draw a box with optional title
    public func drawBox(row: Int, col: Int, width: Int, height: Int, title: String? = nil) {
        moveTo(row: row, col: col)
        print(Terminal.cyan, terminator: "")

        // Top border
        print(Terminal.boxTopLeft, terminator: "")
        if let title = title {
            let titlePadded = " \(title) "
            let remainingWidth = width - 2 - titlePadded.count
            let leftPadding = remainingWidth / 2
            let rightPadding = remainingWidth - leftPadding
            print(String(repeating: Terminal.boxHorizontal, count: leftPadding), terminator: "")
            print("\(Terminal.brightCyan)\(titlePadded)\(Terminal.cyan)", terminator: "")
            print(String(repeating: Terminal.boxHorizontal, count: rightPadding), terminator: "")
        } else {
            print(String(repeating: Terminal.boxHorizontal, count: width - 2), terminator: "")
        }
        print(Terminal.boxTopRight, terminator: "")

        // Sides
        for i in 1..<(height - 1) {
            moveTo(row: row + i, col: col)
            print(Terminal.boxVertical, terminator: "")
            moveTo(row: row + i, col: col + width - 1)
            print(Terminal.boxVertical, terminator: "")
        }

        // Bottom border
        moveTo(row: row + height - 1, col: col)
        print(Terminal.boxBottomLeft, terminator: "")
        print(String(repeating: Terminal.boxHorizontal, count: width - 2), terminator: "")
        print(Terminal.boxBottomRight, terminator: "")

        print(Terminal.reset, terminator: "")
        fflush(stdout)
    }

    /// Draw a horizontal separator line
    public func drawSeparator(row: Int, col: Int, width: Int) {
        moveTo(row: row, col: col)
        print("\(Terminal.cyan)\(Terminal.boxTeeRight)", terminator: "")
        print(String(repeating: Terminal.boxHorizontal, count: width - 2), terminator: "")
        print("\(Terminal.boxTeeLeft)\(Terminal.reset)", terminator: "")
        fflush(stdout)
    }

    /// Print colored text at position
    public func printAt(row: Int, col: Int, text: String, color: String = "") {
        moveTo(row: row, col: col)
        print("\(color)\(text)\(Terminal.reset)", terminator: "")
        fflush(stdout)
    }

    /// Print a field with label and value
    public func printField(row: Int, col: Int, label: String, value: String, selected: Bool = false, width: Int = 40) {
        moveTo(row: row, col: col)
        print("\(Terminal.dim)\(label):\(Terminal.reset) ", terminator: "")

        let valueWidth = width - label.count - 2
        let displayValue = String(value.prefix(valueWidth)).padding(toLength: valueWidth, withPad: " ", startingAt: 0)

        if selected {
            print("\(Terminal.bgBlue)\(Terminal.white) \(displayValue) \(Terminal.reset)", terminator: "")
        } else {
            print("[\(displayValue)]", terminator: "")
        }
        fflush(stdout)
    }

    /// Print a button
    public func printButton(row: Int, col: Int, label: String, selected: Bool = false, color: String = Terminal.white) {
        moveTo(row: row, col: col)
        if selected {
            print("\(Terminal.bgBlue)\(Terminal.bold)\(Terminal.esc)97m \(label) \(Terminal.reset)", terminator: "")
        } else {
            print("[ \(color)\(label)\(Terminal.reset) ]", terminator: "")
        }
        fflush(stdout)
    }
}

/// Key press types
public enum KeyPress {
    case none
    case char(Character)
    case enter
    case tab
    case shiftTab
    case up
    case down
    case left
    case right
    case escape
    case backspace
    case ctrlC
    case ctrlQ
}

import Foundation

/// Animated spinner for showing progress during async operations
public final class TerminalSpinner {
    private let terminal: Terminal
    private let message: String
    private let row: Int
    private let col: Int
    private var timer: DispatchSourceTimer?
    private let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private var frameIndex = 0

    public init(terminal: Terminal, message: String, row: Int = 1, col: Int = 3) {
        self.terminal = terminal
        self.message = message
        self.row = row
        self.col = col
    }

    public func start() {
        terminal.clearScreen()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .milliseconds(80))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let frame = self.frames[self.frameIndex % self.frames.count]
            self.terminal.printAt(
                row: self.row,
                col: self.col,
                text: "\(Terminal.brightCyan)\(frame)\(Terminal.reset) \(Terminal.bold)\(self.message)\(Terminal.reset)"
            )
            fflush(stdout)
            self.frameIndex += 1
        }
        timer.resume()
        self.timer = timer
    }

    public func stop(message: String, pause: Bool = true) {
        timer?.cancel()
        timer = nil
        terminal.printAt(
            row: row,
            col: col,
            text: "\(Terminal.clearLine)\(Terminal.brightGreen)✓\(Terminal.reset) \(message)   "
        )
        fflush(stdout)
        if pause {
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
}

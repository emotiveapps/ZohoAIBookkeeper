import Foundation
import CoreGraphics
import CoreText

/// Renders plain text into a paginated PDF. Used to convert HTML-bodied email
/// receipts (whose original .html stays in the archive) into a format Zoho
/// accepts as an expense attachment. Thread-safe: CoreText only, no WebKit.
public enum TextPDFRenderer {
    public static func pdfData(text: String, title: String? = nil) -> Data? {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter
        let inset: CGFloat = 48
        let textRect = pageRect.insetBy(dx: inset, dy: inset)

        var content = text
        if let title, !title.isEmpty {
            content = "\(title)\n\n\(text)"
        }

        // CoreText attribute keys (not AppKit/UIKit) so this compiles on every
        // platform; CTFramesetter word-wraps by default.
        let font = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
        let attributed = NSAttributedString(
            string: content,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var mediaBox = pageRect
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        var rendered = 0
        let total = attributed.length

        while rendered < total {
            context.beginPDFPage(nil)
            let path = CGPath(rect: textRect, transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: rendered, length: 0),
                path,
                nil
            )
            CTFrameDraw(frame, context)
            context.endPDFPage()

            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length == 0 { break } // safety: avoid an infinite loop
            rendered += visible.length
        }

        context.closePDF()
        return data as Data
    }
}

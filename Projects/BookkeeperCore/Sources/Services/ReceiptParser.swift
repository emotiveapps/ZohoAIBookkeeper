import Foundation
import SwiftAnthropic

/// Extracts structured fields from a receipt (PDF, image, or HTML/text) with Claude.
public actor ReceiptParser {
    // See ClaudeService for why this suppression is required (SwiftAnthropic
    // isn't Sendable); the service is init-created and used only from this actor.
    private nonisolated(unsafe) let service: any AnthropicService
    private let model: AnthropicModel

    /// Haiku by default: field extraction is easy, receipts are plentiful, and
    /// this runs on every synced email.
    public init(apiKey: String, model: AnthropicModel = .latestHaiku) {
        self.service = AnthropicServiceFactory.service(apiKey: apiKey, betaHeaders: nil)
        self.model = model
    }

    private static let systemPrompt = """
    You extract data from purchase receipts and invoices for bookkeeping.

    Respond ONLY with JSON in this exact format:
    {
      "vendor": "Clean Vendor Name",
      "date": "yyyy-MM-dd",
      "total": 123.45,
      "currency": "USD",
      "card_last4": "1234",
      "confidence": 90,
      "notes": "anything ambiguous"
    }

    Guidelines:
    - "total" is the final amount charged (after tax/tip/shipping)
    - "date" is the purchase/charge date, not a due date
    - Use null for anything not present; confidence 0-100
    - If the content is not a receipt or invoice at all, set confidence to 0
    """

    /// Parse a receipt file. `contentType` decides how it's sent to Claude:
    /// PDFs and images go natively; HTML/text is stripped to plain text.
    public func parse(fileData: Data, contentType: String, filename: String) async throws -> ParsedReceipt {
        let content = try Self.messageContent(fileData: fileData, contentType: contentType, filename: filename)

        let parameters = MessageParameter(
            model: model.asModel,
            messages: [MessageParameter.Message(role: .user, content: content)],
            maxTokens: 512,
            system: .text(Self.systemPrompt)
        )
        let response = try await service.createMessage(parameters)

        var responseText = ""
        for item in response.content {
            if case let .text(text, _) = item {
                responseText = text
                break
            }
        }
        return Self.parseResponse(responseText)
    }

    // MARK: - Content building (internal for tests)

    static func messageContent(
        fileData: Data,
        contentType: String,
        filename: String
    ) throws -> MessageParameter.Message.Content {
        let type = contentType.lowercased()
        let instruction = "Extract the receipt fields from this document (\(filename))."

        if type.contains("pdf") {
            let document = try MessageParameter.Message.Content.DocumentSource.pdf(
                base64Data: fileData.base64EncodedString()
            )
            return .list([.document(document), .text(instruction)])
        }

        if let mediaType = imageMediaType(for: type) {
            let source = MessageParameter.Message.Content.ImageSource(
                type: .base64,
                mediaType: mediaType,
                data: fileData.base64EncodedString()
            )
            return .list([.image(source), .text(instruction)])
        }

        // HTML or plain text: strip markup and send as text.
        let raw = String(data: fileData, encoding: .utf8) ?? ""
        let text = type.contains("html") ? stripHTML(raw) : raw
        return .text("\(instruction)\n\n---\n\(text.prefix(30000))")
    }

    static func imageMediaType(for contentType: String) -> MessageParameter.Message.Content.ImageSource.MediaType? {
        if contentType.contains("jpeg") || contentType.contains("jpg") { return .jpeg }
        if contentType.contains("png") { return .png }
        if contentType.contains("gif") { return .gif }
        if contentType.contains("webp") { return .webp }
        return nil
    }

    /// Crude but sufficient: drop tags/styles/scripts, decode common entities,
    /// collapse whitespace.
    static func stripHTML(_ html: String) -> String {
        var text = html
        for pattern in ["<style[^>]*>[\\s\\S]*?</style>", "<script[^>]*>[\\s\\S]*?</script>", "<[^>]+>"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Response parsing (internal for tests)

    static func parseResponse(_ response: String) -> ParsedReceipt {
        var jsonString = response
        if let start = response.range(of: "{"),
           let end = response.range(of: "}", options: .backwards),
           start.lowerBound < end.upperBound {
            jsonString = String(response[start.lowerBound..<end.upperBound])
        }

        struct Raw: Decodable {
            let vendor: String?
            let date: String?
            let total: Double?
            let currency: String?
            let cardLast4: String?
            let confidence: Int?
            let notes: String?

            enum CodingKeys: String, CodingKey {
                case vendor, date, total, currency, confidence, notes
                case cardLast4 = "card_last4"
            }
        }

        guard let raw = try? JSONDecoder().decode(Raw.self, from: Data(jsonString.utf8)) else {
            return ParsedReceipt(confidence: 0, notes: "Failed to parse extraction response")
        }
        return ParsedReceipt(
            vendor: raw.vendor,
            date: raw.date,
            total: raw.total,
            currency: raw.currency,
            cardLast4: raw.cardLast4,
            confidence: raw.confidence ?? 0,
            notes: raw.notes
        )
    }
}

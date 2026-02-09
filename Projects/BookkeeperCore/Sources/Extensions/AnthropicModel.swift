import SwiftAnthropic

/// Extended model enum that includes newer Claude models not yet in SwiftAnthropic.
/// Maps to SwiftAnthropic's `Model` type via the `asModel` property.
/// - note: When adding new cases, please make sure `latest*` static props are up-to-date
public enum AnthropicModel: String, CaseIterable, Sendable {

  // MARK: - Shortcuts to latest models

  public static var latestSonnet: Self { .claude45Sonnet }
  public static var latestHaiku: Self { .claude45Haiku }
  public static var latestOpus: Self { .claude46Opus }

  // MARK: - Legacy Models

  case claudeInstant12 = "claude-instant-1.2"
  case claude2 = "claude-2.0"
  case claude21 = "claude-2.1"

  // MARK: - Claude 3

  case claude3Opus = "claude-3-opus-20240229"
  case claude3Sonnet = "claude-3-sonnet-20240229"
  case claude3Haiku = "claude-3-haiku-20240307"

  // MARK: - Claude 3.5

  case claude35Sonnet = "claude-3-5-sonnet-latest"
  case claude35Haiku = "claude-3-5-haiku-latest"

  // MARK: - Claude 3.7

  case claude37Sonnet = "claude-3-7-sonnet-latest"

  // MARK: - Claude 4

  case claude4Opus = "claude-opus-4-20250514"
  case claude4Sonnet = "claude-sonnet-4-20250514"

  // MARK: - Claude 4.5 / 4.6

  case claude45Sonnet = "claude-sonnet-4-5-20250929"
  case claude45Haiku = "claude-haiku-4-5-20251001"
  case claude46Opus = "claude-opus-4-6-20260219"

  /// Convert to SwiftAnthropic's `Model` type.
  public var asModel: Model {
    .other(rawValue)
  }
}

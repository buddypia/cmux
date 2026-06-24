/// A multiple-choice question the agent asked the user.
///
/// Sourced from `AskUserQuestion`-style tool invocations. Options render as
/// in-card buttons; a free-text reply through the composer is always
/// available as well.
public struct ChatQuestion: Sendable, Equatable, Codable {
    /// How the question was settled when no answer was selected.
    public enum Resolution: String, Sendable, Equatable, Codable {
        /// The request lapsed because the agent stopped or the session ended.
        case expired
    }

    /// One selectable answer.
    public struct Option: Sendable, Equatable, Codable, Identifiable {
        /// Stable identity within the question (the option's index as text).
        public var id: String { label }

        /// The display text of the option.
        public let label: String

        /// Optional longer explanation of the option.
        public let detail: String?

        /// Creates an option.
        ///
        /// - Parameters:
        ///   - label: Display text.
        ///   - detail: Optional longer explanation.
        public init(label: String, detail: String? = nil) {
            self.label = label
            self.detail = detail
        }

        private enum CodingKeys: String, CodingKey {
            case label
            case detail
        }
    }

    /// The question text.
    public let prompt: String

    /// The selectable answers, in display order.
    public let options: [Option]

    /// The label of the chosen option once answered, `nil` while pending.
    public let selectedOptionLabel: String?

    /// The terminal settlement when the question lapsed unanswered.
    public let resolution: Resolution?

    /// Whether the question is still waiting for user input.
    public var isPending: Bool {
        selectedOptionLabel == nil && resolution == nil
    }

    /// Whether the question was answered or otherwise settled.
    public var isResolved: Bool {
        !isPending
    }

    /// Creates a question.
    ///
    /// - Parameters:
    ///   - prompt: The question text.
    ///   - options: Selectable answers in display order.
    ///   - selectedOptionLabel: Chosen option label once answered.
    ///   - resolution: Settlement when the question lapsed unanswered.
    public init(
        prompt: String,
        options: [Option],
        selectedOptionLabel: String? = nil,
        resolution: Resolution? = nil
    ) {
        self.prompt = prompt
        self.options = options
        self.selectedOptionLabel = selectedOptionLabel
        self.resolution = resolution
    }

    private enum CodingKeys: String, CodingKey {
        case prompt
        case options
        case selectedOptionLabel = "selected_option_label"
        case resolution
    }
}

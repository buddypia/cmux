import SwiftUI

/// Detailed SwiftUI progress inspector panel for an AI CLI agent in Agent Studio.
///
/// Displays real-time CLI status, active tool execution details, event history,
/// and Auto Pilot Mode controls.
public struct AgentProgressInspectorView: View {
    public let agentId: String
    public let roleName: String
    public let cliType: String
    public let currentState: AgentState
    public let currentActionMessage: String?
    public let recentEvents: [CanonicalEvent]

    @Binding public var isAutoPilotEnabled: Bool

    public var onClose: (() -> Void)?
    public var onToggleAutoPilot: ((Bool) -> Void)?
    public var onTriggerAutoContinue: (() -> Void)?

    public init(
        agentId: String,
        roleName: String = "AI Developer",
        cliType: String = "Claude Code",
        currentState: AgentState = .idle,
        currentActionMessage: String? = nil,
        recentEvents: [CanonicalEvent] = [],
        isAutoPilotEnabled: Binding<Bool>,
        onClose: (() -> Void)? = nil,
        onToggleAutoPilot: ((Bool) -> Void)? = nil,
        onTriggerAutoContinue: (() -> Void)? = nil
    ) {
        self.agentId = agentId
        self.roleName = roleName
        self.cliType = cliType
        self.currentState = currentState
        self.currentActionMessage = currentActionMessage
        self.recentEvents = recentEvents
        self._isAutoPilotEnabled = isAutoPilotEnabled
        self.onClose = onClose
        self.onToggleAutoPilot = onToggleAutoPilot
        self.onTriggerAutoContinue = onTriggerAutoContinue
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // MARK: - Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor(for: currentState))
                            .frame(width: 8, height: 8)
                        Text(roleName)
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    Text("ID: \(agentId) • \(cliType)")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(.gray)
                }

                Spacer()

                Button(action: { onClose?() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 4)

            Divider()
                .background(Color.gray.opacity(0.3))

            // MARK: - Auto Pilot Mode Control
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto Pilot Mode")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                    Text("Auto-continue tasks upon turn completion")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                }

                Spacer()

                Toggle("", isOn: $isAutoPilotEnabled)
                    .labelsHidden()
                    .toggleStyle(SwitchToggleStyle(tint: Color.blue))
                    .onChange(of: isAutoPilotEnabled) { _, newValue in
                        onToggleAutoPilot?(newValue)
                    }
            }
            .padding(8)
            .background(Color.blue.opacity(0.12))
            .cornerRadius(6)

            // MARK: - Current State & Action
            VStack(alignment: .leading, spacing: 6) {
                Text("CURRENT STATUS")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.gray)

                HStack(spacing: 8) {
                    Text(currentState.displayName.uppercased())
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(statusColor(for: currentState).opacity(0.2))
                        .foregroundColor(statusColor(for: currentState))
                        .cornerRadius(4)

                    let msg = currentActionMessage ?? currentState.defaultMessage
                    Text(msg)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
            }

            // MARK: - Recent Activity Progress Log
            VStack(alignment: .leading, spacing: 6) {
                Text("RECENT ACTIVITIES")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.gray)

                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if recentEvents.isEmpty {
                            Text("No recent log events")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                                .padding(.vertical, 4)
                        } else {
                            ForEach(displayEvents) { event in
                                eventRow(event)
                            }
                        }
                    }
                }
                .frame(maxHeight: 100)
            }

            // MARK: - Action Buttons
            HStack(spacing: 8) {
                Button(action: { onTriggerAutoContinue?() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                        Text("Auto-Continue Turn")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.green.opacity(0.8))
                    .foregroundColor(.white)
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.top, 4)
        }
        .padding(14)
        .frame(width: 320)
        .background(Color(red: 0.12, green: 0.14, blue: 0.18))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.blue.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 4)
    }

    private var displayEvents: [CanonicalEvent] {
        Array(recentEvents.prefix(6))
    }

    private func eventRow(_ event: CanonicalEvent) -> some View {
        HStack(spacing: 6) {
            Text("•")
                .foregroundColor(.blue)
            Text(event.summary ?? "Event")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
        }
    }

    private func statusColor(for state: AgentState) -> Color {
        switch state {
        case .idle: return .gray
        case .walk: return .cyan
        case .activeRead: return .green
        case .activeType: return .blue
        case .thinking: return .yellow
        case .needsApproval: return .orange
        case .error: return .red
        case .done: return .purple
        }
    }
}

import SwiftUI

/// All transient operation feedback lives outside page scrolling. Full errors remain
/// available through the status button; truncation only applies to its compact title.
struct ServiceFeedback: View {
    let state: AppState
    @State private var showsDetails = false
    private var presentation: ServiceFeedbackPresentation { ServiceFeedbackPresentation(state: state) }

    var body: some View {
        let feedback = presentation
        Button { showsDetails = true } label: {
            HStack(spacing: 6) {
                ZStack {
                    if feedback.working {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: feedback.symbol)
                    }
                }
                .frame(width: 14, height: 14)
                Text(feedback.title).lineLimit(1).truncationMode(.tail)
            }
            .font(.caption)
            .foregroundStyle(feedback.hasError ? Color.red : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(feedback.entries.isEmpty)
        .frame(height: 24)
        .help(feedback.detail)
        .accessibilityLabel(feedback.detail)
        .accessibilityHint(feedback.entries.isEmpty ? "" : "查看完整操作反馈")
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("操作反馈").font(.headline)
                    ForEach(Array(feedback.entries.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title).font(.subheadline.weight(.semibold))
                            Text(entry.detail).font(.caption).textSelection(.enabled)
                        }
                        .foregroundStyle(entry.isError ? Color.red : Color.primary)
                    }
                    Text("用量与配置仅保存在本机。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            .frame(width: 320, height: 260)
        }
    }
}

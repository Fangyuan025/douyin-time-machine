import SwiftUI

struct HistorySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("观看历史").font(.system(size: 18, weight: .bold))
                Text("\(model.history.count) 条").foregroundStyle(.secondary).font(.system(size: 12))
                Spacer()
                Button("清空") { confirmClear = true }
                    .disabled(model.history.isEmpty)
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(18)
            Divider()
            if model.history.isEmpty {
                ContentUnavailableView("还没有观看记录", systemImage: "clock", description: Text("在时光机里看过的视频会出现在这里"))
                    .frame(maxHeight: .infinity)
            } else {
                List(model.history) { entry in
                    HistoryRow(entry: entry)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.playNow(entry.aweme)
                            dismiss()
                        }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: 640, height: 600)
        .preferredColorScheme(.dark)
        .confirmationDialog("清空全部观看历史？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { model.clearHistory() }
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: entry.aweme.coverURL)
                .frame(width: 54, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.aweme.desc.isEmpty ? "（无描述）" : entry.aweme.desc)
                    .font(.system(size: 13))
                    .lineLimit(2)
                Text("@\(entry.aweme.author.nickname)")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Label(Fmt.dayFormatter.string(from: entry.aweme.date), systemImage: "calendar")
                    Label("看于 \(Fmt.ago(entry.watchedAt))", systemImage: "eye")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

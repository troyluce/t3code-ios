import SwiftUI

struct PendingUserInputCard: View {
    let pendingInput: PendingUserInput
    let onRespond: ([String: Any]) -> Void

    @State private var selectionsByQuestion: [String: Set<String>] = [:]
    @State private var customByQuestion: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: T3Spacing.md) {
            header
            ForEach(pendingInput.questions) { question in
                questionBlock(question)
            }
            sendRow
        }
        .padding(T3Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T3Color.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: T3Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: T3Radius.lg, style: .continuous)
                .stroke(T3Color.warning.opacity(0.4), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: T3Spacing.sm) {
            Image(systemName: "questionmark.bubble.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(T3Color.warning)
                .frame(width: 28, height: 28)
                .background(T3Color.warning.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("需要补充信息")
                    .font(T3Typography.headline)
                    .foregroundStyle(T3Color.textPrimary)
                Text("回答后继续")
                    .font(T3Typography.footnote)
                    .foregroundStyle(T3Color.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func questionBlock(_ question: UserInputQuestion) -> some View {
        VStack(alignment: .leading, spacing: T3Spacing.sm) {
            Text(question.header.uppercased())
                .font(T3Typography.caption)
                .foregroundStyle(T3Color.textTertiary)
                .tracking(0.6)
            Text(question.question)
                .font(T3Typography.body)
                .foregroundStyle(T3Color.textPrimary)
            VStack(spacing: T3Spacing.xs) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                    optionRow(question: question, option: option)
                }
                customRow(question: question)
            }
        }
        .padding(.vertical, T3Spacing.xs)
    }

    private func optionRow(question: UserInputQuestion, option: UserInputOption) -> some View {
        Button {
            toggle(questionId: question.id, label: option.label, multi: question.multiSelect)
        } label: {
            HStack(alignment: .top, spacing: T3Spacing.sm) {
                Image(systemName: isSelected(questionId: question.id, label: option.label)
                                  ? (question.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                                  : (question.multiSelect ? "square" : "circle"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected(questionId: question.id, label: option.label)
                                     ? T3Color.primary
                                     : T3Color.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(T3Typography.bodyEmphasis)
                        .foregroundStyle(T3Color.textPrimary)
                    Text(option.description)
                        .font(T3Typography.footnote)
                        .foregroundStyle(T3Color.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(T3Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(T3Color.surfaceMuted, in: RoundedRectangle(cornerRadius: T3Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: T3Radius.sm, style: .continuous)
                    .stroke(T3Color.separator, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func customRow(question: UserInputQuestion) -> some View {
        HStack(spacing: T3Spacing.sm) {
            Image(systemName: "pencil")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(T3Color.textTertiary)
                .frame(width: 22)
            TextField("其他回答（选填）",
                      text: Binding(get: { customByQuestion[question.id] ?? "" },
                                    set: { customByQuestion[question.id] = $0 }))
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled(false)
                .font(T3Typography.body)
                .padding(.horizontal, T3Spacing.sm)
                .padding(.vertical, 6)
                .background(T3Color.surfaceMuted, in: RoundedRectangle(cornerRadius: T3Radius.sm, style: .continuous))
        }
    }

    private var sendRow: some View {
        HStack {
            Spacer()
            Button {
                onRespond(buildAnswers())
            } label: {
                HStack(spacing: T3Spacing.xs) {
                    Image(systemName: "paperplane.fill")
                    Text("提交")
                        .font(T3Typography.bodyEmphasis)
                }
                .padding(.horizontal, T3Spacing.lg)
                .padding(.vertical, 8)
                .background(T3Color.primary)
                .foregroundStyle(.white)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!hasAnswers)
            .opacity(hasAnswers ? 1 : 0.5)
        }
    }

    private var hasAnswers: Bool {
        pendingInput.questions.contains { question in
            let selected = selectionsByQuestion[question.id]?.isEmpty == false
            let custom = (customByQuestion[question.id] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
            return selected || custom
        }
    }

    private func toggle(questionId: String, label: String, multi: Bool) {
        var selections = selectionsByQuestion[questionId] ?? Set<String>()
        if multi {
            if selections.contains(label) {
                selections.remove(label)
            } else {
                selections.insert(label)
            }
        } else {
            if selections.contains(label) {
                selections.removeAll()
            } else {
                selections = [label]
            }
        }
        selectionsByQuestion[questionId] = selections
    }

    private func isSelected(questionId: String, label: String) -> Bool {
        selectionsByQuestion[questionId]?.contains(label) ?? false
    }

    private func buildAnswers() -> [String: Any] {
        var out: [String: Any] = [:]
        for question in pendingInput.questions {
            let selected = Array(selectionsByQuestion[question.id] ?? Set<String>())
            let custom = (customByQuestion[question.id] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var answer: [String: Any] = [:]
            if !selected.isEmpty {
                answer["selections"] = selected
            }
            if !custom.isEmpty {
                answer["custom"] = custom
            }
            if !answer.isEmpty {
                out[question.id] = answer
            }
        }
        return out
    }
}

import SwiftUI

/// 标量数组 / 标量字典的编辑器。
///
/// **写法上仍然是"单字段 op"**：整个容器作为一个值写到它自己的路径上。这不违反
/// 计划 §5 红线 1——红线禁的是"读-改-写**整段 ns**"，那会波及没见过的字段和被
/// redact 掉的 secret。这里写的是一个我们完整看得见的标量容器：它按定义装不下
/// secret（`role('secret')` 声明在标量字段上，而 redact 只摘那些字段本身），
/// 也装不下我们不认识的子结构。
///
/// 元素是对象的容器**不走这儿**（`ListField` 已经挡在前面）：那种要重建嵌套结构，
/// 正是红线说的形状。
struct ScalarListEditor: View {
    @ObservedObject var model: SettingsModel
    let snapshot: NamespaceSnapshot
    let path: [String]
    let value: JSONValue?
    let isDict: Bool

    @State private var expanded = false
    @State private var newKey = ""
    @State private var newValue = ""

    private var items: [(key: String, value: JSONValue)] {
        switch value {
        case .array(let list):
            return list.enumerated().map { (String($0.offset), $0.element) }
        case .object(let fields):
            // 字典键在 JSON 里无序，显示时排一下——否则每次推快照行序都在跳。
            return fields.keys.sorted().map { ($0, fields[$0] ?? .null) }
        default:
            return []
        }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(items.isEmpty ? "空" : "\(items.count) 项")
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(items, id: \.key) { item in
                        HStack(spacing: 6) {
                            Text(isDict ? item.key : "\(item.key).")
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                            Text(item.value.summary)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Button {
                                remove(key: item.key)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                        }
                    }
                    HStack(spacing: 6) {
                        if isDict {
                            TextField("键", text: $newKey)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 88)
                        }
                        TextField("值", text: $newValue)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(append)
                        Button("加", action: append)
                            .controlSize(.small)
                            .disabled(newValue.isEmpty || (isDict && newKey.isEmpty))
                    }
                }
                .frame(width: 260)
            }
        }
    }

    private func append() {
        let entry = JSONValue.string(newValue)
        switch value {
        case .array(let list) where !isDict:
            write(.array(list + [entry]))
        case .object(let fields) where isDict:
            write(.object(fields.merging([newKey: entry]) { _, new in new }))
        case .none, .null:
            write(isDict ? .object([newKey: entry]) : .array([entry]))
        default:
            model.setLocalError(snapshot.ns, path, "当前值的形状不是\(isDict ? "字典" : "数组")，改不了")
            return
        }
        newKey = ""
        newValue = ""
    }

    private func remove(key: String) {
        switch value {
        case .array(let list):
            guard let index = Int(key), list.indices.contains(index) else { return }
            var next = list
            next.remove(at: index)
            write(.array(next))
        case .object(let fields):
            var next = fields
            next.removeValue(forKey: key)
            write(.object(next))
        default:
            return
        }
    }

    private func write(_ next: JSONValue) {
        model.set(ns: snapshot.ns, path: path, value: next)
    }
}

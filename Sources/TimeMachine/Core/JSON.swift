import Foundation

/// 宽松的 JSON 访问器：抖音接口字段类型并不稳定（数字/字符串/布尔混用），
/// 用它来避免 Codable 因为一个字段类型不符就整体解码失败。
struct J {
    let raw: Any?

    init(_ raw: Any?) {
        self.raw = (raw is NSNull) ? nil : raw
    }

    static func parse(_ text: String) -> J? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        return J(obj)
    }

    subscript(_ key: String) -> J { J((raw as? [String: Any])?[key]) }

    subscript(_ index: Int) -> J {
        guard let arr = raw as? [Any], index >= 0, index < arr.count else { return J(nil) }
        return J(arr[index])
    }

    var exists: Bool { raw != nil }

    var string: String? {
        switch raw {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    var int: Int? {
        switch raw {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s) ?? Double(s).map { Int($0) }
        default: return nil
        }
    }

    var double: Double? {
        switch raw {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    var bool: Bool? {
        switch raw {
        case let n as NSNumber: return n.boolValue
        case let s as String: return s == "true" || s == "1"
        default: return nil
        }
    }

    var array: [J] { (raw as? [Any])?.map { J($0) } ?? [] }

    var keys: [String] { (raw as? [String: Any]).map { Array($0.keys) } ?? [] }

    /// 抖音图片/视频地址对象：{ "uri": ..., "url_list": [...] }
    var urlList: [URL] {
        self["url_list"].array.compactMap { $0.string.flatMap { URL(string: $0) } }
    }
}

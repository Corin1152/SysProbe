import Foundation

// 这一层只做一件事：把 CoreTelephony 给回来的原始字典翻译成界面能用的模型。
//
// 设计上刻意**不枚举制式**。原因不是洁癖，是数据本身：CoreTelephony 的字典键在
// 不同 iOS 版本上写法并不统一（见过 `LTE`，也见过 `kCTCellMonitorRadioAccessTechnologyLTE`），
// 写死一组枚举值就意味着「认不出来的制式」会被静默丢掉 —— 而丢掉它等于把用户
// 看不见的那部分配置一起删了。所以这里包住原始键，只在需要决定频段号怎么拼的
// 时候归一次类。
//
// 频段号的拼法（n78 / B3 / BC0 / 直接写数字）是 3GPP 的规定，不是本项目的选择；
// 制式名的匹配顺序由字符串本身的包含关系决定（见 `Family.init(rawKey:)`）。

/// 一个无线接入制式。
nonisolated struct RadioAccessTechnology: Hashable {

    /// 频段号的书写家族 —— 同家族拼法一致。
    enum Family: Hashable {
        /// n78
        case nr
        /// B3
        case lte
        /// 2100
        case umts
        /// TD 34
        case tdscdma
        /// BC0
        case cdma
        /// 900
        case gsm
        /// 认不出来。标题就显示原始键。
        case other
    }

    /// CoreTelephony 字典里的原始键。
    ///
    /// **写回时原样用回去**，不要拿 `family` 反推一个「标准名」—— 拼错一个字母，
    /// 那一组频段在写回时就会被丢掉，而界面看不出任何异常。
    let rawKey: String
    let family: Family

    init(rawKey: String) {
        self.rawKey = rawKey
        self.family = Family(rawKey: rawKey)
    }

    /// 分组标题。
    ///
    /// **不走本地化**：这些是技术标识（5G (NR)、4G (LTE)），译成中文反而要在括号里
    /// 再标一次制式，而且和频段号（n78、B3）是同一类东西。
    var title: String {
        switch family {
        case .nr: return "5G (NR)"
        case .lte: return "4G (LTE)"
        case .umts: return "3G (UMTS/WCDMA)"
        case .tdscdma: return "3G (TD-SCDMA)"
        case .cdma: return "3G (CDMA)"
        case .gsm: return "2G (GSM)"
        case .other: return rawKey
        }
    }
}

nonisolated extension RadioAccessTechnology.Family {

    /// 从原始键认家族。
    ///
    /// **顺序不能调。** `TDSCDMA` 这个字符串里含 `CDMA`，先判 CDMA 会把 TD-SCDMA
    /// 整组吞掉；同理 `UTRAN` 要在更宽的模式之前判。这是数据本身的性质，不是偏好。
    init(rawKey: String) {
        if rawKey.contains("LTE") { self = .lte; return }
        if rawKey.contains("NR") { self = .nr; return }
        if rawKey.contains("GSM") { self = .gsm; return }
        if rawKey.contains("UTRAN") { self = .umts; return }
        if rawKey.contains("TDSCDMA") { self = .tdscdma; return }
        if rawKey.contains("CDMA") { self = .cdma; return }
        self = .other
    }

    /// 界面上的固定顺序。
    ///
    /// 字典是无序的，不排的话每次进这一页分组的顺序都在变 —— 看起来像随机，
    /// 而用户会以为是自己刚才点错了什么。
    static let preferredOrder: [RadioAccessTechnology.Family] = [.nr, .lte, .umts, .cdma, .tdscdma, .gsm]
}

/// 一个频段。`number` 就是频段号。
nonisolated struct Band: Hashable, Comparable {
    let technology: RadioAccessTechnology
    let number: Int

    /// 频段号的通行写法。
    var label: String {
        switch technology.family {
        case .nr: return "n\(number)"
        case .lte: return "B\(number)"
        case .cdma: return "BC\(number)"
        case .tdscdma: return "TD \(number)"
        case .umts, .gsm, .other: return String(number)
        }
    }

    static func < (lhs: Band, rhs: Band) -> Bool { lhs.number < rhs.number }
}

/// 一个卡槽的频段集合。
nonisolated struct BandSet: Equatable {

    /// 网络广播允许使用的频段 —— **这一份是可写的**。
    var active: [RadioAccessTechnology: [Band]] = [:]

    /// 设备声明支持的频段 —— 只读。
    ///
    /// 它决定「界面上列出哪些、哪些能勾」，写回时**原样带回去**：
    /// 只替换 `active`，这样界面上不认识的制式不会被顺手删掉。
    var supported: [RadioAccessTechnology: [Band]] = [:]

    /// 可编辑的制式，按固定顺序。
    var editable: [RadioAccessTechnology] {
        supported.keys
            .filter { supported[$0]?.isEmpty == false }
            .sorted { lhs, rhs in
                let l = RadioAccessTechnology.Family.preferredOrder.firstIndex(of: lhs.family) ?? .max
                let r = RadioAccessTechnology.Family.preferredOrder.firstIndex(of: rhs.family) ?? .max
                // 认不出来的家族排在最后，并按原始键排序 —— 至少顺序是稳定的。
                return l == r ? lhs.rawKey < rhs.rawKey : l < r
            }
    }

    func supportedBands(of technology: RadioAccessTechnology) -> [Band] {
        (supported[technology] ?? []).sorted()
    }

    func activeNumbers(of technology: RadioAccessTechnology) -> Set<Int> {
        Set((active[technology] ?? []).map(\.number))
    }

    /// 把界面上的勾选状态转成桥接层要的字典：`@{原始键: @[频段号, …]}`。
    ///
    /// `only` 限定**只输出这些制式**。这一条是安全约束，不是优化：
    ///
    ///   - 桥接层写回时是从原 `fActiveBands` 的 mutableCopy 起手、只覆盖传进去的键
    ///     （见 `CommCenterBridge.m`），所以**没传的键会原样保留**；
    ///   - 而界面现在只画 4G（见 `BandPanels.visibleRats`）。如果这里仍然输出
    ///     全部 supported 制式，「界面上没画出来」的那些就会被按当前 selection 重写，
    ///     一旦哪次 selection 没初始化全，它们就被静默清空 —— 那是「禁用 3G/2G」，
    ///     不是「不展示 3G/2G」。
    ///
    /// 所以：**只对界面上真正可编辑的制式负责，其余一概不碰。**
    static func payload(selection: [RadioAccessTechnology: Set<Int>],
                        supported: [RadioAccessTechnology: [Band]],
                        only: [RadioAccessTechnology]) -> [String: [NSNumber]] {
        var out: [String: [NSNumber]] = [:]
        for technology in only {
            guard let bands = supported[technology] else { continue }
            let picked = selection[technology] ?? []
            out[technology.rawKey] = bands
                .filter { picked.contains($0.number) }
                .sorted()
                .map { NSNumber(value: $0.number) }
        }
        return out
    }

    /// 解析桥接层给的字典。
    ///
    /// 形状是 `@{原始键: @[NSNumber 频段号, …]}` —— 归一化已经在
    /// `CommCenterBridge.m` 里做过，这里只负责转成 Swift 类型。
    static func parse(_ raw: [String: Any]) -> [RadioAccessTechnology: [Band]] {
        var out: [RadioAccessTechnology: [Band]] = [:]
        for (key, value) in raw {
            let technology = RadioAccessTechnology(rawKey: key)
            let numbers = (value as? [NSNumber]) ?? []
            out[technology] = numbers.map { Band(technology: technology, number: $0.intValue) }.sorted()
        }
        return out
    }
}

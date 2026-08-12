import AppKit
import UniformTypeIdentifiers   // ⚠️ FR-056（收尾批次）：UTType.image 拖拽类型判定

// MarkdownTextView.swift — NSTextView 子类（S-007，AD-1 绑定，FR-001）
// 基础编辑/撤销重做/复制粘贴/服务菜单为 NSTextView 原生能力；
// 事件经闭包暴露，供 RenderCoordinator（S-010）/IMEHandling（S-008）/ScrollSync（S-013）订阅
// ⚠️ 遗留 #5（批次 1）：订阅 editorThemeDidChange 广播响应主题（AD-10 ① 编辑器外观）
final class MarkdownTextView: NSTextView, EditorEventSource {
    // 编辑事件（S-010 订阅：textDidChange → RenderCoordinator.input）
    var onTextDidChange: ((String) -> Void)?
    /// 非图片文件拖入回调（FR-078）
    var onFileDrop: ((URL) -> Void)?
    // ⚠️ P1-1：原始文本回调（保存/导出数据源）——rawText 每次更新时触发，
    // 恒携带完整原文（折叠态下含折叠区间行；onTextDidChange 折叠时只带 renderingText）
    var onRawTextDidChange: ((String) -> Void)?
    // 选区事件（S-008/S-013/S-024 订阅）
    var onSelectionDidChange: ((NSRange) -> Void)?
    // 滚动事件：可见区域顶部 visibleMinY 与内容高度（S-013 比例同步输入；top 基准：顶=0 底=1）
    var onScrollRatio: ((Double) -> Void)?
    // IME compose 状态变化（EditorEventSource，S-008 订阅 → RenderCoordinator.pause/resume）
    var onComposeStateChange: ((Bool) -> Void)?

    private var lastComposing = false

    // ⚠️ S-027：字体存储注入（init 参数透传；设置广播订阅构造 FontSettings 用）
    private let defaults: UserDefaults

    // ⚠️ S-027 实证修正（批 2 GREEN）：NSTextView.font getter 随 textStorage 首字符字体派生
    //（storage 被外部污染/setAttributedString 替换后 font 读回污染值）→ recolor/高亮覆盖
    // 必须用权威 currentFont（init 从 FontSettings 读取；applyUserFont 更新），非派生 getter
    private var currentFont: NSFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)

    // ⚠️ S-023：高亮器（语法高亮调度/主题重放；构造于 init，Editor/ 模块内）
    let syntaxHighlighter: SyntaxHighlighter

    // ⚠️ 修复（focus-fix，根因 1）：程序化回填抑制标志——setTextProgrammatically 置位期间
    // 拦截 didChangeNotification 回调。打破 回填→通知→onTextDidChange→@State 写→
    // updateNSView 同帧循环 → AttributeGraph cycle → UI 冻结 的故障链
    // ⚠️ 修订（审查 CRITICAL #1 第 2 轮）：internal（非 private）——T1.1 测试需
    // 手动置位验证抑制机制（@testable import 只提升 internal，不提升 private）
    var isProgrammaticUpdate = false

    // ⚠️ 修复（T2.3-fix1，评审 IMPORTANT #4）：格式化命令编辑标记——performFormatting 的
    // shouldChangeText 委托校验期间置位，缩进分支据此放行（codeBlock/table/mathBlock 等
    // replacement 含 \n 的命令输出不被自动缩进劫持注入前缀，既有功能回归修复）
    private var isFormattingEdit = false

    // ⚠️ Epic-6 批次 2（T2.2）：折叠集成——rawText 为原始文本缓存（落盘/渲染语义的原文基准），
    // textStorage 为显示文本（折叠后含 ▸ 标记行，string 读回显示文本）；
    // renderingText 由 rawText + FoldState 派生（预览取折叠语义）
    private(set) var rawText: String = ""
    /// 会话级折叠状态（T2.1 交付：toggle 单行锚点语义；foldingRange 计算章节/围栏区间）
    let foldState = FoldState()

    // ⚠️ 遗留 #5：主题同步源（EditorView 挂接 → themeService.effectiveMode）。
    // 广播恒为 effectiveMode（light/dark），.system 由 ThemeService 解析后下发，订阅端不感知
    var themeProvider: (() -> ThemeMode)?

    // ⚠️ 修复 #13（T2.1）：macOS 26.1 SDK 中 NSTextView 的指定初始化器为 init(frame:textContainer:)，
    // init(frame:) 是 convenience init（内部 self.init(frame:textContainer:) 动态派发）。
    // 计划 Code 的 super.init(frame: .zero) 会动态派发到未实现的 designated init →
    // Swift 生成 fatalError stub → 运行时崩溃（Signal 4）。改用指定初始化器直接调用。
    // ⚠️ 修复 #13 附注：该 SDK 中 init(frame:textContainer:) 传 nil 不会自动创建文本系统
    // （textStorage/layoutManager 均为 nil，string 读回空字符串）→ 须显式构建
    // NSTextStorage → NSLayoutManager → NSTextContainer 链条后传入（标准子类初始化模式）。
    init(defaults: UserDefaults = .standard) {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        // ⚠️ 第七轮修复（round7 T1.1，真正根因，Epic-1 遗留）：containerSize 宽度跟随 textView
        // ——手动构建链条下若不跟随，containerSize 宽度恒为 0 → 文字无水平布局空间 → 从不渲染
        // （五轮颜色修复无效的真正原因：问题不是颜色，是文字从未布局；背景绘制正常故"黑色看不到内容"）
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)
        // ⚠️ S-023：高亮器（Highlightr 封装；失败内部降级，此处永不 nil）；
        // defaults 注入便于测试关闭开关（生产 .standard）
        // ⚠️ 适配（T5.1）：无默认值 let 属性须在 super.init 前完成初始化（Swift 初始化规则），
        // 与计划注释"super.init 之后"不同——语义不变（注入 defaults 构造，不访问 self 成员）
        self.syntaxHighlighter = SyntaxHighlighter(defaults: defaults)
        self.defaults = defaults
        super.init(frame: .zero, textContainer: textContainer)
        drawsBackground = true   // ⚠️ 修复（round5 T1.1）：确保 backgroundColor 绘制（否则显示父视图背景 → 白底白字不可见）
        // ⚠️ S-029：行号 gutter 留白（固定 48pt——文本起点右移避开 gutter；数字右对齐绘制于此区内）
        // ⚠️ 修复（真机验收）：底部留白——最后一行滚动到底部时仍有可视空间，
        // 光标可移动到末行编辑（此前 contentView 底部贴内容，末行被遮挡/无法滚到底）
        // textContainerInset.height 上下对称（AppKit 限制），取 14pt 兼顾顶部与底部呼吸空间
        // 底部留白 14 + 状态栏高度补偿 22（状态栏展示时最后一行不被遮挡）
        // 顶部留白 12pt（行号 gutter 对齐呼吸）；底部留白由 scrollView.contentInsets 承担
        //（EditorView——不对称，状态栏遮挡根治）
        textContainerInset = NSSize(width: 48, height: 12)
        isRichText = false                       // 纯文本（MVP，FR-003 高亮在 S-023）
        isContinuousSpellCheckingEnabled = true
        isAutomaticQuoteSubstitutionEnabled = false  // ⚠️ 修复（T2.1 审查）：Markdown 源码编辑器禁止弯引号自动替换，避免 " 被替换为 “” 污染落盘内容（与关闭链接检测同理）
        isAutomaticLinkDetectionEnabled = false  // 链接检测会干扰 Markdown 原文
        // ⚠️ S-027：编辑器字体从 FontSettings 读取为 currentFont 权威快照（默认 monospacedSystemFont(14)，
        // 保持现状行为；init 赋值 font + currentFont，applyUserFont 更新权威快照）——
        // font getter 随 textStorage 首字符字体派生（见属性声明注释）→ setTextProgrammatically/applyTheme
        // 的 font 书写必须用 currentFont（权威快照，非派生 getter），保证回填/主题切换后字体不跳变
        let settingsFont = FontSettings(defaults: defaults).font
        font = settingsFont
        currentFont = settingsFont   // 权威字体快照（font getter 存储派生，见属性声明注释）
        allowsUndo = true
        setupEventNotifications()                // ⚠️ 修复 C1：通知订阅（替代 override）
        // ⚠️ FR-056（收尾批次）：叠加 .fileURL 拖拽注册（图片文件拖入 → 光标处插入图片语法）。
        // registerForDraggedTypes 为整体替换语义——union 追加保 NSTextView 文本拖拽不被覆盖
        var dragTypes = registeredDraggedTypes
        if !dragTypes.contains(.fileURL) { dragTypes.append(.fileURL) }
        registerForDraggedTypes(dragTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - 事件
    // ⚠️ 修复 C1（第 7 轮）：macOS 26.1 SDK 中 NSTextView 的 textDidChange/selectionDidChange
    // 标 NS_SWIFT_UI_ACTOR（@UIActor），Swift 导入后完全不可见 → override 编译失败。
    // 改用通知订阅：NSText.didChangeNotification / NSTextView.didChangeSelectionNotification

    /// 注册通知订阅（init 末尾调用；返回 tokens 供 deinit 移除）
    private var notificationTokens: [NSObjectProtocol] = []

    func setupEventNotifications() {
        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(forName: NSText.didChangeNotification, object: self, queue: .main)
            { [weak self] _ in
                guard let self else { return }
                guard !self.isProgrammaticUpdate else { return }   // ⚠️ focus-fix：程序化回填期间抑制回调（防循环）
                // ⚠️ 修复（T2.2-fix1，评审 CRITICAL）：编辑时同步原始文本缓存——折叠未激活时
                // 显示 == 原文，rawText = string；折叠激活时显示文本含 ▸ 标记且缺折叠区间行，
                // 无条件 rawText = self.string 会把折叠态显示文本写入原文基准（折叠行永久丢失）→
                // 经 expandDisplayToRaw 将显示文本映射回原文（可见行编辑保留 + 区间行恢复）
                if self.foldState.folded.isEmpty {
                    self.rawText = self.string
                    self.onTextDidChange?(self.string)
                    self.onRawTextDidChange?(self.rawText)
                } else {
                    self.rawText = self.expandDisplayToRaw(self.string, from: self.rawText)
                    self.onTextDidChange?(self.renderingText)
                    self.onRawTextDidChange?(self.rawText)
                }
                // ⚠️ 第六轮修复（round6 T1.1，根因 1）：输入后强制重着色——typingAttributes
                // 可能被 IME 输入/撤销/自动替换重建重置（round5 日志证明 applyTheme 设置正确
                // 但用户环境输入文字颜色仍错）；在抑制标志下 recolor。
                // ⚠️ 修订 MINOR #3（第 1 轮）：defer 复位（防未来 recolor 早退泄漏抑制标志）；
                // ⚠️ MINOR #1：recolor 属性编辑实测不触发 didChange 通知（NSTextView 编辑链路
                // 才发布）——guard 拦截为防御兜底
                self.isProgrammaticUpdate = true
                defer { self.isProgrammaticUpdate = false }
                self.recolorTextStorage()
                // ⚠️ 修复（真机验收）：输入后刷新行号——文本变化重绘可能只覆盖内容区
                //（rect 不含 gutter 左侧 48pt），行号需显式重绘（首行/行数变化时）
                if LineNumberPreference.isEnabled(defaults: self.defaults) {
                    self.needsDisplay = true
                }
                // ⚠️ S-023：输入后调度高亮（开关开启 + 非 IME compose；450ms debounce 内聚于
                // highlighter；recolor 先执行提供过渡基础色 → debounce 后高亮覆盖，设计 §4）
                self.scheduleSyntaxHighlight()
                // IME compose 检测（S-008）：compose 期间暂停渲染，上屏后恢复
                let composing = self.hasMarkedText()
                if composing != self.lastComposing {
                    self.lastComposing = composing
                    self.onComposeStateChange?(composing)
                }
            },
            center.addObserver(forName: NSTextView.didChangeSelectionNotification, object: self, queue: .main)
            { [weak self] _ in
                guard let self else { return }
                // ⚠️ S-024：与 didChange 对称——setTextProgrammatically 回填/applySyntaxHighlight
                // 会改选区，抑制标志期间不触发定位同步（防打开文件/回填时光标跳转预览）
                guard !self.isProgrammaticUpdate else { return }
                self.onSelectionDidChange?(self.selectedRange())
            },
            // ⚠️ 遗留 #5（批次 1）：编辑器主题广播订阅（AD-10 ①）
            // object: nil + payload 解包统一策略；广播 object 恒为 effectiveMode（light/dark），
            // .system 已由 ThemeService 解析，订阅端无 system 分支
            center.addObserver(forName: .editorThemeDidChange, object: nil, queue: .main)
            { [weak self] note in
                guard let self else { return }
                // ⚠️ 适配（Swift 6 严格并发）：非 Sendable 的 note 不可跨隔离域发送进
                // assumeIsolated 闭包（sending 'note' risks causing data races）→ 解包提到外层完成
                let mode = note.object as? ThemeMode
                MainActor.assumeIsolated {
                    if let mode {
                        self.applyTheme(mode)
                    }
                    // 解包失败（异常广播）→ 跳过设色，系统跟随兜底（设计 §10）
                }
            },
            // ⚠️ S-027/S-028：设置广播订阅（字体/高亮开关实时生效；userInfo 携带变更键集合——
            // 与 editorThemeDidChange 同构：object: nil 全局订阅，键集合解包外层完成）
            center.addObserver(forName: .editorSettingsDidChange, object: nil, queue: .main)
            { [weak self] note in
                let keys = (note.userInfo?[SettingsNotificationUserInfoKey.changedKeys] as? [String]) ?? []
                MainActor.assumeIsolated {
                    self?.applySettingsChange(keys: keys)
                }
            },
        ]
    }

    // MARK: - 程序化回填（focus-fix，根因 1）

    /// 程序化回填入口：EditorView.updateNSView 回填改走此方法（替代直接 string 赋值）。
    /// 值比较短路（相同文本不写）+ 置位抑制标志（赋值期间 didChangeNotification 被
    /// 通知闭包开头 guard 拦截）。defer 复位：即使 NSTextView 内部赋值异常也保证
    /// 标志复位，不泄漏抑制状态。
    /// ⚠️ 修订（审查 CRITICAL #1 第 2 轮）：返回 Bool = 是否实际写入——
    /// 供 T2.1 回填后显式触发渲染（抑制通知 ≠ 阻断渲染链路，防打开文件预览不更新）
    @discardableResult
    func setTextProgrammatically(_ text: String) -> Bool {
        // ⚠️ 修复（T2.2-fix1，评审 IMPORTANT）：回填新文档前清空会话折叠状态——
        // 置于值比较短路前恒清理（换文档残留：旧折叠区间指向新文档行号 → ▸ 错位残留）
        foldState.removeAllFolds()
        guard string != text else { return false }
        // ⚠️ 新增（T2.2）：回填同步原始文本缓存——此时无折叠（显示 == 原文），
        // rawText 为后续折叠/渲染语义的原文基准
        rawText = text
        onRawTextDidChange?(rawText)
        isProgrammaticUpdate = true
        defer { isProgrammaticUpdate = false }
        // ⚠️ 修复（round5 T1.1）：attributedString 构造驱动——不依赖 textColor/typingAttributes
        // 的 SDK 渲染路径（macOS 26 行为不明），文本属性显式写入 attributedString 保证渲染；
        // setAttributedString 整体替换 → 旧字符级残留背景一并清除（round4 写入的 bg 退出）
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: currentThemeForeground,
            .font: currentFont as Any,
        ]
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attrs))
        scheduleSyntaxHighlight()   // ⚠️ S-023：回填抑制 didChange → 高亮显式调度（打开/新建文件后生效）
        return true
    }

    // MARK: - 格式化命令执行（S-021/S-022，设计 §4 方案 1）

    /// 执行格式化命令：TextFormatting 纯函数变换 → NSText 原生编辑链路
    /// - shouldChangeText 委托链校验（与键盘输入一致，可被 NSTextViewDelegate 拦截）
    /// - replaceCharacters + didChangeText = 原生编辑链路 → didChangeNotification 发布 →
    ///   onTextDidChange → RenderCoordinator.input → 渲染管线自动更新（零额外接线，设计 §5 数据流）
    /// - 撤销/重做自动进 undo 栈（原生编辑链，无自定义栈，设计 §6 Failure Modes）
    /// Execute a formatting command via TextFormatting pure functions, applied through
    /// NSText's native edit path (shouldChangeText + replaceCharacters + didChangeText)
    /// so the didChange notification drives the render pipeline automatically.
    func performFormatting(_ command: EditorCommand) {
        let editRange = selectedRange()
        guard let result = TextFormatting.format(string, range: editRange, command: command) else { return }
        // ⚠️ 修复（T2.3-fix1，评审 IMPORTANT #4）：格式化编辑标记——shouldChangeText 委托校验
        // 期间缩进分支跳过（codeBlock/table/mathBlock replacement 含 \n，防被注入列表/引用前缀劫持）；
        // defer 复位：guard 早退/正常路径均不泄漏标记
        isFormattingEdit = true
        defer { isFormattingEdit = false }
        guard shouldChangeText(in: result.editRange, replacementString: result.replacement) else { return }
        replaceCharacters(in: result.editRange, with: result.replacement)
        // ⚠️ 适配（T2.1）：didChangeNotification 由 didChangeText 收尾发布——标准编辑链路
        // shouldChangeText → replaceCharacters → didChangeText（SDK 头 NSTextView.h:231 确认）；
        // 设计 §5 数据流依赖此通知驱动 onTextDidChange → 渲染管线更新
        didChangeText()
        setSelectedRange(result.selection)
    }

    // MARK: - 拖拽图片插入（FR-056：图片文件拖入 → 光标处插入 Markdown 图片语法）
    // 与窗口级 .onDrop（MainApp.swift:318，FR-078 打开文件）协同：编辑器内仅拦截图片
    // 类型；仅含非图片 fileURL → 拒绝（.none，落窗口级 onDrop 打开——NSTextView 默认
    // 会插入文件路径文本，必须显式拒绝）；文本拖拽走 super（NSTextView 原生能力）

    /// 拖拽进入：图片文件 → .copy（插入语义）；仅非图片 fileURL → .none（拒绝落窗口级）；
    /// 纯文本拖拽 → super（文本拖拽原样）；混合拖拽（文本+非图片 fileURL）→ 整体拒绝
    ///（防 NSTextView 默认插入文件路径文本——doc-reviewer 修复 #2 语义）
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pasteboard = sender.draggingPasteboard
        if !Self.imageURLs(from: pasteboard).isEmpty { return .copy }
        if !Self.fileURLs(from: pasteboard).isEmpty { return .copy }   // 非图片文件：接受，落地时 onFileDrop 打开
        return super.draggingEntered(sender)
    }

    /// 拖拽放置：图片 URL → 光标处逐个插入（多图顺序插入）；仅非图片 fileURL → false（拒绝）；
    /// 纯文本拖拽 → super（混合拖拽含非图片 fileURL → 整体拒绝，语义同上）
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        if handleImageDrop(urls: Self.imageURLs(from: pasteboard)) { return true }
        let fileURLs = Self.fileURLs(from: pasteboard)
        if !fileURLs.isEmpty {
            // 非图片文件：回调打开（FR-078——.md 拖入直接打开）
            fileURLs.forEach { onFileDrop?($0) }
            return true
        }
        return super.performDragOperation(sender)
    }

    /// 全部 fileURL（图片 + 非图片，拖拽判定辅助；internal 可测）
    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// 图片拖拽落地处理（internal 可测：分离 NSDraggingInfo 构造难题）：
    /// 每个 URL → imageMarkdown → 光标处插入（原生编辑链：undo/渲染自动）
    /// ⚠️ 已知语义（混合拖拽）：仅插入图片文件，同拖拽中的非图片文件不转发窗口级
    /// onDrop（FR-078 仅覆盖纯非图片拖拽；转发实现超出本任务范围）
    @discardableResult
    func handleImageDrop(urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        // ⚠️ 修复（审查 MINOR #3）：多图拖拽合并为单次撤销动作（begin/endUndoGrouping
        // 判空安全——undoManager 可能为 nil；单图场景语义不变）
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }
        var inserted = false
        for url in urls {
            if insertImageMarkdown(TextFormatting.imageMarkdown(path: url.path)) { inserted = true }
        }
        // ⚠️ 修复（审查 IMPORTANT #1）：返回"至少一个插入成功"——全部被拒
        //（shouldChangeText 拦截/只读）→ false → performDragOperation 不消费拖拽
        //（落窗口级 onDrop / super 兜底），防图片无声丢失
        return inserted
    }

    /// 光标处插入 Markdown 图片语法（原生编辑链：shouldChangeText → replaceCharacters →
    /// didChangeText → 光标移到插入内容之后；撤销自动进栈，didChange 通知驱动渲染管线）
    /// 返回是否实际插入（shouldChangeText 拒绝 → false，调用方据此决定拖拽消费）
    @discardableResult
    func insertImageMarkdown(_ markdown: String) -> Bool {
        let editRange = selectedRange()
        guard shouldChangeText(in: editRange, replacementString: markdown) else { return false }
        replaceCharacters(in: editRange, with: markdown)
        didChangeText()
        setSelectedRange(NSRange(location: editRange.location + (markdown as NSString).length, length: 0))
        return true
    }

    /// 剪贴板 → 图片文件 URL 列表（纯读取：fileURLsOnly + UTType.image 过滤）
    static func imageURLs(from pasteboard: NSPasteboard) -> [URL] {
        guard let objects = pasteboard.readObjects(forClasses: [NSURL.self],
                                                   options: [.urlReadingFileURLsOnly: true]) as? [URL] else {
            return []
        }
        return objects.filter { isImageURL($0) }
    }

    /// 图片文件判定（UTType：扩展名 → 类型 → 符合 image 统一类型）
    static func isImageURL(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    // MARK: - 自动缩进（Epic-6 批次 2，T2.3：shouldChangeText 拦截 \n 注入前导空白）
    // ⚠️ 不 override insertNewline（@UIActor 风险 U5，textDidChange 先例）
    // ⚠️ shouldChangeText 是纯查询方法（返回是否允许编辑），无法修改调用方传入的
    // replacementString——拦截到 \n 时自行执行替换（原生编辑链）并返回 false 阻止调用方重复插入；
    // super 调用用注入后的字符串（委托校验 + undo 注册语义一致，performFormatting 先例）
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        // ⚠️ 新增（Epic-6 批次 2，T2.4）：括号配对自动补全——单个开括号 ( [ { 且开关开启 →
        // IME 跳过（guard !hasMarkedText）→ 光标后已是对应闭合符则不补 → 否则执行配对插入
        // 编辑链（replaceCharacters(开+闭) → didChangeText → setSelectedRange 光标在开括号后）
        // → 返回 false 阻止调用方重复插入；undo 自动进栈（原生编辑链，performFormatting 先例）
        if let replacement = replacementString,
           AutoPair.isEnabled(defaults: defaults),
           !hasMarkedText(),
           let closing = AutoPair.closingPair(for: replacement),
           affectedCharRange.length == 0,
           !hasClosingBracketAfterCursor(at: affectedCharRange.location, closing: closing) {
            let pair = replacement + closing
            guard super.shouldChangeText(in: affectedCharRange, replacementString: pair) else { return false }
            replaceCharacters(in: affectedCharRange, with: pair)
            didChangeText()
            setSelectedRange(NSRange(location: affectedCharRange.location + (replacement as NSString).length, length: 0))
            return false
        }

        // ⚠️ 修复（T2.3-fix1，评审 IMPORTANT #4 + MINOR）：缩进分支守卫——
        // ① !isFormattingEdit：performFormatting 的 shouldChangeText 校验放行（replacement 含 \n 的
        //   codeBlock/table/mathBlock 命令输出不被注入前缀劫持）
        // ② !hasMarkedText()：IME compose 期间跳过（与 T2.4 AutoPair 对称，防未上屏输入注入干扰）
        guard !isFormattingEdit, let replacement = replacementString, replacement.contains("\n"),
              AutoIndent.isEnabled(defaults: defaults), !hasMarkedText() else {
            return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        }
        // ⚠️ 修复（T2.3-fix1，评审 IMPORTANT #3）：闭合围栏行区分——开围栏（```lang）回车补 4 空格
        // 进入代码块缩进上下文；闭合围栏（```）回车不注入（围栏后段落变代码块回归）
        let prefix = AutoIndent.indentationPrefix(
            for: lineText(at: affectedCharRange.location),
            isClosingFence: AutoIndent.isClosingFenceLine(at: affectedCharRange.location, in: string))
        guard !prefix.isEmpty else {
            return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        }
        // 替换串内每个 \n 后注入前缀（回车/多行粘贴续行对齐）
        let modified = replacement.replacingOccurrences(of: "\n", with: "\n" + prefix)
        guard super.shouldChangeText(in: affectedCharRange, replacementString: modified) else { return false }
        // 自行完成编辑（insertText 拿到 false 后不再插入原始串）
        replaceCharacters(in: affectedCharRange, with: modified)
        didChangeText()
        // 光标落于注入文本之后（原生编辑链下 replaceCharacters 不自动移动光标）
        setSelectedRange(NSRange(location: affectedCharRange.location + (modified as NSString).length, length: 0))
        return false
    }

    /// 指定位置所在行文本（不含行终止符；行首向前/行尾向后扫描 \n）
    /// ⚠️ 修复（T2.3-fix1，评审 IMPORTANT #1）：全链路 NSString UTF-16 API——修复前 Character
    /// 索引（head.lastIndex(of:)/tail.firstIndex(of:)）与 NSString UTF-16 偏移（substring/to:）
    /// 混用，emoji 等多 UTF-16 单元字符致索引错位 → lineStart/lineEnd 计算错误 → 错行取文
    private func lineText(at location: Int) -> String {
        let ns = string as NSString
        let clamped = min(max(location, 0), ns.length)
        let head = ns.substring(to: clamped)
        let headNS = head as NSString
        let lastNL = headNS.range(of: "\n", options: .backwards)
        let lineStart = lastNL.location == NSNotFound ? 0 : lastNL.location + 1
        let tail = ns.substring(from: lineStart)
        let tailNS = tail as NSString
        let firstNL = tailNS.range(of: "\n")
        let lineEnd = firstNL.location == NSNotFound ? ns.length : lineStart + firstNL.location
        return ns.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
    }

    /// 光标后字符是否已是对应闭合符（T2.4：已存在则跳过自动补全，防 "ab)" 场景重复补出 "())"）
    private func hasClosingBracketAfterCursor(at location: Int, closing: String) -> Bool {
        let ns = string as NSString
        guard location >= 0, location < ns.length else { return false }
        return ns.substring(with: NSRange(location: location, length: 1)) == closing
    }

    // MARK: - 折叠（Epic-6 批次 2，T2.2：原始文本访问器 + ▸ 标记显示）

    /// 渲染输入文本（折叠语义）：按 FoldState 折叠区间剔除行后的原始文本——
    /// 折叠区间（foldingRange 语义：H2/H3 章节/围栏）整段剔除，其余行原样保留。
    /// 与显示文本（buildDisplayLines）同源派生 → 预览所见即所得（折叠后 string 为显示文本）
    var renderingText: String {
        let lines = rawText.components(separatedBy: "\n")
        var kept: [String] = []
        var idx = 0
        while idx < lines.count {
            if foldState.isFolded(at: idx) {
                // 折叠区间行剔除（含锚点行；foldingRange 失效时回退单行）
                idx = (FoldState.foldingRange(for: idx, in: lines)?.endLine ?? idx) + 1
            } else {
                kept.append(lines[idx])
                idx += 1
            }
        }
        return kept.joined(separator: "\n")
    }

    /// 折叠命令入口：FoldState.toggle → 重建显示文本（折叠：区间 → ▸ 标记单行；
    /// 展开：恢复原始行区间）。
    /// ⚠️ 适配（计划"FoldState 存原文行文本"）：rawText 为原文唯一来源，显示文本由
    /// rawText + FoldState 派生（buildDisplayLines），展开自动恢复原文——等效实现零冗余缓存
    /// ⚠️ didChangeText() 补发：原生编辑链收尾，缺此 didChangeNotification 不发布；
    /// 通知闭包被 isProgrammaticUpdate 抑制拦截 → 显式 onTextDidChange(renderingText)
    /// 触发渲染链路（预览更新折叠语义——评审注意点：闭包被 guard 拦截，此处必须自调）
    /// ⚠️ 修订（T2.2-fix1）：at 行号 = rawText 原始行索引（非显示文本行号——折叠/展开
    /// 均以原文行为锚；折叠态下显示文本行号与原文行号错位，须用原文索引）
    func toggleFold(at line: Int) {
        let lines = rawText.components(separatedBy: "\n")
        guard line >= 0, line < lines.count else { return }

        // ⚠️ P1-2（T2.2-fix1）：折叠区间内非锚点行 → 锚点行映射——NSTextView 折叠后
        // 光标可能落在区间内（replaceCharacters 后 caret 移至显示文本尾部），toggleFoldAtCursor
        // 再次调用读到的行在折叠区间内但非锚点（isFolded 只认存储的锚点单行区间）；
        // 区间内行应视为已折叠 → 映射回锚点行，展开语义正确（toggle 双语义）
        // Map lines inside a folded anchor's effective range back to the anchor line
        // (isFolded only knows the stored singleton anchor range)
        var effectiveLine = line
        if !foldState.isFolded(at: line) {
            for anchor in foldState.folded {
                if let range = FoldState.foldingRange(for: anchor.startLine, in: lines),
                   line > anchor.startLine, line <= range.endLine {
                    effectiveLine = anchor.startLine
                    break
                }
            }
        }

        let wasFolded = foldState.isFolded(at: effectiveLine)
        foldState.toggle(line: effectiveLine)
        // 折叠路径守卫：无可折叠内容（foldingRange nil——非 H2/H3/未闭合围栏/单行）
        // → 回滚 toggle（空折叠不生效，锚点不残留）
        if !wasFolded, FoldState.foldingRange(for: effectiveLine, in: lines) == nil {
            foldState.toggle(line: effectiveLine)
            return
        }

        let newText = buildDisplayLines().joined(separator: "\n")
        // ⚠️ 审查修复（盲审 #2）：折叠/展开是显示变换（非文本编辑）——原生
        // replaceCharacters 不经 shouldChangeText，不注册撤销动作；折叠前用户编辑
        // 残留撤销栈，折叠态下 Cmd+Z 会把旧编辑的 UTF-16 范围作用于折叠显示文本
        // → 范围错位 → expandDisplayToRaw 映射损坏原文。清除撤销/重做栈（MVP：
        // 折叠即提交点；disableUndoRegistration 不足——旧编辑仍在栈上）
        undoManager?.removeAllActions()
        isProgrammaticUpdate = true
        defer { isProgrammaticUpdate = false }
        replaceCharacters(in: NSRange(location: 0, length: (string as NSString).length), with: newText)
        didChangeText()                    // ⚠️ 补发 didChangeNotification（原生编辑链收尾）
        syntaxHighlighter.cancelPending()  // 取消挂起高亮（防过期结果覆盖新显示）
        scheduleSyntaxHighlight()          // 基于显示文本重高亮（cancelPending 已取消挂起——过期结果不覆盖）
        onTextDidChange?(renderingText)    // 渲染链显式触发（通知闭包被抑制拦截，折叠语义文本）
    }

    /// 由 rawText + FoldState 重建显示行（折叠区间 → ▸ 标记单行；与 renderingText 同源——
    /// 所见即所得：显示与预览折叠语义一致）
    private func buildDisplayLines() -> [String] {
        let lines = rawText.components(separatedBy: "\n")
        var result: [String] = []
        var idx = 0
        while idx < lines.count {
            if foldState.isFolded(at: idx) {
                result.append(FoldMarker.prefix + lines[idx])
                idx = (FoldState.foldingRange(for: idx, in: lines)?.endLine ?? idx) + 1
            } else {
                result.append(lines[idx])
                idx += 1
            }
        }
        return result
    }

    /// 折叠激活时显示文本 → 原文展开映射（编辑回写 rawText 用）：
    /// 可见行编辑原样保留；折叠区间锚点行（▸ 前缀）编辑同步到锚点原文，并恢复区间内其余原文行
    /// Expand display text back to raw text: visible edited lines are kept as-is;
    /// a folded anchor line (▸ prefix) syncs its edit onto the raw anchor line and
    /// restores the remaining original lines of the folded range.
    private func expandDisplayToRaw(_ display: String, from oldRaw: String) -> String {
        let displayLines = display.components(separatedBy: "\n")
        let originalLines = oldRaw.components(separatedBy: "\n")
        var result: [String] = []
        var idx = 0
        for dline in displayLines {
            if idx < originalLines.count, foldState.isFolded(at: idx) {
                let anchor = dline.hasPrefix(FoldMarker.prefix)
                    ? String(dline.dropFirst(FoldMarker.prefix.count))
                    : originalLines[idx]
                result.append(anchor)
                if let range = FoldState.foldingRange(for: idx, in: originalLines), range.endLine > idx {
                    result.append(contentsOf: originalLines[(idx + 1)...range.endLine])
                    idx = range.endLine
                }
            } else {
                result.append(dline)
            }
            idx += 1
        }
        return result.joined(separator: "\n")
    }

    // MARK: - 语法高亮调度（S-023，设计 §4 方案 A / §5 数据流）

    /// 调度高亮：开关关闭 → 跳过（recolor 纯文本路径零回归）；IME compose → 延后
    ///（上屏后 didChange 再触发，IME 安全）；450ms debounce 内聚于 highlighter
    private func scheduleSyntaxHighlight() {
        guard syntaxHighlighter.isHighlightingEnabled else { return }
        guard !hasMarkedText() else { return }
        syntaxHighlighter.scheduleHighlight(string) { [weak self] result in
            self?.applySyntaxHighlight(result)
        }
    }

    /// 字体变更（设置面板实时生效）：更新 currentFont + font + 重着色 + 高亮重放
    /// Font change (settings panel live update)
    func applyFontChange(_ newFont: NSFont) {
        currentFont = newFont
        font = newFont
        recolorTextStorage()
        highlightNow()
    }

    /// 立即执行高亮（测试入口；主题重放经 debounce 调度，此为显式 flush）
    func highlightNow() {
        guard syntaxHighlighter.isHighlightingEnabled else { return }
        applySyntaxHighlight(syntaxHighlighter.highlightNow(string))
    }

    /// 回填高亮结果：textStorage 属性替换（属性编辑不触发 didChangeNotification → 无循环，
    /// 设计 Assumption ✅）；文本已变 → 丢弃过期结果（debounce 竞争守卫）
    /// ⚠️ S-027：输出后整段 font 覆盖——Highlightr 输出 Courier 14（Theme.swift:55/139/165），
    /// 高亮前后字体跳变；覆盖后统一为用户字体（高亮字体统一连带收益）
    private func applySyntaxHighlight(_ result: NSAttributedString?) {
        guard let result, let storage = textStorage else { return }
        // 修复光标跳末尾 bug：setAttributedString 整体替换会重置光标到末尾 →
        // 保存/恢复选中位置 + 可见滚动区域
        let savedSelectedRange = selectedRange()
        let savedVisibleRect = enclosingScrollView?.documentVisibleRect ?? .zero
        isProgrammaticUpdate = true
        defer { isProgrammaticUpdate = false }
        storage.setAttributedString(result)
        // ⚠️ S-027：用权威 currentFont 覆盖（font getter 在 setAttributedString 后读回
        // Highlightr Courier → 自写自杀；currentFont 不受 storage 派生影响）
        storage.addAttribute(.font, value: currentFont,
                             range: NSRange(location: 0, length: storage.length))
        // 恢复光标位置（clamp 到新长度防越界）+ 滚动位置
        let clampedLocation = min(savedSelectedRange.location, max(storage.length, 0))
        let clampedLength = min(savedSelectedRange.length, max(storage.length - clampedLocation, 0))
        setSelectedRange(NSRange(location: clampedLocation, length: clampedLength))
        if savedVisibleRect != .zero {
            enclosingScrollView?.documentView?.scroll(savedVisibleRect.origin)
        }
    }

    deinit {
        // ⚠️ 修复（第 10 轮）：Swift 6 语言模式下 deinit 为 nonisolated，
        // 直接访问非 Sendable 的 notificationTokens 报隔离编译错误；
        // AppKit 对象在主线程释放，用 assumeIsolated 显式断言（与修复 #3 同模式）
        MainActor.assumeIsolated {
            notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }

    /// 滚动比例（S-013 输入）：由外层 NSScrollView bounds 变化驱动，EditorView 挂接
    /// ⚠️ 修复（T4.6 盲审 ①）：top 基准正确公式 scrollTop/(contentHeight−visibleHeight)（顶=0 底=1）
    func reportScroll(visibleMinY: CGFloat, visibleHeight: CGFloat, contentHeight: CGFloat) {
        guard contentHeight > 0, visibleHeight > 0 else { return }
        let maxScroll = contentHeight - visibleHeight
        guard maxScroll > 0 else { onScrollRatio?(0); return }   // 内容不足一屏：锁定顶部
        let ratio = min(max(Double(visibleMinY / maxScroll), 0), 1)   // top 基准：顶=0 底=1
        onScrollRatio?(ratio)
    }

    // MARK: - 设置应用（S-027/S-028：字体 + 高亮开关实时路径）

    /// 设置广播分发（按变更键应用；未知键忽略——通知天然容错，设计 §错误处理）
    func applySettingsChange(keys: [String]) {
        if keys.contains(SettingsChangeKey.font) { applyUserFont() }
        if keys.contains(SettingsChangeKey.highlightEnabled) { applyHighlightSwitch() }
        // ⚠️ S-029：行号开关 → 重绘（开关值在 drawBackground 现读 defaults，此处仅触发绘制）
        if keys.contains(SettingsChangeKey.lineNumbersEnabled) { needsDisplay = true }
    }

    /// 字体变更（S-027，FR-101）：font 改写 + typingAttributes 跟随 + 重着色 + 高亮重放
    ///（设计 §S-027 字体流：FontSettings 变更 → 广播 → 订阅 → font 改写 + 重着色 + 高亮重放）
    func applyUserFont() {
        let newFont = FontSettings(defaults: defaults).font
        guard newFont != currentFont else { return }
        currentFont = newFont   // 先更新权威快照（recolor 读 currentFont）
        font = newFont
        // typingAttributes 跟随（applyTheme 的 typingAttributes 是旧字体快照——新输入须用新字体）
        typingAttributes[.font] = newFont
        recolorTextStorage()   // 现有文本 fg+font 整段重写（recolor 已升级为 fg+font）
        if syntaxHighlighter.isHighlightingEnabled {
            scheduleSyntaxHighlight()   // 高亮重放（applySyntaxHighlight 内统一为用户字体）
        }
    }

    /// 高亮开关变更（S-028，FR-108）：关闭 → 取消挂起 + fg+font 整段重写（清除 Highlightr
    /// 残留色/字体）；开启 → schedule 重放（isHighlightingEnabled 每次现读 defaults——实时生效）
    func applyHighlightSwitch() {
        if syntaxHighlighter.isHighlightingEnabled {
            scheduleSyntaxHighlight()
        } else {
            syntaxHighlighter.cancelPending()
            recolorTextStorage()
        }
    }

    // MARK: - 主题（遗留 #5，AD-10 ①）

    // ⚠️ 修复（round4 T1.1，根因 1）：当前主题色缓存——setTextProgrammatically 回填后重着色用。
    // 初值动态色仅作首帧占位，applyTheme 后即被固定色覆盖
    private var currentThemeForeground: NSColor = .textColor
    /// 当前是否 dark 主题（行号/辅助元素配色用——基于 applyTheme 设置的固定前景色判断）
    private var isDarkTheme: Bool { currentThemeForeground == .white }
    private var currentThemeBackground: NSColor = .textBackgroundColor

    /// 应用主题外观（light：固定黑字白底；dark：固定白字深底；system：防御分支不设色）
    /// ⚠️ 修复（T1.1，根因 1）：改用固定色——动态色（.textColor/.textBackgroundColor）在
    /// 窗口恢复/嵌套视图等 appearance 上下文不一致时解析为同色系 → 黑字黑底不可见。
    /// 主题与系统外观完全解耦（system 由 ThemeService 解析为 effectiveMode 后下发，语义不变）
    /// ⚠️ 修复（round4 T1.1，根因 1）：显式 typingAttributes——textColor setter 只影响派生
    /// 属性，污染后新输入字符可能沿用旧前景色（黑字黑底不可见）；全量 textStorage 重着色
    /// 覆盖 string 回填的已有文本（默认 attributedString 无前景色 → 黑字）
    func applyTheme(_ mode: ThemeMode) {
        let fg: NSColor
        let bg: NSColor
        switch mode {
        case .light:
            // 固定色：黑字白底（与系统外观解耦，任意外观下均可见）
            fg = .black
            bg = .white
        case .dark:
            // 固定色：白字 0.18 深底（0.12 过黑提亮）
            fg = .white
            bg = NSColor(white: 0.18, alpha: 1)
        case .system:
            // ⚠️ 修订 MINOR #6（第 1 轮）：保留 NSLog 复验日志（return 前记录）——
            // 广播恒为 effectiveMode 实际不触发，但手动验收的日志链路不丢失
            NSLog("[Theme] editor applyTheme mode=system (defensive)")
            return   // 广播恒为 effectiveMode，.system 不出现（防御分支；保系统跟随）
        }
        currentThemeForeground = fg
        currentThemeBackground = bg
        textColor = fg
        insertionPointColor = fg
        backgroundColor = bg
        drawsBackground = true   // ⚠️ 修复（round5 T1.1）：强制绘制 backgroundColor（兜底 init 设置被覆写场景）
        // ⚠️ 修复（round5 T1.1）：typingAttributes 不再带字符级 backgroundColor——
        // 文本自身 bg 与视图 bg 叠加出错觉（同色系不可见根因之一）；背景统一由视图承载
        typingAttributes = [.foregroundColor: fg, .font: currentFont as Any]
        recolorTextStorage()
        // ⚠️ S-023：主题切换 → 高亮器换主题 + 重放（AD-8 双轨同名主题；关闭时 recolor 保持零回归）
        syntaxHighlighter.setTheme(mode)
        if syntaxHighlighter.isHighlightingEnabled {
            scheduleSyntaxHighlight()
        }
        // ⚠️ 诊断日志（round5 T1.1）：用户复验确认设置生效（drawsBg=1 + 颜色值）；
        // 若日志正确仍不可见 → SDK 渲染层问题（attributedString 构造路径已就位，下一步二分）
        NSLog("[Theme] editor applyTheme mode=%@ textColor=%@ bg=%@ drawsBg=%d",
              mode.rawValue, String(describing: fg), String(describing: bg), drawsBackground ? 1 : 0)
        NSLog("[Theme] editor effectiveAppearance=%@ windowAppearance=%@",
              String(describing: NSApp?.effectiveAppearance), String(describing: window?.effectiveAppearance))
        // ⚠️ 诊断日志（round7 T1.1）：复验布局状态——containerSize 宽度 > 0 证明文字有
        // 水平布局空间（widthTracksTextView 生效）；frame 与 storageLength 佐证视图/内容状态。
        // 读取 NSTextView 属性（textContainer/frame/textStorage），非 init 局部变量
        NSLog("[Editor] layout containerSize=%@ frame=%@ storageLength=%d",
              NSStringFromSize(textContainer?.containerSize ?? .zero),
              NSStringFromRect(frame),
              textStorage?.length ?? 0)
    }

    /// 全量重着色（round4 T1.1，根因 1）：string 回填的已有文本默认 attributedString 无前景色
    /// → 黑字黑底不可见。按当前主题前景色整段覆盖（背景由 textStorage 的 backgroundColor 统一承载）
    /// ⚠️ 修订（round4 T1.1 CRITICAL #1）：同步重写字符级背景——typingAttributes 写入的
    /// 字符级 .backgroundColor 在主题切换后残留 → 黑字压深块/白字压白块不可见；按当前主题背景色整段覆盖
    /// ⚠️ S-027：连带 font 整段重写——recolor 语义升级为 fg+font（高亮残留字体清除的统一入口：
    /// 高亮开关关闭路径 + 输入过渡色路径共用）
    private func recolorTextStorage() {
        guard let storage = textStorage, storage.length > 0 else { return }
        // ⚠️ 修复（round5 T1.1）：beginEditing/endEditing 包裹（批量编辑合并为一次通知）+
        // 只写前景色+font（字符级背景彻底退出——背景由视图 backgroundColor + drawsBackground 承载）
        storage.beginEditing()
        let range = NSRange(location: 0, length: storage.length)
        storage.addAttribute(.foregroundColor, value: currentThemeForeground, range: range)
        // ⚠️ S-027 实证修正：写权威 currentFont（font getter 存储派生——storage 被污染后
        // font 读回污染值，写回无效；currentFont 由 init/applyUserFont 维护，不受派生影响）
        storage.addAttribute(.font, value: currentFont, range: range)
        storage.endEditing()
    }

    /// 订阅后主动同步一次（遗留 #5）：容器 init 的 apply() 广播早于视图订阅注册 →
    /// 初始广播丢失；视图挂载时经 themeProvider 读取当前 effectiveMode 补发
    ///（显式 dark 启动场景由此覆盖）
    func syncThemeFromProvider() {
        guard let mode = themeProvider?() else { return }
        applyTheme(mode)
    }

    // MARK: - 聚焦（focus-fix，根因 2）

    /// 声明可聚焦：事件链路 NSSplitView → NSHostingView → NSScrollView → NSTextView
    /// 嵌套中默认聚焦行为失效，显式声明接受 first responder
    override var acceptsFirstResponder: Bool { true }

    /// 点击强制转移 first responder：嵌套链路中 NSTextView 默认点击聚焦失效 → 手动接管
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // ⚠️ P1-2：▸ 点击展开——点击位置所在显示行首为折叠标记 → toggleFold（原文行锚定）；
        // 折叠态下显示行号 ≠ 原文行号，经 FoldMarker 映射；展开后不重定位光标
        //（replaceCharacters 保持点击处相对偏移，光标停留锚点行附近——MVP 可接受）
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if let rawLine = FoldMarker.rawLineForMarker(at: index, display: string, raw: rawText,
                                                     folded: foldState.folded),
           // ⚠️ 审查修复（盲审 #1）：命中区域限定为 ▸ 标记字形 boundingRect——
           // 防 gutter（48pt 行号区）/行尾空白/文档下方空白点击意外展开并消费点击
           markerGlyphRect(forLineContaining: index).map({ $0.contains(point) }) == true {
            toggleFold(at: rawLine)   // 点击 ▸ = 展开该折叠区间（toggleFold 双语义）
            return   // 消费本次点击——不进入编辑光标放置
        }
        super.mouseDown(with: event)
    }

    /// ▸ 标记字形矩形（视图坐标）：index 所在显示行行首前缀的 layoutManager boundingRect
    ///（仅对折叠标记行调用；非标记行返回 nil）
    private func markerGlyphRect(forLineContaining index: Int) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let ns = string as NSString
        let clamped = min(max(index, 0), ns.length)
        let head = ns.substring(to: clamped)
        let lastNL = (head as NSString).range(of: "\n", options: .backwards).location
        let lineStart = lastNL == NSNotFound ? 0 : lastNL + 1
        let prefixLength = (FoldMarker.prefix as NSString).length
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: lineStart, length: prefixLength),
            actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return nil }
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        return rect
    }

    // MARK: - 行号 gutter（S-029，FR-004/FR-107）

    /// drawBackground 内绘制行号（零新视图；滚动天然同步——绘制随视图滚动重触发）
    /// 视觉行（软换行感知）：enumerateLineFragments 枚举每 fragment，fragment 起点
    /// 恰为逻辑行首时绘制行号（软换行续行不重复编号，UNVERIFIED 细化）
    /// 开关实时生效：LineNumberPreference.isEnabled 现读 defaults（SyntaxHighlighter 先例）
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard LineNumberPreference.isEnabled(defaults: defaults),
              let layoutManager, let textContainer,
              let storage = textStorage, storage.length > 0 else { return }
        let gutter = textContainerInset.width
        guard gutter > 0 else { return }
        // ⚠️ 修复（真机验收）：
        // 1) rect 为视图坐标（含 inset）→ 转容器坐标查 glyphRange（防边界行号漏画）
        // 2) "行号渲染一半"根因：drawBackground 分批调用（rect 每次只含部分区域），
        //    行号随批次绘制在批间显示中间态 → 基于完整可见区域（visibleRect）绘制行号，
        //    使整列行号一次成型（同批合成），消除"上半先出/下半后出"的割裂视觉
        let visibleContainerRect = visibleRect.offsetBy(dx: -textContainerInset.width,
                                                        dy: -textContainerInset.height)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleContainerRect, in: textContainer)
        let text = string
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            [weak self] lineRect, _, _, fragmentGlyphRange, _ in
            guard let self else { return }
            let charIndex = layoutManager.characterIndexForGlyph(at: fragmentGlyphRange.location)
            guard LineNumbers.isLineStart(characterIndex: charIndex, in: text) else { return }
            let number = LineNumbers.lineNumber(forCharacterIndex: charIndex, in: text)
            // ⚠️ 修复（真机验收）：行号配色——light 保持系统次级灰（原状）；
            // dark 用亮青蓝（Xcode/VS Code 深色编辑器行号风格，#6E9EFF → 0.43/0.62/1.0），
            // 避免灰黑系看不清
            let lineNumberColor: NSColor = self.isDarkTheme
                ? NSColor(calibratedRed: 0.43, green: 0.62, blue: 1.0, alpha: 0.85)   // dark：亮青蓝
                : NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.20, alpha: 1.0)  // light：橘色系（用户偏好）
            let attrStr = NSAttributedString(string: "\(number)", attributes: [
                .foregroundColor: lineNumberColor,
                .font: self.currentFont,
            ])
            // 右对齐于 gutter 内（右侧留 8pt 呼吸空间）
            let size = attrStr.size()
            // ⚠️ 修复（真机验收）：行号垂直对齐——用字体度量（ascender/descender）对齐文本
            // 基线中心，而非行高简单居中（font 与 lineRect 高度不匹配时错位）
            let font = self.currentFont
            // ⚠️ 修复（真机验收）：行号坐标 = 容器坐标(lineRect) + 顶部 inset（实证：
            // enumerateLineFragments 返回容器坐标，lineRect.minY=0 不含 inset）→
            // 加 inset 使行号区与编辑文本区顶部对齐；垂直居中用行高简单居中
            let y = lineRect.minY + self.textContainerInset.height + (lineRect.height - size.height) / 2
            attrStr.draw(at: NSPoint(x: gutter - 8 - size.width, y: y))
        }
    }
}

// 行号纯函数（S-029，FR-004）：逻辑行定位/行首判定/行数——无 AppKit 依赖可单测（TextFormatting 先例）
enum LineNumbers {
    /// 字符 index → 逻辑行号（1-based；index 越界 clamp 到最近行）
    static func lineNumber(forCharacterIndex index: Int, in text: String) -> Int {
        let ns = text as NSString
        let clamped = min(max(index, 0), ns.length)
        let prefix = ns.substring(to: clamped)
        return prefix.components(separatedBy: "\n").count
    }

    /// 行首判定（视觉行 fragment 起点 → 是否逻辑行首：index==0 或前一字符为换行）
    static func isLineStart(characterIndex index: Int, in text: String) -> Bool {
        guard index > 0 else { return true }
        let ns = text as NSString
        guard index <= ns.length else { return false }
        return ns.character(at: index - 1) == 0x0A
    }

    /// 逻辑行数（含无换行结尾的末行）
    static func lineCount(in text: String) -> Int {
        lineNumber(forCharacterIndex: (text as NSString).length, in: text)
    }
}

// 自动缩进纯函数（Epic-6 批次 2，T2.3）：回车续行缩进前缀计算——无 AppKit 依赖可单测（TextFormatting 先例）
// 开关经 UserDefaults 注入（init(defaults:) 已有注入模式；批次 3 面板接线 SettingsChangeKey.autoIndentEnabled）
enum AutoIndent {
    /// 开关存储键（批次 3 面板接线；本任务仅读取）
    static let enabledKey = "autoIndentEnabled"

    /// 开关读取：默认开启（object(forKey:) 区分未设置与显式 false——SyntaxHighlighter 先例）
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: enabledKey) == nil { return true }
        return defaults.bool(forKey: enabledKey)
    }

    /// 回车续行缩进前缀（纯函数）：
    /// - 当前行前导空白（空格/tab）保留
    /// - 列表项（- / * / + / 数字. 后跟空格）→ 前导空白 + 列表标记 + 空格
    /// - 引用行（> ）→ 前导空白 + > 
    /// - 代码围栏行（``` 开头）→ 4 空格跟随（代码块缩进上下文）；闭合围栏行 → 不注入
    /// - 空行/无前导 → 空串
    /// ⚠️ 修复（T2.3-fix1，评审 IMPORTANT #2/#3）：纯空白行返回前导空白（修复前返回 "" →
    /// 代码块内 "    " 空行回车续行缩进断裂）；isClosingFence 区分围栏开闭（修复前闭合
    /// ``` 行回车注入 4 空格 → 围栏后段落变代码块）
    static func indentationPrefix(for line: String, isClosingFence: Bool = false) -> String {
        let whitespace = line.prefix(while: { $0 == " " || $0 == "\t" })
        let rest = line.dropFirst(whitespace.count)
        guard !rest.isEmpty else { return String(whitespace) }
        // 列表项：标记 + 空格（含任务列表 - [ ] 的 - 前缀场景）
        if let marker = listMarker(in: rest) {
            return String(whitespace) + marker
        }
        // 引用行
        if rest.hasPrefix("> ") {
            return String(whitespace) + "> "
        }
        // 代码围栏（``` 或 ```lang）→ 4 空格跟随；闭合围栏行 → 不注入
        if rest.hasPrefix("```") {
            return isClosingFence ? "" : "    "
        }
        // 普通行 → 仅前导空白
        return String(whitespace)
    }

    /// 光标所在行是否为闭合围栏行（纯函数）：
    /// 统计当前行之前（不含当前行本身）的 ``` 前缀行数——奇数 → 当前行为闭合围栏行。
    /// ⚠️ 适配（评审指令细化）：围栏行自身不计入统计——若计入，开围栏行（此前 0 条围栏，
    /// 计入后 1 条 → 奇数）会被误判为闭合围栏行而不注入 4 空格，与"开围栏回车 → 4 空格
    /// 注入"的测试契约矛盾；闭围栏行（此前 1 条围栏 → 奇数）正确判定为闭合。
    static func isClosingFenceLine(at location: Int, in text: String) -> Bool {
        let ns = text as NSString
        let clamped = min(max(location, 0), ns.length)
        let head = ns.substring(to: clamped)
        let headNS = head as NSString
        let lastNL = headNS.range(of: "\n", options: .backwards)
        let lineStart = lastNL.location == NSNotFound ? 0 : lastNL.location + 1
        let beforeCurrent = headNS.substring(to: lineStart)
        let fenceCount = beforeCurrent.components(separatedBy: "\n")
            .filter { $0.hasPrefix("```") }.count
        return fenceCount % 2 == 1
    }

    /// 列表标记识别：- / * / + 或 数字. 后跟空格 → 返回标记含尾随空格（"- "、"1. " 等）
    private static func listMarker(in text: Substring) -> String? {
        let rest = String(text)
        let unordered = ["- ", "* ", "+ "]
        if let marker = unordered.first(where: { rest.hasPrefix($0) }) {
            return marker
        }
        // 有序列表：ASCII 数字 + "." + 空格（1. / 10. 等）
        // ⚠️ 修复（T2.3-fix1，评审 MINOR）：isNumber 含 Unicode 数字（² 等上标/圈数字）→
        // "². x" 被误判为有序列表标记；改 ASCII 判定（isASCII + isNumber = ASCII 数字）
        var index = rest.startIndex
        var digits = ""
        while index < rest.endIndex, rest[index].isASCII, rest[index].isNumber {
            digits.append(rest[index])
            index = rest.index(after: index)
        }
        guard !digits.isEmpty, index < rest.endIndex,
              rest[index] == ".", rest.index(after: index) < rest.endIndex,
              rest[rest.index(after: index)] == " " else { return nil }
        return digits + ". "
    }
}

// 括号配对纯函数（Epic-6 批次 2，T2.4）：开括号 → 对应闭合括号映射——无 AppKit 依赖可单测（AutoIndent 先例）
// 开关经 UserDefaults 注入（init(defaults:) 已有注入模式；批次 3 面板接线 SettingsChangeKey.autoPairEnabled）
enum AutoPair {
    /// 开关存储键（批次 3 面板接线；本任务仅读取）
    static let enabledKey = "autoPairEnabled"

    /// 开关读取：默认开启（object(forKey:) 区分未设置与显式 false——AutoIndent 先例）
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: enabledKey) == nil { return true }
        return defaults.bool(forKey: enabledKey)
    }

    /// 开括号 → 对应闭合括号（( [ { → ) ] }）；非开括号 → nil（不参与自动配对）
    static func closingPair(for opening: String) -> String? {
        switch opening {
        case "(": return ")"
        case "[": return "]"
        case "{": return "}"
        default: return nil
        }
    }
}

// 折叠标记纯函数（P1-2 ▸ 点击展开）：▸ 行判定 + 显示行 → 原文行映射——无 AppKit 依赖可单测（LineNumbers 先例）
// Fold-marker pure functions: ▸ line detection + display-line → raw-line mapping (P1-2)

/// 折叠标记纯函数（P1-2）：▸ 前缀行判定 + 显示行 → 原文行映射
/// Fold-marker pure functions: ▸ line detection + display-line → raw-line mapping
enum FoldMarker {
    /// 折叠标记前缀（单一事实源：buildDisplayLines 写入、expandDisplayToRaw 剥离、点击判定共用）
    /// Fold marker prefix (single source of truth shared by display build / strip / click detection)
    static let prefix = "▸ "

    /// 字符 index 所在显示行 → 对应**原文**行号（0 基；任意显示行——含 ▸ 折叠标记行）。
    /// 折叠感知映射：折叠区间在显示中消耗 1 行（▸ 锚点行）、在原文中消耗 [start,end] 多行
    ///（与 buildDisplayLines 同源扫描；折叠态下显示行号 ≠ 原文行号，必须经映射——
    /// 评审 CRITICAL #1 修正：selectedRange 是显示索引，直接对 rawText 做行号统计
    /// 会在光标上方存在折叠时错位）
    /// Maps any character position in the display text to its raw-text line index
    /// (fold-aware: a folded range occupies a single display line).
    static func rawLine(at characterIndex: Int, display: String, raw: String,
                        folded: [FoldRange]) -> Int? {
        let displayLines = display.components(separatedBy: "\n")
        let ns = display as NSString
        let clamped = min(max(characterIndex, 0), ns.length)
        let displayLine = ns.substring(to: clamped).components(separatedBy: "\n").count - 1
        guard displayLine >= 0, displayLine < displayLines.count else { return nil }
        let rawLines = raw.components(separatedBy: "\n")
        var displayIdx = 0
        var rawIdx = 0
        while rawIdx < rawLines.count {
            if folded.contains(where: { $0.startLine <= rawIdx && rawIdx <= $0.endLine }) {
                if displayIdx == displayLine { return rawIdx }
                displayIdx += 1
                rawIdx = (FoldState.foldingRange(for: rawIdx, in: rawLines)?.endLine ?? rawIdx) + 1
            } else {
                if displayIdx == displayLine { return rawIdx }
                displayIdx += 1
                rawIdx += 1
            }
        }
        return nil
    }

    /// 字符 index 所在显示行是否为折叠标记行（▸ 前缀）→ 命中返回对应**原文**行号（0 基）；
    /// 未命中（普通行/无折叠）→ nil。（鼠标 ▸ 点击展开的命中测试：仅 ▸ 标记行触发）
    static func rawLineForMarker(at characterIndex: Int, display: String, raw: String,
                                 folded: [FoldRange]) -> Int? {
        guard let rawIdx = rawLine(at: characterIndex, display: display, raw: raw, folded: folded) else {
            return nil
        }
        let ns = display as NSString
        let clamped = min(max(characterIndex, 0), ns.length)
        let displayLine = ns.substring(to: clamped).components(separatedBy: "\n").count - 1
        let displayLines = display.components(separatedBy: "\n")
        guard displayLine >= 0, displayLine < displayLines.count,
              displayLines[displayLine].hasPrefix(FoldMarker.prefix) else { return nil }
        return rawIdx
    }
}

// 滚动事件挂接辅助：观察 NSScrollView contentView bounds 变化（S-013 铺路）
@MainActor  // ⚠️ 修复 #4（第 7 轮）：访问 scrollView.contentView（@MainActor）
final class ScrollTracker {
    private var observer: NSObjectProtocol?

    func attach(to scrollView: NSScrollView, textView: MarkdownTextView) {
        detach()   // 先移除旧 observer，防重复 attach 累积 stale observer
        // ⚠️ 修复 F3（第 8 轮）：闭包同时 weak 捕获 scrollView 与 textView——
        // 只 weak textView 会让 scrollView 被隐式强捕获（block 持有 → 永不释放 → observer 泄漏）
        observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView, queue: .main
        ) { [weak scrollView, weak textView] _ in
            guard let sv = scrollView, let tv = textView else { return }
            // ⚠️ 修复 #3（第 9 轮）：通知闭包同步执行于主线程（queue: .main），
            // 访问 @MainActor 属性用 assumeIsolated 显式断言（勿用 Task 引入异步）
            MainActor.assumeIsolated {
                let visible = sv.contentView.bounds
                let total = tv.frame.height
                tv.reportScroll(visibleMinY: visible.minY, visibleHeight: visible.height, contentHeight: total)
            }
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
    }

    func detach() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    // ⚠️ 修复 F3（第 8 轮）：deinit 兜底移除（detach 无调用点时防泄漏；
    // EditorView.Coordinator deinit 也应调用 detach）
    // ⚠️ 修复（第 10 轮）：deinit nonisolated 无法直接访问非 Sendable 的 observer，
    // 用 assumeIsolated 断言（观察者总是注册/注销于主线程）
    deinit {
        MainActor.assumeIsolated {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

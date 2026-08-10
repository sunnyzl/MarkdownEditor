/* MessageBridge.js — Swift↔Web 消息桥（设计 §5.1 schema 锁定，AD-9）
 * Web → Swift: renderDone / linkClicked / errorOccurred (postMessage)
 * Swift → Web: window.setContent / setTheme / setViewport（window 命名空间全局函数） */
(function () {
  'use strict';

  var container = document.getElementById('content');

  function post(name, payload) {
    try {
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[name]) {
        window.webkit.messageHandlers[name].postMessage(payload || {});
      }
    } catch (e) { /* 浏览器直开 preview.html（无宿主）时静默 */ }
  }

  /* T1.5（Epic-6 批次 1，源码定位）：[data-sourcepos] 索引缓存——
   * setContent 注入后一次性 querySelectorAll，parse 每元素 data-sourcepos 属性
   * 的起止行（Down 格式 "startLine:startCol-endLine:endCol"）；供 setScrollToSource
   * 按源码行精确滚动定位（源码行 → 预览元素） */
  var sourceposIndex = [];   /* [{ startLine, endLine, el }]，按 startLine 升序 */

  function buildSourceposIndex() {
    sourceposIndex = [];
    container.querySelectorAll('[data-sourcepos]').forEach(function (el) {
      var attr = el.getAttribute('data-sourcepos') || '';
      var m = attr.match(/^(\d+):(\d+)-(\d+):(\d+)$/);
      if (!m) { return; }   /* 格式不符（防御）：跳过该元素 */
      sourceposIndex.push({
        startLine: parseInt(m[1], 10),
        endLine: parseInt(m[3], 10),
        el: el
      });
    });
    sourceposIndex.sort(function (a, b) { return a.startLine - b.startLine; });
  }

  /* 阶段 4 + 阶段 5（设计 §5.2）：
   * morphdom 主 + innerHTML 兜底 → 残留检测（JS DOM 兜底）→ katex → mermaid → hljs → renderDone */
  /* ⚠️ 修复（focus-fix，根因 3）：async → 同步——async 函数返回 Promise，
   * evaluateJavaScript 对 Promise 返回值报 "unsupported type"（用户日志 ×3 证据）；
   * 内部 await 改 fire-and-forget（mermaid.run 不等待） */
  /* R-M4 v2（设计 §1）：局部重渲染——morphdom 注入前后对比各 pre.mermaid 源码，
   * 仅对变化块执行 mermaid.run({ nodes })；零变化 → 零渲染开销 */
  window.setContent = function (html) {
    var t0 = performance.now();
    var status = 'ok', error = null;
    try {
      /* R-M4 v2 ①（⚠️ 第 2 轮审查重写——简化方案）：不再需要 prevSources 集合——
       * 注入后的存档循环天然识别需要渲染的块（无 data-processed = 未渲染 =
       * 变化块 + 新增块）；钩子仅负责"同源跳过保留 SVG"防销毁 */
      if (typeof morphdom !== 'undefined') {
        /* ⚠️ 第 1 轮审查 CRITICAL #1 修复：onBeforeElUpdated 钩子——
         * 源码相同的 pre.mermaid 跳过更新（return false → 保留已渲染 SVG + data-processed）：
         * 否则 morphdom 会把 SVG（nodeType=1）与源码文本（nodeType=3）视为不匹配而
         * 无条件移除 SVG → 未变化图若再跳过渲染则永久停留在源码文本（图消失）。
         * ⚠️ 第 2 轮：同源判断基于【该元素新旧源码比较】（非集合去重）——
         * 图 B 改成与图 A 相同源码时 fromEl(B).旧源码 ≠ toEl 新源码 → 正确判定变化 ✓ */
        morphdom(container, '<div id="content">' + html + '</div>', {
          onBeforeElUpdated: function (fromEl, toEl) {
            if (fromEl.classList && fromEl.classList.contains('mermaid') &&
                (fromEl.getAttribute('data-mermaid-source') || fromEl.textContent) ===
                (toEl.getAttribute('data-mermaid-source') || toEl.textContent)) {
              return false;   /* 同源跳过：保留 SVG 渲染状态 */
            }
            return true;
          }
        });
        /* ⚠️ 修复（round5 T1.2a 审查 CRITICAL）：morphdom 的 morphAttrs 会删除新模板缺失的
         * style 属性 → zoom 被抹掉（每次编辑重渲染后缩放失效、Swift 状态漂移）；此处重放 */
        container.style.zoom = currentZoom;
      } else {
        container.innerHTML = html;
        /* ⚠️ 第 2 轮 MINOR #3：fallback 路径重建容器 → 所有图无 data-processed/data-mermaid-source
         * → 下方存档循环全部捕获 → 全量渲染（自动正确，无需特判） */
      }
      /* 阶段 3 残留检测：Swift 正则未覆盖（Down 格式变化）→ JS DOM 兜底（方案 A，幂等） */
      if (typeof MermaidDomTransformer !== 'undefined' &&
          container.querySelector('code.language-mermaid')) {
        MermaidDomTransformer.transform(container);
      }
    } catch (e) {
      status = 'error'; error = String(e);
      container.innerHTML = html;   /* 兜底：内容必须呈现（NFR-012） */
      if (typeof MermaidDomTransformer !== 'undefined') {
        MermaidDomTransformer.transform(container);   /* T3.5：兜底路径接入 JS DOM 转换 */
      }
    }
    /* T1.5：注入完成（含兜底路径）→ 重建 sourcepos 索引；无 [data-sourcepos] 元素 → 空数组 */
    buildSourceposIndex();
    /* 阶段 5：katex（同步，FR-033 先于 mermaid）→ mermaid.run（异步）→ hljs（幂等） */
    try {
      if (window.renderMathInElement) {
        /* S-026（FR-035，R-M1 缓解）：单 $ 分隔符条件化——katexSingleDollar=false 时
         * 移除 $ 单分隔符（保留 $$ 块级与 \(\) 行内）；JS 反斜杠：源码 '\\(' 运行时 \( */
        var delimiters = [
          { left: '$$', right: '$$', display: true },
          { left: '\\(', right: '\\)', display: false }
        ];
        if (katexSingleDollar) {
          delimiters.push({ left: '$', right: '$', display: false });
        }
        renderMathInElement(container, {
          delimiters: delimiters,
          throwOnError: false
        });
      }
    } catch (e) { if (!error) { status = 'error'; error = 'katex: ' + String(e); } }
    try {
      if (window.mermaid) {
        /* S-015：首次渲染前存档源码（mermaid v11 以 innerHTML 为源且渲染后销毁）。
         * ⚠️ 第 2 轮简化：存档循环 = changedNodes 收集——无 data-processed && 无 source 的块
         * （变化块 morph 后属性被删 + 新增块）补存档并收集；未变化块（钩子保留 SVG +
         * data-processed + source）不捕获 → 零渲染。
         * 同源多图场景天然正确：B 改成 A 的源码 → B 的 fromEl 旧源码 ≠ toEl 新源码 →
         * 钩子放行更新 → 存档循环捕获 → 渲染 ✓（无需集合去重） */
        var changedNodes = [];
        container.querySelectorAll('pre.mermaid').forEach(function (pre) {
          if (!pre.hasAttribute('data-processed') && !pre.hasAttribute('data-mermaid-source')) {
            pre.setAttribute('data-mermaid-source', pre.textContent);
            changedNodes.push(pre);
          }
        });
        /* focus-fix：fire-and-forget——不再 await（函数不返回 Promise，消除
         * evaluateJavaScript "unsupported type"）；错误留在对应块（POC S-001），
         * catch 静默防 unhandled rejection；renderDone 不等待 mermaid（设计 §5 已接受）
         * R-M4 v2 ④：仅渲染变化块；主题切换路径（setTheme）保持全量（设计 §1 ⑤） */
        if (changedNodes.length > 0) {
          /* ⚠️ 第 1 轮审查 IMPORTANT #4：run 前显式清除 data-processed 防御
           * （兜底路径/未来 morphdom 行为变化未删属性时 mermaid 会跳过） */
          changedNodes.forEach(function (el) { el.removeAttribute('data-processed'); });
          mermaid.run({ nodes: changedNodes }).catch(function (e) {
            if (!error) { status = "error"; error = "mermaid: " + String(e); }
            /* ⚠️ 修订 B1：catch 回调在微任务队列晚于同步 post('renderDone') 执行，status 变更对已发送 payload 无效 → 补发 errorOccurred 保证不静默（勿用 .then 延迟 post——设计 §5 renderDone 不等 mermaid） */
            post('errorOccurred', { phase: 'mermaid', message: String(e) });
          });
        }
      }
    } catch (e) { if (!error) { status = 'error'; error = 'mermaid: ' + String(e); } }
    try { if (window.hljs) hljs.highlightAll(); } catch (e) { if (!error) { status = 'error'; error = 'hljs: ' + String(e); } }
    post('renderDone', {
      status: status,
      error: error,
      /* T1.5（源码定位）：sourceMap = data-sourcepos 属性纯字符串数组（Swift 侧解析）；
       * 由 sourceposIndex 派生，保证与索引同源一致（消除 document/container 双数据源不一致）；
       * 仅 setContent 上报（setTheme/setConfig/setFont 保持现状）；无元素 → [] */
      sourceMap: sourceposIndex.map(function (item) {
        return item.el.getAttribute('data-sourcepos');
      }),
      scrollHeight: document.body.scrollHeight,
      elapsed: Math.round(performance.now() - t0)   /* NFR-001 计时埋点 */
    });
  };

  /* 主题：body.dark + CSS 变量（AD-10；S-015 ThemeService 双轨下发；hljs 主题 link 在 S-012 追加） */
  /* ⚠️ 修复（focus-fix，根因 3）：async → 同步（与 setContent 同理，消除 Promise 返回值上报） */
  window.setTheme = function (mode) {
    var dark = (mode === 'dark');
    /* ⚠️ 修订偏差落地（executor T1.2）：计划文本 catch 引用 status/error 但作用域未声明——
     * 按注释意图（IMPORTANT #3 + MINOR #5）补声明 + 上报 */
    var t0 = performance.now();
    var status = 'ok', error = null;
    document.body.classList.toggle('dark', dark);
    /* S-012：hljs 主题双轨——light/dark CSS link 的 disabled 与 body.dark 联动（修复 #6 联动缺口） */
    var light = document.getElementById('hljs-theme-light');
    var darkLink = document.getElementById('hljs-theme-dark');
    if (light) light.disabled = (mode === 'dark');
    if (darkLink) darkLink.disabled = (mode !== 'dark');
    try {
      if (window.mermaid) {
        /* S-026：主题初始化抽出为 applyMermaidTheme()——mermaid 主题由 setConfig 决定
         *（AD-10 正交：ThemeService 三态切换不再覆盖用户选择的 mermaid 主题） */
        applyMermaidTheme();
      }
    } catch (e) {
      /* ⚠️ 修订 MINOR #5（第 2 轮）：外层同步异常同样汇入 status（不静默吞）——
       * 与 IMPORTANT #3 的"不静默"精神一致；浏览器直开（无宿主）场景仍静默 */
      if (!error) { status = 'error'; error = 'setTheme: ' + String(e); }
    }
    /* ⚠️ 修订偏差落地（executor T1.2）：汇入 renderDone——setTheme 原作用域无 status/error，
     * 计划文本按注释意图补声明 + 上报（保 ScrollSync 错误基线语义；无宿主场景 post 静默） */
    post('renderDone', {
      status: status,
      error: error,
      scrollHeight: document.body.scrollHeight,
      elapsed: Math.round(performance.now() - t0)
    });
  };

  /* S-026（FR-035/046）：预览配置（window.setConfig）——Swift 侧 PreviewSettings →
   * PreviewConfig → 本入口；delimiters 每次渲染时按配置构建（见 setContent 内条件化） */
  var katexSingleDollar = true;   /* R-M1 缓解开关（FR-035；默认 true 行为不变） */
  var mermaidTheme = 'default';   /* FR-046 四选项：default/dark/forest/neutral（跟随已由 Swift 解析） */

  /* S-026：mermaid 主题统一应用（setTheme 与 setConfig 共用；原 setTheme :137-152 整体搬移——
   * initialize + 存档恢复 + 全量重渲染；保持"theme 先于 content"隐式契约） */
  var appliedMermaidTheme = null;   /* 已应用主题——仅变化时全量重渲染 */
  function applyMermaidTheme(force) {
    if (!window.mermaid) { return; }
    /* ⚠️ 修复（真机验收）：页面主题切换（setTheme light/dark）不再触发 mermaid 全量重渲染——
     * 仅当 mermaidTheme 实际变化（setConfig）或首次才 initialize + mermaid.run()；
     * 否则只更新容器背景（轻量 DOM 操作）。消除切主题的显著延迟（小文档同样受影响） */
    var changed = (appliedMermaidTheme !== mermaidTheme) || force;
    /* 容器背景始终随当前 mermaidTheme 更新（轻量）——
     * dark 主题用 #0d1117（GitHub dark 背景，mermaid dark 主题的设计基准——深色元素
     * 在其上有足够对比；#1e1e1e 过浅导致 dark 主题深色文字看不清） */
    var light = (mermaidTheme !== 'dark');
    container.querySelectorAll('pre.mermaid').forEach(function (pre) {
      pre.style.background = light ? '#ffffff' : '#0d1117';
      pre.style.borderColor = light ? '#d0d7de' : '#30363d';
    });
    if (!changed) { return; }
    appliedMermaidTheme = mermaidTheme;
    mermaid.initialize({ theme: mermaidTheme, startOnLoad: false });
    /* 恢复存档源码 + 清守卫 → 以新主题重渲染 */
    container.querySelectorAll('pre.mermaid[data-processed]').forEach(function (pre) {
      var src = pre.getAttribute('data-mermaid-source');
      if (src !== null) {
        pre.textContent = src;
        pre.removeAttribute('data-processed');
      }
    });
    /* focus-fix：fire-and-forget（与 setContent 同理） */
    mermaid.run().catch(function (e) {
      post('errorOccurred', { phase: 'mermaid', message: String(e) });
    });
  }

  window.setConfig = function (config) {
    var t0 = performance.now();
    var status = 'ok', error = null;
    try {
      if (config && typeof config === 'object') {
        if (typeof config.katexSingleDollar === 'boolean') { katexSingleDollar = config.katexSingleDollar; }
        if (typeof config.mermaidTheme === 'string' && ['default', 'dark', 'forest', 'neutral'].indexOf(config.mermaidTheme) >= 0) { mermaidTheme = config.mermaidTheme; }
      }
      /* 配置变更 → 按新主题重渲染（存档恢复）；delimiters 在下次 setContent 生效 */
      applyMermaidTheme();
    } catch (e) {
      if (!error) { status = 'error'; error = 'setConfig: ' + String(e); }
    }
    /* 对称上报 renderDone（scrollHeight 更新驱动 ScrollSync 补偿，与 setTheme 同基线） */
    post('renderDone', {
      status: status,
      error: error,
      scrollHeight: document.body.scrollHeight,
      elapsed: Math.round(performance.now() - t0)
    });
  };

  /* S-027（FR-086）：预览字体——CSS 变量 --font-family/--code-font-family 切换。
   * ⚠️ 不走 setContent：morphdom 同源跳过会拦截未变化内容，字体不生效（设计 §S-027）；
   * setProperty 写 documentElement 内联样式，与主题 body.dark 类互不干扰。
   * 与 setTheme/setConfig 同基线：同步 + renderDone 上报（scrollHeight 驱动 ScrollSync 补偿） */
  window.setFont = function (fontFamily, codeFontFamily) {
    var t0 = performance.now();
    var status = 'ok', error = null;
    try {
      var root = document.documentElement;
      if (typeof fontFamily === 'string' && fontFamily) {
        root.style.setProperty('--font-family', fontFamily);
      }
      if (typeof codeFontFamily === 'string' && codeFontFamily) {
        root.style.setProperty('--code-font-family', codeFontFamily);
      }
    } catch (e) {
      if (!error) { status = 'error'; error = 'setFont: ' + String(e); }
    }
    post('renderDone', {
      status: status,
      error: error,
      scrollHeight: document.body.scrollHeight,
      elapsed: Math.round(performance.now() - t0)
    });
  };

  /* 滚动同步（S-013）：比例映射的落地入口 */
  window.setViewport = function (scrollTop) {
    var y = Number(scrollTop) || 0;
    document.documentElement.scrollTop = y;
    document.body.scrollTop = y;
  };

  /* 预览缩放（round5 T1.2）：CSS zoom 应用于 #content（保留布局，简单可靠）；
   * 0.5x ~ 3.0x 限制（与 Swift 侧 clampedZoom 同源契约：NaN/±Infinity → 1.0） */
  var currentZoom = 1.0;
  window.setZoom = function (factor) {
    var n = Number(factor);
    if (!isFinite(n)) { n = 1.0; }   /* 与 Swift clampedZoom 同源：NaN/±Infinity → 1.0（isFinite 检查） */
    currentZoom = Math.max(0.5, Math.min(3.0, n));
    container.style.zoom = currentZoom;
  };

  /* T1.5（源码定位）：Swift 侧源码行点击 → 预览对应元素滚动定位。
   * 查索引：命中覆盖 [startLine, endLine] 且区间跨度最小（最深嵌套最精确）的元素；
   * zoom 处理：offsetTop / currentZoom（U2 实测锁定项；若精度不足可换
   * scrollIntoView({block:'start'}) 备选）；scrollTop 设置复用 setViewport 双写逻辑。
   * 未命中（索引为空/行越界）→ 静默（无对应元素可定位） */
  window.setScrollToSource = function (startLine, endLine) {
    var s = Number(startLine) || 0;
    var e = Number(endLine) || s;
    if (e < s) { e = s; }   /* 防御：endLine < startLine 时按单行处理 */
    if (s <= 0) { return; }
    var best = null, bestSpan = Infinity;
    sourceposIndex.forEach(function (item) {
      if (item.startLine <= s && item.endLine >= e && (item.endLine - item.startLine) < bestSpan) {
        best = item;
        bestSpan = item.endLine - item.startLine;
      }
    });
    if (!best) { return; }   /* 未命中：静默返回 */
    var y = best.el.offsetTop / currentZoom;   /* CSS zoom 下 offsetTop 为缩放像素 → 还原文档坐标 */
    setViewport(y);
  };

  /* 链接点击：上报 Swift 侧（FR-029 外链打开；S-025 增强，MVP 上报即可） */
  document.addEventListener('click', function (e) {
    var target = e.target;
    while (target && target !== document) {
      if (target.tagName === 'A' && target.getAttribute('href')) {
        var href = target.getAttribute('href');
        /* 锚点（TOC 页内跳转，linkClicked 仅限外部链接）与修饰键/中键点击：交浏览器默认行为 */
        if (href.charAt(0) === '#' || e.metaKey || e.ctrlKey || e.altKey || e.shiftKey || e.button !== 0) {
          return;
        }
        e.preventDefault();
        post('linkClicked', { href: href });
        return;
      }
      target = target.parentNode;
    }
  });

  /* S-031（FR-091）：导出 HTML 内容读取——Swift 侧 ExportManager 在渲染稳定后调用。
   * 同步返回（非 Promise，规避 evaluateJavaScript "unsupported type" 已知陷阱）。
   * getUnrenderedCount：未完成 mermaid 渲染的块数（导出降级警告依据） */
  window.getContent = function () {
    return container.innerHTML;
  };

  window.getUnrenderedCount = function () {
    var n = 0;
    container.querySelectorAll('pre.mermaid').forEach(function (pre) {
      if (!pre.hasAttribute('data-processed')) { n += 1; }
    });
    return n;
  };

  /* 错误上报入口（NFR-012：Swift 侧主动调用） */
  window.reportError = function (phase, message) {
    post('errorOccurred', { phase: String(phase), message: String(message) });
  };
})();

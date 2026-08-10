/* MermaidDomTransformer.js — JS DOM 转换兜底（AD-4 方案 A，设计 §5.2 阶段 3 兜底）
 * JS DOM transform fallback (AD-4 Option A, design §5.2 stage-3 fallback)
 * 触发条件：Swift 正则主方案未覆盖（Down 输出格式变化残留）
 * Trigger: Swift regex primary path misses (Down output format drift residual)
 * 幂等（transform 将 code 元素替换为文本 → 二次调用 NodeList 为空，自然幂等；class 守卫为防御冗余）/ 无副作用（仅处理 language-mermaid）
 * Idempotent (code element replaced by text → empty NodeList on re-call; class guard is defensive) / side-effect free (only language-mermaid) */
(function () {
  'use strict';
  window.MermaidDomTransformer = {
    /* 转换容器内全部 mermaid code 块；返回转换数量
     * Transform all mermaid code blocks in container; return count */
    transform: function (root) {
      var codes = (root || document).querySelectorAll('code.language-mermaid');
      var count = 0;
      codes.forEach(function (code) {
        var pre = code.parentElement;
        if (!pre || pre.tagName !== 'PRE') return;
        if (pre.classList.contains('mermaid')) return;   /* 幂等 / idempotent */
        pre.classList.add('mermaid');
        pre.textContent = code.textContent;              /* 原文（textContent 往返精确还原）raw text (exact round-trip) */
        count += 1;
      });
      return count;
    }
  };
})();

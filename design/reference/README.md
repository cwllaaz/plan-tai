# design/reference —— 已确认效果图

## 状态：**图片缺失**

本目录应存放项目发起人确认过的 Windows 首页效果图：

```
design/reference/approved-home.png   ← 当前不存在
```

已核对位置：本目录、`docs/`、`legacy-node-prototype/`、Git 全部历史、桌面常用目录。
`docs/01-开发前技术与需求评审报告.md` §2.1 也曾记录该图未进入工程目录。

## 因此

- `docs/UI_SPEC.md` 以 `docs/01` §2.8 的书面设计令牌为基线，**不代表已对齐效果图**。
- 任何 Agent 不得用其他设计图、网上参考图或自绘稿替代"已确认效果图"。
- 效果图补齐后：放入本目录并命名为 `approved-home.png`，在 `docs/UI_SPEC.md`
  §0 补《效果图对照》，再按对照结果只调整 `lib/core/theme/tokens.dart` 与 UI_SPEC。

## 需要发起人确认的 4 个点

1. 主色色相：当前 `#3E63DD`（蓝）；历史实现出现过 `#6E56CF`（紫）。
2. 月历行高比例与格子内边距。
3. 月历与右侧抽屉之间：1px 分隔线（当前）还是浮层阴影。
4. 顶栏控件密度与右侧按钮组合。

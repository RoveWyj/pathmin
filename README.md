# pathmin

> 用 MoonBit 编写的 **SVG `<path>` 无损压缩器（minifier）** —— 压缩体积，形状不变。

为 Web 图标库、地图矢量、SVG 素材精简 `<path d="...">` 字符串，减少传输与存储体积，**完全不改变渲染出来的图形**。

## 特性

- **无损压缩**：只删除冗余信息，不损失任何精度
  - 去掉多余空格与逗号分隔符：`M 10, 20 L 30, 40` → `M10 20 30 40`
  - 去掉小数尾零与末尾小数点：`10.0000` → `10`、`5.50` → `5.5`
  - 去掉正号：`+1.5` → `1.5`
  - **隐含命令省略**：`M` 后连续坐标省略 `L` 字母（`M10 20 30 40`）
  - **连续同命令合并**：多个 `C` 只保留一次
  - **按需分隔**：命令与数字、数字与负数之间不加空格（`M1.5-2.5`）
  - **冗余段消除**：删除零长度线段（`L`/`H`/`V` 落回当前点）与重复闭合（`Z Z` → `Z`）
- **科学计数法安全**：`1.5e10` 的指数部分不会被误裁剪
- **有损模式可选**：`--precision N` 截断小数位，换取更高压缩率
- **MoonBit 语言优势**：用 ADT（`enum Token` + `enum OutItem`）+ 模式匹配描述语法结构
- **可测试**：29 个单元测试，含 round-trip 无损自证、路径校验、冗余段消除、幂等性、边界用例

## 效果对比

输入（常见人工格式化写法）：

```
M 24.000, 12.000 C 24.000, 5.373 18.627, 0.000 12.000, 0.000 C 5.373, 0.000 0.000, 5.373 0.000, 12.000 C 0.000, 18.627 5.373, 24.000 12.000, 24.000 C 18.627, 24.000 24.000, 18.627 24.000, 12.000 Z
```

输出：

```
M24 12C24 5.373 18.627 0 12 0 5.373 0 0 5.373 0 12 0 18.627 5.373 24 12 24 18.627 24 24 18.627 24 12Z
```

| | 长度 |
|---|---|
| 原始 | 196 字节 |
| 优化后 | 101 字节 |
| 节省 | **48%** |

两个字符串渲染出的图形完全一致。

## 环境要求

- [MoonBit CLI](https://www.moonbitlang.cn/download/)（建议最新版）
- VSCode + MoonBit 插件（可选，提供语法高亮与补全）

验证安装：

```bash
moon version
```

## 快速开始

```bash
# 静态检查
moon check

# 运行单元测试
moon test

# 运行 CLI：传入一段 path d
moon run cmd/main "M 100.000,200.000 L 300.0000,400.0000 Z"

# 不带参数时使用内置示例
moon run cmd/main

# 统计命令出现次数
moon run cmd/main --stats "M1,2 L3,4 Z"

# 有损模式：保留 2 位小数
moon run cmd/main --precision 2 "M 1.23456, 2.34567 Z"
```

示例输出：

```
input    : M 100.000, 200.000 L 300.0000, 400.0000 L 0.0000, 0.0000 Z
minified : M100 200 300 400 0 0Z
bytes    : 58 -> 21  (saved 63%)
```

## 库用法

项目同时提供库 API，可被其他 MoonBit 包引用：

```moonbit
let r = @pathmin.optimize("M 10.000, 20.000 L 30.0000, 40.0000")
r.minified      // "M10 20 30 40"
r.original_len  // 原始长度
r.new_len       // 优化后长度

// 有损模式：截断到 2 位小数
let r2 = @pathmin.optimize_precision("M 1.23456, 2.34567", 2)

// 删除冗余段（零长度线段 / 重复闭合）
let d2 = @pathmin.remove_degenerate("M10 10 L10 10 L20 20 Z Z") // "M10 10 20 20Z"

// 校验与统计
let ok = @pathmin.is_valid_path("M1,2 L3,4 Z")  // true
let n = @pathmin.segment_count("M1,2 L3,4 Z")   // 3
let ok_lossless = @pathmin.verify_lossless("M 10.000, 20.000 L 30.0, 40.0") // true
```

## 项目结构

```
pathmin/
├── .github/workflows/  # GitHub Actions CI
├── moon.mod            # 模块配置
├── moon.pkg            # 根库包
├── lib.mbt             # 核心：词法分析 + 命令分组 + 序列化 + 精度裁剪
├── lib_test.mbt        # 单元测试（29 个）
├── cmd/
│   └── main/           # 可执行入口（CLI）
│       ├── main.mbt
│       └── moon.pkg
└── README.md
```

## CI

GitHub Actions 在每次 push/PR 时自动运行 `moon check` 与 `moon test`。

## Roadmap

- [x] 隐含命令省略（`M` 后连续坐标省略 `L`）
- [x] 数字精度裁剪（有损模式，`--precision`）
- [x] **冗余段消除**：零长度段、重复闭合点的删除（`remove_degenerate`）
- [ ] **WASM 在线演示**：编译到 WebAssembly，浏览器内实时输入输出
- [ ] **真实数据集基准报告**：在公开图标库上统计平均压缩率

## 许可证

[MIT](./LICENSE)

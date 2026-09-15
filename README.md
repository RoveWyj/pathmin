# pathmin

用 MoonBit 编写的 **SVG `<path>` 解析与体积优化器**。

## 它是做什么的
解析 `<path d="...">` 的命令序列，做**无损精简**：
- 删除多余空格与逗号分隔符
- 数字去前导 `+`、去小数尾零（`10.0000` → `10`）
- 为后续扩展保留指令合并、冗余消除能力的结构

核心亮点：用 MoonBit 的 **ADT（`enum Token`）+ 模式匹配** 描述语法结构。

## 环境要求
- MoonBit CLI（https://www.moonbitlang.cn/download/）
- VSCode + MoonBit 插件（可选）

## 安装
```bash
moon version
```

## 构建 & 测试
```bash
moon check   # 静态检查
moon test    # 单元测试
```

## 运行
```bash
moon run cmd/main "M 100.000,200.000 L 300.0000,400.0000 Z"
moon run cmd/main    # 走内置示例
```

## 项目结构
```
idea/
├── moon.mod
├── moon.pkg
├── lib.mbt
├── lib_test.mbt
├── cmd/main/{moon.pkg, main.mbt}
└── README.md
```

## Roadmap
- 相邻同类型直线/顶点指令合并（`M` 后省略隐含 `L`）
- 二次/三次贝塞尔控制点无损合并
- 零长度段、冗余闭合点消除（可配置）
- 编译到 WASM 的在线演示页

## 许可证
MIT
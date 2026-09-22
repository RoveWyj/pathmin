test "optimize 压缩长度" {
  let r = optimize("M 10.000, 20.000 L 30.0000, 40.0000")
  if !(r.new_len < r.original_len) {
    fail("预期 new_len 小于 original_len")
  }
  let s = optimize_to_string("M 10.0000, 20.0000")
  if s.contains(".0000") {
    fail("预期去掉尾零: " + s)
  }
}

test "紧凑输入不再增大" {
  let s = optimize_to_string("M1,2 L3,4")
  if !s.has_prefix("M") {
    fail("预期以 M 开头: " + s)
  }
  if !(s.length() < "M1,2 L3,4".length()) {
    fail("紧凑输入不应被撑大: " + s + " (" + s.length().to_string() + ")")
  }
}

test "命令计数" {
  let counts = command_counts("M1,2 L3,4 L5,6 Z")
  if counts.length() != 3 {
    fail("预期 3 种命令")
  }
}

test "科学计数法不被破坏" {
  let s = optimize_to_string("M 1.5e10, 2.0e-3 L 3E5, 4")
  if !s.contains("1.5e10") {
    fail("指数不应被去尾零破坏: " + s)
  }
  if !s.contains("2e-3") {
    fail("尾数应精简但指数保留: " + s)
  }
  if !s.contains("3E5") {
    fail("大写 E 指数应保留: " + s)
  }
}

test "负数紧凑写法正确解析" {
  let s = optimize_to_string("M1.5-2.5 L3-4")
  if !s.contains("-2.5") {
    fail("负数应作为独立坐标: " + s)
  }
  if !(s.length() <= "M1.5-2.5L3-4".length()) {
    fail("紧凑写法不应被撑大: " + s)
  }
}

test "紧凑输出示例" {
  let s = optimize_to_string("M 100.000, 200.000 L 300.0000, 400.0000 Z")
  if s != "M100 200 300 400Z" {
    fail("预期 M100 200 300 400Z，实际: " + s)
  }
}

test "隐含命令省略：M 后连续坐标省略 L" {
  let s = optimize_to_string("M 10, 20 L 30, 40 L 50, 60 Z")
  if !s.has_prefix("M10 20 30 40 50 60Z") {
    fail("预期 M10 20 30 40 50 60Z，实际: " + s)
  }
}

test "隐含命令省略：M 后显式重复 L 组" {
  // L 组在一个 M 后可以被省略字母（SVG 规范允许）
  let s = optimize_to_string("M1,2 3,4 5,6Z")
  // 输入已隐含 L；输出应保持紧凑且语义不变
  if s.contains("L") || s.contains("l") {
    fail("不应出现 L: " + s)
  }
}

test "非 M 前缀的 L 不被错误省略" {
  let s = optimize_to_string("M1,2 Z L3,4")
  // Z 之后的 L 不能省略
  if !s.contains("L3") {
    fail("Z 后的 L 不可省略: " + s)
  }
}

test "连续同命令省略：C 组重复" {
  let s = optimize_to_string("M1,2 C3,4 5,6 7,8 C9,10 11,12 13,14 Z")
  // 期望 C 合并为一次，输出形如 M1 2C3 4 5 6 7 8 9 10 11 12 13 14Z
  if !s.has_prefix("M1 2C3") {
    fail("M 后 C 应输出一次，实际: " + s)
  }
  // 只应出现一次 C 字母
  let mut c_count = 0
  for ch in s {
    if ch == 'C' {
      c_count = c_count + 1
    }
  }
  if c_count != 1 {
    fail("连续 C 应合并为一次，实际: " + s + " (C 出现 " + c_count.to_string() + " 次)")
  }
}

/// round-trip：优化输出可被重新解析。
/// 验证每个命令的参数个数是该命令 arity 的整数倍（确保几何数据完整）。
fn roundtrip_ok(input : String) -> Bool {
  let out = optimize_to_string(input)
  let ts = tokens(out)
  let counts : Array[(UInt16, Int)] = []
  for t in ts {
    match t {
      Cmd(c) => counts.push((c, 0))
      Num(_) => {
        if counts.length() == 0 {
          return false
        }
        counts[counts.length() - 1] = (counts[counts.length() - 1].0, counts[counts.length() - 1].1 + 1)
      }
    }
  }
  for (c, n) in counts {
    let arity = command_arity(c)
    if arity > 0 && n % arity != 0 {
      return false
    }
  }
  true
}

test "round-trip：命令与参数可重解析" {
  let cases = [
    "M 10.000, 20.000 L 30.0000, 40.0000 L 0.0000, 0.0000 Z",
    "M 1.5e10, 2.0e-3 L 3E5, 4",
    "M1.5-2.5 L3-4",
    "M1,2 C3,4 5,6 7,8 C9,10 11,12 13,14 Z",
  ]
  for c in cases {
    if !roundtrip_ok(c) {
      fail("round-trip 失败: " + c)
    }
  }
}

test "round-trip：优化结果再次优化为空闲操作（幂等）" {
  let input = "M 100.000, 200.000 L 300.0000, 400.0000 Z"
  let once = optimize_to_string(input)
  let twice = optimize_to_string(once)
  if once != twice {
    fail("优化应幂等: " + once + " -> " + twice)
  }
}

test "边界：空输入与纯命令" {
  if optimize_to_string("").length() != 0 {
    fail("空输入应输出空")
  }
  let s = optimize_to_string("M0,0Z")
  if s != "M0 0Z" {
    fail("边界值: " + s)
  }
}

test "有损精度裁剪：截断到指定位数" {
  let r = optimize_precision("M 1.23456, 2.34567 L 3.00001, 4", 2)
  let s = r.minified
  if !s.contains("1.23") {
    fail("应截断到 2 位小数: " + s)
  }
  if s.contains("1.234") {
    fail("不应保留 3 位小数: " + s)
  }
}

test "有损精度裁剪：多位数与科学计数法不受影响" {
  let r = optimize_precision("M 1.23456e5, 2.5", 2)
  let s = r.minified
  if s.contains("1.23456") {
    fail("尾数应被截断: " + s)
  }
  if !s.contains("e5") {
    fail("指数应保留: " + s)
  }
}

test "冗余段消除：零长度 L 段被删除" {
  let s = remove_degenerate("M10 10 L10 10 L20 20 Z")
  if s != "M10 10 20 20Z" {
    fail("零长度段应被删除，实际: " + s)
  }
}

test "冗余段消除：重复闭合只保留一个" {
  let s = remove_degenerate("M0 0 L10 0 Z Z Z")
  if s != "M0 0 10 0Z" {
    fail("重复闭合应合并，实际: " + s)
  }
}

test "冗余段消除：非零长度段保留" {
  let s = remove_degenerate("M0 0 H10 V10 Z")
  if s != "M0 0H10V10Z" {
    fail("H/V 非零位移段应保留，实际: " + s)
  }
}

test "校验：合法与非法 path" {
  if !is_valid_path("M1,2 L3,4 Z") {
    fail("合法 path 应通过")
  }
  if is_valid_path("") {
    fail("空输入应非法")
  }
  if is_valid_path("1,2 M3,4") {
    fail("数字开头应非法")
  }
  if is_valid_path("M1,2 L3") {
    fail("参数不齐应非法（L 缺一个坐标）")
  }
}

test "统计：段数 / 点数 / 命令序列" {
  if segment_count("M1,2 L3,4 Z") != 3 {
    fail("段数应为 3")
  }
  if point_count("M1,2 L3,4") != 4 {
    fail("点数应为 4")
  }
  if commands("M1,2 L3,4 C5,6 7,8 9,10 11,12 Z") != "MLCZ" {
    fail("命令序列应 MLCZ，实际: " + commands("M1,2 L3,4 C5,6 7,8 9,10 11,12 Z"))
  }
}

test "无损自证：优化前后数字序列一致" {
  let cases = [
    "M 10.000, 20.000 L 30.0000, 40.0000 Z",
    "M 1.5e10, 2.0e-3 L 3E5, 4",
    "M1.5-2.5 L3-4",
  ]
  for c in cases {
    if !verify_lossless(c) {
      fail("应验证为无损: " + c)
    }
  }
}

test "展开隐含命令" {
  let s = expand_implicit("M10 20 30 40")
  if s != "M10 20L30 40" {
    fail("展开隐含 L 失败，实际: " + s)
  }
}

test "仅精简数字保留命令结构" {
  let s = minify_numbers_only("M 10.000, 20 L 30.0, 40")
  if s != "M10 20L30 40" {
    fail("仅精简数字失败，实际: " + s)
  }
}

test "按命令拆分" {
  let parts = split_commands("M1 2 L3 4 Z")
  if parts.length() != 3 {
    fail("应拆成 3 段")
  }
  if parts[0] != "M1 2" || parts[1] != "L3 4" || parts[2] != "Z" {
    fail("拆分内容不符: " + parts[0] + " | " + parts[1] + " | " + parts[2])
  }
}

test "命令位置索引" {
  let pos = command_positions("M1 2 L3 4")
  if pos.length() != 2 || pos[0].1 != 0 || pos[1].1 != 3 {
    fail("命令位置不符")
  }
}

test "按子路径拆分" {
  let sub = split_subpaths("M0 0 L10 0 Z M20 20 L30 20 Z")
  if sub.length() != 2 {
    fail("应拆成 2 个子路径，实际 " + sub.length().to_string())
  }
  if sub[0] != "M0 0 10 0Z" || sub[1] != "M20 20 30 20Z" {
    fail("子路径内容不符: " + sub[0] + " | " + sub[1])
  }
}

test "去重命令列表" {
  let cmds = unique_commands("M1 2 L3 4 L5 6 Z")
  if cmds.length() != 3 {
    fail("应 3 个不同命令")
  }
}

test "数字构成分类" {
  let r = number_classification("M1.5 2 3e5 -4.0")
  if r.0 != 1 || r.1 != 2 || r.2 != 1 {
    fail("数字分类不符: 整数=" + r.0.to_string() + " 小数=" + r.1.to_string() + " 指数=" + r.2.to_string())
  }
}

test "完整优化：先删冗余段再压缩" {
  let r = optimize_full("M10 10 L10 10 L20 20 Z")
  if r.minified != "M10 10 20 20Z" {
    fail("完整优化失败，实际: " + r.minified)
  }
}
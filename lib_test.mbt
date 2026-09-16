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
  // 期望 C 合并为一次，输出形如 M1 2 C3 4 5 6 7 8 9 10 11 12 13 14Z
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
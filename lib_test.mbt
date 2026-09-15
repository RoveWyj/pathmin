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

test "保留命令字母" {
  let s = optimize_to_string("M1,2 L3,4")
  if !s.has_prefix("M") {
    fail("预期以 M 开头: " + s)
  }
}

test "命令计数" {
  let counts = command_counts("M1,2 L3,4 L5,6 Z")
  if counts.length() != 3 {
    fail("预期 3 种命令")
  }
}
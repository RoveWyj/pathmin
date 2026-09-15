/// 基本 Token：命令字母 或 数字，用 ADT 表达。
/// 命令字母以 UTF-16 code unit（UInt16）保存，避免字符与字节混淆。
pub enum Token {
  Cmd(UInt16)
  Num(String) // 一个数字字面量
} derive(Debug)

/// 优化结果统计
pub struct OptimizeResult {
  minified: String
  original_len: Int
  new_len: Int
} derive(Debug)

/// 判断是否命令字母（SVG 命令均为 ASCII 字母）
fn is_cmd(c : UInt16) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

/// 判断是否数字字符（含符号、小数点、指数）
fn is_num_char(c : UInt16) -> Bool {
  (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '+' || c == 'e' || c == 'E'
}

/// 词法扫描：把 d 字符串切成 token 序列
pub fn tokens(d : String) -> Array[Token] {
  let arr : Array[Token] = []
  let mut i = 0
  let n = d.length()
  while i < n {
    let c = d.code_unit_at(i)
    if is_cmd(c) {
      arr.push(Cmd(c))
      i = i + 1
    } else if is_num_char(c) {
      let mut j = i
      while j < n && is_num_char(d.code_unit_at(j)) {
        j = j + 1
      }
      arr.push(Num(d[i:j].to_owned()))
      i = j
    } else {
      i = i + 1 // 忽略空格与逗号分隔符
    }
  }
  arr
}

/// 数字字面量无损精简：去前导 +，去小数尾零与末尾小数点
fn minify_num(s : String) -> String {
  let mut t = s
  if t.length() > 0 && t.code_unit_at(0) == '+' {
    t = t[1:].to_owned()
  }
  if t.contains(".") {
    while t.length() > 0 && t.code_unit_at(t.length() - 1) == '0' {
      t = t[:t.length() - 1].to_owned()
    }
    if t.has_suffix(".") {
      t = t[:t.length() - 1].to_owned()
    }
  }
  if t.length() == 0 || t == "-" || t == "." {
    t = "0"
  }
  t
}

/// 把命令 code unit 还原为字符字符串（SVG 均为 ASCII，安全）
fn cmd_to_string(c : UInt16) -> String {
  "\{c.unsafe_to_char()}"
}

/// 序列化：紧凑输出（每 token 一个空格，去掉逗号与多余空白）
fn serialize(a : Array[Token]) -> String {
  let mut out = ""
  for t in a {
    match t {
      Cmd(c) => out = out + " " + cmd_to_string(c)
      Num(s) => out = out + " " + minify_num(s)
    }
  }
  if out.has_prefix(" ") {
    out = out[1:].to_owned()
  }
  out
}

/// 统计各命令出现次数（演示 ADT + 模式匹配）
pub fn command_counts(d : String) -> Array[(UInt16, Int)] {
  let ts = tokens(d)
  let m : Array[(UInt16, Int)] = []
  for t in ts {
    match t {
      Cmd(c) => {
        let mut found = false
        for i = 0; i < m.length(); i = i + 1 {
          if m[i].0 == c {
            m[i] = (c, m[i].1 + 1)
            found = true
            break
          }
        }
        if !found {
          m.push((c, 1))
        }
      }
      _ => ()
    }
  }
  m
}

/// 对外入口：解析并优化 path
pub fn optimize(d : String) -> OptimizeResult {
  let ts = tokens(d)
  let out = serialize(ts)
  { minified: out, original_len: d.length(), new_len: out.length() }
}

/// 便捷：直接得到优化后的字符串
pub fn optimize_to_string(d : String) -> String {
  optimize(d).minified
}
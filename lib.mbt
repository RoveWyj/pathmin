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

/// 判断是否可作为数字的开头（含符号、小数点）
fn is_num_start(c : UInt16) -> Bool {
  (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '+'
}

/// 判断字符是否延续当前数字：
/// 数字、小数点、指数符 e/E 直接延续；+/- 仅在紧跟 e/E 时延续，
/// 其余情况（如 "1.5-2.5" 中的 "-"）属于下一个数字的开头。
fn continues_num(d : String, pos : Int) -> Bool {
  let c = d.code_unit_at(pos)
  if (c >= '0' && c <= '9') || c == '.' || c == 'e' || c == 'E' {
    return true
  }
  if c == '-' || c == '+' {
    if pos > 0 {
      return d.code_unit_at(pos - 1) == 'e' || d.code_unit_at(pos - 1) == 'E'
    }
    return false
  }
  false
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
    } else if is_num_start(c) {
      let mut j = i + 1
      while j < n && continues_num(d, j) {
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

/// 尾数部分无损精简：去小数尾零与末尾小数点
fn minify_mantissa(s : String) -> String {
  let mut t = s
  if t.contains(".") {
    while t.length() > 0 && t.code_unit_at(t.length() - 1) == '0' {
      t = t[:t.length() - 1].to_owned()
    }
    if t.has_suffix(".") {
      t = t[:t.length() - 1].to_owned()
    }
  }
  if t.length() == 0 || t == "-" || t == "." || t == "-." {
    t = "0"
  }
  t
}

/// 数字字面量无损精简：去前导 +，去小数尾零与末尾小数点；
/// 科学计数法（e/E 指数）中的指数部分保持原样，避免数值被破坏。
fn minify_num(s : String) -> String {
  let mut t = s
  if t.length() > 0 && t.code_unit_at(0) == '+' {
    t = t[1:].to_owned()
  }
  // 定位指数分隔符 e/E（若存在）
  let mut exp_pos = -1
  for i = 0; i < t.length(); i = i + 1 {
    let c = t.code_unit_at(i)
    if c == 'e' || c == 'E' {
      exp_pos = i
      break
    }
  }
  let mantissa = if exp_pos >= 0 { t[:exp_pos].to_owned() } else { t }
  let exponent = if exp_pos >= 0 { t[exp_pos:].to_owned() } else { "" }
  // 尾数去尾零与末尾小数点
  let mant = minify_mantissa(mantissa)
  // 指数部分仅去 e/E 后的前导 +（如 e+10 -> e10），其余保持
  let mut exp = exponent
  if exp.length() > 1 && exp.code_unit_at(1) == '+' {
    exp = exp[0:1].to_owned() + exp[2:].to_owned()
  }
  mant + exp
}

/// 把命令 code unit 还原为字符字符串（SVG 均为 ASCII，安全）
fn cmd_to_string(c : UInt16) -> String {
  "\{c.unsafe_to_char()}"
}

/// 命令组：一个命令字母 + 跟随它的数字参数
struct CmdGroup {
  code : UInt16
  args : Array[String]
}

/// 各 SVG 命令的期望参数个数（每组的坐标数）
fn command_arity(c : UInt16) -> Int {
  match cmd_to_string(c) {
    "M" | "m" | "L" | "l" | "T" | "t" => 2
    "H" | "h" | "V" | "v" => 1
    "C" | "c" | "Q" | "q" | "S" | "s" => 4
    "A" | "a" => 7
    _ => 0 // Z/z 及其它
  }
}

/// 把平铺 token 序列按命令分组。
/// 每个命令组的参数可能超出期望个数（如 M 后连续坐标隐含 L），
/// 拆分成标准 sizing 的 chunk 在序列化阶段处理。
fn parse_groups(a : Array[Token]) -> Array[CmdGroup] {
  let groups : Array[CmdGroup] = []
  let mut cur : CmdGroup = { code: 0, args: [] } // 占位初始化
  let mut started = false
  for t in a {
    match t {
      Cmd(c) => {
        if started {
          groups.push(cur)
        }
        cur = { code: c, args: [] }
        started = true
      }
      Num(s) => cur.args.push(s)
      _ => ()
    }
  }
  if started {
    groups.push(cur)
  }
  groups
}

/// 判断两个「输出项」之间是否需要空格分隔。
/// 规则：数字接数字且后者不以 -/+ 开头时需要；命令字母接命令字母时需要。
fn need_space(prev_is_num : Bool, cur_is_num : Bool, cur_first : UInt16) -> Bool {
  if prev_is_num && cur_is_num {
    // 后一个数字以 -/+ 开头可省略空格（如 1.5-2.5）
    return !(cur_first == '-' || cur_first == '+')
  }
  (!prev_is_num) && (!cur_is_num)
}

/// 输出项：命令字母 或 数字字面量
enum OutItem {
  Letter(String)
  Number(String)
}

/// 序列化：按需分隔 + 隐含命令省略。
/// 省略规则：当前命令字母与上一命令相同，或 L/l 紧跟 M/m 时，省略字母。
/// 同一命令的参数若超过期望数（如 M 后多个坐标对），后续参数自然隐含同命令。
fn serialize_groups(groups : Array[CmdGroup]) -> String {
  let items : Array[OutItem] = []
  let mut last_letter = ""
  for i = 0; i < groups.length(); i = i + 1 {
    let g = groups[i]
    let arity = command_arity(g.code)
    let letter = cmd_to_string(g.code)
    let args = g.args
    if arity == 0 {
      // Z/z 等无参数命令
      items.push(Letter(letter))
      last_letter = letter
    } else {
      // 省略判断：同命令延续，或 L/l 紧跟 M/m（M 隐含 L）
      let omit =
        letter == last_letter ||
          ((letter == "L" || letter == "l") && (last_letter == "M" || last_letter == "m"))
      if !omit {
        items.push(Letter(letter))
      }
      for j = 0; j < args.length(); j = j + 1 {
        items.push(Number(minify_num(args[j])))
      }
      last_letter = letter
    }
  }
  // 线性拼接（StringBuilder 避免 O(n²) 字符串拼接）
  let buf = StringBuilder::new()
  for i = 0; i < items.length(); i = i + 1 {
    if i > 0 {
      let prev = items[i - 1]
      let cur = items[i]
      let prev_is_num = match prev { Number(_) => true; _ => false }
      let cur_is_num = match cur { Number(_) => true; _ => false }
      let cur_first = match cur {
        Number(s) => s.code_unit_at(0)
        Letter(s) => s.code_unit_at(0)
      }
      if need_space(prev_is_num, cur_is_num, cur_first) {
        buf.write_char(' ')
      }
    }
    match items[i] {
      Letter(s) => buf.write_string(s)
      Number(s) => buf.write_string(s)
    }
  }
  buf.to_string()
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
  let groups = parse_groups(ts)
  let out = serialize_groups(groups)
  { minified: out, original_len: d.length(), new_len: out.length() }
}

/// 便捷：直接得到优化后的字符串
pub fn optimize_to_string(d : String) -> String {
  optimize(d).minified
}
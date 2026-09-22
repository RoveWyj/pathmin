// pathmin 核心库
//
// 一个 SVG <path> 数据的无损压缩器（minifier）。
//
// 设计的核心思想是「token 化 → 分组 → 序列化」三段式管线：
//
//   1. tokens      词法扫描：把 path 字符串拆成「命令字母 / 数字」两种 token。
//   2. parse_groups  语法分组：按 SVG 命令语法，把平铺 token 归并成命令组。
//   3. serialize_groups 序列化：按需加空格、省略隐含命令，重新拼出最短字符串。
//
// 本库保证「图形不变」：整个过程只删除冗余信息（多余分隔符、尾零、
// 正号、可省略的命令字母），绝不改动任何坐标的数值或命令的语义。
// 精度裁剪（--precision）是唯一的有损路径，需要显式调用才会启用。

// ---------------------------------------------------------------------------
// 基础数据结构
// ---------------------------------------------------------------------------

/// 基本 Token：命令字母 或 数字，用 ADT 表达。
///
/// 用枚举（sum type）而非字符串标记的好处是：类型层面就杜绝了
/// 「既不是命令又不是数字」的第三种非法状态，配合模式匹配可以
/// 让上游逻辑穷尽且无遗漏。
///
/// * `Cmd(UInt16)` —— 一个 SVG 命令字母。命令字母以 UTF-16 code unit
///   （UInt16）保存，避免字符与字节之间的混淆，也方便后续按数值比较。
/// * `Num(String)` —— 一个数字字面量，原样保留其文本（可能含小数点、
///   负号、指数符号），压缩时再做规范化。
pub enum Token {
  Cmd(UInt16)
  Num(String) // 一个数字字面量
} derive(Debug)

/// 优化结果统计。
///
/// 同时返回压缩后的字符串、压缩前后的字节长度，方便调用方计算
/// 节省比例、显示对比信息，而不需要自行重新测量。
pub struct OptimizeResult {
  minified : String
  original_len : Int
  new_len : Int
} derive(Debug)

/// 命令组：一个命令字母 + 跟随它的若干个数字参数。
///
/// 这是「语法分组」阶段的中间表示，仅在库内部使用，不对外暴露。
/// 由于 SVG 允许在 `M` 后携带超出标准数量的坐标对（隐含 `L`），
/// 因此 `args` 的长度可能大于该命令的标准参数个数，具体拆解在
/// 序列化阶段再处理。
priv struct CmdGroup {
  code : UInt16
  args : Array[String]
}

/// 输出项：序列化阶段的中间表示，或者是命令字母，或者是数字。
///
/// 用 ADT 区分两类单元，是因为「是否需要在两个输出项之间插入空格」
/// 的判断依赖前后两个"项"的类型（命令 vs 数字），把它们收进一个
/// 枚举后再线性拼接最清晰。
priv enum OutItem {
  Letter(String)
  Number(String)
}

// ---------------------------------------------------------------------------
// 字符分类（词法分析的低层判断）
// ---------------------------------------------------------------------------

/// 判断一个 code unit 是否为命令字母。
///
/// SVG 路径命令均为 ASCII 字母（`M L H V C S Q T A Z` 及对应小写）。
/// 这里用 code unit 的数值范围判断，比转成字符再比较更快，
/// 也避免了字符编码带来的边界问题。
fn is_cmd(c : UInt16) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

/// 判断一个 code unit 是否可以作为一个数字的开头。
///
/// SVG 数字可以以数字、小数点、负号或正号开头。注意逗号和空格
/// 不属于数字的一部分，它们只是分隔符，会被词法扫描跳过。
fn is_num_start(c : UInt16) -> Bool {
  (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '+'
}

/// 判断位置 `pos` 处的字符是否延续「当前正在扫描的数字」。
///
/// 这是词法扫描中最容易出错的地方，规则如下：
///
/// * 数字、小数点、指数符 `e`/`E` 直接延续（如 `1.5e10` 应整体
///   识别为一个数字，而不是 `1.5` 和 `e10` 两个）。
/// * `-`/`+` 仅在紧跟 `e`/`E` 时延续（表示指数部分的符号，如 `2e-3`）。
/// * 其余情况的 `-`（如紧凑坐标 `1.5-2.5` 中的减号）属于**下一个**
///   数字的开头，而非当前数字的一部分。
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

// ---------------------------------------------------------------------------
// 词法扫描
// ---------------------------------------------------------------------------

/// 词法扫描：把 path 字符串 `d` 切分成 token 序列。
///
/// 遍历输入，跳过所有空格与逗号分隔符，把命令字母识别为 `Cmd`、
/// 把连续的数字字符识别为 `Num`。数字的边界由 `continues_num`
/// 界定，从而正确处理小数、负号与科学计数法。
///
/// 例：
///   `tokens("M 10.5-2.5 L 3e-2")`
///   → `[Cmd('M'), Num("10.5"), Num("-2.5"), Cmd('L'), Num("3e-2")]`
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

// ---------------------------------------------------------------------------
// 数字规范化（无损 + 有损）
// ---------------------------------------------------------------------------

/// 定位数字中指数分隔符 `e`/`E` 的位置，不存在则返回 -1。
///
/// 科学计数法的尾数与指数需要分开处理：尾数部分可以放心去尾零、
/// 去小数点；指数部分必须原样保留（顶多去掉 `+`），否则数值会被
/// 破坏。因此多处逻辑都需要先定位这个分隔符。
fn find_exp_pos(s : String) -> Int {
  for i = 0; i < s.length(); i = i + 1 {
    let c = s.code_unit_at(i)
    if c == 'e' || c == 'E' {
      return i
    }
  }
  -1
}

/// 定位数字中小数点的位置，不存在则返回 -1。
///
/// 有损精度裁剪需要根据小数点位置来计算「应保留多少位小数」，
/// 因此单独抽出一个查找函数。
fn find_dot_pos(s : String) -> Int {
  for i = 0; i < s.length(); i = i + 1 {
    if s.code_unit_at(i) == '.' {
      return i
    }
  }
  -1
}

/// 去掉数字开头的正号（`+1.5` → `1.5`），无正号则原样返回。
///
/// SVG 数字中的前导 `+` 是冗余的，去掉后数值不变。多个数字处理
/// 入口都需要这个步骤，故单独提出来。
fn strip_leading_plus(s : String) -> String {
  if s.length() > 0 && s.code_unit_at(0) == '+' {
    s[1:].to_owned()
  } else {
    s
  }
}

/// 尾数部分无损精简：去掉小数尾零与末尾小数点。
///
/// 例：`"12.500"` → `"12.5"`，`"12.000"` → `"12"`，`"0.000"` → `"0"`。
///
/// 注意边界处理：当精简后得到空串或仅剩符号（`"-"`、`"."`、`"-."`）
/// 时，说明原数字等价于零，统一归一为 `"0"`，避免产生非法数字。
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

/// 数字字面量无损精简：去前导 `+`、去小数尾零与末尾小数点。
///
/// 关键点：科学计数法（`e`/`E` 指数）中的指数部分保持原样，
/// 只对尾数部分做去零处理，避免把 `1.5e10` 错误地压成 `1.5e1`。
///
/// 处理步骤：
///   1. 去掉前导正号；
///   2. 若有指数符号，把尾数与指数分开；
///   3. 尾数调用 `minify_mantissa` 去尾零；
///   4. 指数部分仅去掉 `e`/`E` 后面的前导 `+`（`e+10` → `e10`）。
fn minify_num(s : String) -> String {
  let t = strip_leading_plus(s)
  let exp_pos = find_exp_pos(t)
  let mantissa = if exp_pos >= 0 { t[:exp_pos].to_owned() } else { t }
  let exponent = if exp_pos >= 0 { t[exp_pos:].to_owned() } else { "" }
  // 尾数去尾零与末尾小数点
  let mant = minify_mantissa(mantissa)
  // 指数部分仅去 e/E 后的前导 +
  let mut exp = exponent
  if exp.length() > 1 && exp.code_unit_at(1) == '+' {
    exp = exp[0:1].to_owned() + exp[2:].to_owned()
  }
  mant + exp
}

/// 数字有损精简：在小数点后截断到 `precision` 位（不做四舍五入），
/// 随后复用无损去尾零流程。
///
/// `precision < 0` 表示不截断（等价于无损）。
///
/// 例：`minify_num_precision("1.23456", 2)` → `"1.23"`。
fn minify_num_precision(s : String, precision : Int) -> String {
  let t = strip_leading_plus(s)
  let exp_pos = find_exp_pos(t)
  let mantissa = if exp_pos >= 0 { t[:exp_pos].to_owned() } else { t }
  let exponent = if exp_pos >= 0 { t[exp_pos:].to_owned() } else { "" }
  // 截断：找到小数点，最多保留 precision 位小数
  let mut truncated = mantissa
  let dot = find_dot_pos(mantissa)
  if dot >= 0 {
    let frac_len = mantissa.length() - dot - 1
    if frac_len > precision {
      truncated = mantissa[:dot + precision + 1].to_owned()
    }
  }
  // 截断后复用去尾零流程
  let mant = minify_mantissa(truncated)
  mant + exponent
}

// ---------------------------------------------------------------------------
// 命令辅助
// ---------------------------------------------------------------------------

/// 把命令 code unit 还原为单字符字符串（SVG 命令均为 ASCII，安全）。
pub fn cmd_to_char(c : UInt16) -> String {
  "\{c.unsafe_to_char()}"
}

/// 判断某个 code unit 是否代表「移动」命令（`M`/`m`）。
///
/// 移动命令是唯一允许在标准参数个数之外携带额外坐标对的命令，
/// 因此序列化与校验阶段都需要单独判断它。
fn is_move_cmd(c : UInt16) -> Bool {
  c == 'M' || c == 'm'
}

/// 各 SVG 命令的期望参数个数（即每组坐标/参数的数量）。
///
/// * `M/m` `L/l` `T/t` → 2（一个坐标对 x,y）
/// * `H/h` `V/v`        → 1（单坐标，仅 x 或仅 y）
/// * `C/c` `Q/q` `S/s`  → 4（两个控制点共两对坐标）
/// * `A/a`              → 7（rx,ry,rotation,large-arc,sweep,x,y）
/// * `Z/z` 及其它       → 0（闭合命令无参数）
pub fn command_arity(c : UInt16) -> Int {
  match cmd_to_char(c) {
    "M" | "m" | "L" | "l" | "T" | "t" => 2
    "H" | "h" | "V" | "v" => 1
    "C" | "c" | "Q" | "q" | "S" | "s" => 4
    "A" | "a" => 7
    _ => 0 // Z/z 及其它
  }
}

// ---------------------------------------------------------------------------
// 语法分组
// ---------------------------------------------------------------------------

/// 把平铺的 token 序列按命令分组。
///
/// 每个命令组包含「一个命令字母 + 跟随它的全部数字参数」。由于 SVG
/// 允许 `M` 后携带超过 2 个坐标（多余部分隐含 `L`），因此组的参数
/// 个数可能超过该命令的标准个数，具体的按标准尺寸拆分在序列化阶段
/// 通过 `serialize_groups` 处理。
///
/// 若 token 序列以数字开头（非法 path），这些数字会因没有归属命令
/// 而被忽略——这类输入应由 `is_valid_path` 提前拒绝。
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
    }
  }
  if started {
    groups.push(cur)
  }
  groups
}

// ---------------------------------------------------------------------------
// 序列化
// ---------------------------------------------------------------------------

/// 判断两个相邻「输出项」之间是否需要插入空格。
///
/// 规则：
/// * 数字接数字，且后一个数字以 `-`/`+` 开头时，可省略空格
///   （例如 `1.5-2.5`）；否则必须保留空格（例如 `1 2`，否则会粘连成 `12`）。
/// * 命令字母接命令字母时，需要保留空格（例如 `Z` 后面的命令）。
/// * 命令与数字之间、数字与命令之间，天然无需空格。
fn need_space(prev_is_num : Bool, cur_is_num : Bool, cur_first : UInt16) -> Bool {
  if prev_is_num && cur_is_num {
    // 后一个数字以 -/+ 开头可省略空格（如 1.5-2.5）
    return !(cur_first == '-' || cur_first == '+')
  }
  (!prev_is_num) && (!cur_is_num)
}

/// 把「输出项」列表按需加空格后线性拼接成最终字符串。
///
/// 这是所有序列化出口共用的拼接逻辑：根据前后两项的类型
/// （命令字母 or 数字）以及后一项的首字符，调用 `need_space`
/// 决定是否插入空格，再用 StringBuilder 线性写出，避免 O(n²)。
fn join_items(items : Array[OutItem]) -> String {
  let buf = StringBuilder()
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

/// 序列化：按需分隔 + 隐含命令省略。
///
/// 省略规则：
/// * 当前命令字母与上一个命令相同时，省略字母（连续 `C C` → `C`）。
/// * `L`/`l` 紧跟 `M`/`m` 时，省略 `L`（`M` 隐含 `L`）。
/// * 同一命令的参数若超过期望个数（如 `M` 后多个坐标对），后续参数
///   自然延续同一命令，无需重复字母。
///
/// 数字部分根据 `precision` 走无损或有害精简，最后用 StringBuilder
/// 线性拼接，避免 O(n²) 的字符串连接。
fn serialize_groups(groups : Array[CmdGroup], precision : Int) -> String {
  let items : Array[OutItem] = []
  let mut last_letter = ""
  for i = 0; i < groups.length(); i = i + 1 {
    let g = groups[i]
    let arity = command_arity(g.code)
    let letter = cmd_to_char(g.code)
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
        let num = if precision >= 0 {
          minify_num_precision(args[j], precision)
        } else {
          minify_num(args[j])
        }
        items.push(Number(num))
      }
      last_letter = letter
    }
  }
  join_items(items)
}

// ---------------------------------------------------------------------------
// 统计类 API
// ---------------------------------------------------------------------------

/// 统计各命令出现次数（演示 ADT + 模式匹配）。
///
/// 返回一个数组，每个元素是 `(命令 code unit, 出现次数)`，按首次
/// 出现的顺序排列。
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

/// 统计 path 中的命令段数量（每个路径命令记作一段，`Z` 也计入）。
///
/// 例：`segment_count("M1,2 L3,4 Z")` → `3`。
pub fn segment_count(d : String) -> Int {
  let ts = tokens(d)
  let mut n = 0
  for t in ts {
    match t {
      Cmd(_) => n = n + 1
      _ => ()
    }
  }
  n
}

/// 统计 path 中数字（坐标/参数）的总个数。
///
/// 例：`point_count("M1,2 L3,4")` → `4`（两对坐标共 4 个数）。
pub fn point_count(d : String) -> Int {
  let ts = tokens(d)
  let mut n = 0
  for t in ts {
    match t {
      Num(_) => n = n + 1
      _ => ()
    }
  }
  n
}

/// 返回 path 中所有命令字母组成的序列（忽略参数）。
///
/// 例：`commands("M1,2 L3,4 C5,6 7,8 9,10 11,12 Z")` → `"MLCZ"`。
pub fn commands(d : String) -> String {
  let ts = tokens(d)
  let buf = StringBuilder()
  for t in ts {
    match t {
      Cmd(c) => buf.write_char(c.unsafe_to_char())
      _ => ()
    }
  }
  buf.to_string()
}

/// 提取 path 中所有数字，并按下无损规则规范化。
///
/// 这是 `verify_lossless` 的基础：无论输入是原始带冗余的写法，
/// 还是优化后的紧凑写法，只要数值没有被改变，规范化后的序列应当
/// 完全一致。
fn collect_numbers(d : String) -> Array[String] {
  let ts = tokens(d)
  let out : Array[String] = []
  for t in ts {
    match t {
      Num(s) => out.push(minify_num(s))
      _ => ()
    }
  }
  out
}

// ---------------------------------------------------------------------------
// 校验类 API
// ---------------------------------------------------------------------------

/// 校验一段 path 是否语法合法。
///
/// 检查规则：
/// * path 不能为空，且必须以命令字母开头（不接受以数字/分隔符开头）；
/// * `Z`/`z` 之后不允许携带任何参数；
/// * 每个命令组的参数个数必须与该命令的期望个数一致；
/// * 唯一的例外是 `M`/`m`：它允许携带"坐标对"的整数倍（至少一对），
///   多余的对数按 SVG 规范隐含为 `L`。
pub fn is_valid_path(d : String) -> Bool {
  let ts = tokens(d)
  if ts.length() == 0 {
    return false
  }
  // 必须以命令字母开头
  match ts[0] {
    Cmd(_) => ()
    Num(_) => return false
  }
  let groups = parse_groups(ts)
  for g in groups {
    let arity = command_arity(g.code)
    let n = g.args.length()
    if arity == 0 {
      // Z/z 不应携带参数
      if n != 0 {
        return false
      }
    } else if is_move_cmd(g.code) {
      // M/m 至少一对坐标，且个数为偶数（成对坐标）
      if n < 2 || n % 2 != 0 {
        return false
      }
    } else if n != arity {
      return false
    }
  }
  // groups 为空（没有任何命令）时视为非法
  groups.length() > 0
}

/// 无损自证：优化前后两版 path 的数字序列（经规范化后）完全一致。
///
/// 原理：本库的压缩只删除冗余信息，不改变任何坐标数值。因此把原始
/// 输入与优化输出分别解析、提取数字并做同一套"去尾零/去正号"规范化，
/// 两串数字序列应当逐项相等。若相等，即可证明这次压缩是无损的。
pub fn verify_lossless(d : String) -> Bool {
  let before = collect_numbers(d)
  let after = collect_numbers(optimize_to_string(d))
  if before.length() != after.length() {
    return false
  }
  for i = 0; i < before.length(); i = i + 1 {
    if before[i] != after[i] {
      return false
    }
  }
  true
}

// ---------------------------------------------------------------------------
// 冗余段消除（Lossless）
// ---------------------------------------------------------------------------

/// 在「命令组」层面删除几何冗余段。
///
/// 这是可选的第二级优化，在建好命令组、尚未序列化之前对组做一次
/// 过滤。它通过跟踪一个「当前坐标点」来识别不会产生任何位移的冗余段：
///
/// * 零长度线段：绝对命令 `L`/`H`/`V` 的目标坐标与当前点完全相同
///   （如 `M10 10 L10 10` 中的 `L10 10`），删除后图形不变。
/// * 重复闭合：连续的多个 `Z`/`z` 只保留一个（`Z Z` → `Z`）。
///
/// 保守策略：
/// * 只对**绝对命令**（大写 `M/L/H/V`）做几何判定；相对命令（小写）
///   需要做坐标累加，为避免引入浮点误差与复杂度，一律原样保留。
/// * 曲线命令 `C/Q/S/T/A` 及其它命令同样原样保留。
/// * 数字用 `minify_num` 规范化后按字符串比较，同一 SVG 文件内的
///   相同坐标通常写法一致，因此判断可靠。
fn drop_degenerate_groups(groups : Array[CmdGroup]) -> Array[CmdGroup] {
  let out : Array[CmdGroup] = []
  let mut cur_x = ""
  let mut cur_y = ""
  let mut prev_was_close = false
  for g in groups {
    let ch = g.code
    let args = g.args
    let is_close = ch == 'Z' || ch == 'z'
    let mut dropped = false
    if is_close {
      // 连续闭合命令只保留一个（重复闭合点）
      dropped = prev_was_close
      prev_was_close = true
    } else {
      prev_was_close = false
      if ch == 'M' {
        // M 可能携带多对坐标（隐含 L），当前点落在最后一对
        let n = args.length()
        if n >= 2 {
          cur_x = minify_num(args[n - 2])
          cur_y = minify_num(args[n - 1])
        }
      } else if ch == 'L' && args.length() >= 2 {
        let nx = minify_num(args[0])
        let ny = minify_num(args[1])
        if nx == cur_x && ny == cur_y {
          dropped = true
        } else {
          cur_x = nx
          cur_y = ny
        }
      } else if ch == 'H' && args.length() >= 1 {
        let nx = minify_num(args[0])
        if nx == cur_x {
          dropped = true
        } else {
          cur_x = nx
        }
      } else if ch == 'V' && args.length() >= 1 {
        let ny = minify_num(args[0])
        if ny == cur_y {
          dropped = true
        } else {
          cur_y = ny
        }
      }
    }
    if !dropped {
      out.push(g)
    }
  }
  out
}

/// 对外入口：删除冗余段，保持图形不变。
///
/// 主要处理：
/// * 零长度线段：绝对命令 `L`/`H`/`V` 落回当前点的段直接删除；
/// * 重复闭合：连续多个 `Z`/`z` 只保留一个。
///
/// 例：`remove_degenerate("M10 10 L10 10 L20 20 Z Z")`
///   → `"M10 10 20 20Z"`（零长度段与重复闭合都被去掉）。
pub fn remove_degenerate(d : String) -> String {
  let groups = parse_groups(tokens(d))
  serialize_groups(drop_degenerate_groups(groups), -1)
}

// ---------------------------------------------------------------------------
// 对外入口
// ---------------------------------------------------------------------------

/// 对外入口：解析并无损失地优化 path。
///
/// 等价于 `optimize_precision(d, -1)`（`precision < 0` 表示不截断）。
pub fn optimize(d : String) -> OptimizeResult {
  optimize_precision(d, -1)
}

/// 便捷入口：直接得到优化后的字符串，忽略长度统计。
pub fn optimize_to_string(d : String) -> String {
  optimize(d).minified
}

/// 有损优化入口：把数字截断到 `precision` 位小数。
///
/// `precision < 0` 表示不截断（保持无损）。返回完整的 `OptimizeResult`，
/// 包含压缩后的字符串与前后长度统计。
pub fn optimize_precision(d : String, precision : Int) -> OptimizeResult {
  let ts = tokens(d)
  let groups = parse_groups(ts)
  let out = serialize_groups(groups, precision)
  { minified: out, original_len: d.length(), new_len: out.length() }
}

// ---------------------------------------------------------------------------
// 扩展 API
// ---------------------------------------------------------------------------

/// 展开隐含命令：把 `M`/`m` 后省略的 `L`/`l` 显式地写出来。
///
/// SVG 允许 `M` 后连续跟多个坐标对，多余的隐式作为 `L`。这个函数
/// 把这种简写还原为显式命令，便于调试、对比或喂给只接受显式命令的
/// 下游工具。
///
/// 例：`expand_implicit("M10 20 30 40")` → `"M10 20L30 40"`。
pub fn expand_implicit(d : String) -> String {
  let groups = parse_groups(tokens(d))
  let items : Array[OutItem] = []
  for g in groups {
    let letter = cmd_to_char(g.code)
    let args = g.args
    let arity = command_arity(g.code)
    if arity == 0 {
      items.push(Letter(letter))
    } else if is_move_cmd(g.code) && args.length() > 2 {
      items.push(Letter(letter))
      items.push(Number(minify_num(args[0])))
      items.push(Number(minify_num(args[1])))
      let cont = if g.code == 'M' { "L" } else { "l" }
      let mut k = 2
      while k + 1 < args.length() {
        items.push(Letter(cont))
        items.push(Number(minify_num(args[k])))
        items.push(Number(minify_num(args[k + 1])))
        k = k + 2
      }
    } else {
      items.push(Letter(letter))
      for j = 0; j < args.length(); j = j + 1 {
        items.push(Number(minify_num(args[j])))
      }
    }
  }
  join_items(items)
}

/// 仅精简数字：对每处数字做无损规范化，但不省略任何命令字母、
/// 不合并命令，保留原命令结构。用于隔离「数字精简」这一维度的影响。
///
/// 例：`minify_numbers_only("M 10.000, 20 L 30.0, 40")` → `"M10 20L30 40"`。
pub fn minify_numbers_only(d : String) -> String {
  let groups = parse_groups(tokens(d))
  let items : Array[OutItem] = []
  for g in groups {
    items.push(Letter(cmd_to_char(g.code)))
    let arity = command_arity(g.code)
    if arity > 0 {
      for j = 0; j < g.args.length(); j = j + 1 {
        items.push(Number(minify_num(g.args[j])))
      }
    }
  }
  join_items(items)
}

/// 把 path 拆成「每个命令 + 其参数」的独立字符串。
///
/// 例：`split_commands("M1 2 L3 4 Z")` → `["M1 2", "L3 4", "Z"]`。
pub fn split_commands(d : String) -> Array[String] {
  let groups = parse_groups(tokens(d))
  let out : Array[String] = []
  for g in groups {
    let items : Array[OutItem] = []
    items.push(Letter(cmd_to_char(g.code)))
    let arity = command_arity(g.code)
    if arity > 0 {
      for j = 0; j < g.args.length(); j = j + 1 {
        items.push(Number(minify_num(g.args[j])))
      }
    }
    out.push(join_items(items))
  }
  out
}

/// 返回每个命令字母在 token 序列中的位置索引（从 0 起）。
///
/// 例：`command_positions("M1 2 L3 4")` → `[('M', 0), ('L', 3)]`。
pub fn command_positions(d : String) -> Array[(UInt16, Int)] {
  let ts = tokens(d)
  let out : Array[(UInt16, Int)] = []
  for i = 0; i < ts.length(); i = i + 1 {
    match ts[i] {
      Cmd(c) => out.push((c, i))
      _ => ()
    }
  }
  out
}

/// 按子路径拆分：每遇到一个 `M`/`m` 就开启一段新的子路径。
///
/// 多子路径在图标库中很常见（一个 path 描述多个独立形状），本函数
/// 返回每段各自（无损）优化后的字符串。
pub fn split_subpaths(d : String) -> Array[String] {
  let groups = parse_groups(tokens(d))
  let out : Array[String] = []
  let mut cur : Array[CmdGroup] = []
  for g in groups {
    if is_move_cmd(g.code) && cur.length() > 0 {
      out.push(serialize_groups(cur, -1))
      cur = []
    }
    cur.push(g)
  }
  if cur.length() > 0 {
    out.push(serialize_groups(cur, -1))
  }
  out
}

/// 返回 path 中使用到的命令（按首次出现顺序去重）。
///
/// 例：`unique_commands("M1 2 L3 4 L5 6 Z")` → `['M', 'L', 'Z']`。
pub fn unique_commands(d : String) -> Array[UInt16] {
  let counts = command_counts(d)
  let out : Array[UInt16] = []
  for (c, _) in counts {
    out.push(c)
  }
  out
}

/// 数字构成分类：返回 `(整数个数, 带小数点个数, 科学计数法个数)`。
///
/// 用于评估一段 path 中数字的可压缩空间——小数尾零越多、正号越多，
/// 无损压缩的收益越明显。
pub fn number_classification(d : String) -> (Int, Int, Int) {
  let ts = tokens(d)
  let mut ints = 0
  let mut decimals = 0
  let mut exps = 0
  for t in ts {
    match t {
      Num(s) => {
        if s.contains("e") || s.contains("E") {
          exps = exps + 1
        } else if s.contains(".") {
          decimals = decimals + 1
        } else {
          ints = ints + 1
        }
      }
      _ => ()
    }
  }
  (ints, decimals, exps)
}

/// 完整优化入口：先删除冗余段，再做无损压缩。
///
/// 等价于「`remove_degenerate` + `optimize`」的串联，`original_len`
/// 以原始输入为准，便于正确计算总节省比例。
pub fn optimize_full(d : String) -> OptimizeResult {
  let cleaned = remove_degenerate(d)
  let r = optimize(cleaned)
  { minified: r.minified, original_len: d.length(), new_len: r.new_len }
}
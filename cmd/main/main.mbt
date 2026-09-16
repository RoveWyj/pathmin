fn main {
  let argv = @env.args()
  // argv[0]=程序名，argv[1..]为参数
  let args = argv[1:]
  if args.length() == 0 {
    run_example()
  } else {
    match args[0] {
      "--help" | "-h" => print_help()
      "--stats" => {
        // 统计模式：对每个后续参数打印命令分布
        for i = 1; i < args.length(); i = i + 1 {
          println("== \{args[i]} ==")
          let counts = @lib.command_counts(args[i])
          for (c, n) in counts {
            println("  \{@lib.cmd_to_char(c)} : \{n}")
          }
        }
      }
      "--precision" => {
        // 有损精度模式：--precision N "<path d>"
        if args.length() >= 3 {
          let n = try {
            @string.parse_int(args[1][:])
          } catch {
            _ => 0
          }
          optimize_and_print_precision(args[2], n)
        } else {
          println("用法: --precision <N> \"<path d>\"  (N 为保留的小数位数)")
        }
      }
      "--version" | "-v" => println("pathmin 0.1.0")
      "--bench" => run_bench()
      _ => optimize_and_print(args[0])
    }
  }
}

fn run_example() -> Unit {
  let input = "M 100.000, 200.000 L 300.0000, 400.0000 L 0.0000, 0.0000 Z"
  optimize_and_print(input)
}

fn optimize_and_print(input : String) -> Unit {
  let r = @lib.optimize(input)
  let saved = 100 * (r.original_len - r.new_len) / r.original_len
  println("input    : \{input}")
  println("minified : \{r.minified}")
  println("bytes    : \{r.original_len} -> \{r.new_len}  (saved \{saved}%)")
}

fn optimize_and_print_precision(input : String, n : Int) -> Unit {
  let r = @lib.optimize_precision(input, n)
  let saved = 100 * (r.original_len - r.new_len) / r.original_len
  println("input    : \{input}")
  println("minified : \{r.minified}  (precision=\{n})")
  println("bytes    : \{r.original_len} -> \{r.new_len}  (saved \{saved}%)")
}

/// 基准：内置常见矢量形状（圆/星/心/箭头/地图路径等），统计平均压缩率
fn run_bench() -> Unit {
  let dataset = [
    ("circle", "M 24.000, 12.000 C 24.000, 5.373 18.627, 0.000 12.000, 0.000 C 5.373, 0.000 0.000, 5.373 0.000, 12.000 C 0.000, 18.627 5.373, 24.000 12.000, 24.000 C 18.627, 24.000 24.000, 18.627 24.000, 12.000 Z"),
    ("star", "M 12.000, 0.000 L 14.900, 8.300 L 23.700, 8.300 L 16.400, 13.400 L 19.300, 21.700 L 12.000, 16.600 L 4.700, 21.700 L 7.600, 13.400 L 0.300, 8.300 L 9.100, 8.300 Z"),
    ("heart", "M 12.000, 21.724 L 0.000, 9.724 C -3.000, 6.724 3.000, -1.000 6.000, 2.000 L 7.000, 3.000 L 12.000, 8.000 L 17.000, 3.000 L 18.000, 2.000 C 21.000, -1.000 27.000, 6.724 24.000, 9.724 Z"),
    ("arrow", "M 2.000, 12.000 L 22.000, 12.000 M 12.000, 2.000 L 22.000, 12.000 L 12.000, 22.000"),
    ("polyline", "M 1.000, 1.000 L 5.000, 4.000 L 9.000, 2.000 L 13.000, 7.000 L 17.000, 5.000 L 21.000, 9.000 L 23.000, 9.000"),
    ("rounded-rect", "M 4.000, 0.000 L 20.000, 0.000 C 22.209, 0.000 24.000, 1.791 24.000, 4.000 L 24.000, 20.000 C 24.000, 22.209 22.209, 24.000 20.000, 24.000 L 4.000, 24.000 C 1.791, 24.000 0.000, 22.209 0.000, 20.000 L 0.000, 4.000 C 0.000, 1.791 1.791, 0.000 4.000, 0.000 Z"),
    ("curve", "M 1.500, 20.000 C 8.000, 2.000 16.000, 2.000 22.500, 20.000"),
    ("spline-map", "M 2.000, 18.000 C 2.000, 10.000 6.000, 4.000 10.000, 4.000 C 14.000, 4.000 16.000, 8.000 20.000, 8.000 C 22.000, 8.000 24.000, 6.000 24.000, 4.000"),
  ]
  println("pathmin benchmark：常见矢量形状无损压缩")
  println("")
  println("\{pad("名", 14)}\{pad("原始", 8)}\{pad("优化后", 8)}  节省")
  println("------------------------------------------")
  let mut total_orig = 0
  let mut total_new = 0
  for (name, d) in dataset {
    let r = @lib.optimize(d)
    total_orig = total_orig + r.original_len
    total_new = total_new + r.new_len
    let saved = 100 * (r.original_len - r.new_len) / r.original_len
    println("\{pad(name, 14)}\{pad_num(r.original_len, 7)}\{pad_num(r.new_len, 7)}  \{saved}%")
  }
  let avg_saved = 100 * (total_orig - total_new) / total_orig
  println("------------------------------------------")
  println("\{pad("合计", 14)}\{pad_num(total_orig, 7)}\{pad_num(total_new, 7)}  \{avg_saved}%")
}

fn pad(s : String, w : Int) -> String {
  let mut out = s
  while out.length() < w {
    out = out + " "
  }
  out
}

fn pad_num(n : Int, w : Int) -> String {
  let mut out = n.to_string()
  while out.length() < w {
    out = " " + out
  }
  out
}

fn print_help() -> Unit {
  println("pathmin - SVG path 无损压缩器 (MoonBit)")
  println("")
  println("用法:")
  println("  moon run cmd/main                        使用内置示例")
  println("  moon run cmd/main \"<path d>\"            压缩一段 path")
  println("  moon run cmd/main --stats \"<path d>\"...  统计命令出现次数")
  println("  moon run cmd/main --precision <N> \"<path d>\"  有损模式：保留 N 位小数")
  println("  moon run cmd/main --bench                 内置数据集平均压缩率")
  println("  moon run cmd/main --help                 显示本帮助")
  println("  moon run cmd/main --version              显示版本")
}
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

fn print_help() -> Unit {
  println("pathmin - SVG path 无损压缩器 (MoonBit)")
  println("")
  println("用法:")
  println("  moon run cmd/main                        使用内置示例")
  println("  moon run cmd/main \"<path d>\"            压缩一段 path")
  println("  moon run cmd/main --stats \"<path d>\"...  统计命令出现次数")
  println("  moon run cmd/main --precision <N> \"<path d>\"  有损模式：保留 N 位小数")
  println("  moon run cmd/main --help                 显示本帮助")
  println("  moon run cmd/main --version              显示版本")
}
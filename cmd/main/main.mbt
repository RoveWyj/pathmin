fn main {
  let argv = @env.args()
  // argv[0]=程序名，argv[1]=path d；无参数时用内置示例
  let input = if argv.length() > 1 {
    argv[1]
  } else {
    "M 100.000, 200.000 L 300.0000, 400.0000 L 0.0000, 0.0000 Z"
  }
  let r = @lib.optimize(input)
  let saved = 100 * (r.original_len - r.new_len) / r.original_len
  println("input    : \{input}")
  println("minified : \{r.minified}")
  println("bytes    : \{r.original_len} -> \{r.new_len}  (saved \{saved}%)")
}
-- ==
-- structure { Screma 2 }
let main [n][m] (a: [n][m]i32): i32 =
  let b = map (\z1: [m]i32  ->
                map (*3) z1) a
  let ravgs = map (\r: i32  ->
                   reduce (+) 0 r / i32.i64 n)
                  (transpose b)
  let res = reduce (+) 0 ravgs in
  res

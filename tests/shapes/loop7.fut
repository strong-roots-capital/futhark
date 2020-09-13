-- Infer correctly that the loop parameter 'ys' has a variant size.
-- ==
-- input { [0i64,1i64] } output { 2i64 [0i64] }

let first_nonempty f xs =
  loop (i, ys) = (0, [] : []i64) while null ys && i < length xs do
  let i' = i+1
  let ys' = f xs[i]
  in (i', ys')

let main [n] (xs: [n]i64) =
  first_nonempty iota xs

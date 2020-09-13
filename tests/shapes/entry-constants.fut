-- Dimension declarations on entry points can refer to constants.
-- ==
-- input { [1i64,2i64,3i64] } output { [0i64,1i64] }
-- compiled input { [1i64,2i64] } error: Error
-- compiled input { [1i64,3i64,2i64] } error: Error

let three: i64 = 3
let two: i64 = 2

let main(a: [three]i64): [two]i64 = iota a[1] :> [two]i64

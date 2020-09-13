-- Test register tiling when all input arrays are invariant to one parallel dimension.
-- This is a more complex code, in which the code after the stream has both variant
-- and invariant parts.
--
-- ==
-- input {
--   [ [1.0f32, 3.0], [2.0, 4.0] ]
--   [ [5.0f32, 8.0], [6.0, 7.0] ]
--   [ [1.0f32, 1.0], [9.0, 1.0] ]
-- }
-- output { 
--   [ [ [28.0f32, 40.0f32], [42.0f32, 58.0f32] ]
--   , [ [39.0f32, 32.0f32], [48.0f32, 42.0f32] ]
--   ]
-- }

-- compile input @ data/medium.in
-- output @ data/medium-2.out

let pred (x : f32) : bool = x < 9.0

let dotprod_filt [n] (vct: [n]f32) (xs: [n]f32) (ys: [n]f32) (k : i64) : f32 =
  let s = f32.sum (map3 (\v x y -> let z = x*y in let f = f32.bool (pred v) in z*f) vct xs ys)
  let var_term = 2.0 * #[unsafe] vct[k]
  let inv_term = 3.0 * #[unsafe] xs[k]
  in  s + inv_term + var_term

let matmul_filt [n][p][m] (xss: [n][p]f32) (yss: [p][m]f32) (vct: [p]f32) : [n][m]f32 =
  map (\xs -> map2 (dotprod_filt vct xs) (transpose yss) (iota m)) xss

let main [m][n][u]  (ass: [n][u]f32) 
                    (bss: [u][n]f32) 
                    (fss: [m][u]f32)
                    : [m][n][n]f32 =
    map (matmul_filt ass bss) fss

-- Horizontal fusion of reductions.
-- ==
-- structure { Screma 1 }

let main (xs: []i32) = (i32.sum xs, f32.sum (map f32.i32 xs))

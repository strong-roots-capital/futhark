-- Simple intra-group scan.
-- ==
-- random input { [1][256]i32 } auto output
-- random input { [100][256]i32 } auto output
-- random input { [100][512]i32 } auto output
-- structure distributed { SegMap/SegScan 1 }

let main = map (scan (+) 0i32)

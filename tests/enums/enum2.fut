-- Matches on nested tuples 2.
-- ==
-- input { } 
-- output { 6 }

let main : i32 =
  match ((1,2), 3)
    case ((5,2), 3) -> 5
    case ((1,2), 3) -> 6
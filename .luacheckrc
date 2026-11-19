std = "lua51"
read_globals = { "plugin", "cliamp" }
max_line_length = 100

-- The callbacks take self and do not use it. "not (a < b)" is on purpose
-- where a can be NaN.
ignore = { "212/self", "581" }

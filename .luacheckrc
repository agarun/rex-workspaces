std = "luajit"
read_globals = { "rex" }
max_line_length = 120
exclude_files = { "ui/target" }
files["test/"] = { std = "+busted" }

-- cpv: track https://github.com/nvim-telescope/telescope.nvim/blob/63e279049652b514b7c3cbe5f6b248db53d77516/README.md?plain=1#L138-L142
local builtin = require("telescope.builtin")
vim.keymap.set("n", "ff", builtin.find_files, {})
vim.keymap.set("n", "fg", builtin.live_grep, {})
vim.keymap.set("n", "fb", builtin.buffers, {})
vim.keymap.set("n", "fh", builtin.help_tags, {})
-- cpv: end

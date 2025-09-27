# User Story
- Copy code snippet and github rich url
- Rich url contains hash, line numbers, etc
- Paste snippet into your codebase with comment with rich url on top, prefixed by `copyv: `
- On future date, when you want to see how the code has changed, call into cli tool to give a report

# Functionality Required
- Search codebase and identify tagged snippets
- Parse urls
- Identify head hash on main branch on remote
- Pull each raw file from main head
- Generate diffs

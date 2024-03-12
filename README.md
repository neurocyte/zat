# zat
zat is a syntax highlighting cat like utility.

It uses tree-sitter and supports for vscode themes.

Build with the provided zig wrapper:
```shell
./zig build -Doptimize=ReleaseSmall
```

The zig wrapper just fetches a known good version of zig nightly and places it
in the .cache directory. Or use your own version of zig.

Run with:
```shell
zig-out/bin/zat
```

Place it in your path for convenient access.


Supply files to highlight on the command line. Multiple files will be appended
like with cat. If no files are on the command line zat will read from stdin.
Override the language with --language and select a different theme with --theme.
The default theme will be read from ~/.config/flow/config.json if found.

See `scripts/fzf-grep` for an example of using zat to highlight fzf previews.

See --help for full command line.

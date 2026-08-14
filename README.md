# SimpleEditorConfig

EditorConfig support for local and SimpleRemote workspaces. It applies the
standard indentation, line-ending, charset, maximum-line-length, trailing
whitespace and final-newline properties without a Python dependency.

For `remote://` buffers it discovers `.editorconfig` files asynchronously via
`g:SimpleRemoteReadFile()` and never mounts or shells out to read configuration.

Use `:SimpleEditorConfigInfo`, `:SimpleEditorConfigReload` and
`:SimpleEditorConfigHealth` for inspection.

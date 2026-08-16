# SimpleEditorConfig

EditorConfig support for local and SimpleRemote workspaces. It applies the
standard indentation, line-ending, charset, maximum-line-length, trailing
whitespace and final-newline properties without a Python dependency.

## SimpleRemote workspaces

Everything below is feature-detected: without SimpleRemote the plugin is a
plain local EditorConfig implementation.

* **Virtual mode (`remote://` buffers).**  `.editorconfig` files are
  discovered asynchronously through `g:SimpleRemoteReadFile()` — the plugin
  never mounts or shells out to read configuration.  Every directory from the
  file's own up to the workspace root is asked at once, so a file at any depth
  costs one round-trip, and the parsed answers (hits and misses) are cached per
  workspace.  The cache is dropped when a `remote://` buffer saves a
  `.editorconfig`, when SimpleRemote reports a tree/upload/API change touching
  one (`SimpleRemoteFilesChanged`), when the workspace changes or disconnects,
  and by `:SimpleEditorConfigReload`.  The walk never leaves the workspace
  root, and a walk that hits a transport failure applies nothing rather than a
  partial set.  SimpleRemote fires `BufWritePre` for remote saves, so
  `trim_trailing_whitespace` and `charset = utf-8-bom` work on `remote://`
  buffers too.
* **Projected modes (`sshfs`, `docker-bind`).**  Buffers under the
  workspace's `local_root` are ordinary files, but the walk stops at the mount
  point: what sits above it on this machine (`~/.editorconfig`,
  `~/.local/state/...`) is not part of the project.  `local-map` — a directory
  you chose yourself — keeps walking to `/` like any local file.

Use `:SimpleEditorConfigInfo`, `:SimpleEditorConfigReload` and
`:SimpleEditorConfigHealth` for inspection; both Info and Health name the
active workspace and its mode.

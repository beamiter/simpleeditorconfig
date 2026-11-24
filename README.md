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
  file's own up to the first cached `root = true` or the workspace root is
  asked at once, so a file at any depth
  costs one round-trip, and the parsed answers (hits and misses) are cached per
  workspace and configuration path. Overlapping walks share pending reads.
  A save or SimpleRemoteFilesChanged event invalidates only the affected paths
  in the current workspace and refreshes affected loaded buffers. Late
  replies to superseded reads cannot configure buffers or refill the cache.
  Workspace change, disconnect and :SimpleEditorConfigReload clear the
  complete remote cache. The walk never leaves the
  workspace root, and a transport failure at or below the first `root = true`
  applies nothing rather than a partial set (above it, the failed directory
  was going to be discarded anyway).  SimpleRemote fires `BufWritePre` for
  remote saves, so `trim_trailing_whitespace` and `charset = utf-8-bom` work
  on `remote://` buffers too.
* **Projected modes (`sshfs`, `docker-bind`, `local-map`).**  Buffers under
  the workspace's `local_root` are ordinary files.  In `sshfs` mode that
  directory is a mount SimpleRemote made under
  `~/.local/state/vim/simpleremote/mounts`, so the walk stops there: what sits
  above it on this machine (`~/.editorconfig`, `~/.local/state/...`) is not
  part of the project.  `docker-bind` and `local-map` are places you chose
  yourself — an explicit mapping, or the host side of the container's bind
  mount — so they keep walking to `/` like any local file, and connecting a
  workspace never changes what a local buffer in them gets.

Use `:SimpleEditorConfigInfo`, `:SimpleEditorConfigReload` and
`:SimpleEditorConfigHealth` for inspection; both Info and Health name the
active workspace and its mode.

# Session lifecycle

`SessionLifecycle` is the source of truth for connection intent and media
activity. It replaces the overlapping `is_streaming`, `_restarting_stream`,
`_reconnecting`, and `_connect_timeout_pending` fields that previously lived in
`main.gd`.

## Phases

- `BOOT`: application services and XR presentation are still initializing.
- `SERVER_SELECTION`: no connection is active; welcome/server UI is available.
- `CONNECTING`: an ordinary host launch or pairing connection is in progress.
- `STREAMING`: decoder media is active.
- `RESTARTING`: a settings or resolution change is deliberately replacing the
  stream. The phase remains active across the old decoder's termination and the
  new connection attempt.
- `RECONNECTING`: the native stream backend is retrying an unexpected failure.
- `DISCONNECTING`: a user or idle timeout requested an orderly stop.
- `FAILED`: connection setup or all reconnect attempts failed. Cleanup preserves
  this phase while restoring the server UI.

`media_active` is separate from the phase because a deliberate restart begins
while the old stream is still active, then remains `RESTARTING` after that media
session terminates. Code that only needs to know whether frames can be consumed
uses `main.is_streaming`, a read-only view of `media_active`.

## Ownership

- `StreamManager` begins connection attempts.
- `SettingsController` requests deliberate restarts.
- Native stream signals report media start, termination, reconnect scheduling,
  and reconnect exhaustion through `main.gd`.
- `SessionLifecycle` owns the resulting phase, timeout guard, and media-active
  state; it owns no UI, backend, renderer, or persistence objects.

Resource cleanup remains in the modules that own those resources. Lifecycle
transitions describe intent and ordering but do not destroy decoder or OpenXR
objects themselves.

## Telemetry

`PerformanceTelemetry` owns frame/update sampling intervals and combines adjacent
native performance windows. It is data-only: `main.gd` still decides when to
consume decoder frames, while composition and native-XR modules still present the
resulting overlay. This keeps counters and timing state out of the application
coordinator without coupling telemetry to a renderer.

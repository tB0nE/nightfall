# Future Features - Research Notes

> Status: Active backlog

## 5. Custom Skybox Backgrounds

**Goal**: Load user-provided 360°/equirectangular images as environment backgrounds (replacing or supplementing the starfield).

**Approach**:
- Use `Sky` resource with `PanoramaTexture` (equirectangular image) in `WorldEnvironment`
- Or: Create a large inverted sphere mesh with the 360° texture (like starfield approach but with image)
- User places images in a specific directory on headset storage (`/sdcard/Nightfall/skyboxes/`)
- UI: Add "Skybox" button that cycles through: Off (black) → Starfield → Custom skybox 1 → Custom skybox 2 → ...
- File browser or just auto-load all images from the directory
- Supported formats: JPG, PNG, EXR (HDR)
- Godot API: `load()`, `ImageTexture.load_from_file()`, `Environment.set_sky()`

**Implementation**:
1. Add `skybox_mode` int (0=off, 1=starfield, 2+=custom indices) and `skybox_paths` array
2. `_create_skybox()` creates inverted sphere with texture
3. Persist selected skybox in state
4. Scan directory on startup for available skyboxes

**References**:
- Virtual Desktop: supports custom skybox images, multiple built-in environments
- Bigscreen: cinema environments, community environments

---

## 6. Environment Ambient Sounds

**Goal**: Play background audio per environment (rain, fireplace, cafe, space, forest, ocean).

**Approach**:
- Bundle small OGG audio files (looping) in `res://src/assets/ambient/`
- Or load user-provided audio from `/sdcard/Nightfall/ambient/`
- Use `AudioStreamPlayer` or `AudioStreamPlayer2D` for playback
- UI: "Ambient" button cycles: Off → Rain → Fire → Cafe → Space → ...
- Volume slider or just fixed pleasant level
- Independent of stream audio (separate AudioBus)

**Implementation**:
1. Add `ambient_mode` int and `ambient_labels` array
2. Load audio files as `AudioStreamOggVorbis` resources
3. Play via dedicated `AudioStreamPlayer` node
4. Crossfade when switching (optional)
5. Persist in state

**File sizes**:
- Typical ambient loops: 200KB-1MB each (OGG, mono, 44.1kHz)
- 6-8 environments = ~3-5MB total

---

## 7. Hand Tracking

**Goal**: Use Meta Quest hand tracking for pointer interaction (pinch to click, point to hover).

**Godot 4.x Built-in Support**:
- `XRHandTracker` class provides 26 joints per hand
- `XRHandModifier3D` applies tracking to skeleton
- Enable in Project Settings > OpenXR > Extensions > Hand Tracking
- Enable in Export Settings > Meta section

**OpenXR Extensions Needed**:
- `XR_EXT_hand_tracking` (core, required)
- `XR_FB_hand_tracking_aim` (stabilized aim direction, recommended)
- `XR_MSFT_hand_interaction` (pinch/select gesture mapping)

**Gesture→Input Mapping**:
| Gesture | Action |
|---------|--------|
| Pinch (thumb+index) | Left click |
| Pinch hold + move | Drag |
| Index point | Hover/aim |
| Fist (grasp) | Right click |
| Two-hand spread | Scroll |

**Implementation**:
1. Add `XRNode3D` per hand under `XROrigin3D` with tracker `/user/hand_tracker/left|right`
2. Add hand meshes (runtime-provided via `XR_FB_hand_tracking_mesh` or custom)
3. Create `HandTrackingController` GDScript that:
   - Reads `XRHandTracker.get_hand_joint_transform()` for joint positions
   - Computes pinch distance (thumb tip to index tip)
   - Casts ray from index tip in pointing direction
   - Converts 3D hit to 2D viewport coords → injects InputEvent
4. Fallback to controllers when hands lose tracking (`has_tracking_data == false`)

**Limitations**:
- 30-50ms latency, no haptics
- Needs adequate IR lighting (indoor OK, dark rooms degrade)
- Tracking range: 0.2m-1.5m from headset
- Controller/hand switch can be jarring

**Libraries**:
- `godot_openxr_vendors` plugin: Meta-specific extensions
- `Godot-XR-AH` (Auto Hands): maps gestures to controller events
- `GodotXRHandPoseDetector`: configurable pose detection

---

## 8. Wide Virtual Monitor (Multi-Monitor)

**Goal**: Display a very wide virtual screen that spans the user's view, effectively acting as multiple monitors.

**Protocol Limitation**:
- GameStream/Moonlight protocol is single-display-per-session (one width/height pair in `STREAM_CONFIGURATION`)
- No way to request multiple display captures from a single client
- Sunshine captures one display at a time per session

**Approach A: Wide Virtual Display** (recommended):
- Create a single very wide virtual display on the host (e.g., 3840x1080 or 5120x1440)
- Sunshine captures it as one stream
- Nightfall renders it as a wide curved screen (cylinder with large central angle)
- On Windows: use Apollo with SudoVDA to create custom-size virtual display
- On Linux: use `xrandr` to create a large virtual mode, or `cvt` for modeline

**Approach B: Multiple Apollo Instances** (Windows only):
- Run multiple Apollo instances on different ports
- Each creates its own virtual display
- Nightfall connects to each as separate stream
- Display each stream on separate composition layers
- Complex: multiple video decoders, input routing to correct session

**Implementation for Approach A**:
1. Add "Wide" resolution preset (e.g., 3840x1080, 5120x1440)
2. When selected, request wide resolution from Sunshine
3. Render on a wide cylinder (larger central angle, e.g., 90-120°)
4. User positions head to focus on different "regions"
5. Keyboard/mouse input works on the full virtual desktop area

**Host Configuration**:
- Windows: Apollo + SudoVDA auto-creates virtual display at requested resolution
- Linux: `xrandr --newmode "wide" ... && xrandr --addmode ... && xrandr --output ... --mode wide`
- Sunshine `output_name` config selects which display to capture

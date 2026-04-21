# 🚀 Ty-Streamer

A Godot 4 XR application for streaming PC desktops via Moonlight with stereoscopic 3D support.

## 🛠 Project Status
- [x] Milestone 1: Compile/load GDExtension in Godot.
- [x] Milestone 2: 2D stream implementation logic.
- [x] Milestone 3: OpenXR/WiVRn setup.
- [x] Milestone 4: Stereo Shader for SBS games.

## 🚀 How to Run

### 1. Prerequisites
- **WiVRn:** Ensure `wivrn-server` is running on your host.
- **Sunshine:** Ensure Sunshine is running on your host PC and you know its IP address.

### 2. Launching the App
Since Godot is installed via Steam, use the following command to launch with XR enabled:

```bash
"/var/home/tyrone/.local/share/Steam/steamapps/common/Godot Engine/godot.x11.opt.tools.64" --xr-mode on --path .
```

### 3. Pairing
1. Open `res://main.gd`.
2. Uncomment the `pair_and_start("YOUR_IP")` line in `_ready()` and replace with your Sunshine host IP.
3. Run the app.
4. Check the console for the PIN and enter it in the Sunshine web UI.

## 📺 Controls
- Input events (Keyboard, Mouse, Gamepad) are automatically forwarded to the remote host while streaming.

## 🎨 Shader Details
The `stereo_screen.gdshader` handles Side-By-Side (SBS) content by splitting the texture based on the `VIEW_INDEX` (Multiview). This allows you to play 3D games (via ReShade/SuperDepth3D) in true stereoscopic depth.

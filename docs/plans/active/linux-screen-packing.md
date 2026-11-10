# Linux: pack screens into one frame (KDE and GNOME)

Status: in progress, started 2026-11-09. Host work is in Vibepollo
(`~/Development/Personal/meteor-vibepollo`, branch `linux-virtual-monitors`).

## Why

KDE virtual monitors (done) capture one desktop rectangle. That pulls in any
monitor between the chosen ones, and on GNOME Mutter caps a rectangle
(`RecordArea`) at 60 fps while a single monitor (`RecordMonitor`,
`RecordVirtual`) runs at its own refresh rate. Packing each screen's own stream
into the frame, as Windows does, gives full rate on both desktops and lets any
set of monitors be chosen.

## What the GNOME spike showed (headless Mutter 50.6)

- Mutter's private `org.gnome.Mutter.ScreenCast` works from an ordinary process.
- `RecordVirtual` makes a monitor only once a consumer negotiates the stream;
  the consumer's caps set its size, and `max-framerate=120/1` makes it 120 Hz.
- The monitor stays after the consumer pauses or disconnects, until its
  session stops: one session per virtual monitor can own it, apart from capture.
- `org.gnome.Mutter.DisplayConfig.ApplyMonitorsConfig` moves it.
- `RecordArea` offers `maxFramerate` at most 60; monitor streams offer the
  monitor's rate.

## Design

1. **Plan:** use `display_plan.h` (screens packed into rows by size, the
   primary first) on Linux too. The manifest serves it and claims
   `any_selection`; `frame_to_desktop` maps input through its tiles.
2. **Packer** (`pipewire_multi.cpp`): a `platf::display_t` owning one
   `pipewire_t` stream per screen. Each frame it imports the latest dmabuf of
   every stream (`egl::import_source`) and blits it into its tile of a GBM
   buffer the plan's size (a small ring), then hands that dmabuf to the encoder
   as one stream would (`fill_img_dmabuf` shape). The cursor comes from whichever
   stream carries it, offset by its tile. SHM streams upload through GL.
   A screen with no frame yet stays black; the frame size never changes in a
   session.
3. **Sources:** a provider gives the packer a PipeWire node per screen.
   - KDE: `stream_output` per output (virtual monitors keep their owner).
   - GNOME: `RecordMonitor` per physical monitor; virtual monitors from a
     `RecordVirtual` session owner (negotiated once at the stream's size and
     rate), placed with `ApplyMonitorsConfig`.
4. **Meteor:** advertise virtual monitors on GNOME Wayland too.

## Testing

- Unit: plan/tile mapping and packer placement offsets.
- Headless Mutter in the `nf-gnome` distrobox (own D-Bus, own config folder).
- KDE live on the user's PC; GNOME on the user's GNOME machine (Bazzite GNOME).
- Watch: input on GNOME (absolute pointer mapping across monitors), encoder
  import of the packer's GBM buffer on NVIDIA (CUDA) and AMD (VA-API).

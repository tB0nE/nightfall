shader_type spatial;
render_mode unshaded;

// Opt-in variant used only while Brightness, Contrast, or Gamma is adjusted.
#define NIGHTFALL_PICTURE_GRADE
#include "res://src/shaders/stereo_screen_core.gdshaderinc"

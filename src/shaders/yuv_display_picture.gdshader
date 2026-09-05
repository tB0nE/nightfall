shader_type canvas_item;

// Opt-in variant used only while Brightness, Contrast, or Gamma is adjusted.
#define NIGHTFALL_PICTURE_GRADE
#include "res://src/shaders/yuv_display_core.gdshaderinc"

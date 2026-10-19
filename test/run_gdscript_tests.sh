#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NIGHTFALL_TEST_DATA_ROOT="${NIGHTFALL_TEST_DATA_ROOT:-${TMPDIR:-/tmp}/nightfall-gdscript-tests}"

if [[ -n "${NIGHTFALL_GODOT_EDITOR:-}" ]]; then
	NIGHTFALL_TEST_GODOT="$NIGHTFALL_GODOT_EDITOR"
elif command -v godot >/dev/null 2>&1; then
	NIGHTFALL_TEST_GODOT="$(command -v godot)"
else
	NIGHTFALL_TEST_GODOT="/var/home/tyrone/Applications/Godot_v4.7-stable_linux.x86_64"
fi

if [[ ! -x "$NIGHTFALL_TEST_GODOT" ]]; then
	echo "Godot executable not found: $NIGHTFALL_TEST_GODOT" >&2
	echo "Set NIGHTFALL_GODOT_EDITOR to a Godot 4.7 executable." >&2
	exit 1
fi

mkdir -p "$NIGHTFALL_TEST_DATA_ROOT"

tests=(
	"test/test_pcvr_session.gd"
	"test/test_meteor_xr_control.gd"
	"test/test_xr_diagnostic_ledger.gd"
	"test/test_pcvr_test_controller.gd"
	"test/test_browser_depth_policy.gd"
	"test/test_screen_primary_selection.gd"
	"test/test_stream_browser_workspace.gd"
	"test/test_screen_tab_hit_physics.gd"
	"test/test_screen_tab_strip.gd"
	"test/test_browser_gamepad.gd"
	"test/test_browser_presentation_isolation.gd"
	"test/test_shared_screen_controls.gd"
	"test/test_depth_welcome_restore.gd"
	"test/test_app_settings.gd"
	"test/test_menu_schema.gd"
	"test/test_localization.gd"
	"test/test_licences.gd"
	"test/test_ui_tooltips.gd"
	"test/test_performance_telemetry.gd"
	"test/test_ai3d_adaptive_pacer.gd"
	"test/test_welcome_screen.gd"
	"test/test_session_lifecycle.gd"
	"test/test_monitor_grid.gd"
	"test/test_screen_registry.gd"
	"test/test_screen_shortcut_bar.gd"
	"test/test_virtual_keyboard.gd"
	"test/test_screen_layout.gd"
	"test/test_monitor_presets.gd"
	"test/test_video_presentation.gd"
	"test/test_meteor_client.gd"
	"test/test_controller_layout.gd"
	"test/test_hand_aim.gd"
	"test/test_content_tabs.gd"
	"test/test_screen_sources.gd"
	"test/test_browser_prototype.gd"
	"test/test_primary_media.gd"
	"test/test_browser_close.gd"
)

for test_file in "${tests[@]}"; do
	test_name="$(basename "$test_file" .gd)"
	output_file="$NIGHTFALL_TEST_DATA_ROOT/$test_name.out"
	log_file="$NIGHTFALL_TEST_DATA_ROOT/$test_name.log"
	user_data_dir="$NIGHTFALL_TEST_DATA_ROOT/user-data-$test_name"
	mkdir -p "$user_data_dir"

	echo "Running $test_file"
	if ! XDG_DATA_HOME="$user_data_dir" "$NIGHTFALL_TEST_GODOT" \
		--headless \
		--xr-mode off \
		--log-file "$log_file" \
		--path "$PROJECT_ROOT" \
		--script "$test_file" 2>&1 | tee "$output_file"; then
		echo "$test_file exited unsuccessfully" >&2
		exit 1
	fi

	# GDScript assertions are reported as script errors but Godot can still exit
	# with status zero. Treat either marker as a failed test explicitly.
	if grep -qE "SCRIPT ERROR:|Assertion failed" "$output_file"; then
		echo "$test_file reported a script failure" >&2
		exit 1
	fi
done

echo "All GDScript test scripts passed"

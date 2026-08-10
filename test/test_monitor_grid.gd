extends SceneTree

func _init():
	_test_cells_overlap()
	_test_cell_in_bounds()
	_test_col_row_center()
	print("All monitor_grid tests passed")
	quit()

func _test_cells_overlap():
	assert(MonitorGrid.cells_overlap(Vector2i(2, 1), Vector2i(2, 1)))
	assert(MonitorGrid.cells_overlap(Vector2i(2, 1), Vector2i(3, 1)))
	assert(not MonitorGrid.cells_overlap(Vector2i(2, 1), Vector2i(4, 1)))
	assert(not MonitorGrid.cells_overlap(Vector2i(0, 0), Vector2i(0, 2)))

func _test_cell_in_bounds():
	assert(MonitorGrid.cell_in_bounds(0, 0))
	assert(MonitorGrid.cell_in_bounds(6, 2))
	assert(not MonitorGrid.cell_in_bounds(7, 0))
	assert(not MonitorGrid.cell_in_bounds(0, 3))
	assert(not MonitorGrid.cell_in_bounds(-1, 0))

func _test_col_row_center():
	assert(absf(MonitorGrid.col_center(3) - 4.0) < 0.0001)
	assert(absf(MonitorGrid.row_center(1) - 2.0) < 0.0001)

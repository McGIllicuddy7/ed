package ascii
import "core:encoding/json"
import "core:fmt"
import "core:math/linalg/hlsl"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "vendor:raylib"
BUFFER_HEIGHT :: 45
BUFFER_WIDTH :: 80

color_t :: enum (u8) {
	BLACK,
	RED,
	GREEN,
	YELLOW,
	BLUE,
	MAGENTA,
	CYAN,
	WHITE,
	BRIGHT_BLACK,
	BRIGHT_RED,
	BRIGHT_GREEN,
	BRIGHT_YELLOW,
	BRIGHT_BLUE,
	BRIGHT_MAGENTA,
	BRIGHT_CYAN,
	BRIGHT_WHITE,
}

EditorMode :: enum {
	Normal,
	Visual,
	Text,
	Drawing,
	Command,
}

Point :: struct {
	x: i16,
	y: i16,
}


Cell :: struct {
	ch:    rune,
	color: color_t,
}

Line :: struct {
	start: Point,
	end:   Point,
}

LineKind :: enum {
	Wall,
	Door,
}

LineStruct :: struct {
	line: Line,
	kind: LineKind,
}

BufferSavestate :: struct {
	lines:  [dynamic]LineStruct,
	buffer: [60][80]Cell,
}

BufferState :: struct {
	lines:  map[Line]LineKind,
	buffer: [60][80]Cell,
}

Editor :: struct {
	file_name:          string,
	mode:               EditorMode,
	cursor_x:           i16,
	cursor_y:           i16,
	select_start_x:     i16,
	select_start_y:     i16,
	carriage_return:    i16,
	last_return_x:      i16,
	frame_allocator:    mem.Allocator,
	frame_arena:        mem.Arena,
	command_buffer:     strings.Builder,
	should_quit:        bool,
	plugin_command_set: map[string]#type proc(
		this: ^Editor,
		command: string,
		entire_command: []string,
	),
	text_color:         color_t,
	background_color:   color_t,
	move_timer:         f32,
	using state:        BufferState,
}

get_color :: proc(color: color_t, bg := false) -> (out: raylib.Color) {
	switch color {
	case .BLACK:
		out = {10, 10, 10, 255}
	case .RED:
		out = raylib.RED
	case .GREEN:
		out = raylib.DARKGREEN
	case .YELLOW:
		out = raylib.YELLOW
	case .BLUE:
		out = raylib.BLUE
	case .MAGENTA:
		out = raylib.MAGENTA
	case .CYAN:
		out = {0, 200, 200, 255}
	case .WHITE:
		out = {200, 200, 200, 255}
	case .BRIGHT_BLACK:
		out = raylib.DARKGRAY
	case .BRIGHT_RED:
		out = {255, 0, 0, 255}
	case .BRIGHT_GREEN:
		out = {0, 255, 0, 255}
	case .BRIGHT_YELLOW:
		out = {255, 255, 0, 255}
	case .BRIGHT_BLUE:
		out = {0, 0, 255, 255}
	case .BRIGHT_MAGENTA:
		out = {255, 0, 255, 255}
	case .BRIGHT_CYAN:
		out = {0, 255, 255, 255}
	case .BRIGHT_WHITE:
		out = {255, 255, 255, 255}
	}
	if bg {
		if out.r > 10 {
			out.r -= 10
		} else {
			out.r = 0
		}
		if out.g > 10 {
			out.g -= 10
		} else {
			out.g = 0
		}
		if out.b > 10 {
			out.b -= 10
		} else {
			out.b = 0
		}
	}
	return
}

drawing_to_screen_space :: proc(x: i16, y: i16, cell_size: i16) -> raylib.Vector2 {
	x0 := cast(int)x
	y0 := cast(int)y
	cell := cast(int)cell_size
	out := raylib.Vector2{cast(f32)(x0 * cell + cell / 2), cast(f32)(y0 * cell + cell / 2)}
	return out
}

canonicalize_line :: proc(line: Line) -> (out: Line) {
	out = line
	if out.start.y > out.end.y {
		tmp := out.start
		out.start = out.end
		out.end = tmp
	} else if out.start.y == out.end.y {
		if out.start.x > out.end.x {
			tmp := out.start
			out.start = out.end
			out.end = tmp
		}
	}
	return
}

editor :: proc() {
	frame_buffer := make_slice([]u8, 65536)
	this := new(Editor)
	strings.builder_init(&this.command_buffer)
	mem.arena_init(&this.frame_arena, frame_buffer)
	this.frame_allocator = mem.arena_allocator(&this.frame_arena)
	this.lines = make(map[Line]LineKind)
	mem.arena_init(&this.frame_arena, frame_buffer)
	this.background_color = .BLACK
	this.text_color = .GREEN
	this.file_name = strings.clone("test.json")
	defer {
		strings.builder_destroy(&this.command_buffer)
		delete(this.lines)
		delete(frame_buffer)
		free(this)
	}
	raylib.InitWindow(1200, 1000, "ed(1)")
	defer {
		raylib.CloseWindow()
	}
	raylib.SetTraceLogLevel(.ERROR)
	raylib.SetExitKey(.KEY_NULL)
	font := raylib.LoadFont("Ac437_IBM_VGA_9x16.ttf")
	defer raylib.UnloadFont(font)
	for !this.should_quit && !raylib.WindowShouldClose() {
		if this.move_timer > 0. {
			this.move_timer -= raylib.GetFrameTime()
			if this.move_timer < 0. {
				this.move_timer = 0.
			}
		}
		mem.arena_free_all(&this.frame_arena)
		switch this.mode {
		case .Normal:
			editor_update_normal(this)
		case .Visual:
			editor_update_visual(this)
		case .Text:
			editor_update_text(this)
		case .Drawing:
			editor_update_drawing(this)
		case .Command:
			editor_update_command(this)
		}
		this.cursor_x = clamp(this.cursor_x, 0, BUFFER_WIDTH - 1)
		this.carriage_return = clamp(this.carriage_return, 0, BUFFER_WIDTH - 1)
		this.last_return_x = clamp(this.last_return_x, 0, BUFFER_WIDTH - 1)
		if this.mode != .Drawing {
			this.cursor_y = clamp(this.cursor_y, 0, BUFFER_HEIGHT - 1)
		} else {
			this.cursor_y = clamp(this.cursor_y, 0, (BUFFER_HEIGHT) * 2 - 1)
		}
		cell_size: i16 = 10
		cell_width: i16 = cell_size
		cell_height: i16 = cell_size * 2
		raylib.BeginDrawing()
		raylib.ClearBackground(get_color(this.background_color, true))
		for line, kind in this.state.lines {
			point := line.start
			point2 := line.end
			if kind == .Wall {
				s0 := drawing_to_screen_space(point.x, point.y, cell_size)
				s1 := drawing_to_screen_space(point2.x, point2.y, cell_size)
				raylib.DrawLineV(s0, s1, get_color(this.text_color))
			} else if kind == .Door {
				s0 := drawing_to_screen_space(point.x, point.y, cell_size)
				s1 := drawing_to_screen_space(point2.x, point2.y, cell_size)
				m0 := (s0 + s1) / 2
				e0 := (s0 * 0.6 + m0 * 0.4)
				e1 := (s1 * 0.6 + m0 * 0.4)
				raylib.DrawLineV(s0, e0, get_color(this.text_color))
				raylib.DrawLineV(s1, e1, get_color(this.text_color))
			}
		}
		for y in 0 ..< len(this.buffer) {
			for x in 0 ..< len(this.buffer[0]) {
				px := cast(i32)x * cast(i32)cell_width
				py := cast(i32)y * cast(i32)cell_height
				ch := cast(i32)cell_height
				if this.buffer[y][x].ch != cast(rune)0 &&
				   !(strings.is_space(this.buffer[y][x].ch)) {
					pos := raylib.Vector2{cast(f32)px, cast(f32)py}
					fs := cast(f32)cell_height * 0.8
					raylib.DrawTextCodepoint(
						font,
						this.buffer[y][x].ch,
						pos,
						fs,
						get_color(this.buffer[y][x].color),
					)
				}
			}
		}
		if this.mode == .Drawing {
			raylib.DrawTextCodepoint(
				font,
				'x',
				{
					cast(f32)this.cursor_x * cast(f32)cell_size +
					cast(f32)cell_size / 2 -
					0.2 * cast(f32)(cell_size),
					cast(f32)this.cursor_y * cast(f32)cell_size - cast(f32)cell_size * 0.15,
				},
				0.5 * cast(f32)(cell_height),
				raylib.RED,
			)
		} else {
			raylib.DrawTextCodepoint(
				font,
				'|',
				{
					cast(f32)this.cursor_x * cast(f32)cell_width,
					cast(f32)this.cursor_y * cast(f32)cell_height,
				},
				0.8 * cast(f32)(cell_height),
				raylib.GREEN,
			)
		}

		raylib.DrawTextEx(
			font,
			fmt.caprintf("MODE:%v", this.mode, allocator = this.frame_allocator),
			{0, cast(f32)((BUFFER_HEIGHT) * cast(i32)cell_height)},
			cast(f32)cell_height * 0.8,
			1.,
			raylib.GREEN,
		)
		raylib.DrawTextEx(
			font,
			fmt.caprintf(
				"COMMAND_BUFFER:%s",
				strings.to_string(this.command_buffer),
				allocator = this.frame_allocator,
			),
			{0, cast(f32)((BUFFER_HEIGHT + 1) * cast(i32)cell_height)},
			cast(f32)cell_height * 0.8,
			1.,
			raylib.GREEN,
		)
		raylib.DrawTextEx(
			font,
			fmt.caprintf("CURSOR_X:%d, CURSOR_Y:%d", this.cursor_x, this.cursor_y),
			{0, cast(f32)((BUFFER_HEIGHT + 2) * cast(i32)cell_height)},
			cast(f32)cell_height * 0.8,
			1.,
			raylib.GREEN,
		)
		raylib.EndDrawing()
	}
	editor_save_file(this, this.file_name)
}

slutty_parse_partial_vim_keybind_inputs :: proc(
	this: ^Editor,
	base_x: i16,
	base_y: i16,
	drawing: bool,
) -> (
	x: i16,
	y: i16,
) {
	check_keys_pressed :: proc(this: ^Editor, keys: []raylib.KeyboardKey) -> bool {
		for i in keys {
			if raylib.IsKeyPressed(i) || raylib.IsKeyDown(i) && this.move_timer <= 0. {
				this.move_timer = 0.18
				return true
			}
		}
		return false
	}
	x = base_x
	y = base_y
	if drawing {
		if check_keys_pressed(this, {.H, .LEFT, .A}) {
			if x > 0 {
				x -= 1
			}
		}
		if check_keys_pressed(this, {.J, .DOWN, .S}) {
			if y < (BUFFER_HEIGHT) * 2 - 1 {
				y += 1
			}
		}
		if check_keys_pressed(this, {.K, .UP, .W}) {
			if y > 0 {
				y -= 1
			}
		}
		if check_keys_pressed(this, {.L, .RIGHT, .D}) {
			if x < BUFFER_WIDTH - 1 {
				x += 1
			}
		}
	} else {
		if check_keys_pressed(this, {.H, .LEFT}) {
			if x > 0 {
				x -= 1
			}
		}
		if check_keys_pressed(this, {.J, .DOWN}) {
			if y < (BUFFER_HEIGHT) * 2 - 1 {
				y += 1
			}
		}
		if check_keys_pressed(this, {.K, .UP}) {
			if y > 0 {
				y -= 1
			}
		}
		if check_keys_pressed(this, {.L, .RIGHT}) {
			if x < BUFFER_WIDTH - 1 {
				x += 1
			}
		}
		if raylib.IsKeyPressed(.FOUR) &&
		   (raylib.IsKeyDown(.LEFT_SHIFT) || raylib.IsKeyDown(.RIGHT_SHIFT)) {
			max_x: i16 = 0
			for dx in x ..< BUFFER_WIDTH {
				if !strings.is_space(this.buffer[y][dx].ch) {
					max_x = dx
				}
			}
			x = clamp(max_x + 1, x, BUFFER_WIDTH - 1)
		}
		if raylib.IsKeyPressed(.W) {
			hit_space := false
			dx := x
			dy := y
			hit := false
			for {
				if !hit_space {
					if strings.is_space(this.buffer[dy][dx].ch) {
						hit_space = true
					}
				} else {
					if !(strings.is_space(this.buffer[dy][dx].ch)) {
						hit = true
						break
					}
				}
				dx += 1
				if dx >= BUFFER_WIDTH {
					dx = 0
					dy += 1
					if dy >= BUFFER_HEIGHT {
						break
					}
				}
			}
			if hit {
				x = dx
				y = dy
			} else {
				x = base_y
				y = base_x
			}
		}
		if raylib.IsKeyPressed(.B) {
			hit_word := false
			dx := x
			dy := y
			prev_x := dx
			prev_y := dy
			hit := false
			first := false
			for {
				if !first {
					if !hit_word {
						if !(strings.is_space(this.buffer[dy][dx].ch)) {
							hit_word = true
						}
					} else {
						if strings.is_space(this.buffer[dy][dx].ch) {
							hit = true
							break
						}
					}
				}
				first = false
				prev_x = dx
				prev_y = dy
				if dx > 0 {
					dx -= 1
				} else if dy > 0 {
					dy -= 1
				} else {
					break
				}
			}
			if hit {
				x = prev_x
				y = prev_y
			} else {
				x = base_x
				y = base_y
			}
		}
		if raylib.IsKeyPressed(.E) {
			hit_word := false
			dx := x
			dy := y
			prev_x := dx
			prev_y := dy
			hit := false
			for {
				if !hit_word {
					if !(strings.is_space(this.buffer[dy][dx].ch)) {
						hit_word = true
					}
				} else {
					if strings.is_space(this.buffer[dy][dx].ch) {
						hit = true
						break
					}
				}
				prev_x = dx
				prev_y = dy
				if dx < BUFFER_WIDTH - 1 {
					dx += 1
				} else if dy < BUFFER_HEIGHT - 1 {
					dy += 1
					dx = 0
				} else {
					break
				}
			}
			if hit {
				x = prev_x
				y = prev_y
			} else {
				x = base_x
				y = base_y
			}
		}
		if raylib.IsKeyPressed(.ZERO) {
			x = 0
		}
	}
	return
}

editor_update_normal :: proc(this: ^Editor) {
	x, y := slutty_parse_partial_vim_keybind_inputs(this, this.cursor_x, this.cursor_y, false)
	this.cursor_x = x
	this.cursor_y = y
	if raylib.IsKeyPressed(.I) {
		this.mode = .Text
		this.carriage_return = this.cursor_x
	} else if raylib.IsKeyPressed(.A) {
		this.cursor_x += 1
		if this.cursor_x > BUFFER_WIDTH - 1 {
			this.cursor_x = 0
			this.cursor_y += 1
			this.cursor_y = clamp(this.cursor_y, 0, BUFFER_HEIGHT - 1)
		}
	} else if raylib.IsKeyPressed(.D) {
		if !(raylib.IsKeyDown(.LEFT_SHIFT) || raylib.IsKeyDown(.RIGHT_SHIFT)) {
			this.cursor_y *= 2
			this.cursor_y += 1
			this.mode = .Drawing
		} else {
			this.cursor_y *= 2
			this.mode = .Drawing
		}
	} else if raylib.IsKeyPressed(.SEMICOLON) && raylib.IsKeyDown(.LEFT_SHIFT) {
		this.mode = .Command
	} else if raylib.IsKeyPressed(.O) {
		x = 0
		if y < BUFFER_HEIGHT - 1 {
			y += 1
		}
		this.mode = .Text
	} else if raylib.IsKeyPressed(.V) {
		this.select_start_x = this.cursor_x
		this.select_start_y = this.cursor_y
		this.mode = .Visual
	} else if raylib.IsKeyPressed(.P) {
		buf := cast(string)raylib.GetClipboardText()
		this.carriage_return = this.cursor_x
		for i in buf {
			if i == '\n' {
				this.cursor_y += 1
				this.cursor_x = this.carriage_return
			} else {
				this.buffer[this.cursor_y][this.cursor_y] = {i, this.text_color}
			}
			this.cursor_x += 1
			if this.cursor_x > BUFFER_WIDTH - 1 {
				this.cursor_y += 1
				this.cursor_x = this.carriage_return
			}
			if this.cursor_y > BUFFER_HEIGHT - 1 {
				this.cursor_y = BUFFER_HEIGHT - 1
				break
			}
		}
	}
}

editor_update_visual :: proc(this: ^Editor) {
	if raylib.IsKeyPressed(.ESCAPE) {
		this.mode = .Normal
		return
	}
	x, y := slutty_parse_partial_vim_keybind_inputs(this, this.cursor_x, this.cursor_y, false)
	this.cursor_x = x
	this.cursor_y = y
	if raylib.IsKeyPressed(.Y) {
		min_x := min(this.cursor_x, this.select_start_x)
		min_y := min(this.cursor_y, this.select_start_y)
		max_x := max(this.cursor_x, this.select_start_x)
		max_y := max(this.cursor_y, this.select_start_y)
		buffer := strings.builder_make()
		defer strings.builder_destroy(&buffer)
		for y in min_y ..= max_y {
			for x in min_x ..= max_x {
				strings.write_rune(&buffer, this.buffer[y][x].ch)
			}
			strings.write_rune(&buffer, '\n')
		}
		tstr := strings.to_cstring(&buffer)
		defer delete(tstr)
		raylib.SetClipboardText(tstr)
		this.mode = .Normal
	}
}

editor_update_text :: proc(this: ^Editor) {
	if raylib.IsKeyPressed(.ESCAPE) {
		this.mode = .Normal
	} else if raylib.IsKeyPressed(.ENTER) || raylib.IsKeyPressedRepeat(.ENTER) {
		this.last_return_x = this.cursor_x
		this.cursor_x = this.carriage_return
		this.cursor_y += 1
		this.cursor_y = clamp(this.cursor_y, 0, BUFFER_HEIGHT - 1)
	} else if raylib.IsKeyPressed(.BACKSPACE) ||
	   raylib.IsKeyPressedRepeat(.BACKSPACE) ||
	   raylib.IsKeyPressed(.DELETE) ||
	   raylib.IsKeyPressedRepeat(.DELETE) {
		this.buffer[this.cursor_y][this.cursor_x] = {cast(rune)0, this.text_color}
		if this.cursor_x > this.carriage_return {
			this.cursor_x -= 1
		} else if this.cursor_y > 0 {
			this.cursor_x = this.last_return_x
			this.cursor_y -= 1
		} else {
			this.cursor_x = this.carriage_return
			this.cursor_y = 0
		}
	} else {
		char := raylib.GetCharPressed()
		if char != cast(rune)0 {
			this.buffer[this.cursor_y][this.cursor_x] = {char, this.text_color}
			if this.cursor_x >= BUFFER_WIDTH - 1 {
				this.last_return_x = this.cursor_x
				this.cursor_x = this.carriage_return
				this.cursor_y += 1
				if this.cursor_y >= BUFFER_HEIGHT - 1 {
					this.cursor_y = BUFFER_HEIGHT - 1
				}
			} else {
				this.cursor_x += 1
			}
		}
	}
}

editor_update_drawing :: proc(this: ^Editor) {
	base_x := this.cursor_x
	base_y := this.cursor_y
	x, y := slutty_parse_partial_vim_keybind_inputs(this, this.cursor_x, this.cursor_y, true)
	if raylib.IsKeyPressed(.ESCAPE) {
		this.cursor_y /= 2
		this.mode = .Normal
		return
	}
	if raylib.IsKeyPressed(.X) || raylib.IsKeyPressed(.BACKSPACE) || raylib.IsKeyPressed(.DELETE) {
		delete_list := make([dynamic]Line)
		defer delete(delete_list)
		for line, _con in this.lines {
			if (line.start.x == base_x && line.start.y == base_y) ||
			   (line.end.x == base_x && line.end.y == base_y) {
				append(&delete_list, line)
			}
		}
		for i in delete_list {
			delete_key(&this.lines, i)
		}
	} else if raylib.IsKeyDown(.E) {
		line := canonicalize_line(Line{{base_x, base_y}, {x, y}})
		if line in this.lines {
			this.lines[line] = .Wall
		}
	} else if raylib.IsKeyDown(.Q) {
		line := canonicalize_line(Line{{base_x, base_y}, {x, y}})
		if line in this.lines {
			this.lines[line] = .Door
		}
	} else if !(raylib.IsKeyDown(.LEFT_SHIFT) || raylib.IsKeyDown(.RIGHT_SHIFT)) {
		this.cursor_x = x
		this.cursor_y = y
	} else {
		this.cursor_x = x
		this.cursor_y = y
		if this.cursor_x == base_x && this.cursor_y == base_y {
			return
		}
		line := canonicalize_line(Line{{base_x, base_y}, {this.cursor_x, this.cursor_y}})
		this.lines[line] = .Wall
	}
}

editor_update_command :: proc(this: ^Editor) {
	if raylib.IsKeyPressed(.ESCAPE) {
		strings.builder_reset(&this.command_buffer)
		this.mode = .Normal
	} else if raylib.IsKeyPressed(.ENTER) {
		cmd := strings.clone(strings.to_string(this.command_buffer), this.frame_allocator)
		strings.builder_reset(&this.command_buffer)
		editor_exec_command(this, cmd)
		this.mode = .Normal
	} else {
		rn := raylib.GetCharPressed()
		if rn != 0 {
			strings.write_rune(&this.command_buffer, rn)
		}
	}
}


editor_exec_command :: proc(this: ^Editor, cmd: string) {
	split, err := strings.split_after(cmd, " ", this.frame_allocator)
	if err != nil {
		return
	}
	if len(split) == 0 {
		return
	}
	cmd_base := split[0]
	switch cmd_base {
	case "w":
		editor_save_file(this, this.file_name)
	case "wq":
		editor_save_file(this, this.file_name)
		this.should_quit = true
	case "e":
		if len(cmd_base) == 2 {
			editor_save_file(this, this.file_name)
			editor_load_file(this, split[1])
		}
	case:
		if cmd_base in this.plugin_command_set {
			this.plugin_command_set[cmd_base](this, cmd_base, split)
		}
	}
}

editor_save_file :: proc(this: ^Editor, path: string) {
	save_state := BufferSavestate{}
	save_state.buffer = this.buffer
	save_state.lines = make([dynamic]LineStruct)
	defer delete(save_state.lines)
	for i, k in this.lines {
		append(&save_state.lines, LineStruct{i, k})
	}
	jsn, err := json.marshal(save_state, allocator = context.allocator)
	if err != nil {
		fmt.printf("ERROR WRITING JSON:%v\n", err)
		return
	}
	defer delete(jsn)
	err2 := os.write_entire_file_from_bytes(path, jsn)
	if err2 != nil {
		fmt.printf("ERROR WRITING:%v\n", err2)
		return
	}
}

editor_load_file :: proc(this: ^Editor, file: string) {
	this.buffer = {}
	delete_map(this.lines)
	delete(this.file_name)
	this.file_name = strings.clone(file)
	buffer, err := os.read_entire_file(file, context.allocator)
	if err != nil {
		this.lines = make(map[Line]LineKind)
		return
	}
	defer delete(buffer)
	new_state: BufferSavestate
	err2 := json.unmarshal(buffer, &new_state)
	if err2 != nil {
		fmt.printf("ERROR PARSING FILE:%v\n", err2)
		this.lines = make(map[Line]LineKind)
		return
	}
	this.state.buffer = new_state.buffer
	this.state.lines = make(map[Line]LineKind)
	for i in new_state.lines {
		this.lines[canonicalize_line(i.line)] = i.kind
	}
}

defmodule ScrollPhatHdEx.Server do
  use GenServer

  @bus "i2c-1"
  @address 0x74

  @width 17
  @height 7

  @mode_register 0x00
  @frame_register 0x01
  # @autoplay1_register 0x02
  # @autoplay2_register 0x03
  # @blink_register 0x05
  @audiosync_register 0x06
  # @breath1_register 0x08
  # @breath2_register 0x09
  @shutdown_register 0x0A
  # @gain_register 0x0b
  # @adc_register 0x0c

  @config_bank 0x0B
  @bank_address 0xFD

  @picture_mode 0x00
  # @autoplay_mode 0x08
  # @audioplay_mode 0x18

  @enable_offset 0x00
  # @blink_offset 0x12
  @color_offset 0x24

  defmodule State do
    defstruct buffer: nil,
              i2c: nil,
              current_frame: 0,
              flip_x: true,
              flip_y: true,
              brightness: 0.05
  end

  # Public API

  def start_link(_) do
    GenServer.start_link(__MODULE__, [@bus, @address], name: __MODULE__)
  end

  def state do
    GenServer.call(__MODULE__, :state)
  end

  def show do
    GenServer.call(__MODULE__, :show)
  end

  def set_brightness(value) do
    GenServer.call(__MODULE__, {:set_brightness, value})
  end

  def fill do
    GenServer.call(__MODULE__, :fill)
  end

  def fill_up(limit) do
    GenServer.call(__MODULE__, {:fill_up, limit})
  end

  def write_buffer(buffer) do
    GenServer.call(__MODULE__, {:write_buffer, buffer})
  end

  def write_char(char, font_size \\ :small) do
    write_buffer(get_char(char, font_size))
  end

  def write_string(string, font_size \\ :small) do
    string
    |> String.codepoints()
    |> Enum.map(fn string ->
      List.first(to_charlist(string))
    end)
    |> Enum.reduce([], fn char, result ->
      letter = get_char(char, font_size)

      result
      |> nested_list_concat(letter)
      |> nested_list_concat(character_padding())
    end)
    |> write_buffer
  end

  def scroll_string(string, font_size \\ :small) do
    sentence =
      string
      |> String.codepoints()
      |> Enum.map(fn string ->
        List.first(to_charlist(string))
      end)
      |> Enum.map(&get_char(&1, font_size))
      |> Enum.intersperse(character_padding())
      |> Enum.reduce(fn elem, result ->
        nested_list_concat(result, elem)
      end)

    sentence_padding =
      List.duplicate(0, @width)
      |> List.duplicate(@height)

    # pad the string both left and right to
    # allow nice scrolling experience for the user
    result =
      sentence_padding
      |> nested_list_concat(sentence)
      |> nested_list_concat(sentence_padding)

    result_width =
      result
      |> List.first()
      |> length()

    0..(result_width - @width)
    |> Enum.each(fn n ->
      visible =
        result
        |> Enum.map(fn list ->
          {_, visible_row} = Enum.split(list, n)
          visible_row
        end)

      write_buffer(visible)
      show()
      Process.sleep(100)
    end)

    clear()
    show()
  end

  def fill_animation do
    0..119
    |> Enum.each(fn n ->
      fill_up(n)
      show()
    end)

    clear()
    show()
  end

  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  # Callbacks

  def init([bus, address]) do
    {:ok, i2c} = I2c.start_link(bus, address)
    reset_i2c(i2c)
    initialize_display(i2c)
    {:ok, %State{buffer: empty_buffer(), i2c: i2c}}
  end

  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:show, _from, state) do
    next_frame = next_frame(state.current_frame)

    write_bank(state.i2c, next_frame)
    flipped_buffer = flip_buffer(state.buffer, state.flip_x, state.flip_y)
    output = convert_buffer_to_output(flipped_buffer, state.brightness)
    write_output(state.i2c, output)

    write_config_register(state.i2c, @frame_register, next_frame)
    {:reply, :ok, %{state | current_frame: next_frame}}
  end

  def handle_call({:set_brightness, brightness}, _from, state) do
    {:reply, :ok, %{state | brightness: brightness}}
  end

  def handle_call(:fill, _from, state) do
    new_buffer = Matrix.ones(@width, @height) |> Matrix.scale(255)
    {:reply, :ok, %{state | buffer: new_buffer}}
  end

  def handle_call({:fill_up, limit}, _from, state) do
    new_buffer =
      Enum.reduce(0..(limit - 1), empty_buffer(), fn n, result ->
        x = Integer.mod(n, @width)
        y = trunc(n / @width)
        Matrix.set(result, x, y, 255)
      end)

    {:reply, :ok, %{state | buffer: new_buffer}}
  end

  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | buffer: empty_buffer()}}
  end

  def handle_call({:write_buffer, nested_list}, _from, state) do
    new_buffer =
      nested_list
      |> Enum.map(fn list ->
        {result, _} = Enum.split(list, @width)
        result
      end)
      |> nested_list_to_buffer()

    {:reply, :ok, %{state | buffer: new_buffer}}
  end

  # Helpers

  defp empty_buffer() do
    Matrix.new(@width, @height)
  end

  defp reset_i2c(i2c) do
    write_bank(i2c, @config_bank)
    i2c_write(i2c, @shutdown_register, 0)
    Process.sleep(1)
    i2c_write(i2c, @shutdown_register, 1)
  end

  defp initialize_display(i2c) do
    # Switch to configuration bank
    write_bank(i2c, @config_bank)

    # Switch to picture mode
    i2c_write(i2c, @mode_register, @picture_mode)

    # Disable audio sync
    i2c_write(i2c, @audiosync_register, 0)

    # Switch to bank 1 (frame 1)
    write_bank(i2c, 1)
    i2c_write(i2c, @enable_offset, List.duplicate(255, 18))

    # Switch to bank 0 (frame 0) and enable all LEDs
    write_bank(i2c, 0)
    i2c_write(i2c, @enable_offset, List.duplicate(255, 18))
  end

  defp write_bank(i2c, value) do
    i2c_write(i2c, @bank_address, value)
  end

  defp write_config_register(i2c, register, value) do
    write_bank(i2c, @config_bank)
    i2c_write(i2c, register, value)
  end

  defp i2c_write(i2c, address, value) do
    I2c.write(i2c, IO.iodata_to_binary([address, value]))
  end

  defp next_frame(0), do: 1
  defp next_frame(1), do: 0

  defp convert_buffer_to_output(buffer, brightness) do
    # our display is 17x7 but the actual controller is designed for a 16x9 display
    # what they did is to take the original display wirings and split them apart and
    # put one on top of another. we need to do some acrobatics to get things working
    for(x <- 0..(@width - 1), y <- 0..(@height - 1), do: {x, y})
    |> Enum.reduce(List.duplicate(0, 144), fn {x, y}, result ->
      value = round(Matrix.elem(buffer, x, y) * brightness)
      List.replace_at(result, pixel_address(x, 6 - y), value)
    end)
  end

  defp pixel_address(x, y) when x > 8 do
    x_t = x - 8
    y_t = 6 - (y + 8)
    x_t * 16 + y_t
  end

  defp pixel_address(x, y) do
    x_t = 8 - x
    x_t * 16 + y
  end

  defp write_output(i2c, output) do
    chunk_size = 32

    Enum.chunk(output, chunk_size, chunk_size, [])
    |> Enum.with_index()
    |> Enum.each(fn {chunks, index} ->
      i2c_write(i2c, @color_offset + index * chunk_size, chunks)
    end)
  end

  defp nested_list_to_buffer(nested_list) do
    Enum.reduce(Enum.with_index(nested_list), empty_buffer(), fn {row, row_index}, result ->
      Enum.reduce(Enum.with_index(row), result, fn {value, col_index}, inner_result ->
        Matrix.set(inner_result, col_index, row_index, value)
      end)
    end)
  end

  defp nested_list_concat(first, []), do: first
  defp nested_list_concat([], second), do: second

  defp nested_list_concat(first, second) do
    Enum.zip(first, second)
    |> Enum.map(fn {r1, r2} -> r1 ++ r2 end)
  end

  def flip_buffer(buffer, false, false), do: buffer

  def flip_buffer(buffer, flip_x, flip_y) do
    conditional_flip = fn
      list, true ->
        Enum.reverse(list)

      list, false ->
        list
    end

    conditional_flip.(buffer, flip_y)
    |> Enum.map(fn row ->
      conditional_flip.(row, flip_x)
    end)
  end

  defp get_char(char, font_size) do
    font =
      case font_size do
        :small -> ScrollPhatHdEx.Fonts.Font3By5
        :big -> ScrollPhatHdEx.Fonts.Font5by7Smoothed
      end

    char_font = Map.get(font.data, char)

    case font_size do
      :small ->
        case char_font do
          [first | _] ->
            padding = List.duplicate(0, length(first))
            [padding | char_font] ++ [padding]

          _ ->
            char_font
        end

      :big ->
        char_font
    end
  end

  defp character_padding do
    List.duplicate([0], @height)
  end
end

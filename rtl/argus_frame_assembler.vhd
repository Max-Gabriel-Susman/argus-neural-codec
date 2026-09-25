--------------------------------------------------------------------------------
-- argus_frame_assembler.vhd
--
-- Collects the SPI master's slot stream into complete frames and presents
-- them through a read port. Double buffered: the frame just completed stays
-- stable for a full sweep while the next one is written, so a consumer is
-- never racing the writer.
--
-- This is where channel ordering policy lives. The master is a protocol
-- engine and knows only about chips and channels; the mapping from those to
-- an electrode index belongs here, in one function, so swapping in a real
-- MEA pinout touches nothing else.
--
-- WRITES ARE SERIALISED
--   Each slot carries CHIP_COUNT words, but a flat frame buffer has one
--   write port. Writing one lane per clock over the following CHIP_COUNT
--   clocks keeps the buffer a simple single-port memory and lets the
--   electrode map permute arbitrarily across chip boundaries -- which
--   per-chip buffers would forbid. There are SLOT_CLOCKS (119) clocks
--   between slots and only CHIP_COUNT (3) writes to make, so the margin is
--   large; overrun is still flagged rather than assumed impossible.
--
-- VHDL-93 compatible.
--------------------------------------------------------------------------------

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity argus_frame_assembler is
  generic (
    chip_count  : natural := 3;
    ch_per_chip : natural := 32
  );
  port (
    clk   : in    std_logic;
    rst_n : in    std_logic;

    -- Slot stream from argus_rhd_spi_master. slot_channel already names the
    -- channel the data belongs to; the two-command pipeline is resolved
    -- upstream and is not this module's concern.
    slot_valid   : in    std_logic;
    slot_channel : in    unsigned(5 downto 0);
    slot_data    : in    std_logic_vector(chip_count * 16 - 1 downto 0);
    slot_is_aux  : in    std_logic;
    slot_last    : in    std_logic;

    -- Pulses for one clock when a frame has finished writing and the read
    -- port has switched to it.
    frame_valid : out   std_logic;
    frame_index : out   unsigned(31 downto 0);

    -- Read port into the most recently completed frame. Registered: data
    -- appears the clock after rd_en.
    rd_en   : in    std_logic;
    rd_addr : in    unsigned(7 downto 0);
    rd_data : out   std_logic_vector(15 downto 0);

    -- Sticky. Set if a slot arrives while the previous one is still being
    -- written, which would silently drop samples.
    overrun : out   std_logic
  );
end entity argus_frame_assembler;

architecture rtl of argus_frame_assembler is

  constant total_channels : natural := chip_count * ch_per_chip;

  type frame_buf_t is array (0 to 2 * total_channels - 1) of std_logic_vector(15 downto 0);

  ------------------------------------------------------------------------
  -- Electrode map.
  --
  -- Identity today: index = chip * CH_PER_CHIP + channel, which is simply
  -- what the SPI topology hands over. A planar MEA's electrode numbering
  -- does not follow chip boundaries -- electrode 47 is not necessarily chip
  -- 1 channel 15 -- so the real map replaces this body and nothing else in
  -- the design changes.
  ------------------------------------------------------------------------

  function electrode_index (
    chip : natural;
    ch   : unsigned(5 downto 0)
  ) return natural is
  begin

    return chip * CH_PER_CHIP + to_integer(ch);

  end function electrode_index;

  signal buf : frame_buf_t;

  signal wr_bank  : std_logic;
  signal wr_busy  : std_logic;
  signal wr_lane  : natural range 0 to 15;
  signal lat_data : std_logic_vector(chip_count * 16 - 1 downto 0);
  signal lat_ch   : unsigned(5 downto 0);
  signal lat_last : std_logic;

  signal frame_valid_r : std_logic;
  signal frame_index_r : unsigned(31 downto 0);
  signal overrun_r     : std_logic;
  signal rd_data_r     : std_logic_vector(15 downto 0);

begin

  assert total_channels <= 256
    report "TOTAL_CHANNELS exceeds the 8-bit read address"
    severity failure;

  assert CHIP_COUNT <= 16
    report "CHIP_COUNT exceeds the lane counter range"
    severity failure;

  ------------------------------------------------------------------------
  -- Write side
  ------------------------------------------------------------------------

  writer : process (clk) is

    variable widx : natural;

  begin

    if rising_edge(clk) then
      if (rst_n = '0') then
        wr_bank       <= '0';
        wr_busy       <= '0';
        wr_lane       <= 0;
        lat_data      <= (others => '0');
        lat_ch        <= (others => '0');
        lat_last      <= '0';
        frame_valid_r <= '0';
        frame_index_r <= (others => '0');
        overrun_r     <= '0';
      else
        frame_valid_r <= '0';

        ----------------------------------------------------------------
        -- Accept a slot. Auxiliary channels are not part of the frame;
        -- they are routed by whatever consumes slot_is_aux, not here.
        ----------------------------------------------------------------
        if ((slot_valid = '1') and (slot_is_aux = '0')) then
          if (wr_busy = '1') then
            overrun_r <= '1';
          else
            lat_data <= slot_data;
            lat_ch   <= slot_channel;
            lat_last <= slot_last;
            wr_lane  <= 0;
            wr_busy  <= '1';
          end if;
        elsif (wr_busy = '1') then
          ----------------------------------------------------------------
          -- One lane per clock into the bank being written.
          ----------------------------------------------------------------
          widx := electrode_index(wr_lane, lat_ch);

          if (wr_bank = '1') then
            widx := widx + total_channels;
          end if;

          buf(widx) <= lat_data(wr_lane * 16 + 15 downto wr_lane * 16);

          if (wr_lane = chip_count - 1) then
            wr_busy <= '0';

            -- The frame closes on the last amplifier channel. Flipping the
            -- bank here is what hands the completed frame to the read port.
            if (lat_last = '1') then
              wr_bank       <= not wr_bank;
              frame_index_r <= frame_index_r + 1;
              frame_valid_r <= '1';
            end if;
          else
            wr_lane <= wr_lane + 1;
          end if;
        end if;
      end if;
    end if;

  end process writer;

  ------------------------------------------------------------------------
  -- Read side. Always addresses the bank not being written, so the frame
  -- last announced by frame_valid stays intact for a full sweep.
  ------------------------------------------------------------------------

  reader : process (clk) is

    variable ridx : natural;

  begin

    if rising_edge(clk) then
      if (rst_n = '0') then
        rd_data_r <= (others => '0');
      elsif (rd_en = '1') then
        ridx := to_integer(rd_addr);

        if (wr_bank = '0') then
          ridx := ridx + total_channels;
        end if;

        rd_data_r <= buf(ridx);
      end if;
    end if;

  end process reader;

  frame_valid <= frame_valid_r;
  frame_index <= frame_index_r;
  rd_data     <= rd_data_r;
  overrun     <= overrun_r;

end architecture rtl;

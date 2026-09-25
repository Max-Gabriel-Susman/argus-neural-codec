--------------------------------------------------------------------------------
-- tb_argus_frame_assembler.vhd
--
-- End-to-end: the SPI master drives three argus_rhd2132_model instances, the
-- assembler collects their slot stream, and the completed frames are read
-- back and checked word by word.
--
-- WHAT THIS ADDS OVER tb_argus_rhd_spi_master
--
--   1. ELECTRODE MAPPING. Frame word n must carry the sample for the chip
--      and channel that electrode_index() maps n to. With the identity map
--      that is chip n/32, channel n mod 32 -- but the check is written
--      against the mapping, so it keeps working when a real MEA pinout
--      replaces it.
--
--   2. DOUBLE BUFFERING. A frame is read immediately after frame_valid and
--      again most of a sweep later. The two reads must agree: if the writer
--      were clobbering the bank being read, the second read would show the
--      next sweep's sample index bleeding in.
--
--   3. FRAME INDEX. Must advance by exactly one per sweep. A missed or
--      duplicated frame_valid shows up here and nowhere else.
--
--   4. AUXILIARY EXCLUSION. The three aux slots must not disturb the frame.
--      Covered implicitly: a frame whose words all carry the right sample
--      index cannot have had an aux word written into it.
--
-- Run: make tb_argus_frame_assembler   (from sim/)
--------------------------------------------------------------------------------

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity tb_argus_frame_assembler is
end entity tb_argus_frame_assembler;

architecture sim of tb_argus_frame_assembler is

  constant chip_count  : natural := 3;
  constant ch_per_chip : natural := 32;
  constant aux_slots   : natural := 3;
  constant slot_clocks : natural := 119;
  constant sclk_div    : natural := 5;

  constant total_channels : natural := chip_count * ch_per_chip;

  constant clk_period : time    := 8 ns;
  constant frames     : natural := 4;

  signal clk    : std_logic := '0';
  signal rst_n  : std_logic := '0';
  signal enable : std_logic := '0';

  signal sclk : std_logic;
  signal cs_n : std_logic;
  signal mosi : std_logic;
  signal miso : std_logic_vector(chip_count - 1 downto 0);

  signal miso_oe : std_logic_vector(chip_count - 1 downto 0);

  signal slot_valid   : std_logic;
  signal slot_channel : unsigned(5 downto 0);
  signal slot_data    : std_logic_vector(chip_count * 16 - 1 downto 0);
  signal slot_is_aux  : std_logic;
  signal slot_last    : std_logic;
  signal ready        : std_logic;

  signal frame_valid : std_logic;
  signal frame_index : unsigned(31 downto 0);
  signal rd_en       : std_logic            := '0';
  signal rd_addr     : unsigned(7 downto 0) := (others => '0');
  signal rd_data     : std_logic_vector(15 downto 0);
  signal overrun     : std_logic;

  signal sim_done : boolean := false;
  signal errors   : natural := 0;

  function hex4 (
    v : std_logic_vector(15 downto 0)
  ) return string is

    constant digits : string(1 to 16) := "0123456789ABCDEF";
    variable s      : string(1 to 4);
    variable nib    : integer;

  begin

    for i in 0 to 3 loop

      nib      := to_integer(unsigned(v(15 - 4 * i downto 12 - 4 * i)));
      s(i + 1) := DIGITS(nib + 1);

    end loop;

    return s;

  end function hex4;

  -- Mirrors electrode_index() in the assembler. Kept separate on purpose: if
  -- the two disagree the test fails, which is the point.

  function expect_chip (
    idx : natural
  ) return natural is
  begin

    return idx / CH_PER_CHIP;

  end function expect_chip;

  function expect_channel (
    idx : natural
  ) return unsigned is
  begin

    return to_unsigned(idx mod CH_PER_CHIP, 6);

  end function expect_channel;

  -- IDENT layout, from the specification rather than from the model.

  function ident_word (
    chip : natural;
    ch   : unsigned(5 downto 0);
    idx  : unsigned(7 downto 0)
  ) return std_logic_vector is
  begin

    return std_logic_vector(to_unsigned(chip mod 4, 2))
           & std_logic_vector(ch)
           & std_logic_vector(idx);

  end function ident_word;

begin

  clk <= not clk after clk_period / 2 when not sim_done else
         '0';

  master : entity work.argus_rhd_spi_master
    generic map (
      chip_count  => CHIP_COUNT,
      ch_per_chip => CH_PER_CHIP,
      aux_slots   => AUX_SLOTS,
      slot_clocks => SLOT_CLOCKS,
      sclk_div    => SCLK_DIV
    )
    port map (
      clk          => clk,
      rst_n        => rst_n,
      enable       => enable,
      sclk         => sclk,
      cs_n         => cs_n,
      mosi         => mosi,
      miso         => miso,
      slot_valid   => slot_valid,
      slot_channel => slot_channel,
      slot_data    => slot_data,
      slot_is_aux  => slot_is_aux,
      slot_last    => slot_last,
      ready        => ready
    );

  chips : for c in 0 to chip_count - 1 generate

    chip_inst : entity work.argus_rhd2132_model
      generic map (
        ch_per_chip  => CH_PER_CHIP,
        chip_id      => c,
        chip_type_id => 1,
        pattern      => 0
      )
      port map (
        clk           => clk,
        rst_n         => rst_n,
        sclk          => sclk,
        cs_n          => cs_n,
        mosi          => mosi,
        miso          => miso(c),
        miso_oe       => miso_oe(c),
        dbg_last_cmd  => open,
        dbg_cmd_valid => open,
        dbg_last_resp => open
      );

  end generate chips;

  assembler : entity work.argus_frame_assembler
    generic map (
      chip_count  => CHIP_COUNT,
      ch_per_chip => CH_PER_CHIP
    )
    port map (
      clk          => clk,
      rst_n        => rst_n,
      slot_valid   => slot_valid,
      slot_channel => slot_channel,
      slot_data    => slot_data,
      slot_is_aux  => slot_is_aux,
      slot_last    => slot_last,
      frame_valid  => frame_valid,
      frame_index  => frame_index,
      rd_en        => rd_en,
      rd_addr      => rd_addr,
      rd_data      => rd_data,
      overrun      => overrun
    );

  ------------------------------------------------------------------------
  -- Checker
  ------------------------------------------------------------------------

  checker : process is

    variable frame     : natural := 0;
    variable errs      : natural := 0;
    variable frame_idx : unsigned(7 downto 0);
    variable prev_fi   : unsigned(31 downto 0);
    variable have_fi   : boolean := false;
    variable first     : std_logic_vector(15 downto 0);
    variable second    : std_logic_vector(15 downto 0);
    variable want      : std_logic_vector(15 downto 0);

    -- Registered read: assert the address, wait a clock, then sample.

    procedure read_word (
      idx : in    natural;
      w   : out   std_logic_vector(15 downto 0)
    ) is
    begin

      rd_addr <= to_unsigned(idx, 8);
      rd_en   <= '1';
      wait until rising_edge(clk);
      rd_en   <= '0';
      wait until rising_edge(clk);
      w       := rd_data;

    end procedure read_word;

  begin

    rst_n  <= '0';
    wait for 20 * clk_period;
    rst_n  <= '1';
    wait for 20 * clk_period;
    enable <= '1';

    wait until ready = '1';
    report "master ready; collecting frames";

    while frame < frames loop

      wait until rising_edge(clk) and frame_valid = '1';

      if (have_fi and (frame_index /= prev_fi + 1)) then
        errs := errs + 1;
        report "FAIL frame index " & integer'image(to_integer(frame_index))
               & " does not follow " & integer'image(to_integer(prev_fi))
          severity error;
      end if;

      prev_fi := frame_index;
      have_fi := true;

      -- First pass. Word 0 sets the sample index the whole frame must share.
      read_word(0, first);
      frame_idx := unsigned(first(7 downto 0));

      for n in 0 to total_channels - 1 loop

        read_word(n, first);
        want := ident_word(expect_chip(n), expect_channel(n), frame_idx);

        if (first /= want) then
          errs := errs + 1;
          report "FAIL frame " & integer'image(frame)
                 & " word " & integer'image(n)
                 & ": " & hex4(first)
                 & ", expected " & hex4(want)
            severity error;
        end if;

      end loop;

      -- Second pass, most of a sweep later. The writer is well into the next
      -- frame by now; a single-buffered design would show its sample index
      -- bleeding into these reads.
      wait for 25 us;

      for n in 0 to total_channels - 1 loop

        read_word(n, second);
        want := ident_word(expect_chip(n), expect_channel(n), frame_idx);

        if (second /= want) then
          errs := errs + 1;
          report "FAIL frame " & integer'image(frame)
                 & " word " & integer'image(n)
                 & " disturbed by the next sweep: " & hex4(second)
                 & ", expected " & hex4(want)
            severity error;
        end if;

      end loop;

      errors <= errs;
      frame  := frame + 1;

    end loop;

    if (overrun /= '0') then
      errs := errs + 1;
      report "FAIL assembler reported overrun"
        severity error;
    end if;

    errors <= errs;
    wait for 1 ns;

    report "checked " & integer'image(frames) & " frames of "
           & integer'image(total_channels) & " channels";

    if (errors = 0) then
      report "PASS: electrode mapping, double buffering and frame indexing verified";
    else
      report "FAIL: " & integer'image(errors) & " error(s)"
        severity failure;
    end if;

    sim_done <= true;
    wait;

  end process checker;

  watchdog : process is
  begin

    wait for 20 ms;

    if (not sim_done) then
      report "FAIL: timeout"
        severity failure;
    end if;

    wait;

  end process watchdog;

end architecture sim;

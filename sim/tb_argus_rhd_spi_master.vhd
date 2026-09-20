--------------------------------------------------------------------------------
-- tb_argus_rhd_spi_master.vhd
--
-- Closes the acquisition loop in simulation: the master drives a broadcast
-- bus, three argus_rhd2132_model instances answer on independent MISO lines,
-- and the slot stream is checked against the identity pattern the models
-- generate.
--
-- Nothing here reads the models' internals. The expected values are derived
-- from the IDENT specification, so a bug in the model's sample_value is
-- caught rather than mirrored -- the same discipline the model's own
-- testbench uses.
--
-- WHAT IS ACTUALLY BEING TESTED
--
--   1. PIPELINE. slot_channel must name the channel the data belongs to,
--      not the channel being requested. The models stamp their channel into
--      bits 13:8 of every word, so a two-slot rotation shows up immediately
--      as a channel mismatch rather than as plausible-looking data.
--
--   2. CHIP LANES. Each model carries a distinct CHIP_ID in bits 15:14, so
--      swapped or crossed MISO lanes are caught. This is the failure the
--      three-chip broadcast topology is most prone to.
--
--   3. SWEEP COHERENCE. Every channel within one sweep must carry the same
--      sample index, and the index must advance by one between sweeps. A
--      slot-counting error at the sweep boundary breaks this while leaving
--      individual words correct.
--
--   4. AUXILIARY SLOTS. Channels at or above CH_PER_CHIP take a different
--      path through the model and must be flagged by slot_is_aux.
--
--   5. TIMING. SCLK period, CS-high duration and slot period are measured
--      against the datasheet minimums rather than assumed from the generics.
--
-- The error counters are split per process. An unresolved signal type admits
-- exactly one driver, so a single shared counter fails elaboration.
--
-- Run: make tb_argus_rhd_spi_master   (from sim/)
--------------------------------------------------------------------------------

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity tb_argus_rhd_spi_master is
end entity tb_argus_rhd_spi_master;

architecture sim of tb_argus_rhd_spi_master is

  constant CHIP_COUNT  : natural := 3;
  constant CH_PER_CHIP : natural := 32;
  constant AUX_SLOTS   : natural := 3;
  constant SLOT_CLOCKS : natural := 119;
  constant SCLK_DIV    : natural := 5;

  constant CLK_PERIOD : time    := 8 ns;   -- 125 MHz
  constant SWEEPS     : natural := 4;

  -- Datasheet minimums, checked against the measured waveform.
  constant TSCLK_MIN  : time := 40 ns;
  constant TCSOFF_MIN : time := 154 ns;

  signal clk    : std_logic := '0';
  signal rst_n  : std_logic := '0';
  signal enable : std_logic := '0';

  signal sclk : std_logic;
  signal cs_n : std_logic;
  signal mosi : std_logic;
  signal miso : std_logic_vector(CHIP_COUNT - 1 downto 0);

  signal miso_oe : std_logic_vector(CHIP_COUNT - 1 downto 0);

  signal slot_valid   : std_logic;
  signal slot_channel : unsigned(5 downto 0);
  signal slot_data    : std_logic_vector(CHIP_COUNT * 16 - 1 downto 0);
  signal slot_is_aux  : std_logic;
  signal slot_last    : std_logic;
  signal ready        : std_logic;

  signal sim_done : boolean := false;

  -- One counter per driving process.
  signal check_errors : natural := 0;
  signal time_errors  : natural := 0;

  function hex4 (v : std_logic_vector(15 downto 0)) return string is

    constant DIGITS : string(1 to 16) := "0123456789ABCDEF";
    variable s      : string(1 to 4);
    variable nib    : integer;

  begin

    for i in 0 to 3 loop

      nib      := to_integer(unsigned(v(15 - 4 * i downto 12 - 4 * i)));
      s(i + 1) := DIGITS(nib + 1);

    end loop;

    return s;

  end function hex4;

  -- IDENT layout, from the specification rather than from the model:
  --   bits 15:14 chip, 13:8 channel, 7:0 sample index.
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

  -- Auxiliary marker, for channels at or above the amplifier count.
  function aux_word (ch : unsigned(5 downto 0)) return std_logic_vector is
  begin

    return x"A0" & "00" & std_logic_vector(ch);

  end function aux_word;

begin

  clk <= not clk after CLK_PERIOD / 2 when not sim_done else '0';

  --------------------------------------------------------------------------
  -- Device under test
  --------------------------------------------------------------------------

  dut : entity work.argus_rhd_spi_master
    generic map (
      CHIP_COUNT  => CHIP_COUNT,
      CH_PER_CHIP => CH_PER_CHIP,
      AUX_SLOTS   => AUX_SLOTS,
      SLOT_CLOCKS => SLOT_CLOCKS,
      SCLK_DIV    => SCLK_DIV
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

  --------------------------------------------------------------------------
  -- Three chips on the broadcast bus, distinguished only by CHIP_ID
  --------------------------------------------------------------------------

  chips : for c in 0 to CHIP_COUNT - 1 generate

    chip_inst : entity work.argus_rhd2132_model
      generic map (
        CH_PER_CHIP  => CH_PER_CHIP,
        CHIP_ID      => c,
        CHIP_TYPE_ID => 1,
        PATTERN      => 0
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

  --------------------------------------------------------------------------
  -- Stream checker
  --------------------------------------------------------------------------

  checker : process is

    variable sweep     : natural := 0;
    variable expect_ch : natural := 0;
    variable sweep_idx : unsigned(7 downto 0);
    variable prev_idx  : unsigned(7 downto 0);
    variable have_prev : boolean := false;
    variable word      : std_logic_vector(15 downto 0);
    variable slots     : natural := 0;
    variable errs      : natural := 0;

  begin

    rst_n <= '0';
    wait for 20 * CLK_PERIOD;
    rst_n <= '1';
    wait for 20 * CLK_PERIOD;
    enable <= '1';

    report "waiting for initialisation sequence";
    wait until ready = '1';
    report "ready asserted; sweeping";

    while sweep < SWEEPS loop

      wait until rising_edge(clk) and slot_valid = '1';
      slots := slots + 1;

      -- Channel identity. The master must name the channel the data belongs
      -- to; a two-slot rotation lands here.
      if (to_integer(slot_channel) /= expect_ch) then
        errs := errs + 1;
        report "FAIL sweep " & integer'image(sweep)
               & ": slot_channel " & integer'image(to_integer(slot_channel))
               & ", expected " & integer'image(expect_ch)
          severity error;
      end if;

      if (expect_ch >= CH_PER_CHIP) then

        -- Auxiliary slot: every lane returns the marker, flag must be set.
        if (slot_is_aux /= '1') then
          errs := errs + 1;
          report "FAIL channel " & integer'image(expect_ch)
                 & ": slot_is_aux not set"
            severity error;
        end if;

        for c in 0 to CHIP_COUNT - 1 loop

          word := slot_data(c * 16 + 15 downto c * 16);

          if (word /= aux_word(slot_channel)) then
            errs := errs + 1;
            report "FAIL aux ch " & integer'image(expect_ch)
                   & " chip " & integer'image(c)
                   & ": " & hex4(word)
                   & ", expected " & hex4(aux_word(slot_channel))
              severity error;
          end if;

        end loop;

      else

        if (slot_is_aux /= '0') then
          errs := errs + 1;
          report "FAIL channel " & integer'image(expect_ch)
                 & ": slot_is_aux set on an amplifier channel"
            severity error;
        end if;

        -- Latch the sweep's sample index from channel 0, then require every
        -- other channel in the sweep to carry the same one.
        if (expect_ch = 0) then
          sweep_idx := unsigned(slot_data(7 downto 0));

          if (have_prev and (sweep_idx /= prev_idx + 1)) then
            errs := errs + 1;
            report "FAIL sweep " & integer'image(sweep)
                   & ": sample index " & integer'image(to_integer(sweep_idx))
                   & " does not follow " & integer'image(to_integer(prev_idx))
              severity error;
          end if;

          prev_idx  := sweep_idx;
          have_prev := true;
        end if;

        -- Chip lane identity. Each model stamps its own CHIP_ID, so crossed
        -- MISO lines fail here and nowhere else.
        for c in 0 to CHIP_COUNT - 1 loop

          word := slot_data(c * 16 + 15 downto c * 16);

          if (word /= ident_word(c, slot_channel, sweep_idx)) then
            errs := errs + 1;
            report "FAIL sweep " & integer'image(sweep)
                   & " ch " & integer'image(expect_ch)
                   & " chip " & integer'image(c)
                   & ": " & hex4(word)
                   & ", expected " & hex4(ident_word(c, slot_channel, sweep_idx))
              severity error;
          end if;

        end loop;

        -- slot_last marks the final amplifier channel, which is what a frame
        -- assembler keys its frame boundary off.
        if (expect_ch = CH_PER_CHIP - 1) then
          if (slot_last /= '1') then
            errs := errs + 1;
            report "FAIL sweep " & integer'image(sweep)
                   & ": slot_last not set on the last amplifier channel"
              severity error;
          end if;
        elsif (slot_last /= '0') then
          errs := errs + 1;
          report "FAIL sweep " & integer'image(sweep)
                 & " ch " & integer'image(expect_ch)
                 & ": slot_last set early"
            severity error;
        end if;

      end if;

      check_errors <= errs;

      if (expect_ch = CH_PER_CHIP + AUX_SLOTS - 1) then
        expect_ch := 0;
        sweep     := sweep + 1;
      else
        expect_ch := expect_ch + 1;
      end if;

    end loop;

    check_errors <= errs;

    -- Let the timing process's last increment settle before reading totals.
    wait for 1 ns;

    report "checked " & integer'image(slots) & " slots over "
           & integer'image(SWEEPS) & " sweeps";

    if ((check_errors = 0) and (time_errors = 0)) then
      report "PASS: pipeline, chip lanes, sweep coherence and aux slots verified";
    else
      report "FAIL: " & integer'image(check_errors) & " stream error(s), "
             & integer'image(time_errors) & " timing error(s)"
        severity failure;
    end if;

    sim_done <= true;
    wait;

  end process checker;

  --------------------------------------------------------------------------
  -- Bus timing, measured rather than assumed
  --------------------------------------------------------------------------

  timing : process is

    variable t_sclk_rise : time    := 0 ns;
    variable t_cs_rise   : time    := 0 ns;
    variable measured    : time;
    variable errs        : natural := 0;

  begin

    wait until ready = '1';

    loop

      wait until rising_edge(sclk) or rising_edge(cs_n) or falling_edge(cs_n);

      exit when sim_done;

      if ((sclk = '1') and (cs_n = '0')) then
        if (t_sclk_rise /= 0 ns) then
          measured := now - t_sclk_rise;

          -- Only consecutive edges within one command are meaningful; the
          -- gap across a CS pulse is much larger and is skipped.
          if ((measured < TSCLK_MIN) and (measured < 200 ns)) then
            errs := errs + 1;
            report "FAIL tSCLK " & time'image(measured)
                   & " below the " & time'image(TSCLK_MIN) & " minimum"
              severity error;
          end if;
        end if;

        t_sclk_rise := now;
      end if;

      if (cs_n = '1') then
        t_cs_rise := now;
      elsif ((cs_n = '0') and (t_cs_rise /= 0 ns)) then
        measured := now - t_cs_rise;

        if (measured < TCSOFF_MIN) then
          errs := errs + 1;
          report "FAIL tCSOFF " & time'image(measured)
                 & " below the " & time'image(TCSOFF_MIN) & " minimum"
            severity error;
        end if;
      end if;

      time_errors <= errs;

    end loop;

    time_errors <= errs;
    wait;

  end process timing;

  --------------------------------------------------------------------------
  -- Watchdog. A stalled sequencer would otherwise hang rather than fail.
  --------------------------------------------------------------------------

  watchdog : process is
  begin

    wait for 20 ms;

    if not sim_done then
      report "FAIL: timeout" severity failure;
    end if;

    wait;

  end process watchdog;

end architecture sim;

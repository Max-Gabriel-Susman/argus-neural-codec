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
-- caught rather than mirrored.
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
--      sample index, and the index must advance by one between sweeps.
--
--   4. AUXILIARY SLOTS. Channels at or above CH_PER_CHIP take a different
--      path through the model and must be flagged by slot_is_aux.
--
--   5. TIMING. SCLK period and CS-high duration are measured against the
--      datasheet minimums rather than assumed from the generics.
--
-- To confirm check 5 actually fires, set SCLK_DIV to 4 below and re-run: a
-- 32 ns SCLK against a 40 ns minimum must produce FAIL lines. A check that
-- has never failed is not yet known to work.
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

  constant chip_count  : natural := 3;
  constant ch_per_chip : natural := 32;
  constant aux_slots   : natural := 3;
  constant slot_clocks : natural := 119;
  constant sclk_div    : natural := 5;

  constant clk_period : time    := 8 ns;   -- 125 MHz
  constant sweeps     : natural := 4;

  -- Datasheet minimums, checked against the measured waveform.
  constant tsclk_min  : time := 40 ns;
  constant tcsoff_min : time := 154 ns;

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

  signal sim_done : boolean := false;

  -- One counter per driving process.
  signal check_errors : natural := 0;
  signal time_errors  : natural := 0;

  -- Proves the timing process saw the bus at all, rather than silently
  -- never firing and reporting zero errors.
  signal sclk_edges : natural := 0;
  signal cs_gaps    : natural := 0;

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

  function aux_word (
    ch : unsigned(5 downto 0)
  ) return std_logic_vector is
  begin

    return x"A0" & "00" & std_logic_vector(ch);

  end function aux_word;

begin

  clk <= not clk after clk_period / 2 when not sim_done else
         '0';

  ------------------------------------------------------------------------
  -- Device under test
  ------------------------------------------------------------------------

  dut : entity work.argus_rhd_spi_master
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

  ------------------------------------------------------------------------
  -- Three chips on the broadcast bus, distinguished only by CHIP_ID
  ------------------------------------------------------------------------

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

  ------------------------------------------------------------------------
  -- Stream checker
  ------------------------------------------------------------------------

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

    rst_n  <= '0';
    wait for 20 * clk_period;
    rst_n  <= '1';
    wait for 20 * clk_period;
    enable <= '1';

    report "waiting for initialisation sequence";
    wait until ready = '1';
    report "ready asserted; sweeping";

    while sweep < sweeps loop

      wait until rising_edge(clk) and slot_valid = '1';
      slots := slots + 1;

      if (to_integer(slot_channel) /= expect_ch) then
        errs := errs + 1;
        report "FAIL sweep " & integer'image(sweep)
               & ": slot_channel " & integer'image(to_integer(slot_channel))
               & ", expected " & integer'image(expect_ch)
          severity error;
      end if;

      if (expect_ch >= ch_per_chip) then
        if (slot_is_aux /= '1') then
          errs := errs + 1;
          report "FAIL channel " & integer'image(expect_ch)
                 & ": slot_is_aux not set"
            severity error;
        end if;

        for c in 0 to chip_count - 1 loop

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

        for c in 0 to chip_count - 1 loop

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

        if (expect_ch = ch_per_chip - 1) then
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

      if (expect_ch = ch_per_chip + aux_slots - 1) then
        expect_ch := 0;
        sweep     := sweep + 1;
      else
        expect_ch := expect_ch + 1;
      end if;

    end loop;

    check_errors <= errs;

    -- Let the timing process's last update settle before reading totals.
    wait for 1 ns;

    report "checked " & integer'image(slots) & " slots over "
           & integer'image(sweeps) & " sweeps";
    report "timing: " & integer'image(sclk_edges) & " SCLK edges, "
           & integer'image(cs_gaps) & " CS gaps measured";

    -- A timing process that never fired would report zero errors and look
    -- like a pass.
    if ((sclk_edges = 0) or (cs_gaps = 0)) then
      report "FAIL: timing process never observed the bus"
        severity failure;
    end if;

    if ((check_errors = 0) and (time_errors = 0)) then
      report "PASS: pipeline, chip lanes, sweep coherence, aux slots and timing verified";
    else
      report "FAIL: " & integer'image(check_errors) & " stream error(s), "
             & integer'image(time_errors) & " timing error(s)"
        severity failure;
    end if;

    sim_done <= true;
    wait;

  end process checker;

  ------------------------------------------------------------------------
  -- Bus timing, sampled in the clock domain
  --
  -- Everything is sampled on clk rather than waited on with edge functions.
  -- A single wait listing three edge conditions resolves its disambiguating
  -- level test a delta after the edge, by which point the signals have
  -- moved -- so no edge is ever recognised and the check silently never
  -- fires. Counting clocks is deterministic and needs no disambiguation.
  ------------------------------------------------------------------------

  timing : process (clk) is

    variable sclk_q     : std_logic := '0';
    variable cs_q       : std_logic := '1';
    variable since_sclk : natural   := 0;
    variable since_cs   : natural   := 0;
    variable have_sclk  : boolean   := false;
    variable have_cs    : boolean   := false;
    variable errs       : natural   := 0;
    variable n_sclk     : natural   := 0;
    variable n_cs       : natural   := 0;
    variable measured   : time;

  begin

    if rising_edge(clk) then
      if (ready = '1') then
        since_sclk := since_sclk + 1;
        since_cs   := since_cs + 1;

        -- Rising SCLK edge while a chip is selected.
        if ((sclk = '1') and (sclk_q = '0') and (cs_n = '0')) then
          if (have_sclk) then
            measured := since_sclk * clk_period;
            n_sclk   := n_sclk + 1;

            if (measured < tsclk_min) then
              errs := errs + 1;
              report "FAIL tSCLK " & time'image(measured)
                     & " below the " & time'image(tsclk_min) & " minimum"
                severity error;
            end if;
          end if;

          have_sclk  := true;
          since_sclk := 0;
        end if;

        -- CS rising: the inter-command gap opens. The SCLK interval across
        -- that gap spans two commands and is not a tSCLK.
        if ((cs_n = '1') and (cs_q = '0')) then
          have_cs   := true;
          since_cs  := 0;
          have_sclk := false;
        end if;

        -- CS falling: the gap closes.
        if ((cs_n = '0') and (cs_q = '1')) then
          if (have_cs) then
            measured := since_cs * clk_period;
            n_cs     := n_cs + 1;

            if (measured < tcsoff_min) then
              errs := errs + 1;
              report "FAIL tCSOFF " & time'image(measured)
                     & " below the " & time'image(tcsoff_min) & " minimum"
                severity error;
            end if;
          end if;
        end if;

        time_errors <= errs;
        sclk_edges  <= n_sclk;
        cs_gaps     <= n_cs;
      end if;

      sclk_q := sclk;
      cs_q   := cs_n;
    end if;

  end process timing;

  ------------------------------------------------------------------------
  -- Watchdog. A stalled sequencer would otherwise hang rather than fail.
  ------------------------------------------------------------------------

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

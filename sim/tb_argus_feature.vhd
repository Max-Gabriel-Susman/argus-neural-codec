--------------------------------------------------------------------------------
-- tb_argus_feature.vhd
--
-- The feature block against the model. Real cortex in, and every bin the
-- block produces is compared to what spike_features.py computed for the
-- same samples with the same arithmetic. The model is bit-exact, so the
-- pass criterion is zero mismatches across every (bin, channel) for both
-- count and power.
--
-- INPUTS, both produced by argus_sim/tools/spike_features.py from the same
-- .bin with the same parameters as the DUT generics:
--
--   stim_file    one line per sweep, 96 integer ADC codes  (--stim)
--   golden_file  "bin ch count power" per line, '#' header (--golden)
--
-- python3 spike_features.py indy_20161005_06_s120_10s.bin --mult 3.5 \
--     --golden feature_golden.txt --stim feature_stim.txt --stim-rows 48000
--
-- The golden is for the full file; this bench feeds the first n_sweeps rows
-- and checks bins 0 .. n_sweeps/bin_len - 1. Processing is causal, so those
-- bins are identical to a run on the prefix alone. 48000 sweeps is 32 bins,
-- ten of them after warm-up.
--
-- DRIVE
--   Each sweep is 32 amplifier slots then 3 aux slots with slot_last on the
--   third, as the master emits them. Slots are slot_gap clocks apart rather
--   than the master's 119, to keep the run short; the block must be idle
--   when each slot arrives, and the bench checks that it is.
--
-- CHECK
--   A checker process watches feature_index. Each time it advances, the
--   bench holds the bank, reads all 96 channels through the registered read
--   port, releases, and compares against the golden for that bin. Bins are
--   1500 sweeps apart and a read is ~200 clocks, so the checker never falls
--   behind, and dropped must read 0 at the end.
--
-- Run from sim/:  make tb_argus_feature
--   or:           ghdl -r --std=08 tb_argus_feature -gstim_file=... -ggolden_file=...
--------------------------------------------------------------------------------

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use std.textio.all;

entity tb_argus_feature is
  generic (
    stim_file   : string  := "feature_stim.txt";
    golden_file : string  := "feature_golden.txt";
    n_sweeps    : natural := 48000;
    slot_gap    : natural := 36;
    -- DUT parameters; must match the golden's header
    b0            : integer := 31932;
    a1            : integer := 31096;
    mult_num      : natural := 49;
    mult_shift    : natural := 2;
    ms_shift      : natural := 15;
    ms_shift_fast : natural := 8;
    refrac_len    : natural := 30;
    warmup        : natural := 32768;
    bin_len       : natural := 1500
  );
end entity tb_argus_feature;

architecture sim of tb_argus_feature is

  constant chip_count  : natural := 3;
  constant ch_per_chip : natural := 32;
  constant aux_slots   : natural := 3;
  constant channels    : natural := chip_count * ch_per_chip;
  constant n_bins      : natural := n_sweeps / bin_len;
  constant clk_period  : time    := 8 ns;

  signal clk   : std_logic := '0';
  signal rst_n : std_logic := '0';

  signal slot_valid   : std_logic                                      := '0';
  signal slot_channel : unsigned(5 downto 0)                           := (others => '0');
  signal slot_data    : std_logic_vector(chip_count * 16 - 1 downto 0) := (others => '0');
  signal slot_is_aux  : std_logic                                      := '0';
  signal slot_last    : std_logic                                      := '0';

  signal hold : std_logic := '0';
  signal held : std_logic;

  signal feature_index : unsigned(31 downto 0);
  signal dropped       : unsigned(15 downto 0);
  signal busy          : std_logic;

  signal rd_en    : std_logic            := '0';
  signal rd_addr  : unsigned(6 downto 0) := (others => '0');
  signal rd_count : unsigned(15 downto 0);
  signal rd_power : unsigned(47 downto 0);

  signal stim_done : boolean := false;
  signal sim_done  : boolean := false;
  signal errors    : natural := 0;

  -- Golden, bins 0 .. n_bins-1

  type cnt_arr_t is array (0 to n_bins - 1, 0 to channels - 1) of natural;

  type pow_arr_t is array (0 to n_bins - 1, 0 to channels - 1) of unsigned(47 downto 0);

  function hex12 (
    v : unsigned(47 downto 0)
  ) return string is

    constant digits : string(1 to 16) := "0123456789ABCDEF";
    variable s      : string(1 to 12);
    variable nib    : integer;

  begin

    for i in 0 to 11 loop

      nib      := to_integer(v(47 - 4 * i downto 44 - 4 * i));
      s(i + 1) := digits(nib + 1);

    end loop;

    return s;

  end function hex12;

  -- Decimal up to 2^48 from a textio line; integer would overflow at 2^31.

  procedure read_u48 (
    l : inout line;
    v : out   unsigned(47 downto 0)
  ) is

    variable c    : character;
    variable good : boolean;
    variable acc  : unsigned(47 downto 0) := (others => '0');

  begin

    loop

      read(l, c, good);
      exit when not good or c /= ' ';

    end loop;

    while good and c >= '0' and c <= '9' loop

      acc := resize(acc * 10, 48) + to_unsigned(character'pos(c) - character'pos('0'), 48);
      read(l, c, good);

    end loop;

    v := acc;

  end procedure read_u48;

begin

  clk <= not clk after clk_period / 2 when not sim_done else
         '0';

  dut : entity work.argus_feature(rtl)
    generic map (
      chip_count    => chip_count,
      ch_per_chip   => ch_per_chip,
      b0            => b0,
      a1            => a1,
      mult_num      => mult_num,
      mult_shift    => mult_shift,
      ms_shift      => ms_shift,
      ms_shift_fast => ms_shift_fast,
      refrac_len    => refrac_len,
      warmup        => warmup,
      bin_len       => bin_len
    )
    port map (
      clk           => clk,
      rst_n         => rst_n,
      slot_valid    => slot_valid,
      slot_channel  => slot_channel,
      slot_data     => slot_data,
      slot_is_aux   => slot_is_aux,
      slot_last     => slot_last,
      hold          => hold,
      held          => held,
      feature_index => feature_index,
      dropped       => dropped,
      busy          => busy,
      rd_en         => rd_en,
      rd_addr       => rd_addr,
      rd_count      => rd_count,
      rd_power      => rd_power
    );

  ------------------------------------------------------------------------
  -- Stimulus: the .bin rows as slots
  ------------------------------------------------------------------------

  stim : process is

    file     f    : text;
    variable st   : file_open_status;
    variable l    : line;
    variable v    : integer;
    variable row  : integer_vector(0 to channels - 1);
    variable sw   : natural := 0;
    variable word : std_logic_vector(15 downto 0);

  begin

    rst_n <= '0';
    wait for 20 * clk_period;
    rst_n <= '1';
    -- Reset zeroes 288 RAM entries before the block accepts slots.
    wait for 400 * clk_period;

    file_open(st, f, stim_file, read_mode);

    if (st /= open_ok) then
      report "FAIL: cannot open stimulus " & stim_file
        severity failure;
    end if;

    report "feeding " & integer'image(n_sweeps) & " sweeps from " & stim_file;

    while (sw < n_sweeps) and not endfile(f) loop

      readline(f, l);

      for c in 0 to channels - 1 loop

        read(l, v);
        row(c) := v;

      end loop;

      -- 32 amplifier slots: chip 0 in the low lane.
      for ch in 0 to ch_per_chip - 1 loop

        for c in 0 to chip_count - 1 loop

          word                                 := std_logic_vector(to_unsigned(row(c * ch_per_chip + ch), 16));
          slot_data(c * 16 + 15 downto c * 16) <= word;

        end loop;

        slot_channel <= to_unsigned(ch, 6);
        slot_is_aux  <= '0';
        slot_last    <= '0';
        slot_valid   <= '1';
        wait until rising_edge(clk);
        slot_valid   <= '0';
        wait for (slot_gap - 1) * clk_period;

      end loop;

      -- 3 aux slots, slot_last on the third.
      for a in 0 to aux_slots - 1 loop

        slot_data    <= (others => '0');
        slot_channel <= to_unsigned(ch_per_chip + a, 6);
        slot_is_aux  <= '1';

        if (a = aux_slots - 1) then
          slot_last <= '1';
        else
          slot_last <= '0';
        end if;

        slot_valid <= '1';
        wait until rising_edge(clk);
        slot_valid <= '0';
        slot_last  <= '0';
        wait for (slot_gap - 1) * clk_period;

      end loop;

      sw := sw + 1;

      if ((sw mod 8000) = 0) then
        report "  sweep " & integer'image(sw) & ", feature_index "
               & integer'image(to_integer(feature_index));
      end if;

    end loop;

    file_close(f);

    if (sw < n_sweeps) then
      report "FAIL: stimulus has only " & integer'image(sw) & " rows"
        severity failure;
    end if;

    stim_done <= true;
    wait;

  end process stim;

  ------------------------------------------------------------------------
  -- Checker: every bin, held and read, against the golden
  ------------------------------------------------------------------------

  checker : process is

    file     f        : text;
    variable st       : file_open_status;
    variable l        : line;
    variable gb       : integer;
    variable gc       : integer;
    variable gcnt     : integer;
    variable gpow     : unsigned(47 downto 0);
    variable good     : boolean;
    variable first    : character;
    variable want_cnt : cnt_arr_t;
    variable want_pow : pow_arr_t;
    variable loaded   : natural := 0;
    variable errs     : natural := 0;
    variable polls    : natural;

  begin

    -- Load the golden for the bins this run covers.
    file_open(st, f, golden_file, read_mode);

    if (st /= open_ok) then
      report "FAIL: cannot open golden " & golden_file
        severity failure;
    end if;

    while not endfile(f) loop

      readline(f, l);

      if (l.all'length = 0) then
        next;
      end if;

      first := l.all(l.all'left);

      if (first = '#') then
        report "golden: " & l.all;
        next;
      end if;

      read(l, gb);
      read(l, gc);
      read(l, gcnt);
      read_u48(l, gpow);

      exit when gb >= n_bins;

      want_cnt(gb, gc) := gcnt;
      want_pow(gb, gc) := gpow;
      loaded           := loaded + 1;

    end loop;

    file_close(f);

    if (loaded /= n_bins * channels) then
      report "FAIL: golden has " & integer'image(loaded) & " entries for the first "
             & integer'image(n_bins) & " bins; expected " & integer'image(n_bins * channels)
        severity failure;
    end if;

    report "golden: " & integer'image(n_bins) & " bins loaded";

    wait until rst_n = '1';

    for b in 0 to n_bins - 1 loop

      -- Wait for bin b to become readable: feature_index = b + 1.
      wait until rising_edge(clk) and feature_index = to_unsigned(b + 1, 32);

      hold  <= '1';
      polls := 0;

      loop

        wait until rising_edge(clk);
        exit when held = '1';
        polls := polls + 1;

        if (polls > 10) then
          errs := errs + 1;
          report "FAIL: held never asserted"
            severity error;
          exit;
        end if;

      end loop;

      for c in 0 to channels - 1 loop

        rd_addr <= to_unsigned(c, 7);
        rd_en   <= '1';
        wait until rising_edge(clk);
        rd_en   <= '0';
        wait until rising_edge(clk);

        if (to_integer(rd_count) /= want_cnt(b, c)) then
          errs := errs + 1;
          if (errs <= 20) then
            report "FAIL bin " & integer'image(b) & " ch " & integer'image(c)
                   & " count " & integer'image(to_integer(rd_count))
                   & ", expected " & integer'image(want_cnt(b, c))
              severity error;
          end if;
        end if;

        if (rd_power /= want_pow(b, c)) then
          errs := errs + 1;
          if (errs <= 20) then
            report "FAIL bin " & integer'image(b) & " ch " & integer'image(c)
                   & " power 0x" & hex12(rd_power)
                   & ", expected 0x" & hex12(want_pow(b, c))
              severity error;
          end if;
        end if;

      end loop;

      hold <= '0';
      wait until rising_edge(clk) and held = '0';

      -- The bank must not have swapped underneath the read.
      if (feature_index /= to_unsigned(b + 1, 32)) then
        errs := errs + 1;
        report "FAIL: feature_index moved to " & integer'image(to_integer(feature_index))
               & " during the held read of bin " & integer'image(b)
          severity error;
      end if;

    end loop;

    -- The stimulus normally finishes a few slots before the last bin's swap,
    -- so this is usually already true; wait until only fires on an event.
    if (not stim_done) then
      wait until stim_done;
    end if;

    wait for 100 * clk_period;

    if (dropped /= 0) then
      errs := errs + 1;
      report "FAIL: dropped = " & integer'image(to_integer(dropped))
        severity error;
    end if;

    errors <= errs;
    wait for 1 ns;

    report "checked " & integer'image(n_bins) & " bins x " & integer'image(channels)
           & " channels, count and power";

    if (errors = 0) then
      report "PASS: argus_feature matches spike_features.py on all "
             & integer'image(n_bins * channels) & " (bin, channel) pairs";
    else
      report "FAIL: " & integer'image(errors) & " error(s)"
        severity failure;
    end if;

    sim_done <= true;
    wait;

  end process checker;

  ------------------------------------------------------------------------
  -- The block must be idle when a slot arrives, or the gap is too small.
  ------------------------------------------------------------------------

  idle_check : process (clk) is
  begin

    if rising_edge(clk) then
      if ((slot_valid = '1') and (busy = '1')) then
        report "FAIL: slot arrived while the block was busy -- increase slot_gap"
          severity failure;
      end if;
    end if;

  end process idle_check;

  watchdog : process is
  begin

    wait for 2000 ms;

    if (not sim_done) then
      report "FAIL: timeout"
        severity failure;
    end if;

    wait;

  end process watchdog;

end architecture sim;

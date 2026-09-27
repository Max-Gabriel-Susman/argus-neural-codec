--------------------------------------------------------------------------------
-- tb_argus_frame_assembler_hold.vhd
--
-- The bank freeze, on its own.
--
-- Deliberately standalone: no SPI master, no chip models. The slot stream
-- is generated directly, which keeps the test about the hold logic and
-- nothing else, and lets a sweep be 5 us instead of 33 us so the run is
-- short.
--
-- WHAT THIS PROVES
--
--   1. HELD FOLLOWS HOLD. held goes high after hold and low after it is
--      released, with no swap in between.
--
--   2. THE INDEX FREEZES. frame_index does not move across several sweeps
--      while held, so the value a consumer reads names the frame it is
--      about to read rather than one that has since been overwritten.
--
--   3. A SLOW READ IS COHERENT. 96 words read at a pace that spans roughly
--      seven sweeps still come back as one frame: every word carries its
--      own chip and channel and all share one sample index. Without the
--      hold this is precisely the read that tears.
--
--   4. IT RESUMES. After release, frame_index advances again and the
--      writer has lost nothing but the frames it discarded.
--
-- VHDL-93 compatible.
--------------------------------------------------------------------------------

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity tb_argus_frame_assembler_hold is
end entity tb_argus_frame_assembler_hold;

architecture sim of tb_argus_frame_assembler_hold is

  constant clk_period  : time    := 8 ns;         -- 125 MHz
  constant chip_count  : natural := 3;
  constant ch_per_chip : natural := 32;
  constant total_ch    : natural := chip_count * ch_per_chip;

  -- Clocks between slots. The real master leaves 119; anything above
  -- chip_count is enough for the serialised lane writes, and a smaller
  -- number keeps the simulation short.
  constant slot_gap : natural := 20;

  signal clk   : std_logic := '0';
  signal rst_n : std_logic := '0';

  signal slot_valid   : std_logic := '0';
  signal slot_channel : unsigned(5 downto 0) := (others => '0');
  signal slot_data    : std_logic_vector(chip_count * 16 - 1 downto 0) := (others => '0');
  signal slot_is_aux  : std_logic := '0';
  signal slot_last    : std_logic := '0';

  signal frame_valid : std_logic;
  signal frame_index : unsigned(31 downto 0);

  signal hold : std_logic := '0';
  signal held : std_logic;

  signal rd_en   : std_logic := '0';
  signal rd_addr : unsigned(7 downto 0) := (others => '0');
  signal rd_data : std_logic_vector(15 downto 0);

  signal overrun : std_logic;

  signal sweeps   : natural := 0;
  signal errors   : natural := 0;
  signal sim_done : boolean := false;

  ------------------------------------------------------------------------
  -- Same layout the chips and the relay both use:
  --   bits 15:14 chip, bits 13:8 channel, bits 7:0 sample index
  ------------------------------------------------------------------------

  function ident_word (
    chip : natural;
    ch   : natural;
    idx  : natural
  ) return std_logic_vector is
  begin

    return std_logic_vector(to_unsigned(chip, 2))
           & std_logic_vector(to_unsigned(ch, 6))
           & std_logic_vector(to_unsigned(idx mod 256, 8));

  end function ident_word;

  function hex4 (
    v : std_logic_vector(15 downto 0)
  ) return string is

    constant digits : string(1 to 16) := "0123456789ABCDEF";
    variable r      : string(1 to 4);

  begin

    for i in 0 to 3 loop
      r(4 - i) := digits(to_integer(unsigned(v(i * 4 + 3 downto i * 4))) + 1);
    end loop;

    return r;

  end function hex4;

begin

  clk <= not clk after clk_period / 2 when not sim_done else '0';

  dut : entity work.argus_frame_assembler(rtl)
    generic map (
      chip_count  => chip_count,
      ch_per_chip => ch_per_chip
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
      hold         => hold,
      held         => held,
      rd_en        => rd_en,
      rd_addr      => rd_addr,
      rd_data      => rd_data,
      overrun      => overrun
    );

  ------------------------------------------------------------------------
  -- Slot stream. Runs forever, independent of the checker, so sweeps keep
  -- closing underneath a held read exactly as they do on hardware.
  ------------------------------------------------------------------------

  driver : process is

    variable d   : std_logic_vector(chip_count * 16 - 1 downto 0);
    variable idx : natural := 0;

  begin

    wait until rst_n = '1';

    loop

      for ch in 0 to ch_per_chip - 1 loop

        for c in 0 to chip_count - 1 loop
          d(c * 16 + 15 downto c * 16) := ident_word(c, ch, idx);
        end loop;

        slot_channel <= to_unsigned(ch, 6);
        slot_data    <= d;
        slot_is_aux  <= '0';
        slot_last    <= '1' when ch = ch_per_chip - 1 else '0';
        slot_valid   <= '1';
        wait until rising_edge(clk);
        slot_valid   <= '0';
        slot_last    <= '0';

        for k in 0 to slot_gap - 1 loop
          wait until rising_edge(clk);
        end loop;

      end loop;

      idx    := idx + 1;
      sweeps <= sweeps + 1;

    end loop;

  end process driver;

  ------------------------------------------------------------------------
  -- Checker
  ------------------------------------------------------------------------

  checker : process is

    variable errs     : natural := 0;
    variable got      : std_logic_vector(15 downto 0);
    variable want     : std_logic_vector(15 downto 0);
    variable idx      : natural;
    variable fi_held  : unsigned(31 downto 0);
    variable fi_after : unsigned(31 downto 0);
    variable mark     : natural;

    procedure read_word (
      a : in    natural;
      w : out   std_logic_vector(15 downto 0)
    ) is
    begin

      rd_addr <= to_unsigned(a, 8);
      rd_en   <= '1';
      wait until rising_edge(clk);
      rd_en   <= '0';
      wait until rising_edge(clk);
      w       := rd_data;

    end procedure read_word;

    procedure wait_sweeps (
      n : in    natural
    ) is

      variable target : natural;

    begin

      target := sweeps + n;

      while sweeps < target loop
        wait until rising_edge(clk);
      end loop;

    end procedure wait_sweeps;

  begin

    rst_n <= '0';
    wait for 20 * clk_period;
    rst_n <= '1';

    -- Let a few frames close so the read bank holds real data.
    wait_sweeps(3);

    ----------------------------------------------------------------------
    -- 1. held tracks hold.
    ----------------------------------------------------------------------
    if (held /= '0') then
      errs := errs + 1;
      report "FAIL: held asserted before hold was requested"
        severity error;
    end if;

    hold <= '1';
    wait until rising_edge(clk);
    wait until rising_edge(clk);

    if (held /= '1') then
      errs := errs + 1;
      report "FAIL: held did not follow hold"
        severity error;
    end if;

    ----------------------------------------------------------------------
    -- 2. frame_index freezes.
    ----------------------------------------------------------------------
    fi_held := frame_index;
    wait_sweeps(5);

    if (frame_index /= fi_held) then
      errs := errs + 1;
      report "FAIL: frame_index moved from "
             & integer'image(to_integer(fi_held)) & " to "
             & integer'image(to_integer(frame_index)) & " while held"
        severity error;
    end if;

    ----------------------------------------------------------------------
    -- 3. A read slow enough to span several sweeps is still one frame.
    --
    -- 96 words at 50 clocks apart is about 38 us of simulated time, seven
    -- sweeps at this slot gap. Unheld, the bank would have swapped under
    -- the read several times over.
    ----------------------------------------------------------------------
    read_word(0, got);
    idx := to_integer(unsigned(got(7 downto 0)));

    for n in 0 to total_ch - 1 loop

      read_word(n, got);
      want := ident_word(n / ch_per_chip, n mod ch_per_chip, idx);

      if (got /= want) then
        errs := errs + 1;
        report "FAIL word " & integer'image(n)
               & ": " & hex4(got) & ", expected " & hex4(want)
          severity error;
      end if;

      for k in 0 to 49 loop
        wait until rising_edge(clk);
      end loop;

    end loop;

    -- The sweep counter the data carries must be the one frame_index named.
    if (idx /= (to_integer(fi_held) - 1) mod 256) then
      errs := errs + 1;
      report "FAIL: data sample index " & integer'image(idx)
             & " does not match frame_index " & integer'image(to_integer(fi_held))
        severity error;
    end if;

    -- And the index must still not have moved, after all that.
    if (frame_index /= fi_held) then
      errs := errs + 1;
      report "FAIL: frame_index moved during the held read"
        severity error;
    end if;

    ----------------------------------------------------------------------
    -- 4. Release, and the chain picks up where it left off.
    ----------------------------------------------------------------------
    hold <= '0';
    wait until rising_edge(clk);
    wait until rising_edge(clk);

    if (held /= '0') then
      errs := errs + 1;
      report "FAIL: held stuck after hold was released"
        severity error;
    end if;

    mark := sweeps;
    wait_sweeps(3);
    fi_after := frame_index;

    if (fi_after <= fi_held) then
      errs := errs + 1;
      report "FAIL: frame_index did not resume after release"
        severity error;
    end if;

    if (overrun /= '0') then
      errs := errs + 1;
      report "FAIL: assembler reported overrun"
        severity error;
    end if;

    report "held read spanned " & integer'image(mark - to_integer(fi_held))
           & " sweeps; frame_index resumed at "
           & integer'image(to_integer(fi_after));

    errors <= errs;
    wait for 1 ns;

    if (errors = 0) then
      report "PASS: bank freeze, index freeze, coherent slow read and release verified";
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

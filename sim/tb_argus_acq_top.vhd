--------------------------------------------------------------------------------
-- tb_argus_acq_top.vhd
--
-- Drives the complete acquisition chain the way the PS will: through the
-- AXI4-Lite register block, with no visibility into anything else. If this
-- passes, the only thing left between here and hardware is the block design
-- and the bus fabric.
--
-- SEQUENCE
--   1. ID reads back as "ACQ2" -- the address map is where we think it is,
--      and this is the fabric revision the firmware expects.
--   2. STATUS shows not-ready before enable; unmapped reads return the
--      sentinel, not garbage.
--   3. Enable; poll STATUS until ready.
--   4. FRAME_INDEX advances at the sweep rate.
--   5. Set CTRL.hold, poll STATUS.held, then read all 96 FRAME words slowly
--      enough to span three sweeps and check every word against the
--      identity pattern through the electrode map. FRAME_INDEX must name
--      the frame read, must not move across the read, and must resume on
--      release. This is what acq_read_frame() in the firmware does.
--   6. Soft reset returns STATUS and FRAME_INDEX to zero.
--
-- The bus functional model is two procedures. It asserts valid and waits for
-- ready, which exercises the slave's registered handshakes properly; a BFM
-- that assumed ready was combinational would pass here and fail on the
-- Zynq's interconnect.
--
-- Run: make tb_argus_acq_top   (from sim/)
--------------------------------------------------------------------------------

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity tb_argus_acq_top is
end entity tb_argus_acq_top;

architecture sim of tb_argus_acq_top is

  constant CHIP_COUNT  : natural := 3;
  constant CH_PER_CHIP : natural := 32;
  constant AUX_SLOTS   : natural := 3;
  constant SLOT_CLOCKS : natural := 119;
  constant SCLK_DIV    : natural := 5;
  constant ADDR_W      : natural := 12;

  constant TOTAL_CHANNELS : natural := CHIP_COUNT * CH_PER_CHIP;

  constant CLK_PERIOD : time := 8 ns;

  constant REG_CTRL        : natural := 16#000#;
  constant REG_STATUS      : natural := 16#004#;
  constant REG_FRAME_INDEX : natural := 16#008#;
  constant REG_ID          : natural := 16#00C#;
  constant REG_FRAME_BASE  : natural := 16#100#;
  constant REG_UNMAPPED    : natural := 16#080#;

  constant ID_EXPECT : std_logic_vector(31 downto 0) := x"41435132";
  constant UNMAPPED  : std_logic_vector(31 downto 0) := x"DEADBEEF";

  -- CTRL bit 0 enable, bit 3 hold. STATUS bit 2 held.
  constant CTRL_ENABLE      : std_logic_vector(31 downto 0) := x"00000001";
  constant CTRL_ENABLE_HOLD : std_logic_vector(31 downto 0) := x"00000009";
  constant STATUS_HELD_BIT  : natural := 2;

  signal clk    : std_logic := '0';
  signal resetn : std_logic := '0';

  signal awaddr  : std_logic_vector(ADDR_W - 1 downto 0) := (others => '0');
  signal awprot  : std_logic_vector(2 downto 0)          := (others => '0');
  signal awvalid : std_logic                             := '0';
  signal awready : std_logic;
  signal wdata   : std_logic_vector(31 downto 0)         := (others => '0');
  signal wstrb   : std_logic_vector(3 downto 0)          := (others => '0');
  signal wvalid  : std_logic                             := '0';
  signal wready  : std_logic;
  signal bresp   : std_logic_vector(1 downto 0);
  signal bvalid  : std_logic;
  signal bready  : std_logic                             := '0';
  signal araddr  : std_logic_vector(ADDR_W - 1 downto 0) := (others => '0');
  signal arprot  : std_logic_vector(2 downto 0)          := (others => '0');
  signal arvalid : std_logic                             := '0';
  signal arready : std_logic;
  signal rdata   : std_logic_vector(31 downto 0);
  signal rresp   : std_logic_vector(1 downto 0);
  signal rvalid  : std_logic;
  signal rready  : std_logic                             := '0';

  -- No memory behind the top in this testbench; the chips stay on their
  -- built-in pattern (CTRL.ext_mode is never set) so port B is unused.
  signal bram_dout : std_logic_vector(31 downto 0) := (others => '0');

  signal sim_done : boolean := false;

  function hex8 (v : std_logic_vector(31 downto 0)) return string is

    constant DIGITS : string(1 to 16) := "0123456789ABCDEF";
    variable s      : string(1 to 8);
    variable nib    : integer;

  begin

    for i in 0 to 7 loop

      nib      := to_integer(unsigned(v(31 - 4 * i downto 28 - 4 * i)));
      s(i + 1) := DIGITS(nib + 1);

    end loop;

    return s;

  end function hex8;

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

  clk <= not clk after CLK_PERIOD / 2 when not sim_done else '0';

  dut : entity work.argus_acq_top
    generic map (
      C_S_AXI_ADDR_WIDTH => ADDR_W,
      CHIP_COUNT         => CHIP_COUNT,
      CH_PER_CHIP        => CH_PER_CHIP,
      AUX_SLOTS          => AUX_SLOTS,
      SLOT_CLOCKS        => SLOT_CLOCKS,
      SCLK_DIV           => SCLK_DIV
    )
    port map (
      s_axi_aclk    => clk,
      s_axi_aresetn => resetn,
      s_axi_awaddr  => awaddr,
      s_axi_awprot  => awprot,
      s_axi_awvalid => awvalid,
      s_axi_awready => awready,
      s_axi_wdata   => wdata,
      s_axi_wstrb   => wstrb,
      s_axi_wvalid  => wvalid,
      s_axi_wready  => wready,
      s_axi_bresp   => bresp,
      s_axi_bvalid  => bvalid,
      s_axi_bready  => bready,
      s_axi_araddr  => araddr,
      s_axi_arprot  => arprot,
      s_axi_arvalid => arvalid,
      s_axi_arready => arready,
      s_axi_rdata   => rdata,
      s_axi_rresp   => rresp,
      s_axi_rvalid  => rvalid,
      s_axi_rready  => rready,
      bram_clk      => open,
      bram_rst      => open,
      bram_en       => open,
      bram_we       => open,
      bram_addr     => open,
      bram_din      => open,
      bram_dout     => bram_dout
    );

  stim : process is

    variable errs      : natural := 0;
    variable v         : std_logic_vector(31 downto 0);
    variable fi_before : std_logic_vector(31 downto 0);
    variable fi_after  : std_logic_vector(31 downto 0);
    variable frame_idx : unsigned(7 downto 0);
    variable want      : std_logic_vector(15 downto 0);
    variable tries     : natural;

    ----------------------------------------------------------------------
    -- AXI4-Lite bus functional model
    ----------------------------------------------------------------------

    procedure axi_write (
      addr : in    natural;
      data : in    std_logic_vector(31 downto 0)
    ) is
    begin

      awaddr  <= std_logic_vector(to_unsigned(addr, ADDR_W));
      wdata   <= data;
      wstrb   <= "1111";
      awvalid <= '1';
      wvalid  <= '1';

      -- Hold both valid until both readies have been seen. The slave asserts
      -- them together, but a compliant master must not assume that.
      wait until rising_edge(clk) and awready = '1' and wready = '1';
      awvalid <= '0';
      wvalid  <= '0';

      bready <= '1';
      wait until rising_edge(clk) and bvalid = '1';
      bready <= '0';

      if (bresp /= "00") then
        errs := errs + 1;
        report "FAIL write to " & integer'image(addr) & ": bresp not OKAY"
          severity error;
      end if;

    end procedure axi_write;

    procedure axi_read (
      addr : in    natural;
      data : out   std_logic_vector(31 downto 0)
    ) is
    begin

      araddr  <= std_logic_vector(to_unsigned(addr, ADDR_W));
      arvalid <= '1';
      wait until rising_edge(clk) and arready = '1';
      arvalid <= '0';

      rready <= '1';
      wait until rising_edge(clk) and rvalid = '1';
      data := rdata;
      rready <= '0';

      if (rresp /= "00") then
        errs := errs + 1;
        report "FAIL read from " & integer'image(addr) & ": rresp not OKAY"
          severity error;
      end if;

    end procedure axi_read;

    procedure expect (
      addr     : in    natural;
      expected : in    std_logic_vector(31 downto 0);
      what     : in    string
    ) is

      variable got : std_logic_vector(31 downto 0);

    begin

      axi_read(addr, got);

      if (got /= expected) then
        errs := errs + 1;
        report "FAIL " & what & ": " & hex8(got) & ", expected " & hex8(expected)
          severity error;
      end if;

    end procedure expect;

  begin

    resetn <= '0';
    wait for 20 * CLK_PERIOD;
    resetn <= '1';
    wait for 20 * CLK_PERIOD;

    ----------------------------------------------------------------------
    -- 1. The address map is where we think it is.
    ----------------------------------------------------------------------
    expect(REG_ID, ID_EXPECT, "ID");
    report "ID ok";

    ----------------------------------------------------------------------
    -- 2. Quiescent state and the unmapped sentinel.
    ----------------------------------------------------------------------
    expect(REG_STATUS, x"00000000", "STATUS before enable");
    expect(REG_FRAME_INDEX, x"00000000", "FRAME_INDEX before enable");
    expect(REG_CTRL, x"00000000", "CTRL after reset");
    expect(REG_UNMAPPED, UNMAPPED, "unmapped read");

    ----------------------------------------------------------------------
    -- 3. Enable and wait for the init sequence.
    ----------------------------------------------------------------------
    axi_write(REG_CTRL, CTRL_ENABLE);
    expect(REG_CTRL, CTRL_ENABLE, "CTRL readback");

    tries := 0;
    loop
      axi_read(REG_STATUS, v);
      exit when v(0) = '1';
      tries := tries + 1;
      if (tries > 1000) then
        errs := errs + 1;
        report "FAIL: ready never asserted" severity error;
        exit;
      end if;
      wait for 1 us;
    end loop;

    report "ready after " & integer'image(tries) & " polls";

    ----------------------------------------------------------------------
    -- 4. FRAME_INDEX advances at the sweep rate.
    ----------------------------------------------------------------------
    axi_read(REG_FRAME_INDEX, fi_before);
    wait for 100 us;   -- three sweeps at 33.3 us
    axi_read(REG_FRAME_INDEX, fi_after);

    if (unsigned(fi_after) - unsigned(fi_before) < 2) then
      errs := errs + 1;
      report "FAIL: FRAME_INDEX advanced by "
             & integer'image(to_integer(unsigned(fi_after) - unsigned(fi_before)))
             & " in 100 us; expected about 3"
        severity error;
    end if;

    ----------------------------------------------------------------------
    -- 5. Read a frame under the hardware hold and check every word.
    --
    -- The read is deliberately slow: one word per microsecond, so the 96
    -- words span about three sweeps, as they do from the A9. Without the
    -- hold the bank would swap underneath it and the sample index would
    -- change partway through. With it, every word must carry one index,
    -- that index must be the one FRAME_INDEX named, and FRAME_INDEX must
    -- not have moved by the end.
    ----------------------------------------------------------------------
    axi_write(REG_CTRL, CTRL_ENABLE_HOLD);
    expect(REG_CTRL, CTRL_ENABLE_HOLD, "CTRL readback with hold");

    tries := 0;
    loop
      axi_read(REG_STATUS, v);
      exit when v(STATUS_HELD_BIT) = '1';
      tries := tries + 1;
      if (tries > 100) then
        errs := errs + 1;
        report "FAIL: STATUS.held never asserted after CTRL.hold" severity error;
        exit;
      end if;
    end loop;

    report "held after " & integer'image(tries) & " polls";

    axi_read(REG_FRAME_INDEX, fi_before);

    axi_read(REG_FRAME_BASE, v);
    frame_idx := unsigned(v(7 downto 0));

    for n in 0 to TOTAL_CHANNELS - 1 loop

      axi_read(REG_FRAME_BASE + 4 * n, v);
      want := ident_word(n / CH_PER_CHIP, to_unsigned(n mod CH_PER_CHIP, 6), frame_idx);

      if (v(15 downto 0) /= want) then
        errs := errs + 1;
        report "FAIL frame word " & integer'image(n)
               & ": " & hex8(v) & ", expected 0000" & hex8(x"0000" & want)(5 to 8)
          severity error;
      end if;

      if (v(31 downto 16) /= x"0000") then
        errs := errs + 1;
        report "FAIL frame word " & integer'image(n) & ": upper half not zero"
          severity error;
      end if;

      wait for 1 us;

    end loop;

    -- The data's sample index must be the frame FRAME_INDEX named. The
    -- chips stamp the sweep counter; the assembler's index is one ahead.
    if (to_integer(frame_idx) /= (to_integer(unsigned(fi_before)) - 1) mod 256) then
      errs := errs + 1;
      report "FAIL: data sample index " & integer'image(to_integer(frame_idx))
             & " does not match FRAME_INDEX " & integer'image(to_integer(unsigned(fi_before)))
        severity error;
    end if;

    -- And FRAME_INDEX must not have moved across a read that spanned sweeps.
    axi_read(REG_FRAME_INDEX, fi_after);

    if (fi_after /= fi_before) then
      errs := errs + 1;
      report "FAIL: FRAME_INDEX moved from " & hex8(fi_before) & " to " & hex8(fi_after)
             & " during the held read"
        severity error;
    end if;

    report "held read coherent, sample index " & integer'image(to_integer(frame_idx))
           & ", FRAME_INDEX " & integer'image(to_integer(unsigned(fi_before)));

    -- Release. held drops and the index resumes.
    axi_write(REG_CTRL, CTRL_ENABLE);
    wait for 1 us;

    axi_read(REG_STATUS, v);

    if (v(STATUS_HELD_BIT) /= '0') then
      errs := errs + 1;
      report "FAIL: STATUS.held stuck after CTRL.hold was cleared" severity error;
    end if;

    wait for 100 us;   -- three sweeps
    axi_read(REG_FRAME_INDEX, fi_after);

    if (unsigned(fi_after) <= unsigned(fi_before)) then
      errs := errs + 1;
      report "FAIL: FRAME_INDEX did not resume after the hold was released"
        severity error;
    end if;

    ----------------------------------------------------------------------
    -- 6. Soft reset returns the chain to zero without disturbing the bus.
    ----------------------------------------------------------------------
    axi_write(REG_CTRL, x"00000002");
    wait for 1 us;
    expect(REG_STATUS, x"00000000", "STATUS under soft reset");
    expect(REG_FRAME_INDEX, x"00000000", "FRAME_INDEX under soft reset");
    expect(REG_ID, ID_EXPECT, "ID under soft reset");
    axi_write(REG_CTRL, x"00000000");

    ----------------------------------------------------------------------
    if (errs = 0) then
      report "PASS: address map, enable, sweep rate, held frame read, release, soft reset";
    else
      report "FAIL: " & integer'image(errs) & " error(s)" severity failure;
    end if;

    sim_done <= true;
    wait;

  end process stim;

  watchdog : process is
  begin

    wait for 20 ms;

    if not sim_done then
      report "FAIL: timeout" severity failure;
    end if;

    wait;

  end process watchdog;

end architecture sim;

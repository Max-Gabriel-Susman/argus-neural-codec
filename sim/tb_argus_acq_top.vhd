--------------------------------------------------------------------------------
-- tb_argus_acq_top.vhd
--
-- Drives the complete acquisition chain the way the PS will: through the
-- AXI4-Lite register block, with no visibility into anything else. If this
-- passes, the only thing left between here and hardware is the block design
-- and the bus fabric.
--
-- SEQUENCE
--   1. ID reads back as "ACQ1" -- the address map is where we think it is.
--   2. STATUS shows not-ready before enable; unmapped reads return the
--      sentinel, not garbage.
--   3. Enable; poll STATUS until ready.
--   4. FRAME_INDEX advances at the sweep rate.
--   5. Read all 96 FRAME words under a seqlock -- FRAME_INDEX unchanged
--      across the read -- and check every word against the identity pattern
--      through the electrode map.
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

  constant chip_count  : natural := 3;
  constant ch_per_chip : natural := 32;
  constant aux_slots   : natural := 3;
  constant slot_clocks : natural := 119;
  constant sclk_div    : natural := 5;
  constant addr_w      : natural := 12;

  constant total_channels : natural := chip_count * ch_per_chip;

  constant clk_period : time := 8 ns;

  constant reg_ctrl        : natural := 16#000#;
  constant reg_status      : natural := 16#004#;
  constant reg_frame_index : natural := 16#008#;
  constant reg_id          : natural := 16#00C#;
  constant reg_frame_base  : natural := 16#100#;
  constant reg_unmapped    : natural := 16#080#;

  constant id_expect : std_logic_vector(31 downto 0) := x"41435131";
  constant unmapped  : std_logic_vector(31 downto 0) := x"DEADBEEF";

  signal clk    : std_logic := '0';
  signal resetn : std_logic := '0';

  signal awaddr  : std_logic_vector(addr_w - 1 downto 0) := (others => '0');
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
  signal araddr  : std_logic_vector(addr_w - 1 downto 0) := (others => '0');
  signal arprot  : std_logic_vector(2 downto 0)          := (others => '0');
  signal arvalid : std_logic                             := '0';
  signal arready : std_logic;
  signal rdata   : std_logic_vector(31 downto 0);
  signal rresp   : std_logic_vector(1 downto 0);
  signal rvalid  : std_logic;
  signal rready  : std_logic                             := '0';

  signal sim_done : boolean := false;

  function hex8 (
    v : std_logic_vector(31 downto 0)
  ) return string is

    constant digits : string(1 to 16) := "0123456789ABCDEF";
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

  clk <= not clk after clk_period / 2 when not sim_done else
         '0';

  dut : entity work.argus_acq_top
    generic map (
      c_s_axi_addr_width => ADDR_W,
      chip_count         => CHIP_COUNT,
      ch_per_chip        => CH_PER_CHIP,
      aux_slots          => AUX_SLOTS,
      slot_clocks        => SLOT_CLOCKS,
      sclk_div           => SCLK_DIV
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
      s_axi_rready  => rready
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
      data   := rdata;
      rready <= '0';

      if (rresp /= "00") then
        errs := errs + 1;
        report "FAIL read from " & integer'image(addr) & ": rresp not OKAY"
          severity error;
      end if;

    end procedure axi_read;

    procedure expect (
      addr : in    natural;
      want : in    std_logic_vector(31 downto 0);
      what : in    string
    ) is

      variable got : std_logic_vector(31 downto 0);

    begin

      axi_read(addr, got);

      if (got /= want) then
        errs := errs + 1;
        report "FAIL " & what & ": " & hex8(got) & ", expected " & hex8(want)
          severity error;
      end if;

    end procedure expect;

  begin

    resetn <= '0';
    wait for 20 * clk_period;
    resetn <= '1';
    wait for 20 * clk_period;

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
    axi_write(REG_CTRL, x"00000001");
    expect(REG_CTRL, x"00000001", "CTRL readback");

    tries := 0;

    loop

      axi_read(REG_STATUS, v);
      exit when v(0) = '1';
      tries := tries + 1;

      if (tries > 1000) then
        errs := errs + 1;
        report "FAIL: ready never asserted"
          severity error;
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
    -- 5. Read a frame under a seqlock and check every word.
    ----------------------------------------------------------------------
    tries := 0;

    loop

      -- Land just after a bank switch so the whole read fits in one sweep.
      axi_read(REG_FRAME_INDEX, fi_before);

      loop

        axi_read(REG_FRAME_INDEX, fi_after);
        exit when fi_after /= fi_before;

      end loop;

      fi_before := fi_after;

      axi_read(REG_FRAME_BASE, v);
      frame_idx := unsigned(v(7 downto 0));

      for n in 0 to total_channels - 1 loop

        axi_read(REG_FRAME_BASE + 4 * n, v);
        want := ident_word(n / ch_per_chip, to_unsigned(n mod ch_per_chip, 6), frame_idx);

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

      end loop;

      axi_read(REG_FRAME_INDEX, fi_after);
      exit when fi_after = fi_before;

      -- The bank switched mid-read. Discard and retry, as software would.
      tries := tries + 1;
      report "frame read torn, retrying"
        severity note;

      if (tries > 3) then
        errs := errs + 1;
        report "FAIL: could not read a coherent frame in 3 tries"
          severity error;
        exit;
      end if;

    end loop;

    report "frame read coherent, sample index " & integer'image(to_integer(frame_idx));

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
      report "PASS: address map, enable, sweep rate, coherent frame read, soft reset";
    else
      report "FAIL: " & integer'image(errs) & " error(s)"
        severity failure;
    end if;

    sim_done <= true;
    wait;

  end process stim;

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

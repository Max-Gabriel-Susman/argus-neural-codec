--------------------------------------------------------------------------------
-- argus_acq_top.vhd
--
-- The complete acquisition chain behind one AXI4-Lite interface: SPI master,
-- three simulated RHD2132 chips, sample fetcher, frame assembler, feature
-- extractor, register block. This is the module the block design
-- instantiates on M_AXI_GP0.
--
-- The feature extractor taps the same slot stream the assembler consumes
-- and runs beside it: the assembler keeps the latest raw frame, the
-- extractor keeps per-channel crossing counts and spike-band power per
-- bin. Both expose a held, double-buffered bank to the register block.
--
-- LANES
--   Each of the chip_count MISO lanes has a source, set by LANE_SRC:
--
--     model  the simulated RHD2132 inside the fabric (the default)
--     pins   an external chip on the spi_* ports, routed to PMOD JA
--            (constraints/argus_pmod_ja.xdc)
--     off    MISO held low; the lane reads zeros
--
--   The bus itself is broadcast: CS, SCLK and MOSI drive the internal chips
--   and the pins at once, so an external chip sees exactly the sequence the
--   models do. Only MISO is selected per lane. A lane switched to the pins
--   keeps its model running, so the replay fetcher, which is driven by chip
--   0's requests, works whatever lane 0's source is.
--
--   An external chip answers late: the SCLK edge has to reach it and its
--   MISO has to come back. MISO_DELAY moves each lane's capture later to
--   cover that (argus_rhd_spi_master, "Sampling an external chip"). The
--   pin input is registered in an IOB flop first, so its timing does not
--   depend on placement; the delay setting absorbs that one clock.
--
--   LANE_SRC and MISO_DELAY are latched while the chain is in reset, so a
--   lane never changes source partway through a word. Set them under
--   CTRL.soft_reset and release it.
--
-- SAMPLE SOURCE
--   With CTRL.ext_mode clear the chips generate their built-in identity
--   pattern. With it set, argus_sample_fetch serves them from the ping-pong
--   BRAM the PS fills over AXI, via the BRAM port-B master interface below.
--   The block design connects that interface to a Block Memory Generator
--   whose port A sits behind an AXI BRAM Controller.
--
-- Two resets:
--   s_axi_aresetn  from the PS, via proc_sys_reset, covers everything
--   soft_reset     from CTRL bit 1, covers the chain but not the register
--                  block, so the PS can restart acquisition from a known
--                  state without losing the bus
--
-- Port names follow the AXI4-Lite convention, so the block design infers
-- S_AXI when this is added as an RTL module. The bram_* ports are connected
-- to the Block Memory Generator's port B pin-by-pin (tools/bd_add_bram.tcl):
-- X_INTERFACE_INFO attributes in the entity and a default on bram_dout both
-- made Vivado's module-reference elaborator reject the entity outright and
-- silently keep the previous port list.
--
-- VHDL-93 compatible.
--------------------------------------------------------------------------------

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity argus_acq_top is
  generic (
    c_s_axi_addr_width : natural := 12;
    chip_count         : natural := 3;
    ch_per_chip        : natural := 32;
    aux_slots          : natural := 2;
    slot_clocks        : natural := 122;
    sclk_div           : natural := 6;
    sweep_pad          : natural := 17;
    samples_per_half   : natural := 147
  );
  port (
    s_axi_aclk    : in    std_logic;
    s_axi_aresetn : in    std_logic;

    s_axi_awaddr  : in    std_logic_vector(c_s_axi_addr_width - 1 downto 0);
    s_axi_awprot  : in    std_logic_vector(2 downto 0);
    s_axi_awvalid : in    std_logic;
    s_axi_awready : out   std_logic;
    s_axi_wdata   : in    std_logic_vector(31 downto 0);
    s_axi_wstrb   : in    std_logic_vector(3 downto 0);
    s_axi_wvalid  : in    std_logic;
    s_axi_wready  : out   std_logic;
    s_axi_bresp   : out   std_logic_vector(1 downto 0);
    s_axi_bvalid  : out   std_logic;
    s_axi_bready  : in    std_logic;
    s_axi_araddr  : in    std_logic_vector(c_s_axi_addr_width - 1 downto 0);
    s_axi_arprot  : in    std_logic_vector(2 downto 0);
    s_axi_arvalid : in    std_logic;
    s_axi_arready : out   std_logic;
    s_axi_rdata   : out   std_logic_vector(31 downto 0);
    s_axi_rresp   : out   std_logic_vector(1 downto 0);
    s_axi_rvalid  : out   std_logic;
    s_axi_rready  : in    std_logic;

    -- BRAM port B, master side (BRAM-controller convention: 32-bit words,
    -- byte addresses).
    bram_clk  : out   std_logic;
    bram_rst  : out   std_logic;
    bram_en   : out   std_logic;
    bram_we   : out   std_logic_vector(3 downto 0);
    bram_addr : out   std_logic_vector(31 downto 0);
    bram_din  : out   std_logic_vector(31 downto 0);
    bram_dout : in    std_logic_vector(31 downto 0);

    -- SPI to external chips on PMOD JA: the same broadcast bus the internal
    -- chips see, and one MISO per lane. Unused unless LANE_SRC selects the
    -- pins for a lane.
    spi_cs_n : out   std_logic;
    spi_sclk : out   std_logic;
    spi_mosi : out   std_logic;
    spi_miso : in    std_logic_vector(chip_count - 1 downto 0)
  );
end entity argus_acq_top;

architecture rtl of argus_acq_top is

  constant total_channels : natural := chip_count * ch_per_chip;

  signal chain_rst_n : std_logic;
  signal enable      : std_logic;
  signal soft_reset  : std_logic;
  signal ext_mode    : std_logic;
  signal hold        : std_logic;
  signal ready       : std_logic;
  signal overrun     : std_logic;
  signal held        : std_logic;
  signal frame_index : unsigned(31 downto 0);

  signal sclk : std_logic;
  signal cs_n : std_logic;
  signal mosi : std_logic;
  signal miso : std_logic_vector(chip_count - 1 downto 0);

  signal miso_oe : std_logic_vector(chip_count - 1 downto 0);

  -- Lane sources. model_miso is what the internal chips drive, pin_miso_q
  -- the external pins after the IOB register; miso, above, is the
  -- selection the master sees.
  signal model_miso   : std_logic_vector(chip_count - 1 downto 0);
  signal pin_miso_q   : std_logic_vector(chip_count - 1 downto 0);
  signal lane_src     : std_logic_vector(31 downto 0);
  signal miso_delay   : std_logic_vector(31 downto 0);
  signal lane_src_q   : std_logic_vector(chip_count * 2 - 1 downto 0);
  signal miso_delay_q : std_logic_vector(chip_count * 3 - 1 downto 0);

  attribute iob : string;
  attribute iob of pin_miso_q : signal is "TRUE";

  signal ext_req : std_logic_vector(chip_count - 1 downto 0);
  signal ext_ch  : unsigned(5 downto 0);
  signal ext_ack : std_logic;
  signal ext_dat : std_logic_vector(chip_count * 16 - 1 downto 0);

  signal slot_valid   : std_logic;
  signal slot_channel : unsigned(5 downto 0);
  signal slot_data    : std_logic_vector(chip_count * 16 - 1 downto 0);
  signal slot_is_aux  : std_logic;
  signal slot_last    : std_logic;

  signal rd_en   : std_logic;
  signal rd_addr : unsigned(7 downto 0);
  signal rd_data : std_logic_vector(15 downto 0);

  signal feat_hold     : std_logic;
  signal feat_held     : std_logic;
  signal feature_index : unsigned(31 downto 0);
  signal feat_dropped  : unsigned(15 downto 0);
  signal feat_rd_en    : std_logic;
  signal feat_rd_addr  : unsigned(6 downto 0);
  signal feat_rd_count : unsigned(15 downto 0);
  signal feat_rd_power : unsigned(47 downto 0);

  signal play_half       : std_logic;
  signal play_row        : unsigned(15 downto 0);
  signal half_consumed   : std_logic_vector(1 downto 0);
  signal replay_underrun : std_logic;
  signal ack_consumed    : std_logic_vector(1 downto 0);
  signal clear_underrun  : std_logic;

begin

  assert chip_count <= 10
    report "LANE_SRC and MISO_DELAY are one 32-bit register each: at most 10 lanes"
    severity failure;

  -- soft_reset is a registered output of the AXI block, so this is a
  -- synchronous reset for the chain.
  chain_rst_n <= s_axi_aresetn and not soft_reset;

  bram_clk <= s_axi_aclk;
  bram_rst <= '0';

  regs : entity work.argus_acq_axi(rtl)
    generic map (
      c_s_axi_addr_width => c_s_axi_addr_width,
      total_channels     => total_channels
    )
    port map (
      s_axi_aclk      => s_axi_aclk,
      s_axi_aresetn   => s_axi_aresetn,
      s_axi_awaddr    => s_axi_awaddr,
      s_axi_awprot    => s_axi_awprot,
      s_axi_awvalid   => s_axi_awvalid,
      s_axi_awready   => s_axi_awready,
      s_axi_wdata     => s_axi_wdata,
      s_axi_wstrb     => s_axi_wstrb,
      s_axi_wvalid    => s_axi_wvalid,
      s_axi_wready    => s_axi_wready,
      s_axi_bresp     => s_axi_bresp,
      s_axi_bvalid    => s_axi_bvalid,
      s_axi_bready    => s_axi_bready,
      s_axi_araddr    => s_axi_araddr,
      s_axi_arprot    => s_axi_arprot,
      s_axi_arvalid   => s_axi_arvalid,
      s_axi_arready   => s_axi_arready,
      s_axi_rdata     => s_axi_rdata,
      s_axi_rresp     => s_axi_rresp,
      s_axi_rvalid    => s_axi_rvalid,
      s_axi_rready    => s_axi_rready,
      enable          => enable,
      soft_reset      => soft_reset,
      ext_mode        => ext_mode,
      hold            => hold,
      ready           => ready,
      overrun         => overrun,
      held            => held,
      frame_index     => frame_index,
      play_half       => play_half,
      play_row        => play_row,
      half_consumed   => half_consumed,
      replay_underrun => replay_underrun,
      ack_consumed    => ack_consumed,
      clear_underrun  => clear_underrun,
      lane_src        => lane_src,
      miso_delay      => miso_delay,
      rd_en           => rd_en,
      rd_addr         => rd_addr,
      rd_data         => rd_data,
      feat_hold       => feat_hold,
      feat_held       => feat_held,
      feature_index   => feature_index,
      feat_dropped    => feat_dropped,
      feat_rd_en      => feat_rd_en,
      feat_rd_addr    => feat_rd_addr,
      feat_rd_count   => feat_rd_count,
      feat_rd_power   => feat_rd_power
    );

  master : entity work.argus_rhd_spi_master(rtl)
    generic map (
      chip_count  => chip_count,
      ch_per_chip => ch_per_chip,
      aux_slots   => aux_slots,
      slot_clocks => slot_clocks,
      sclk_div    => sclk_div,
      sweep_pad   => sweep_pad
    )
    port map (
      clk          => s_axi_aclk,
      rst_n        => chain_rst_n,
      enable       => enable,
      sclk         => sclk,
      cs_n         => cs_n,
      mosi         => mosi,
      miso         => miso,
      miso_delay   => miso_delay_q,
      slot_valid   => slot_valid,
      slot_channel => slot_channel,
      slot_data    => slot_data,
      slot_is_aux  => slot_is_aux,
      slot_last    => slot_last,
      ready        => ready
    );

  chips : for c in 0 to chip_count - 1 generate

    -- All chips request the same channel on the same clock; chip 0's
    -- request drives the fetcher and the ack fans out to all of them.

    chip0 : if c = 0 generate

      chip_inst : entity work.argus_rhd2132_model(rtl)
        generic map (
          ch_per_chip  => ch_per_chip,
          chip_id      => c,
          chip_type_id => 1,
          pattern      => 0
        )
        port map (
          clk           => s_axi_aclk,
          rst_n         => chain_rst_n,
          sclk          => sclk,
          cs_n          => cs_n,
          mosi          => mosi,
          miso          => model_miso(c),
          miso_oe       => miso_oe(c),
          ext_mode      => ext_mode,
          ext_req       => ext_req(c),
          ext_ch        => ext_ch,
          ext_data      => ext_dat(c * 16 + 15 downto c * 16),
          ext_ack       => ext_ack,
          dbg_last_cmd  => open,
          dbg_cmd_valid => open,
          dbg_last_resp => open
        );

    end generate chip0;

    chipn : if c > 0 generate

      chip_inst : entity work.argus_rhd2132_model(rtl)
        generic map (
          ch_per_chip  => ch_per_chip,
          chip_id      => c,
          chip_type_id => 1,
          pattern      => 0
        )
        port map (
          clk           => s_axi_aclk,
          rst_n         => chain_rst_n,
          sclk          => sclk,
          cs_n          => cs_n,
          mosi          => mosi,
          miso          => model_miso(c),
          miso_oe       => miso_oe(c),
          ext_mode      => ext_mode,
          ext_req       => ext_req(c),
          ext_ch        => open,
          ext_data      => ext_dat(c * 16 + 15 downto c * 16),
          ext_ack       => ext_ack,
          dbg_last_cmd  => open,
          dbg_cmd_valid => open,
          dbg_last_resp => open
        );

    end generate chipn;

  end generate chips;

  --------------------------------------------------------------------------
  -- Lanes: the pins, the latched configuration, and the MISO selection.
  --------------------------------------------------------------------------

  spi_cs_n <= cs_n;
  spi_sclk <= sclk;
  spi_mosi <= mosi;

  lane_cfg : process (s_axi_aclk) is
  begin

    if rising_edge(s_axi_aclk) then
      pin_miso_q <= spi_miso;

      if (chain_rst_n = '0') then
        lane_src_q   <= lane_src(chip_count * 2 - 1 downto 0);
        miso_delay_q <= miso_delay(chip_count * 3 - 1 downto 0);
      end if;
    end if;

  end process lane_cfg;

  lanes : for c in 0 to chip_count - 1 generate

    miso(c) <= model_miso(c) when lane_src_q(c * 2 + 1 downto c * 2) = "00" else
               pin_miso_q(c) when lane_src_q(c * 2 + 1 downto c * 2) = "01" else
               '0';

  end generate lanes;

  fetcher : entity work.argus_sample_fetch(rtl)
    generic map (
      chip_count       => chip_count,
      ch_per_chip      => ch_per_chip,
      samples_per_half => samples_per_half
    )
    port map (
      clk            => s_axi_aclk,
      rst_n          => chain_rst_n,
      enable         => ext_mode,
      req            => ext_req(0),
      req_ch         => ext_ch,
      ack            => ext_ack,
      data           => ext_dat,
      bram_en        => bram_en,
      bram_we        => bram_we,
      bram_addr      => bram_addr,
      bram_din       => bram_din,
      bram_dout      => bram_dout,
      play_half      => play_half,
      play_row       => play_row,
      half_consumed  => half_consumed,
      underrun       => replay_underrun,
      ack_consumed   => ack_consumed,
      clear_underrun => clear_underrun
    );

  assembler : entity work.argus_frame_assembler(rtl)
    generic map (
      chip_count  => chip_count,
      ch_per_chip => ch_per_chip
    )
    port map (
      clk          => s_axi_aclk,
      rst_n        => chain_rst_n,
      slot_valid   => slot_valid,
      slot_channel => slot_channel,
      slot_data    => slot_data,
      slot_is_aux  => slot_is_aux,
      slot_last    => slot_last,
      frame_valid  => open,
      frame_index  => frame_index,
      hold         => hold,
      held         => held,
      rd_en        => rd_en,
      rd_addr      => rd_addr,
      rd_data      => rd_data,
      overrun      => overrun
    );

  -- Parameters are argus_feature's defaults: the values locked by decode
  -- accuracy on the Indy session (argus_sim/tools/README.md).
  features : entity work.argus_feature(rtl)
    generic map (
      chip_count  => chip_count,
      ch_per_chip => ch_per_chip
    )
    port map (
      clk           => s_axi_aclk,
      rst_n         => chain_rst_n,
      slot_valid    => slot_valid,
      slot_channel  => slot_channel,
      slot_data     => slot_data,
      slot_is_aux   => slot_is_aux,
      slot_last     => slot_last,
      hold          => feat_hold,
      held          => feat_held,
      feature_index => feature_index,
      dropped       => feat_dropped,
      busy          => open,
      rd_en         => feat_rd_en,
      rd_addr       => feat_rd_addr,
      rd_count      => feat_rd_count,
      rd_power      => feat_rd_power
    );

end architecture rtl;

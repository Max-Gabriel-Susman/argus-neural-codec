--------------------------------------------------------------------------------
-- argus_acq_top.vhd
--
-- The complete acquisition chain behind one AXI4-Lite interface: SPI master,
-- three simulated RHD2132 chips, frame assembler, register block. This is
-- the module the block design instantiates on M_AXI_GP0.
--
-- The chips are internal (Option B, simulated Intan). There are no external
-- SPI pins: the bus never leaves the fabric, so there is nothing to
-- constrain. Bring-up visibility comes from an ILA on the internal signals
-- rather than a scope. When real silicon arrives, a generic here selects
-- external MISO and routes the bus out to pins; the master and assembler
-- do not change.
--
-- Two resets:
--   s_axi_aresetn  from the PS, via proc_sys_reset, covers everything
--   soft_reset     from CTRL bit 1, covers the chain but not the register
--                  block, so the PS can restart acquisition from a known
--                  state without losing the bus
--
-- Port names follow the AXI4-Lite convention so the block design infers the
-- interface when this is added as an RTL module.
--
-- VHDL-93 compatible.
--------------------------------------------------------------------------------

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity argus_acq_top is
  generic (
    C_S_AXI_ADDR_WIDTH : natural := 12;
    CHIP_COUNT         : natural := 3;
    CH_PER_CHIP        : natural := 32;
    AUX_SLOTS          : natural := 3;
    SLOT_CLOCKS        : natural := 119;
    SCLK_DIV           : natural := 5
  );
  port (
    s_axi_aclk    : in    std_logic;
    s_axi_aresetn : in    std_logic;

    s_axi_awaddr  : in    std_logic_vector(C_S_AXI_ADDR_WIDTH - 1 downto 0);
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
    s_axi_araddr  : in    std_logic_vector(C_S_AXI_ADDR_WIDTH - 1 downto 0);
    s_axi_arprot  : in    std_logic_vector(2 downto 0);
    s_axi_arvalid : in    std_logic;
    s_axi_arready : out   std_logic;
    s_axi_rdata   : out   std_logic_vector(31 downto 0);
    s_axi_rresp   : out   std_logic_vector(1 downto 0);
    s_axi_rvalid  : out   std_logic;
    s_axi_rready  : in    std_logic
  );
end entity argus_acq_top;

architecture rtl of argus_acq_top is

  constant TOTAL_CHANNELS : natural := CHIP_COUNT * CH_PER_CHIP;

  signal chain_rst_n : std_logic;
  signal enable      : std_logic;
  signal soft_reset  : std_logic;
  signal ready       : std_logic;
  signal overrun     : std_logic;
  signal frame_index : unsigned(31 downto 0);

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

  signal rd_en   : std_logic;
  signal rd_addr : unsigned(7 downto 0);
  signal rd_data : std_logic_vector(15 downto 0);

begin

  -- soft_reset is a registered output of the AXI block, so this is a
  -- synchronous reset for the chain.
  chain_rst_n <= s_axi_aresetn and not soft_reset;

  regs : entity work.argus_acq_axi(rtl)
    generic map (
      C_S_AXI_ADDR_WIDTH => C_S_AXI_ADDR_WIDTH,
      TOTAL_CHANNELS     => TOTAL_CHANNELS
    )
    port map (
      s_axi_aclk    => s_axi_aclk,
      s_axi_aresetn => s_axi_aresetn,
      s_axi_awaddr  => s_axi_awaddr,
      s_axi_awprot  => s_axi_awprot,
      s_axi_awvalid => s_axi_awvalid,
      s_axi_awready => s_axi_awready,
      s_axi_wdata   => s_axi_wdata,
      s_axi_wstrb   => s_axi_wstrb,
      s_axi_wvalid  => s_axi_wvalid,
      s_axi_wready  => s_axi_wready,
      s_axi_bresp   => s_axi_bresp,
      s_axi_bvalid  => s_axi_bvalid,
      s_axi_bready  => s_axi_bready,
      s_axi_araddr  => s_axi_araddr,
      s_axi_arprot  => s_axi_arprot,
      s_axi_arvalid => s_axi_arvalid,
      s_axi_arready => s_axi_arready,
      s_axi_rdata   => s_axi_rdata,
      s_axi_rresp   => s_axi_rresp,
      s_axi_rvalid  => s_axi_rvalid,
      s_axi_rready  => s_axi_rready,
      enable        => enable,
      soft_reset    => soft_reset,
      ready         => ready,
      overrun       => overrun,
      frame_index   => frame_index,
      rd_en         => rd_en,
      rd_addr       => rd_addr,
      rd_data       => rd_data
    );

  master : entity work.argus_rhd_spi_master(rtl)
    generic map (
      CHIP_COUNT  => CHIP_COUNT,
      CH_PER_CHIP => CH_PER_CHIP,
      AUX_SLOTS   => AUX_SLOTS,
      SLOT_CLOCKS => SLOT_CLOCKS,
      SCLK_DIV    => SCLK_DIV
    )
    port map (
      clk          => s_axi_aclk,
      rst_n        => chain_rst_n,
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

  chips : for c in 0 to CHIP_COUNT - 1 generate

    chip_inst : entity work.argus_rhd2132_model(rtl)
      generic map (
        CH_PER_CHIP  => CH_PER_CHIP,
        CHIP_ID      => c,
        CHIP_TYPE_ID => 1,
        PATTERN      => 0
      )
      port map (
        clk           => s_axi_aclk,
        rst_n         => chain_rst_n,
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

  assembler : entity work.argus_frame_assembler(rtl)
    generic map (
      CHIP_COUNT  => CHIP_COUNT,
      CH_PER_CHIP => CH_PER_CHIP
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
      rd_en        => rd_en,
      rd_addr      => rd_addr,
      rd_data      => rd_data,
      overrun      => overrun
    );

end architecture rtl;

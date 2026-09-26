--------------------------------------------------------------------------------
-- argus_acq_top.vhd
--
-- The complete acquisition chain behind one AXI4-Lite interface: SPI master,
-- three simulated RHD2132 chips, sample fetcher, frame assembler, register
-- block. This is the module the block design instantiates on M_AXI_GP0.
--
-- The chips are internal (Option B, simulated Intan). There are no external
-- SPI pins: the bus never leaves the fabric, so there is nothing to
-- constrain. Bring-up visibility comes from an ILA on the internal signals
-- rather than a scope. When real silicon arrives, a generic here selects
-- external MISO and routes the bus out to pins; the master and assembler
-- do not change.
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
    aux_slots          : natural := 3;
    slot_clocks        : natural := 119;
    sclk_div           : natural := 5;
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
    bram_dout : in    std_logic_vector(31 downto 0)
  );
end entity argus_acq_top;

architecture rtl of argus_acq_top is

  constant total_channels : natural := chip_count * ch_per_chip;

  signal chain_rst_n : std_logic;
  signal enable      : std_logic;
  signal soft_reset  : std_logic;
  signal ext_mode    : std_logic;
  signal ready       : std_logic;
  signal overrun     : std_logic;
  signal frame_index : unsigned(31 downto 0);

  signal sclk : std_logic;
  signal cs_n : std_logic;
  signal mosi : std_logic;
  signal miso : std_logic_vector(chip_count - 1 downto 0);

  signal miso_oe : std_logic_vector(chip_count - 1 downto 0);

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

  signal play_half       : std_logic;
  signal play_row        : unsigned(15 downto 0);
  signal half_consumed   : std_logic_vector(1 downto 0);
  signal replay_underrun : std_logic;
  signal ack_consumed    : std_logic_vector(1 downto 0);
  signal clear_underrun  : std_logic;

begin

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
      ready           => ready,
      overrun         => overrun,
      frame_index     => frame_index,
      play_half       => play_half,
      play_row        => play_row,
      half_consumed   => half_consumed,
      replay_underrun => replay_underrun,
      ack_consumed    => ack_consumed,
      clear_underrun  => clear_underrun,
      rd_en           => rd_en,
      rd_addr         => rd_addr,
      rd_data         => rd_data
    );

  master : entity work.argus_rhd_spi_master(rtl)
    generic map (
      chip_count  => chip_count,
      ch_per_chip => ch_per_chip,
      aux_slots   => aux_slots,
      slot_clocks => slot_clocks,
      sclk_div    => sclk_div
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
          miso          => miso(c),
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
          miso          => miso(c),
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
      rd_en        => rd_en,
      rd_addr      => rd_addr,
      rd_data      => rd_data,
      overrun      => overrun
    );

end architecture rtl;

--------------------------------------------------------------------------------
-- argus_acq_axi.vhd
--
-- AXI4-Lite register block exposing the acquisition chain to the PS.
--
-- REGISTER MAP (byte offsets, 32-bit words)
--
--   0x000  CTRL         RW   bit 0  enable      start / park the master
--                            bit 1  soft_reset  hold the chain in reset
--   0x004  STATUS       RO   bit 0  ready       init sequence complete
--                            bit 1  overrun     assembler dropped a slot
--   0x008  FRAME_INDEX  RO   increments once per completed sweep
--   0x00C  ID           RO   0x41435131 "ACQ1" -- read this first
--   0x100  FRAME[0]     RO   one 16-bit sample in the low half of each word
--     ..
--   0x27C  FRAME[95]
--
-- Everything else reads 0xDEADBEEF with an OKAY response. SLVERR would be
-- more honest, but a Cortex-A9 raises a data abort on it, which is a bad
-- way to discover an address-map typo during bring-up.
--
-- READING A FRAME
--   FRAME words come from the assembler's read port, which is registered, so
--   a FRAME read takes two extra cycles compared to a register. The
--   assembler is double buffered and the bank switches on every sweep, so a
--   full 96-word read must complete within one sweep (33 us at 30 kS/s) to
--   be coherent. Software should read FRAME_INDEX before and after and retry
--   if it moved -- a seqlock, no hardware needed.
--
-- The write path accepts AW and W only when both are valid, which is legal
-- for AXI4-Lite and avoids tracking them separately.
--
-- VHDL-93 compatible.
--------------------------------------------------------------------------------

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity argus_acq_axi is
  generic (
    c_s_axi_addr_width : natural := 12;
    total_channels     : natural := 96
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

    -- Control out, status in
    enable      : out   std_logic;
    soft_reset  : out   std_logic;
    ready       : in    std_logic;
    overrun     : in    std_logic;
    frame_index : in    unsigned(31 downto 0);

    -- Frame read port, to the assembler
    rd_en   : out   std_logic;
    rd_addr : out   unsigned(7 downto 0);
    rd_data : in    std_logic_vector(15 downto 0)
  );
end entity argus_acq_axi;

architecture rtl of argus_acq_axi is

  constant id_value : std_logic_vector(31 downto 0) := x"41435131";
  constant unmapped : std_logic_vector(31 downto 0) := x"DEADBEEF";

  -- Word addresses.
  constant w_ctrl        : natural := 0;
  constant w_status      : natural := 1;
  constant w_frame_index : natural := 2;
  constant w_id          : natural := 3;
  constant w_frame_base  : natural := 64;    -- 0x100

  constant resp_okay : std_logic_vector(1 downto 0) := "00";

  type wr_state_t is (wr_idle, wr_resp);

  type rd_state_t is (rd_idle, rd_ram, rd_wait, rd_resp);

  signal wr_state : wr_state_t;
  signal rd_state : rd_state_t;

  signal awready_r : std_logic;
  signal wready_r  : std_logic;
  signal bvalid_r  : std_logic;
  signal arready_r : std_logic;
  signal rvalid_r  : std_logic;
  signal rdata_r   : std_logic_vector(31 downto 0);

  signal wr_word : natural range 0 to 1023;
  signal wr_data : std_logic_vector(31 downto 0);
  signal wr_strb : std_logic_vector(3 downto 0);
  signal rd_word : natural range 0 to 1023;

  signal ctrl_enable : std_logic;
  signal ctrl_reset  : std_logic;

  signal rd_en_r   : std_logic;
  signal rd_addr_r : unsigned(7 downto 0);

  function word_of (
    addr : std_logic_vector
  ) return natural is
  begin

    return to_integer(unsigned(addr(addr'high downto 2)));

  end function word_of;

begin

  assert C_S_AXI_ADDR_WIDTH >= 10
    report "C_S_AXI_ADDR_WIDTH must cover the 0x27C frame region"
    severity failure;

  --------------------------------------------------------------------------
  -- Write channel
  --------------------------------------------------------------------------

  writer : process (s_axi_aclk) is
  begin

    if rising_edge(s_axi_aclk) then
      if (s_axi_aresetn = '0') then
        wr_state    <= wr_idle;
        awready_r   <= '0';
        wready_r    <= '0';
        bvalid_r    <= '0';
        wr_word     <= 0;
        wr_data     <= (others => '0');
        wr_strb     <= (others => '0');
        ctrl_enable <= '0';
        ctrl_reset  <= '0';
      else

        case wr_state is

          when wr_idle =>

            -- Accept both channels together. ready pulses for one cycle the
            -- clock after both valids are seen; the handshake completes in
            -- that cycle and the captured values are what were on the bus.
            if ((s_axi_awvalid = '1') and (s_axi_wvalid = '1') and (awready_r = '0')) then
              awready_r <= '1';
              wready_r  <= '1';
              wr_word   <= word_of(s_axi_awaddr);
              wr_data   <= s_axi_wdata;
              wr_strb   <= s_axi_wstrb;
            end if;

            if (awready_r = '1') then
              awready_r <= '0';
              wready_r  <= '0';

              -- Only CTRL is writable. Writes elsewhere are acknowledged and
              -- discarded, matching read-only register semantics.
              if ((wr_word = w_ctrl) and (wr_strb(0) = '1')) then
                ctrl_enable <= wr_data(0);
                ctrl_reset  <= wr_data(1);
              end if;

              bvalid_r <= '1';
              wr_state <= wr_resp;
            end if;

          when wr_resp =>

            if (s_axi_bready = '1') then
              bvalid_r <= '0';
              wr_state <= wr_idle;
            end if;

        end case;

      end if;
    end if;

  end process writer;

  --------------------------------------------------------------------------
  -- Read channel
  --------------------------------------------------------------------------

  reader : process (s_axi_aclk) is

    variable n : natural;

  begin

    if rising_edge(s_axi_aclk) then
      if (s_axi_aresetn = '0') then
        rd_state  <= rd_idle;
        arready_r <= '0';
        rvalid_r  <= '0';
        rdata_r   <= (others => '0');
        rd_word   <= 0;
        rd_en_r   <= '0';
        rd_addr_r <= (others => '0');
      else
        rd_en_r <= '0';

        case rd_state is

          when rd_idle =>

            if ((s_axi_arvalid = '1') and (arready_r = '0')) then
              arready_r <= '1';
              rd_word   <= word_of(s_axi_araddr);
            end if;

            if (arready_r = '1') then
              arready_r <= '0';

              if ((rd_word >= w_frame_base) and (rd_word < w_frame_base + total_channels)) then
                -- Frame word: issue the RAM read, collect it two cycles on.
                n         := rd_word - w_frame_base;
                rd_addr_r <= to_unsigned(n, 8);
                rd_en_r   <= '1';
                rd_state  <= rd_ram;
              else

                case rd_word is

                  when w_ctrl =>

                    rdata_r <= (0 => ctrl_enable, 1 => ctrl_reset, others => '0');

                  when w_status =>

                    rdata_r <= (0 => ready, 1 => overrun, others => '0');

                  when w_frame_index =>

                    rdata_r <= std_logic_vector(frame_index);

                  when w_id =>

                    rdata_r <= id_value;

                  when others =>

                    rdata_r <= unmapped;

                end case;

                rvalid_r <= '1';
                rd_state <= rd_resp;
              end if;
            end if;

          when rd_ram =>

            -- rd_en was high last cycle; the assembler registers its output
            -- on this edge. One more cycle before it is valid.
            rd_state <= rd_wait;

          when rd_wait =>

            rdata_r  <= x"0000" & rd_data;
            rvalid_r <= '1';
            rd_state <= rd_resp;

          when rd_resp =>

            if (s_axi_rready = '1') then
              rvalid_r <= '0';
              rd_state <= rd_idle;
            end if;

        end case;

      end if;
    end if;

  end process reader;

  s_axi_awready <= awready_r;
  s_axi_wready  <= wready_r;
  s_axi_bresp   <= resp_okay;
  s_axi_bvalid  <= bvalid_r;
  s_axi_arready <= arready_r;
  s_axi_rdata   <= rdata_r;
  s_axi_rresp   <= resp_okay;
  s_axi_rvalid  <= rvalid_r;

  enable     <= ctrl_enable;
  soft_reset <= ctrl_reset;
  rd_en      <= rd_en_r;
  rd_addr    <= rd_addr_r;

end architecture rtl;

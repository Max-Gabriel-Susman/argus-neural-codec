--------------------------------------------------------------------------------
-- argus_sample_fetch.vhd
--
-- Serves the simulated chips their samples from the ping-pong BRAM the PS
-- fills over AXI, and tracks where in that buffer playback is.
--
-- All CHIP_COUNT models retire the same CONVERT on the same clock, so one
-- request from chip 0 stands for all of them. The fetcher reads one word
-- per chip from the current sample row -- offsets ch, 32+ch, 64+ch -- over
-- a few cycles, then acks every model at once with its own lane. There are
-- SLOT_CLOCKS (119) clocks between retires and this takes about fourteen.
--
-- BRAM LAYOUT
--   Two halves of SAMPLES_PER_HALF rows, each row TOTAL_CHANNELS 16-bit
--   samples, sample-major channel-minor: exactly the relay's chunk payload,
--   so the PS copies chunks straight in with no reshuffling. Port B is
--   32 bits wide and byte addressed (BRAM-controller convention), so two
--   samples share a word: even channel in bits 15:0, odd in 31:16.
--
-- PING-PONG
--   Playback advances one row when the last amplifier channel is served.
--   At the end of a half it flips to the other and sets that half's
--   consumed flag (sticky, cleared by ack_consumed). If it flips INTO a
--   half whose flag is still set, the PS did not refill in time: underrun
--   is set (sticky) and playback continues with stale data rather than
--   stalling the bus.
--
-- READ TIMING
--   The address is held READ_HOLD cycles before dout is sampled, which is
--   correct for a Block Memory Generator with or without its optional
--   output register. Slack is plentiful, so robustness wins over speed.
--
-- NO MULTIPLIER
--   row_base is maintained incrementally -- add one row's worth of samples
--   per advance, reset at each flip -- rather than computed as row * 96.
--   Vivado infers an unregistered DSP48 for the multiply, which alone is a
--   4-5 ns path and failed 125 MHz out of context by 0.55 ns.
--
-- VHDL-93 compatible.
--------------------------------------------------------------------------------

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity argus_sample_fetch is
  generic (
    chip_count       : natural := 3;
    ch_per_chip      : natural := 32;
    samples_per_half : natural := 147;
    read_hold        : natural := 3
  );
  port (
    clk    : in    std_logic;
    rst_n  : in    std_logic;
    enable : in    std_logic;

    -- From chip 0 (all chips request identically).
    req    : in    std_logic;
    req_ch : in    unsigned(5 downto 0);

    -- To every chip. Lane c of data is bits (c*16+15 downto c*16).
    ack  : out   std_logic;
    data : out   std_logic_vector(chip_count * 16 - 1 downto 0);

    -- BRAM port B, master side.
    bram_en   : out   std_logic;
    bram_we   : out   std_logic_vector(3 downto 0);
    bram_addr : out   std_logic_vector(31 downto 0);
    bram_din  : out   std_logic_vector(31 downto 0);
    bram_dout : in    std_logic_vector(31 downto 0);

    -- Playback state, to the register block.
    play_half     : out   std_logic;
    play_row      : out   unsigned(15 downto 0);
    half_consumed : out   std_logic_vector(1 downto 0);
    underrun      : out   std_logic;

    -- From the register block. Pulses.
    ack_consumed   : in    std_logic_vector(1 downto 0);
    clear_underrun : in    std_logic
  );
end entity argus_sample_fetch;

architecture rtl of argus_sample_fetch is

  constant total_channels : natural := chip_count * ch_per_chip;
  constant half_samples   : natural := samples_per_half * total_channels;

  type state_t is (st_idle, st_addr, st_wait, st_done);

  signal state : state_t;

  signal lane     : natural range 0 to 15;
  signal hold_cnt : natural range 0 to 15;
  signal cur_ch   : unsigned(5 downto 0);

  -- Sample index of column 0 of the row being played.
  signal row_base : unsigned(15 downto 0);
  signal row      : unsigned(15 downto 0);
  signal half     : std_logic;

  signal consumed_r : std_logic_vector(1 downto 0);
  signal underrun_r : std_logic;

  signal ack_r  : std_logic;
  signal data_r : std_logic_vector(chip_count * 16 - 1 downto 0);
  signal addr_r : unsigned(31 downto 0);
  signal idx    : unsigned(15 downto 0);


begin

  assert chip_count <= 16
    report "chip_count exceeds the lane counter range"
    severity failure;

  assert 2 * half_samples <= 32768
    report "two halves exceed the 16-bit sample index"
    severity failure;

  fetch : process (clk) is
  begin

    if rising_edge(clk) then
      if ((rst_n = '0') or (enable = '0')) then
        state      <= st_idle;
        lane       <= 0;
        hold_cnt   <= 0;
        cur_ch     <= (others => '0');
        row        <= (others => '0');
        half       <= '0';
        row_base   <= (others => '0');
        consumed_r <= (others => '0');
        underrun_r <= '0';
        ack_r      <= '0';
        data_r     <= (others => '0');
        addr_r     <= (others => '0');
        idx        <= (others => '0');
      else
        ack_r <= '0';

        -- Sticky flags, cleared by the register block.
        if (ack_consumed(0) = '1') then
          consumed_r(0) <= '0';
        end if;

        if (ack_consumed(1) = '1') then
          consumed_r(1) <= '0';
        end if;

        if (clear_underrun = '1') then
          underrun_r <= '0';
        end if;

        case state is

          when st_idle =>

            if (req = '1') then
              cur_ch <= req_ch;
              lane   <= 0;
              state  <= st_addr;
            end if;

          when st_addr =>

            -- Sample index for this lane, then its 32-bit word address.
            idx      <= row_base + to_unsigned(lane * ch_per_chip, 16) + resize(cur_ch, 16);
            hold_cnt <= read_hold;
            state    <= st_wait;

          when st_wait =>

            addr_r <= resize(idx(15 downto 1) & "00", 32);

            if (hold_cnt = 0) then

              if (idx(0) = '0') then
                data_r(lane * 16 + 15 downto lane * 16) <= bram_dout(15 downto 0);
              else
                data_r(lane * 16 + 15 downto lane * 16) <= bram_dout(31 downto 16);
              end if;

              if (lane = chip_count - 1) then
                state <= st_done;
              else
                lane  <= lane + 1;
                state <= st_addr;
              end if;
            else
              hold_cnt <= hold_cnt - 1;
            end if;

          when st_done =>

            ack_r <= '1';
            state <= st_idle;

            -- Last amplifier channel served: advance the row, flipping at
            -- the end of the half.
            if (cur_ch = ch_per_chip - 1) then
              if (row = samples_per_half - 1) then
                row  <= (others => '0');
                half <= not half;

                -- Hand this half to the PS and start the other one. If the
                -- other half is still marked consumed, the PS is behind and
                -- we are about to replay stale data.
                if (half = '0') then
                  row_base      <= to_unsigned(half_samples, 16);
                  consumed_r(0) <= '1';

                  if (consumed_r(1) = '1') then
                    underrun_r <= '1';
                  end if;
                else
                  row_base      <= (others => '0');
                  consumed_r(1) <= '1';

                  if (consumed_r(0) = '1') then
                    underrun_r <= '1';
                  end if;
                end if;
              else
                row      <= row + 1;
                row_base <= row_base + total_channels;
              end if;
            end if;

        end case;

      end if;
    end if;

  end process fetch;

  ack  <= ack_r;
  data <= data_r;

  bram_en   <= '1';
  bram_we   <= (others => '0');
  bram_addr <= std_logic_vector(addr_r);
  bram_din  <= (others => '0');

  play_half     <= half;
  play_row      <= row;
  half_consumed <= consumed_r;
  underrun      <= underrun_r;

end architecture rtl;

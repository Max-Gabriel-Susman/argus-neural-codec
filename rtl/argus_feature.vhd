--------------------------------------------------------------------------------
-- argus_feature.vhd
--
-- Per-channel feature extraction on the slot stream: the codec. Turns the
-- 30 kHz sample stream into what the decoder consumes, one pair of numbers
-- per channel per bin:
--
--   count  threshold crossings -- the high-passed sample going below
--          -MULT x RMS, RMS a running estimate, one count per crossing with
--          a refractory hold-off
--   power  spike-band power -- the sum of the squared high-passed sample
--          over the bin
--
-- The arithmetic is the contract in argus_sim/tools/spike_features.py,
-- line for line, and the testbench compares this block's output against
-- that model's golden file exactly. Parameters were chosen by decoding
-- accuracy on real cortex (argus_sim/tools/README.md); the defaults here
-- are the locked values.
--
-- ARITHMETIC (Q1.15 coefficients; >> is an arithmetic shift, i.e. floor)
--
--   x    = sample - 32768                            16-bit signed
--   d    = x - x1                                    17-bit signed
--   y    = (B0*d + A1*y1 + 2^14) >> 15              18-bit signed, |y| <= 2^15
--   sq   = y*y                                       32-bit unsigned, <= 2^30
--   thrp = (ms * MULT_NUM) >> MULT_SHIFT             from the stored ms
--   u    = min(sq, thrp)   once tracking, else sq   winsorised EMA input
--   ms'  = ms + ((u - ms + 2^(k-1)) >> k)           k = K_FAST for the first
--                                                   2^K sweeps, then K
--   thr  = (ms' * MULT_NUM) >> MULT_SHIFT
--   below = (sq > thr) and (y < 0)
--   cross = below and not below_prev and refrac = 0 and sweep >= WARMUP
--   count += cross; power += sq
--   refrac = REFRAC on a cross, else max(refrac - 1, 0)
--
-- Both +2^(..) terms are rounding. The model found that the floor alone,
-- inside a recursion, biases y by -10 codes and ms by -2^(k-1) -- the
-- latter quietly turning 4.5 sigma into 3.5. A constant before a shift
-- fixes each.
--
-- STRUCTURE
--   One datapath, time-multiplexed. The master emits one slot per channel
--   index per sweep, carrying all three chips' samples for that index, 119
--   clocks apart. This block serialises the three chips and walks each
--   sample through the arithmetic in eight clocks -- 26 per slot -- against
--   state held in a 96-entry RAM, one 136-bit word per channel. Nothing is
--   replicated; the multipliers are three DSP48s.
--
--   State per channel: x1, y1, ms, below_prev, refrac, and the running
--   count and power for the current bin.
--
-- BINS AND THE FEATURE BANK
--   Every BIN_LEN sweeps, as each channel of the bin's last sweep is
--   processed, its count and power are written to the fill bank and its
--   accumulators reset. When that sweep ends the banks swap and
--   FEATURE_INDEX increments. The PS reads the other bank.
--
--   hold/held work as they do for the frame, with one difference: a bin
--   that completes while held is not discarded. Its swap is deferred to the
--   end of the first sweep after hold is released. Only if a second bin
--   completes before that -- a hold longer than 50 ms -- is the first
--   overwritten, and DROPPED counts it. The PS holds for ~0.2 ms.
--
--   The read port is registered: assert rd_en with rd_addr = channel, and
--   rd_count / rd_power are valid on the following clock.
--
-- SWEEP COUNT
--   Sweeps are counted at slot_last. The count is latched when each slot
--   arrives, so every channel of one sweep sees the same sweep number
--   regardless of where in the slot order slot_last falls. Warm-up, the
--   fast-attack window, and bin boundaries are all in sweeps, matching the
--   model's row index.
--
-- Reset zeroes the state RAM and both banks: 288 clocks, during which
-- slots are ignored. The master's initialisation takes far longer.
--
-- VHDL-93 compatible.
--------------------------------------------------------------------------------

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity argus_feature is
  generic (
    chip_count    : natural := 3;
    ch_per_chip   : natural := 32;
    b0            : integer := 31932; -- Q1.15, 250 Hz first-order HPF at 30012 Hz
    a1            : integer := 31096; -- Q1.15
    mult_num      : natural := 49;    -- threshold^2 = mult_num / 2^mult_shift x ms
    mult_shift    : natural := 2;     --   49/4 = 12.25 = 3.5^2
    ms_shift      : natural := 15;    -- EMA shift while tracking
    ms_shift_fast : natural := 8;     -- EMA shift for the first 2^ms_shift sweeps
    refrac_len    : natural := 30;    -- sweeps, ~1 ms
    warmup        : natural := 32768; -- sweeps before crossings count
    bin_len       : natural := 1500   -- sweeps per bin, 50 ms
  );
  port (
    clk   : in    std_logic;
    rst_n : in    std_logic;

    -- Slot stream, tapped between the master and the assembler
    slot_valid   : in    std_logic;
    slot_channel : in    unsigned(5 downto 0);
    slot_data    : in    std_logic_vector(chip_count * 16 - 1 downto 0);
    slot_is_aux  : in    std_logic;
    slot_last    : in    std_logic;

    -- Feature bank hold, as the frame's
    hold : in    std_logic;
    held : out   std_logic;

    feature_index : out   unsigned(31 downto 0);
    dropped       : out   unsigned(15 downto 0);
    busy          : out   std_logic; -- mid-slot; a slot arriving now is lost

    -- Feature bank read port, registered
    rd_en    : in    std_logic;
    rd_addr  : in    unsigned(6 downto 0);
    rd_count : out   unsigned(15 downto 0);
    rd_power : out   unsigned(47 downto 0)
  );
end entity argus_feature;

architecture rtl of argus_feature is

  constant total_channels : natural := chip_count * ch_per_chip;

  -- State word layout
  constant x1_lo     : natural := 0;  -- 16
  constant y1_lo     : natural := 16; -- 18
  constant ms_lo     : natural := 34; -- 32
  constant below_bit : natural := 66; -- 1
  constant refr_lo   : natural := 67; -- 5
  constant cnt_lo    : natural := 72; -- 16
  constant pow_lo    : natural := 88; -- 48
  constant state_w   : natural := 136;

  type state_ram_t is array (0 to total_channels - 1) of std_logic_vector(state_w - 1 downto 0);

  signal ram_raddr : natural range 0 to total_channels - 1;
  signal ram_waddr : natural range 0 to total_channels - 1;
  signal ram_we    : std_logic;
  signal ram_d     : std_logic_vector(state_w - 1 downto 0);
  signal ram_q     : std_logic_vector(state_w - 1 downto 0);

  -- Feature bank: two banks of total_channels, {power[47:0], count[15:0]}

  type bank_t is array (0 to 2 * total_channels - 1) of std_logic_vector(63 downto 0);

  signal bank_waddr : natural range 0 to 2 * total_channels - 1;
  signal bank_we    : std_logic;
  signal bank_d     : std_logic_vector(63 downto 0);
  signal bank_q     : std_logic_vector(63 downto 0);
  signal rd_bank    : std_logic;

  type fsm_t is (
    s_init, s_idle, s_read, s_unpack, s_mult, s_filter, s_square,
    s_ema, s_decide, s_write, s_next, s_done
  );

  signal fsm : fsm_t;

  signal init_cnt : natural range 0 to 2 * total_channels + total_channels;

  -- Latched slot
  signal l_data    : std_logic_vector(chip_count * 16 - 1 downto 0);
  signal l_channel : natural range 0 to ch_per_chip - 1;
  signal l_last    : std_logic;
  signal l_sweep   : unsigned(31 downto 0);
  signal l_binlast : std_logic;
  signal chip      : natural range 0 to chip_count - 1;

  signal sweep_count   : unsigned(31 downto 0);
  signal bin_end_sweep : unsigned(31 downto 0);
  signal findex        : unsigned(31 downto 0);
  signal dropped_r     : unsigned(15 downto 0);
  signal swap_pending  : std_logic;
  signal hold_r        : std_logic;

  -- Datapath registers
  constant b0_s : signed(15 downto 0) := to_signed(b0, 16);
  constant a1_s : signed(15 downto 0) := to_signed(a1, 16);

  signal x          : signed(15 downto 0);
  signal x1         : signed(15 downto 0);
  signal y1         : signed(17 downto 0);
  signal ms         : unsigned(31 downto 0);
  signal below_prev : std_logic;
  signal refrac     : unsigned(4 downto 0);
  signal count      : unsigned(15 downto 0);
  signal power      : unsigned(47 downto 0);

  signal d          : signed(16 downto 0);
  signal p1         : signed(32 downto 0);
  signal p2         : signed(33 downto 0);
  signal y          : signed(17 downto 0);
  signal sq         : unsigned(31 downto 0);
  signal thrp       : unsigned(39 downto 0);
  signal ms_new     : unsigned(31 downto 0);
  signal thr        : unsigned(39 downto 0);
  signal below      : std_logic;
  signal count_new  : unsigned(15 downto 0);
  signal power_new  : unsigned(47 downto 0);
  signal refrac_new : unsigned(4 downto 0);

  signal fast   : std_logic; -- l_sweep < 2^ms_shift
  signal warmed : std_logic; -- l_sweep >= warmup

  function thr_of (
    m : unsigned(31 downto 0)
  ) return unsigned is

    variable prod : unsigned(39 downto 0);

  begin

    prod := m * to_unsigned(mult_num, 8);
    return shift_right(prod, mult_shift);

  end function thr_of;

begin

  --------------------------------------------------------------------------
  -- Memories. Synchronous read, so they can be block RAM. Held as process
  -- variables rather than signals: an array signal written through a
  -- dynamic index makes the process a driver of every element, and GHDL
  -- then updates all 25k scalars every clock. Vivado infers RAM from a
  -- clocked-process variable the same way it does from a signal.
  --------------------------------------------------------------------------

  mem : process (clk) is

    variable state_ram : state_ram_t;
    variable bank      : bank_t;

  begin

    if rising_edge(clk) then
      ram_q <= state_ram(ram_raddr);
      if (ram_we = '1') then
        state_ram(ram_waddr) := ram_d;
      end if;

      if (bank_we = '1') then
        bank(bank_waddr) := bank_d;
      end if;

      if (rd_en = '1') then
        if (rd_bank = '1') then
          bank_q <= bank(total_channels + to_integer(rd_addr));
        else
          bank_q <= bank(to_integer(rd_addr));
        end if;
      end if;
    end if;

  end process mem;

  rd_count <= unsigned(bank_q(15 downto 0));
  rd_power <= unsigned(bank_q(63 downto 16));

  --------------------------------------------------------------------------
  -- Sequencer and datapath
  --------------------------------------------------------------------------

  main : process (clk) is

    variable acc     : signed(34 downto 0);
    variable ysq     : signed(35 downto 0);
    variable u       : unsigned(31 downto 0);
    variable diff    : signed(33 downto 0);
    variable step    : signed(33 downto 0);
    variable ms_next : signed(33 downto 0);
    variable ch_addr : natural range 0 to total_channels - 1;

  begin

    if rising_edge(clk) then
      if (rst_n = '0') then
        fsm           <= s_init;
        init_cnt      <= 0;
        ram_we        <= '0';
        bank_we       <= '0';
        ram_raddr     <= 0;
        ram_waddr     <= 0;
        bank_waddr    <= 0;
        rd_bank       <= '0';
        sweep_count   <= (others => '0');
        bin_end_sweep <= to_unsigned(bin_len - 1, 32);
        findex        <= (others => '0');
        dropped_r     <= (others => '0');
        swap_pending  <= '0';
        hold_r        <= '0';
        chip          <= 0;
        l_last        <= '0';
        l_binlast     <= '0';
        l_channel     <= 0;
        l_sweep       <= (others => '0');
      else
        ram_we  <= '0';
        bank_we <= '0';
        hold_r  <= hold;

        case fsm is

          when s_init =>

            -- Zero the state RAM, then both banks.
            if (init_cnt < total_channels) then
              ram_waddr <= init_cnt;
              ram_d     <= (others => '0');
              ram_we    <= '1';
            else
              bank_waddr <= init_cnt - total_channels;
              bank_d     <= (others => '0');
              bank_we    <= '1';
            end if;

            if (init_cnt = 3 * total_channels - 1) then
              fsm <= s_idle;
            else
              init_cnt <= init_cnt + 1;
            end if;

          when s_idle =>

            if (slot_valid = '1') then
              l_data    <= slot_data;
              l_channel <= to_integer(slot_channel(4 downto 0));
              l_last    <= slot_last;
              l_sweep   <= sweep_count;
              chip      <= 0;
              ram_raddr <= to_integer(slot_channel(4 downto 0));

              if (sweep_count = bin_end_sweep) then
                l_binlast <= '1';
              else
                l_binlast <= '0';
              end if;

              if (slot_last = '1') then
                sweep_count <= sweep_count + 1;
              end if;

              if (slot_is_aux = '1') then
                fsm <= s_done;
              else
                fsm <= s_read;
              end if;
            end if;

          when s_read =>

            -- ram_raddr was set as the slot was latched (or in s_next for the
            -- chips after the first); ram_q loads on this edge and is read in
            -- s_unpack. Offset binary to two's complement is one bit flip.
            x   <= signed(l_data(chip * 16 + 15 downto chip * 16) xor x"8000");
            fsm <= s_unpack;

          when s_unpack =>

            -- ram_q is valid now.
            x1         <= signed(ram_q(x1_lo + 15 downto x1_lo));
            y1         <= signed(ram_q(y1_lo + 17 downto y1_lo));
            ms         <= unsigned(ram_q(ms_lo + 31 downto ms_lo));
            below_prev <= ram_q(below_bit);
            refrac     <= unsigned(ram_q(refr_lo + 4 downto refr_lo));
            count      <= unsigned(ram_q(cnt_lo + 15 downto cnt_lo));
            power      <= unsigned(ram_q(pow_lo + 47 downto pow_lo));

            if (l_sweep < to_unsigned(2 ** ms_shift, 32)) then
              fast <= '1';
            else
              fast <= '0';
            end if;

            if (l_sweep >= to_unsigned(warmup, 32)) then
              warmed <= '1';
            else
              warmed <= '0';
            end if;

            fsm <= s_mult;

          when s_mult =>

            d   <= resize(x, 17) - resize(x1, 17);
            p2  <= a1_s * y1;
            fsm <= s_filter;

          when s_filter =>

            p1  <= b0_s * d;
            fsm <= s_square;

          when s_square =>

            acc  := resize(p1, 35) + resize(p2, 35) + to_signed(2 ** 14, 35);
            y    <= resize(shift_right(acc, 15), 18);
            thrp <= thr_of(ms);
            fsm  <= s_ema;

          when s_ema =>

            ysq := y * y;
            sq  <= unsigned(std_logic_vector(resize(ysq, 32)));
            fsm <= s_decide;

          when s_decide =>

            -- EMA input: winsorised once tracking.
            if (fast = '1') then
              u := sq;
            elsif (resize(sq, 40) > thrp) then
              u := thrp(31 downto 0);
            else
              u := sq;
            end if;

            diff := signed(resize(u, 34)) - signed(resize(ms, 34));

            if (fast = '1') then
              step := shift_right(diff + to_signed(2 ** (ms_shift_fast - 1), 34), ms_shift_fast);
            else
              step := shift_right(diff + to_signed(2 ** (ms_shift - 1), 34), ms_shift);
            end if;

            ms_next := signed(resize(ms, 34)) + step;
            ms_new  <= unsigned(std_logic_vector(ms_next(31 downto 0)));
            thr     <= thr_of(unsigned(std_logic_vector(ms_next(31 downto 0))));
            fsm     <= s_write;

          when s_write =>

            if ((resize(sq, 40) > thr) and (y(17) = '1')) then
              below <= '1';
            else
              below <= '0';
            end if;

            if ((resize(sq, 40) > thr) and (y(17) = '1')
                and (below_prev = '0') and (refrac = 0) and (warmed = '1')) then
              count_new  <= count + 1;
              refrac_new <= to_unsigned(refrac_len, 5);
            else
              count_new <= count;
              if (refrac = 0) then
                refrac_new <= (others => '0');
              else
                refrac_new <= refrac - 1;
              end if;
            end if;

            power_new <= power + resize(sq, 48);
            fsm       <= s_next;

          when s_next =>

            -- Write the state back. On the bin's last sweep the running
            -- count and power go to the fill bank and restart from zero.
            ch_addr   := chip * ch_per_chip + l_channel;
            ram_waddr <= ch_addr;
            ram_we    <= '1';

            ram_d(x1_lo + 15 downto x1_lo)    <= std_logic_vector(x);
            ram_d(y1_lo + 17 downto y1_lo)    <= std_logic_vector(y);
            ram_d(ms_lo + 31 downto ms_lo)    <= std_logic_vector(ms_new);
            ram_d(below_bit)                  <= below;
            ram_d(refr_lo + 4 downto refr_lo) <= std_logic_vector(refrac_new);

            if (l_binlast = '1') then
              ram_d(cnt_lo + 15 downto cnt_lo) <= (others => '0');
              ram_d(pow_lo + 47 downto pow_lo) <= (others => '0');

              if (rd_bank = '1') then
                bank_waddr <= ch_addr;
              else
                bank_waddr <= total_channels + ch_addr;
              end if;
              bank_d  <= std_logic_vector(power_new) & std_logic_vector(count_new);
              bank_we <= '1';
            else
              ram_d(cnt_lo + 15 downto cnt_lo) <= std_logic_vector(count_new);
              ram_d(pow_lo + 47 downto pow_lo) <= std_logic_vector(power_new);
            end if;

            if (chip = chip_count - 1) then
              fsm <= s_done;
            else
              chip      <= chip + 1;
              ram_raddr <= (chip + 1) * ch_per_chip + l_channel;
              fsm       <= s_read;
            end if;

          when s_done =>

            -- Once per sweep, after its last slot: swap if a bin has
            -- completed and the PS is not holding the bank.
            if (l_last = '1') then
              if ((l_binlast = '1') and (swap_pending = '1')) then
                dropped_r <= dropped_r + 1;
              end if;

              if ((hold_r = '0') and ((l_binlast = '1') or (swap_pending = '1'))) then
                rd_bank      <= not rd_bank;
                findex       <= findex + 1;
                swap_pending <= '0';
              elsif (l_binlast = '1') then
                swap_pending <= '1';
              end if;

              if (l_binlast = '1') then
                bin_end_sweep <= bin_end_sweep + bin_len;
              end if;
            end if;

            fsm <= s_idle;

        end case;

      end if;
    end if;

  end process main;

  held          <= hold_r;
  feature_index <= findex;
  dropped       <= dropped_r;
  busy          <= '0' when fsm = s_idle else
                   '1';

end architecture rtl;

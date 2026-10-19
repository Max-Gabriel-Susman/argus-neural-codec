--------------------------------------------------------------------------------
--! @file    argus_rhd_spi_master.vhd
--! @brief   SPI master for a broadcast Intan RHD2000 bus; emits a per-slot
--!          result stream already corrected for the chip's two-command
--!          pipeline.
--!
--! @details
--! One CS/SCLK/MOSI is driven to every chip and one MISO lane returns per
--! chip, so every chip receives identical commands and adding a chip costs
--! one wire. Each sweep issues @c ch_per_chip CONVERT commands followed by
--! @c aux_slots auxiliary commands; after an initialisation sequence
--! (register writes and a CALIBRATE) @c ready asserts and the master sweeps
--! continuously, parking only on a sweep boundary when @c enable drops.
--!
--! The output is a slot stream, not assembled frames: one @c slot_valid
--! pulse per conversion result, with @c slot_channel, @c slot_is_aux and
--! @c slot_last describing the sample, and lane @e c of @c slot_data in
--! bits (c*16+15 downto c*16). Downstream consumers (the frame assembler,
--! the feature codec) hang off this one stream independently.
--!
--! @par The pipeline is the whole game
--! An RHD2000 returns the result of the command issued two slots earlier.
--! This module resolves that offset: @c slot_channel is the channel the
--! data belongs to, never the channel currently being requested. Getting
--! this wrong rotates every frame by two channels, which looks plausible
--! and is invisible without identity-stamped stimulus (see
--! @c tb_argus_rhd_spi_master).
--!
--! @par Timing (125 MHz clk, 8 ns)
--! - @c sclk_div 6      -> 48 ns SCLK, 24 ns high and 24 ns low, against
--!                         the RHD2000's 41.6 ns and 20.8 ns minimums
--! - 16 SCLK periods    -> 96 clocks of shifting
--! - @c slot_clocks 122 -> CS high 20 clocks = 160 ns, against 154 ns tCSOFF
--! - 34 slots + @c sweep_pad 17 -> 4165 clocks per sweep,
--!                         125e6 / 4165 = 30.01 kS/s per channel
--!
--! The sweep length, not the slot length, sets the sample rate, and it is
--! held at 4165 clocks so every bin length, filter coefficient and golden
--! file elsewhere stays valid. An earlier version ran @c sclk_div 5, a
--! 40 ns SCLK with a 16 ns high phase, which the RHD2000 does not
--! guarantee to read; @c sweep_pad is what made the slower SCLK fit.
--!
--! Slot layout by @c clk_cnt: 0..2 CS low, MOSI holds bit 15 (tCS1);
--! 3..98 sixteen SCLK periods of @c sclk_div clocks; 99..101 CS hold
--! (tCS2); 102..121 CS high (tCSOFF). The last slot of each sweep runs
--! @c sweep_pad clocks longer, all of it CS high. Within a bit period SCLK
--! is low for the first half and high for the second; MOSI updates on the
--! falling edge and MISO is sampled on the rising edge (SPI mode 0). Bit
--! phase and bit number are tracked by two small counters rather than
--! derived from @c clk_cnt with mod and division: @c sclk_div is not a
--! power of two, and the dividers that produced landed on the critical
--! path.
--!
--! @par Sampling an external chip
--! A chip inside the fabric answers within a clock of the SCLK falling
--! edge, so sampling MISO on the rising edge, half a bit later, is
--! correct. A chip at the end of a cable is not: the falling edge has to
--! reach it and its answer has to come back, and on a PMOD cable to a
--! Tiny Tapeout chip that round trip is about 30 ns against 24 ns of half
--! bit. Each lane's capture can therefore be moved later by @c miso_delay
--! fabric clocks: lane @e c captures on the rising-edge strobe delayed by
--! the value in bits (c*3+2 downto c*3). The last bit of a word must be
--! captured before CS rises and the word is handed on, which caps the
--! delay at @c max_miso_delay (5 clocks at the default timing); larger
--! settings are clamped. Zero, the default, is today's behaviour exactly.
--!
--! @par Generics
--! - @c chip_count   chips on the bus, one MISO lane each (3)
--! - @c ch_per_chip  amplifier channels per chip; higher channels are aux (32)
--! - @c aux_slots    auxiliary command slots per sweep (2)
--! - @c slot_clocks  clocks per command slot (122)
--! - @c sclk_div     clocks per SCLK period, 4..16 (6)
--! - @c sweep_pad    extra CS-high clocks at the end of each sweep (17);
--!                   rate = clk / (slot_clocks * (ch_per_chip + aux_slots) + sweep_pad)
--!
--! @par Ports
--! - @c clk, @c rst_n       fabric clock and active-low reset
--! - @c enable              low parks the bus; deasserting mid-sweep finishes the sweep
--! - @c sclk, @c cs_n, @c mosi  broadcast SPI outputs
--! - @c miso                one lane per chip, @c chip_count wide
--! - @c miso_delay          per-lane MISO sample delay, three bits per lane
--!                          (see "Sampling an external chip" below)
--! - @c slot_valid, @c slot_channel, @c slot_data, @c slot_is_aux, @c slot_last
--!                          the slot stream (see above)
--! - @c ready               high once initialisation is complete; discard the
--!                          stream until it asserts
--!
--! @note VHDL-93 compatible. Verified by @c sim/tb_argus_rhd_spi_master.vhd
--!       against three @c argus_rhd2132_model instances: slot pipeline,
--!       three lanes, sweep coherence, aux slots, SCLK timing.
--! @see argus_rhd2132_model, argus_frame_assembler, argus_feature, argus_acq_top
--------------------------------------------------------------------------------

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity argus_rhd_spi_master is
  generic (
    -- Chips on the broadcast bus, one MISO lane each.
    chip_count : natural := 3;
    -- Amplifier channels per chip. Channels at or above this are auxiliary.
    ch_per_chip : natural := 32;
    -- Auxiliary command slots appended to each sweep. Intan recommends 32
    -- conversions plus 3 auxiliary commands; two fit the 4165-clock sweep at
    -- a datasheet-compliant SCLK, and Argus does not read the aux inputs.
    aux_slots : natural := 2;
    -- Clocks per command slot.
    slot_clocks : natural := 122;
    -- Clocks per SCLK period. Must be at least 4 for the slave-side edge
    -- detection to resolve both edges, and at most 16 for the phase counter.
    sclk_div : natural := 6;
    -- Extra CS-high clocks appended to the last slot of every sweep, so the
    -- sweep length can be set independently of the slot length.
    sweep_pad : natural := 17
  );
  port (
    clk   : in    std_logic;
    rst_n : in    std_logic;

    -- Held low to park the bus; release once the PS has configured anything
    -- it needs to. Deasserting mid-sweep finishes the current sweep first.
    enable : in    std_logic;

    -- SPI. cs_n/sclk/mosi are broadcast; miso has one lane per chip.
    sclk : out   std_logic;
    cs_n : out   std_logic;
    mosi : out   std_logic;
    miso : in    std_logic_vector(chip_count - 1 downto 0);

    -- Per-lane MISO sample delay, in fabric clocks after the SCLK rising
    -- edge: lane c in bits (c*3+2 downto c*3). Zero for chips inside the
    -- fabric. See "Sampling an external chip" in the header.
    miso_delay : in    std_logic_vector(chip_count * 3 - 1 downto 0) := (others => '0');

    -- Slot stream. One pulse per command slot that carried a conversion
    -- result. Lane c of slot_data occupies bits (c*16+15 downto c*16).
    slot_valid   : out   std_logic;
    slot_channel : out   unsigned(5 downto 0);
    slot_data    : out   std_logic_vector(chip_count * 16 - 1 downto 0);
    slot_is_aux  : out   std_logic;
    slot_last    : out   std_logic;

    -- High once the initialisation sequence has completed and the master is
    -- sweeping. Consumers should discard the stream until this asserts.
    ready : out   std_logic
  );
end entity argus_rhd_spi_master;

architecture rtl of argus_rhd_spi_master is

  constant op_convert : std_logic_vector(1 downto 0) := "00";
  constant op_write   : std_logic_vector(1 downto 0) := "10";
  constant op_read    : std_logic_vector(1 downto 0) := "11";

  constant cmd_calibrate : std_logic_vector(15 downto 0) := x"5500";

  constant sweep_slots : natural := ch_per_chip + aux_slots;

  -- Slot phase boundaries, derived so the timing comment above stays true
  -- when the generics change.
  constant cs_setup_clocks : natural := 3;
  constant cs_hold_clocks  : natural := 3;
  constant sclk_start      : natural := cs_setup_clocks;
  constant sclk_stop       : natural := sclk_start + 16 * sclk_div - 1;
  constant cs_stop         : natural := sclk_stop + cs_hold_clocks;

  -- SCLK is low for the first LOW_PHASE clocks of each bit period, high for
  -- the rest. MOSI updates at offset 0, MISO is sampled at LOW_PHASE. Half
  -- and half, so neither phase is shorter than it has to be.
  constant sclk_low_phase : natural := sclk_div / 2;

  -- The last bit's rising edge, and the most a lane's capture can be
  -- delayed past it while still landing before CS rises at cs_stop + 1.
  constant last_rise      : natural := sclk_stop - (sclk_div - 1 - sclk_low_phase);
  constant max_miso_delay : natural := cs_stop - last_rise;

  type cmd_rom_t is array (natural range <>) of std_logic_vector(15 downto 0);

  function write_cmd (
    addr : natural;
    data : natural
  ) return std_logic_vector is
  begin

    return OP_WRITE & std_logic_vector(to_unsigned(addr, 6))
           & std_logic_vector(to_unsigned(data, 8));

  end function write_cmd;

  function read_cmd (
    addr : natural
  ) return std_logic_vector is
  begin

    return OP_READ & std_logic_vector(to_unsigned(addr, 6)) & x"00";

  end function read_cmd;

  function lane_delay (
    delays : std_logic_vector;
    lane   : natural
  ) return natural is

    variable d : natural;

  begin

    d := to_integer(unsigned(delays(delays'low + lane * 3 + 2 downto delays'low + lane * 3)));

    if (d > max_miso_delay) then
      return max_miso_delay;
    end if;

    return d;

  end function lane_delay;

  function convert_cmd (
    ch : unsigned(5 downto 0)
  ) return std_logic_vector is
  begin

    return OP_CONVERT & std_logic_vector(ch) & x"00";

  end function convert_cmd;

  -- Intan's documented initialisation sequence. The nine reads after
  -- CALIBRATE are consumed but not executed by the chip; they exist to give
  -- calibration time to finish, and their results are discarded here.
  constant init_rom : cmd_rom_t :=
  (
    read_cmd(63),
    read_cmd(63),
    write_cmd(0,
               16#DE#),
    write_cmd(1,
               16#42#),
    write_cmd(2,
               16#04#),
    write_cmd(3,
               16#00#),
    write_cmd(4,
               16#80#),
    write_cmd(5,
               16#40#),
    write_cmd(6,
               16#80#),
    write_cmd(7,
               16#00#),
    write_cmd(8,
               16#16#),
    write_cmd(9,
               16#80#),
    write_cmd(10,
               16#17#),
    write_cmd(11,
               16#80#),
    write_cmd(12,
               16#2C#),
    write_cmd(13,
               16#86#),
    write_cmd(14,
               16#FF#),
    write_cmd(15,
               16#FF#),
    write_cmd(16,
               16#FF#),
    write_cmd(17,
               16#FF#),
    cmd_calibrate,
    read_cmd(63),
    read_cmd(63),
    read_cmd(63),
    read_cmd(63),
    read_cmd(63),
    read_cmd(63),
    read_cmd(63),
    read_cmd(63),
    read_cmd(63)
  );

  constant init_len : natural := init_rom'length;

  type state_t is (st_idle, st_init, st_run);

  signal state : state_t;

  signal clk_cnt : unsigned(15 downto 0);
  -- Initialised because next_command is combinational and indexes INIT_ROM
  -- before the first reset edge propagates. Without it, to_integer sees 'U'
  -- and numeric_std warns at time zero on every run.
  -- vsg_disable_next_line signal_007
  signal seq_idx : unsigned(15 downto 0) := (others => '0');

  -- Bit-period phase and bit number, counted rather than derived.
  signal phase   : natural range 0 to 15;
  signal bit_num : unsigned(3 downto 0);

  signal shift_out : std_logic_vector(15 downto 0);
  signal capture   : std_logic_vector(chip_count * 16 - 1 downto 0);
  signal held      : std_logic_vector(chip_count * 16 - 1 downto 0);

  -- Three-deep tag pipeline. Pushed at slot start, read at slot end, so the
  -- oldest entry describes the command two slots back -- the one whose
  -- result has just finished shifting in.
  signal tag_ch_0 : unsigned(5 downto 0);
  signal tag_ch_1 : unsigned(5 downto 0);
  signal tag_ch_2 : unsigned(5 downto 0);
  signal tag_cv_0 : std_logic;
  signal tag_cv_1 : std_logic;
  signal tag_cv_2 : std_logic;

  signal sclk_r  : std_logic;
  signal cs_n_r  : std_logic;
  signal mosi_r  : std_logic;
  signal valid_r : std_logic;
  signal last_r  : std_logic;
  signal aux_r   : std_logic;
  signal ready_r : std_logic;

  -- Command presented during the slot that is about to start.
  signal next_cmd : std_logic_vector(15 downto 0);
  signal next_ch  : unsigned(5 downto 0);
  signal next_cv  : std_logic;

  -- Last clk_cnt of the current slot: SWEEP_PAD clocks later on the last
  -- slot of a sweep, so the pad lands in the CS-high gap.
  signal slot_end : unsigned(15 downto 0);

  -- MISO capture strobes. rise_now marks the clock SCLK rises on inside the
  -- shifting window; rise_tap(k) is the same strobe k clocks later.
  signal rise_now : std_logic;
  signal rise_q   : std_logic_vector(max_miso_delay downto 1);
  signal rise_tap : std_logic_vector(max_miso_delay downto 0);

begin

  assert SCLK_DIV >= 4
    report "SCLK_DIV below 4: slave-side edge detection cannot resolve both edges"
    severity failure;

  assert SCLK_DIV <= 16
    report "SCLK_DIV above 16: phase counter range exceeded"
    severity failure;

  assert SLOT_CLOCKS > cs_stop + 20
    report "SLOT_CLOCKS leaves less than 160 ns of CS-high time (tCSOFF is 154 ns)"
    severity failure;

  --------------------------------------------------------------------------
  -- Next command. Combinational so it is settled before the slot boundary.
  --------------------------------------------------------------------------

  next_command : process (state, seq_idx) is

    variable ch : unsigned(5 downto 0);

  begin

    if (state = st_run) then
      ch       := resize(seq_idx(5 downto 0), 6);
      next_cmd <= convert_cmd(ch);
      next_ch  <= ch;
      next_cv  <= '1';
    else
      next_cmd <= INIT_ROM(to_integer(seq_idx));
      next_ch  <= (others => '0');
      next_cv  <= '0';
    end if;

  end process next_command;

  slot_end <= to_unsigned(slot_clocks - 1 + sweep_pad, 16) when (state = st_run) and (seq_idx = sweep_slots - 1) else
              to_unsigned(slot_clocks - 1, 16);

  rise_now <= '1' when (state /= st_idle) and (clk_cnt >= sclk_start) and (clk_cnt <= sclk_stop)
                       and (phase = sclk_low_phase) else
              '0';

  rise_tap <= rise_q & rise_now;

  --------------------------------------------------------------------------
  -- Slot engine
  --------------------------------------------------------------------------

  slot_engine : process (clk) is
  begin

    if rising_edge(clk) then
      if (rst_n = '0') then
        state     <= st_idle;
        clk_cnt   <= (others => '0');
        seq_idx   <= (others => '0');
        phase     <= 0;
        bit_num   <= (others => '0');
        shift_out <= (others => '0');
        capture   <= (others => '0');
        held      <= (others => '0');
        tag_ch_0  <= (others => '0');
        tag_ch_1  <= (others => '0');
        tag_ch_2  <= (others => '0');
        tag_cv_0  <= '0';
        tag_cv_1  <= '0';
        tag_cv_2  <= '0';
        sclk_r    <= '0';
        cs_n_r    <= '1';
        mosi_r    <= '0';
        valid_r   <= '0';
        last_r    <= '0';
        aux_r     <= '0';
        ready_r   <= '0';
        rise_q    <= (others => '0');
      else
        valid_r <= '0';
        rise_q  <= rise_tap(max_miso_delay - 1 downto 0);

        case state is

          when st_idle =>

            cs_n_r  <= '1';
            sclk_r  <= '0';
            clk_cnt <= (others => '0');
            seq_idx <= (others => '0');

            if (enable = '1') then
              state <= st_init;
            end if;

          when st_init | st_run =>

            --------------------------------------------------------------
            -- Slot start: load the command, push its tag, drop CS.
            --------------------------------------------------------------
            if (clk_cnt = 0) then
              shift_out <= next_cmd;
              cs_n_r    <= '0';
              sclk_r    <= '0';
              phase     <= 0;
              bit_num   <= (others => '0');
              capture   <= (others => '0');

              tag_ch_2 <= tag_ch_1;
              tag_ch_1 <= tag_ch_0;
              tag_ch_0 <= next_ch;
              tag_cv_2 <= tag_cv_1;
              tag_cv_1 <= tag_cv_0;
              tag_cv_0 <= next_cv;
            end if;

            --------------------------------------------------------------
            -- Shifting window. phase and bit_num advance only in here, so
            -- they are 0 at SCLK_START by construction.
            --------------------------------------------------------------
            if ((clk_cnt >= sclk_start) and (clk_cnt <= sclk_stop)) then
              if (phase = 0) then
                -- Falling edge of the previous bit: present the next one.
                sclk_r <= '0';
                mosi_r <= shift_out(15 - to_integer(bit_num));
              elsif (phase = sclk_low_phase) then
                -- Rising edge: the slave samples MOSI. MISO is captured
                -- below, on this edge or a few clocks after it.
                sclk_r <= '1';
              end if;

              if (phase = sclk_div - 1) then
                phase   <= 0;
                bit_num <= bit_num + 1;
              else
                phase <= phase + 1;
              end if;
            end if;

            --------------------------------------------------------------
            -- MISO capture, per lane, on the rising-edge strobe delayed by
            -- that lane's MISO_DELAY. At delay 0 this is the rising edge
            -- itself, as it always was.
            --------------------------------------------------------------
            for c in 0 to chip_count - 1 loop

              if (rise_tap(lane_delay(miso_delay, c)) = '1') then
                capture(c * 16 + 15 downto c * 16) <= capture(c * 16 + 14 downto c * 16) & miso(c);
              end if;

            end loop;

            --------------------------------------------------------------
            -- CS hold, then CS high
            --------------------------------------------------------------
            if (clk_cnt = sclk_stop + 1) then
              sclk_r <= '0';
            end if;

            if (clk_cnt = cs_stop + 1) then
              cs_n_r <= '1';
              held   <= capture;

              -- Emit the result for the command two slots back. During init,
              -- and for the first two slots of the first sweep, tag_cv_2 is
              -- low and nothing is published.
              if (tag_cv_2 = '1') then
                valid_r <= '1';

                if (tag_ch_2 = ch_per_chip - 1) then
                  last_r <= '1';
                else
                  last_r <= '0';
                end if;

                if (tag_ch_2 >= ch_per_chip) then
                  aux_r <= '1';
                else
                  aux_r <= '0';
                end if;
              end if;
            end if;

            --------------------------------------------------------------
            -- Slot boundary: advance the sequencer.
            --------------------------------------------------------------
            if (clk_cnt = slot_end) then
              clk_cnt <= (others => '0');

              if (state = st_init) then
                if (seq_idx = init_len - 1) then
                  seq_idx <= (others => '0');
                  state   <= st_run;
                  ready_r <= '1';
                else
                  seq_idx <= seq_idx + 1;
                end if;
              else
                if (seq_idx = sweep_slots - 1) then
                  seq_idx <= (others => '0');

                  -- Park only on a sweep boundary, so a consumer never sees
                  -- a partial frame.
                  if (enable = '0') then
                    state   <= st_idle;
                    ready_r <= '0';
                  end if;
                else
                  seq_idx <= seq_idx + 1;
                end if;
              end if;
            else
              clk_cnt <= clk_cnt + 1;
            end if;

        end case;

      end if;
    end if;

  end process slot_engine;

  sclk         <= sclk_r;
  cs_n         <= cs_n_r;
  mosi         <= mosi_r;
  slot_valid   <= valid_r;
  slot_channel <= tag_ch_2;
  slot_data    <= held;
  slot_is_aux  <= aux_r;
  slot_last    <= last_r;
  ready        <= ready_r;

end architecture rtl;

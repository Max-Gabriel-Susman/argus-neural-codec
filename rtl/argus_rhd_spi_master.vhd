--------------------------------------------------------------------------------
-- argus_rhd_spi_master.vhd
--
-- SPI master for a broadcast RHD2000 bus: one CS/SCLK/MOSI driven to every
-- chip, one MISO returned per chip. All chips receive identical commands, so
-- adding a chip costs one more MISO wire and nothing else.
--
-- Emits a slot stream rather than assembled frames. One result per command
-- slot, already corrected for the two-command pipeline. Downstream consumers
-- -- frame assembler, spike detector -- hang off the same stream; neither
-- needs the other to exist.
--
-- TIMING (125 MHz clk, 8 ns period)
--   SCLK_DIV 5      -> 25 MHz SCLK, 40 ns period, at the datasheet tSCLK floor
--   16 SCLK         -> 80 clocks of shifting
--   SLOT_CLOCKS 119 -> 125e6 / (119 * 35) = 30.01 kS/s per channel
--   CS high         -> 33 clocks = 264 ns, against a 154 ns tCSOFF minimum
--
--   Slot layout, by clk_cnt:
--     0  .. 2    CS low, MOSI holds bit 15, SCLK low   (tCS1 setup, 24 ns)
--     3  .. 82   16 SCLK periods, 5 clocks each
--     83 .. 85   CS still low, SCLK low                (tCS2 hold, 24 ns)
--     86 .. 118  CS high                               (tCSOFF, 264 ns)
--
--   Within one 5-clock bit period: SCLK low for 3, high for 2. MOSI is
--   updated on the falling edge, MISO sampled on the rising edge -- SPI
--   mode 0, matching the RHD2000.
--
--   The bit phase and bit number are tracked by two small counters rather
--   than derived from clk_cnt with mod and division. SCLK_DIV is not a
--   power of two, so those synthesised to real dividers on the critical
--   path and left 0.35 ns of slack at 125 MHz out of context.
--
-- THE PIPELINE IS THE WHOLE GAME
--   A result belongs to the command issued TWO slots earlier. This module
--   resolves that and nothing downstream should think about it again: the
--   channel presented on slot_channel is the channel the data belongs to,
--   never the channel currently being requested. Getting this wrong yields a
--   frame rotated by two channels, which looks entirely plausible and is
--   invisible without identity-stamped stimulus.
--
-- VHDL-93 compatible.
--------------------------------------------------------------------------------

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity argus_rhd_spi_master is
  generic (
    -- Chips on the broadcast bus, one MISO lane each.
    CHIP_COUNT : natural := 3;
    -- Amplifier channels per chip. Channels at or above this are auxiliary.
    CH_PER_CHIP : natural := 32;
    -- Auxiliary command slots appended to each sweep. Intan's recommended
    -- sequence is 32 conversions plus 3 auxiliary commands.
    AUX_SLOTS : natural := 3;
    -- Clocks per command slot. Sets the sample rate together with the sweep
    -- length: rate = CLK / (SLOT_CLOCKS * (CH_PER_CHIP + AUX_SLOTS)).
    SLOT_CLOCKS : natural := 119;
    -- Clocks per SCLK period. Must be at least 4 for the slave-side edge
    -- detection to resolve both edges, and at most 16 for the phase counter.
    SCLK_DIV : natural := 5
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
    miso : in    std_logic_vector(CHIP_COUNT - 1 downto 0);

    -- Slot stream. One pulse per command slot that carried a conversion
    -- result. Lane c of slot_data occupies bits (c*16+15 downto c*16).
    slot_valid   : out   std_logic;
    slot_channel : out   unsigned(5 downto 0);
    slot_data    : out   std_logic_vector(CHIP_COUNT * 16 - 1 downto 0);
    slot_is_aux  : out   std_logic;
    slot_last    : out   std_logic;

    -- High once the initialisation sequence has completed and the master is
    -- sweeping. Consumers should discard the stream until this asserts.
    ready : out   std_logic
  );
end entity argus_rhd_spi_master;

architecture rtl of argus_rhd_spi_master is

  constant OP_CONVERT : std_logic_vector(1 downto 0) := "00";
  constant OP_WRITE   : std_logic_vector(1 downto 0) := "10";
  constant OP_READ    : std_logic_vector(1 downto 0) := "11";

  constant CMD_CALIBRATE : std_logic_vector(15 downto 0) := x"5500";

  constant SWEEP_SLOTS : natural := CH_PER_CHIP + AUX_SLOTS;

  -- Slot phase boundaries, derived so the timing comment above stays true
  -- when the generics change.
  constant CS_SETUP_CLOCKS : natural := 3;
  constant CS_HOLD_CLOCKS  : natural := 3;
  constant SCLK_START      : natural := CS_SETUP_CLOCKS;
  constant SCLK_STOP       : natural := SCLK_START + 16 * SCLK_DIV - 1;
  constant CS_STOP         : natural := SCLK_STOP + CS_HOLD_CLOCKS;

  -- SCLK is low for the first LOW_PHASE clocks of each bit period, high for
  -- the rest. MOSI updates at offset 0, MISO is sampled at LOW_PHASE.
  constant SCLK_LOW_PHASE : natural := SCLK_DIV - 2;

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

  function convert_cmd (
    ch : unsigned(5 downto 0)
  ) return std_logic_vector is
  begin

    return OP_CONVERT & std_logic_vector(ch) & x"00";

  end function convert_cmd;

  -- Intan's documented initialisation sequence. The nine reads after
  -- CALIBRATE are consumed but not executed by the chip; they exist to give
  -- calibration time to finish, and their results are discarded here.
  constant INIT_ROM : cmd_rom_t :=
  (
    read_cmd(63), read_cmd(63),
    write_cmd(0, 16#DE#),
    write_cmd(1, 16#42#),
    write_cmd(2, 16#04#),
    write_cmd(3, 16#00#),
    write_cmd(4, 16#80#),
    write_cmd(5, 16#40#),
    write_cmd(6, 16#80#),
    write_cmd(7, 16#00#),
    write_cmd(8, 16#16#),
    write_cmd(9, 16#80#),
    write_cmd(10, 16#17#),
    write_cmd(11, 16#80#),
    write_cmd(12, 16#2C#),
    write_cmd(13, 16#86#),
    write_cmd(14, 16#FF#),
    write_cmd(15, 16#FF#),
    write_cmd(16, 16#FF#),
    write_cmd(17, 16#FF#),
    CMD_CALIBRATE,
    read_cmd(63), read_cmd(63), read_cmd(63),
    read_cmd(63), read_cmd(63), read_cmd(63),
    read_cmd(63), read_cmd(63), read_cmd(63)
  );

  constant INIT_LEN : natural := INIT_ROM'length;

  type state_t is (ST_IDLE, ST_INIT, ST_RUN);

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
  signal capture   : std_logic_vector(CHIP_COUNT * 16 - 1 downto 0);
  signal held      : std_logic_vector(CHIP_COUNT * 16 - 1 downto 0);

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

begin

  assert SCLK_DIV >= 4
    report "SCLK_DIV below 4: slave-side edge detection cannot resolve both edges"
    severity failure;

  assert SCLK_DIV <= 16
    report "SCLK_DIV above 16: phase counter range exceeded"
    severity failure;

  assert SLOT_CLOCKS > CS_STOP + 20
    report "SLOT_CLOCKS leaves less than 160 ns of CS-high time (tCSOFF is 154 ns)"
    severity failure;

  --------------------------------------------------------------------------
  -- Next command. Combinational so it is settled before the slot boundary.
  --------------------------------------------------------------------------

  next_command : process (state, seq_idx) is

    variable ch : unsigned(5 downto 0);

  begin

    if (state = ST_RUN) then
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

  --------------------------------------------------------------------------
  -- Slot engine
  --------------------------------------------------------------------------

  slot_engine : process (clk) is
  begin

    if rising_edge(clk) then
      if (rst_n = '0') then
        state     <= ST_IDLE;
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
      else
        valid_r <= '0';

        case state is

          when ST_IDLE =>

            cs_n_r  <= '1';
            sclk_r  <= '0';
            clk_cnt <= (others => '0');
            seq_idx <= (others => '0');

            if (enable = '1') then
              state <= ST_INIT;
            end if;

          when ST_INIT | ST_RUN =>

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
            if ((clk_cnt >= SCLK_START) and (clk_cnt <= SCLK_STOP)) then

              if (phase = 0) then
                -- Falling edge of the previous bit: present the next one.
                sclk_r <= '0';
                mosi_r <= shift_out(15 - to_integer(bit_num));
              elsif (phase = SCLK_LOW_PHASE) then
                -- Rising edge: the slave samples MOSI, we sample MISO.
                sclk_r <= '1';

                for c in 0 to CHIP_COUNT - 1 loop

                  capture(c * 16 + 15 downto c * 16) <=
                    capture(c * 16 + 14 downto c * 16) & miso(c);

                end loop;

              end if;

              if (phase = SCLK_DIV - 1) then
                phase   <= 0;
                bit_num <= bit_num + 1;
              else
                phase <= phase + 1;
              end if;

            end if;

            --------------------------------------------------------------
            -- CS hold, then CS high
            --------------------------------------------------------------
            if (clk_cnt = SCLK_STOP + 1) then
              sclk_r <= '0';
            end if;

            if (clk_cnt = CS_STOP + 1) then
              cs_n_r <= '1';
              held   <= capture;

              -- Emit the result for the command two slots back. During init,
              -- and for the first two slots of the first sweep, tag_cv_2 is
              -- low and nothing is published.
              if (tag_cv_2 = '1') then
                valid_r <= '1';

                if (tag_ch_2 = CH_PER_CHIP - 1) then
                  last_r <= '1';
                else
                  last_r <= '0';
                end if;

                if (tag_ch_2 >= CH_PER_CHIP) then
                  aux_r <= '1';
                else
                  aux_r <= '0';
                end if;
              end if;
            end if;

            --------------------------------------------------------------
            -- Slot boundary: advance the sequencer.
            --------------------------------------------------------------
            if (clk_cnt = SLOT_CLOCKS - 1) then
              clk_cnt <= (others => '0');

              if (state = ST_INIT) then
                if (seq_idx = INIT_LEN - 1) then
                  seq_idx <= (others => '0');
                  state   <= ST_RUN;
                  ready_r <= '1';
                else
                  seq_idx <= seq_idx + 1;
                end if;
              else
                if (seq_idx = SWEEP_SLOTS - 1) then
                  seq_idx <= (others => '0');

                  -- Park only on a sweep boundary, so a consumer never sees
                  -- a partial frame.
                  if (enable = '0') then
                    state   <= ST_IDLE;
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

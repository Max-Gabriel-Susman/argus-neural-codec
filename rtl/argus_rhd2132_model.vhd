-- ---------------------------------------------------------------------------
-- argus_rhd2132_model.vhd
-- ---------------------------------------------------------------------------

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity argus_rhd2132_model is
  generic (
    ch_per_chip  : natural := 32;
    chip_id      : natural := 0;
    chip_type_id : natural := 1;
    die_revision : natural := 1;

    pattern : natural := 0
  );
  port (
    clk   : in    std_logic;
    rst_n : in    std_logic;

    sclk    : in    std_logic;
    cs_n    : in    std_logic;
    mosi    : in    std_logic;
    miso    : out   std_logic;
    miso_oe : out   std_logic; -- '1' when the model is driving the line

    dbg_last_cmd  : out   std_logic_vector(15 downto 0);
    dbg_cmd_valid : out   std_logic;
    dbg_last_resp : out   std_logic_vector(15 downto 0)
  );
end entity argus_rhd2132_model;

architecture rtl of argus_rhd2132_model is

  constant pattern_ident : natural := 0;
  constant pattern_ramp  : natural := 1;

  constant op_convert : std_logic_vector(1 downto 0) := "00";
  constant op_aux     : std_logic_vector(1 downto 0) := "01"; -- CALIBRATE, CLEAR
  constant op_write   : std_logic_vector(1 downto 0) := "10";
  constant op_read    : std_logic_vector(1 downto 0) := "11";

  constant reg_config   : natural := 4;
  constant r4_weak_miso : natural := 7;
  constant r4_twoscomp  : natural := 6;

  constant cmd_calibrate : std_logic_vector(15 downto 0) := x"5500";
  constant cmd_clear     : std_logic_vector(15 downto 0) := x"6A00";

  constant n_ram_registers : natural := 18;

  type regfile_t is array (0 to 63) of std_logic_vector(7 downto 0);

  function init_regfile return regfile_t is

    variable r : regfile_t;

  begin

    r     := (others => (others => '0'));
    r(40) := std_logic_vector(to_unsigned(character'pos('I'), 8));
    r(41) := std_logic_vector(to_unsigned(character'pos('N'), 8));
    r(42) := std_logic_vector(to_unsigned(character'pos('T'), 8));
    r(43) := std_logic_vector(to_unsigned(character'pos('A'), 8));
    r(44) := std_logic_vector(to_unsigned(character'pos('N'), 8));

    r(60) := std_logic_vector(to_unsigned(DIE_REVISION, 8));
    r(61) := std_logic_vector(to_unsigned(1, 8));
    r(62) := std_logic_vector(to_unsigned(CH_PER_CHIP, 8));
    r(63) := std_logic_vector(to_unsigned(CHIP_TYPE_ID, 8));
    return r;

  end function init_regfile;

  function sample_value (
    ch : std_logic_vector(5 downto 0);
    sample_idx : std_logic_vector(7 downto 0);
    regs : regfile_t;
    chip : natural;
    pat : natural;
    n_chan : natural
  ) return std_logic_vector is

    variable phase : unsigned(7 downto 0);
    variable ramp  : signed(15 downto 0);

  begin

    -- Channels at or above the amplifier count are auxillary sensors
    -- (auxin1-3 on 32-34), supply voltage on 48, temperature on 49).
    -- These are always unsigned and never affected by twoscomp. A
    -- Distinctive contant makes  a mis-slotted auxillary command obvious.
    if (to_integer(unsigned(ch)) >= n_chan) then
      return x"A0" & "00" & ch;
    end if;

    if (pat = PATTERN_RAMP) then
      phase := unsigned(sample_idx) + resize(unsigned(ch), 8);

      ramp := shift_left(resize(signed(phase), 16), 6);
      if (regs(REG_CONFIG)(R4_TWOSCOMP) = '1') then
        return std_logic_vector(ramp);
      else
        return std_logic_vector(unsigned(ramp) + x"8000");
      end if;
    else
      return std_logic_vector(to_unsigned(chip mod 4, 2)) & ch & sample_idx;
    end if;

  end function sample_value;

  function idle_result (
    regs : regfile_t
  ) return std_logic_vector is

    variable v : std_logic_vector(15 downto 0);

  begin

    v     := (others => '0');
    v(15) := not regs(REG_CONFIG)(R4_TWOSCOMP);
    return v;

  end function idle_result;

  function is_ram_register (
    addr : std_logic_vector(5 downto 0)
  ) return boolean is
  begin

    return to_integer(unsigned(addr)) < N_RAM_REGISTERS;

  end function is_ram_register;

  function rhd_response (
    cmd : std_logic_vector(15 downto 0);
    mux_ch : std_logic_vector(5 downto 0); -- resolved channel
    sample_idx :std_logic_vector(7 downto 0);
    regs : regfile_t;
    chip : natural;
    pat : natural;
    n_chan : natural
  ) return std_logic_vector is
  begin

    case cmd(15 downto 14) is

      when OP_CONVERT =>

        return sample_value(mux_ch, sample_idx, regs, chip, pat, n_chan);

      when OP_WRITE =>

        -- Data exhoed in the low byte; upper byte is all ones.
        return x"FF" & cmd(7 downto 0);

      when OP_READ =>

        return x"00" & regs(to_integer(unsigned(cmd(13 downto 8))));

      when others =>

        return idle_result(regs);

    end case;

  end function rhd_response;

  signal sclk_q : std_logic;
  signal cs_n_q : std_logic;

  signal sclk_rise   : std_logic;
  signal sclk_fall   : std_logic;
  signal cs_assert   : std_logic;
  signal cs_deassert : std_logic;

  signal shift_in  : std_logic_vector(15 downto 0);
  signal shift_out : std_logic_vector(15 downto 0);
  signal bit_cnt   : unsigned(4 downto 0);

  signal resp_prev : std_logic_vector(15 downto 0);
  signal resp_last : std_logic_vector(15 downto 0);

  signal sample_idx : std_logic_vector(7 downto 0);
  -- vsg_disable_next_line signal_007
  signal regfile   : regfile_t := init_regfile;
  signal last_cmd  : std_logic_vector(15 downto 0);
  signal cmd_valid : std_logic;

  signal mux_ch        : unsigned(5 downto 0);
  signal cal_countdown : unsigned(3 downto 0);

begin

  sclk_rise   <= sclk and not sclk_q;
  sclk_fall   <= (not sclk) and sclk_q;
  cs_assert   <= (not cs_n) and cs_n_q;
  cs_deassert <= cs_n and (not cs_n_q);

  spi_slave : process (clk) is

    variable conv_ch : unsigned(5 downto 0);

  begin

    if rising_edge(clk) then
      sclk_q <= sclk;
      cs_n_q <= cs_n;

      if (rst_n = '0') then
        shift_in      <= (others => '0');
        shift_out     <= (others => '0');
        bit_cnt       <= (others => '0');
        resp_prev     <= (others => '0');
        resp_last     <= (others => '0');
        sample_idx    <= (others => '0');
        last_cmd      <= (others => '0');
        mux_ch        <= (others => '0');
        cal_countdown <= (others => '0');
        cmd_valid     <= '0';
        shift_in      <= (others => '0');
      else
        cmd_valid <= '0';

        if (cs_assert = '1') then
          bit_cnt   <= (others => '0');
          shift_out <= resp_prev;
          shift_in  <= (others => '0');
        end if;

        if (cs_n = '0') then
          if (sclk_rise = '1') then
            shift_in <= shift_in(14 downto 0) & mosi;
            bit_cnt  <= bit_cnt + 1;
          end if;

          if ((sclk_fall = '1') and (bit_cnt /= 0)) then
            shift_out <= shift_out(14 downto 0) & '0';
          end if;
        end if;
        -- End of frame: retire the command and advance the pipeline.
        if ((cs_deassert = '1') and (bit_cnt = 16)) then
          last_cmd  <= shift_in;
          cmd_valid <= '1';
          conv_ch   := unsigned(shift_in(13 downto 8));

          if (cal_countdown /= 0) then
            -- The nine commands following CALIBRATE are consumed
            -- but not executed; the chip ignores everything until
            -- calibration completes.
            cal_countdown <= cal_countdown - 1;
            resp_last     <= idle_result(regfile);
            resp_prev     <= resp_last;
          else
            if (shift_in(15 downto 14) = op_convert) then
              -- CONVERT(63) advances the multiplexer rather than
              -- naming a channel, wrapping past the last amplifier.
              if (conv_ch = 63) then
                if (mux_ch = ch_per_chip - 1) then
                  conv_ch := (others => '0');
                else
                  conv_ch := mux_ch + 1;
                end if;
              end if;
              mux_ch <= conv_ch;

              if (conv_ch = ch_per_chip - 1) then
                sample_idx <= std_logic_vector(unsigned(sample_idx) + 1);
              end if;
            end if;

            -- Writes to ROM or non-existent registers are
            -- acknowledged in the result but discarded.
            if ((shift_in(15 downto 14) = op_write)
                and is_ram_register(shift_in(13 downto 8))) then
              regfile(to_integer(unsigned(shift_in(13 downto 8))))
 <= shift_in(7 downto 0);
            end if;

            if (shift_in = cmd_calibrate) then
              cal_countdown <= to_unsigned(9, 4);
            end if;

            resp_last <= rhd_response(shift_in,
                                      std_logic_vector(conv_ch),
                                      sample_idx, regfile,
                                      chip_id, pattern, ch_per_chip);
            resp_prev <= resp_last;
          end if;
        end if;
      end if;                                                             -- rst_n
    end if;                                                               -- rising_edge(clk)

  end process spi_slave;

  -- Register 4 weak MISO: 0 releases the line to high impedance when
  -- CS is high so chips can share a return path; 1 drives it weakly.
  miso    <= shift_out(15);
  miso_oe <= '1' when cs_n = '0' else
             regfile(reg_config)(r4_weak_miso);

  dbg_last_cmd  <= last_cmd;
  dbg_cmd_valid <= cmd_valid;
  dbg_last_resp <= resp_last;

end architecture rtl;

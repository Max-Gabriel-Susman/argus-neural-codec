--------------------------------------------------------------------------------
-- tb_argus_sample_fetch.vhd
--
-- The seam, closed in simulation: SPI master, three chips in external mode,
-- the sample fetcher, a behavioural stand-in for the Block Memory Generator's
-- port B, and the frame assembler. The BRAM stub is preloaded with a pattern
-- that encodes half, row and channel, so every assembled frame can be
-- checked against exactly where playback should be.
--
-- WHAT IS ACTUALLY BEING TESTED
--
--   1. LANE ADDRESSING. Frame word n must carry the sample for channel n of
--      the row being played. Three chips read three different offsets of
--      one row; a wrong stride or a swapped half-word shows up per lane.
--
--   2. ROW ADVANCE. Row must step once per sweep and wrap at
--      SAMPLES_PER_HALF, flipping halves.
--
--   3. CONSUMED / ACK. The flag for a half sets on the flip out of it and
--      clears on ack. Half 1 is deliberately never acked.
--
--   4. UNDERRUN. Flipping back into the un-acked half 1 must set underrun,
--      and clear_underrun must clear it. Playback continues regardless.
--
--   5. PIPELINE. The two-command result pipeline is unchanged by the
--      external path: the fetch lands in resp_last well before it is
--      shifted out, so channel tags stay correct.
--
-- SAMPLES_PER_HALF is 8 here so 32 sweeps cover four half-transitions.
--
-- Run: make tb_argus_sample_fetch   (from sim/)
--------------------------------------------------------------------------------

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity tb_argus_sample_fetch is
end entity tb_argus_sample_fetch;

architecture sim of tb_argus_sample_fetch is

  constant chip_count       : natural := 3;
  constant ch_per_chip      : natural := 32;
  constant aux_slots        : natural := 3;
  constant slot_clocks      : natural := 119;
  constant sclk_div         : natural := 5;
  constant samples_per_half : natural := 8;

  constant total_channels : natural := chip_count * ch_per_chip;
  constant half_samples   : natural := samples_per_half * total_channels;

  constant clk_period : time    := 8 ns;
  constant frames     : natural := 4 * samples_per_half;

  constant bram_words : natural := 16384;   -- 64 KB / 4

  signal clk      : std_logic := '0';
  signal rst_n    : std_logic := '0';
  signal enable   : std_logic := '0';
  signal ext_mode : std_logic := '0';

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
  signal ready        : std_logic;

  signal bram_en   : std_logic;
  signal bram_we   : std_logic_vector(3 downto 0);
  signal bram_addr : std_logic_vector(31 downto 0);
  signal bram_din  : std_logic_vector(31 downto 0);
  signal bram_dout : std_logic_vector(31 downto 0) := (others => '0');

  signal play_half      : std_logic;
  signal play_row       : unsigned(15 downto 0);
  signal half_consumed  : std_logic_vector(1 downto 0);
  signal underrun       : std_logic;
  signal ack_consumed   : std_logic_vector(1 downto 0) := (others => '0');
  signal clear_underrun : std_logic := '0';

  signal frame_valid : std_logic;
  signal frame_index : unsigned(31 downto 0);
  signal rd_en       : std_logic := '0';
  signal rd_addr     : unsigned(7 downto 0) := (others => '0');
  signal rd_data     : std_logic_vector(15 downto 0);
  signal overrun     : std_logic;

  signal sim_done : boolean := false;

  function hex4 (v : std_logic_vector(15 downto 0)) return string is

    constant digits : string(1 to 16) := "0123456789ABCDEF";
    variable s      : string(1 to 4);
    variable nib    : integer;

  begin

    for i in 0 to 3 loop

      nib      := to_integer(unsigned(v(15 - 4 * i downto 12 - 4 * i)));
      s(i + 1) := digits(nib + 1);

    end loop;

    return s;

  end function hex4;

  -- What the BRAM holds for (half, row, channel): distinguishable from the
  -- chips' built-in IDENT pattern, and from each other.
  function bram_word (
    h : natural;
    r : natural;
    c : natural
  ) return std_logic_vector is
  begin

    return std_logic_vector(to_unsigned(h, 1))
           & std_logic_vector(to_unsigned(r, 8))
           & std_logic_vector(to_unsigned(c, 7));

  end function bram_word;

  -- Sample index -> stored 16-bit word. Indices past both halves hold a
  -- marker so a stride error into unused memory is obvious.
  function word_at (idx : natural) return std_logic_vector is

    variable h, rem_i, r, c : natural;

  begin

    if (idx >= 2 * half_samples) then
      return x"FFFF";
    end if;

    h     := idx / half_samples;
    rem_i := idx mod half_samples;
    r     := rem_i / total_channels;
    c     := rem_i mod total_channels;
    return bram_word(h, r, c);

  end function word_at;

  type bram_t is array (0 to bram_words - 1) of std_logic_vector(31 downto 0);

  function init_bram return bram_t is

    variable m : bram_t;

  begin

    for w in 0 to bram_words - 1 loop

      m(w) := word_at(2 * w + 1) & word_at(2 * w);

    end loop;

    return m;

  end function init_bram;

  signal bram : bram_t := init_bram;

begin

  clk <= not clk after clk_period / 2 when not sim_done else '0';

  ------------------------------------------------------------------------
  -- Block Memory Generator port B stand-in: 32-bit, byte addressed,
  -- one cycle of read latency, as configured in BRAM-controller mode.
  ------------------------------------------------------------------------

  bram_stub : process (clk) is
  begin

    if rising_edge(clk) then
      if (bram_en = '1') then
        bram_dout <= bram(to_integer(unsigned(bram_addr(15 downto 2))));
      end if;
    end if;

  end process bram_stub;

  master : entity work.argus_rhd_spi_master(rtl)
    generic map (
      chip_count  => chip_count,
      ch_per_chip => ch_per_chip,
      aux_slots   => aux_slots,
      slot_clocks => slot_clocks,
      sclk_div    => sclk_div
    )
    port map (
      clk          => clk,
      rst_n        => rst_n,
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

    -- Chip 0's channel drives the fetcher; the ack fans out to all.
    chip0 : if c = 0 generate

      chip_inst : entity work.argus_rhd2132_model(rtl)
        generic map (
          ch_per_chip  => ch_per_chip,
          chip_id      => c,
          chip_type_id => 1,
          pattern      => 0
        )
        port map (
          clk           => clk,
          rst_n         => rst_n,
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
          clk           => clk,
          rst_n         => rst_n,
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
      clk            => clk,
      rst_n          => rst_n,
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
      underrun       => underrun,
      ack_consumed   => ack_consumed,
      clear_underrun => clear_underrun
    );

  assembler : entity work.argus_frame_assembler(rtl)
    generic map (
      chip_count  => chip_count,
      ch_per_chip => ch_per_chip
    )
    port map (
      clk          => clk,
      rst_n        => rst_n,
      slot_valid   => slot_valid,
      slot_channel => slot_channel,
      slot_data    => slot_data,
      slot_is_aux  => slot_is_aux,
      slot_last    => slot_last,
      frame_valid  => frame_valid,
      frame_index  => frame_index,
      rd_en        => rd_en,
      rd_addr      => rd_addr,
      rd_data      => rd_data,
      overrun      => overrun
    );

  ------------------------------------------------------------------------
  -- Checker
  ------------------------------------------------------------------------

  checker : process is

    variable errs : natural := 0;
    variable got  : std_logic_vector(15 downto 0);
    variable want : std_logic_vector(15 downto 0);
    variable h, r : natural;

    procedure read_word (
      idx : in    natural;
      w   : out   std_logic_vector(15 downto 0)
    ) is
    begin

      rd_addr <= to_unsigned(idx, 8);
      rd_en   <= '1';
      wait until rising_edge(clk);
      rd_en <= '0';
      wait until rising_edge(clk);
      w := rd_data;

    end procedure read_word;

    procedure expect_flag (
      cond : in    boolean;
      what : in    string
    ) is
    begin

      if (not cond) then
        errs := errs + 1;
        report "FAIL " & what severity error;
      end if;

    end procedure expect_flag;

    procedure pulse_ack (
      halves : in    std_logic_vector(1 downto 0);
      clr    : in    std_logic
    ) is
    begin

      ack_consumed   <= halves;
      clear_underrun <= clr;
      wait until rising_edge(clk);
      ack_consumed   <= (others => '0');
      clear_underrun <= '0';
      wait until rising_edge(clk);
      wait until rising_edge(clk);

    end procedure pulse_ack;

  begin

    rst_n <= '0';
    wait for 20 * clk_period;
    rst_n <= '1';
    wait for 20 * clk_period;

    -- External mode before the master starts, so the very first CONVERT
    -- is served from row 0 of half 0.
    ext_mode <= '1';
    enable   <= '1';

    wait until ready = '1';
    report "master ready; playing from BRAM";

    for k in 0 to frames - 1 loop

      wait until rising_edge(clk) and frame_valid = '1';

      h := (k / samples_per_half) mod 2;
      r := k mod samples_per_half;

      for n in 0 to total_channels - 1 loop

        read_word(n, got);
        want := bram_word(h, r, n);

        if (got /= want) then
          errs := errs + 1;
          report "FAIL frame " & integer'image(k)
                 & " (half " & integer'image(h) & " row " & integer'image(r) & ")"
                 & " word " & integer'image(n)
                 & ": " & hex4(got) & ", expected " & hex4(want)
            severity error;
        end if;

      end loop;

      -- Flag behaviour at each half boundary. The flip happens when the
      -- last amplifier channel of the last row is served, which is before
      -- that row's frame closes, so flags are checked after reading it.
      if (r = samples_per_half - 1) then

        if (h = 0) then
          expect_flag(half_consumed(0) = '1',
                      "consumed0 not set after half 0, frame " & integer'image(k));
          expect_flag(play_half = '1',
                      "play_half not 1 after half 0, frame " & integer'image(k));

          -- Second visit to half 0 (k = 23): half 1 was never acked, so the
          -- flip into it at the end of the NEXT half 0 pass will underrun.
          -- Ack half 0 both times so it never contributes.
          pulse_ack("01", '0');
          expect_flag(half_consumed(0) = '0',
                      "consumed0 did not clear on ack, frame " & integer'image(k));
        else
          expect_flag(half_consumed(1) = '1',
                      "consumed1 not set after half 1, frame " & integer'image(k));
          expect_flag(play_half = '0',
                      "play_half not 0 after half 1, frame " & integer'image(k));
          -- Deliberately not acked.
        end if;

      end if;

      -- After the second flip out of half 0 (into the never-acked half 1),
      -- underrun must be set, and playback must have continued.
      if (k = 3 * samples_per_half - 1) then
        expect_flag(underrun = '1',
                    "underrun not set on flip into un-acked half 1");
      end if;

      if ((k < 3 * samples_per_half - 1) and (underrun = '1')) then
        errs := errs + 1;
        report "FAIL underrun set early, frame " & integer'image(k) severity error;
      end if;

    end loop;

    -- Recover: ack everything, clear underrun, confirm clean.
    pulse_ack("11", '1');
    expect_flag(half_consumed = "00", "consumed flags did not clear");
    expect_flag(underrun = '0', "underrun did not clear");
    expect_flag(overrun = '0', "assembler reported overrun");

    report "checked " & integer'image(frames) & " frames across "
           & integer'image(frames / samples_per_half) & " half-transitions";

    if (errs = 0) then
      report "PASS: lane addressing, row advance, consumed/ack, underrun";
    else
      report "FAIL: " & integer'image(errs) & " error(s)" severity failure;
    end if;

    sim_done <= true;
    wait;

  end process checker;

  watchdog : process is
  begin

    wait for 20 ms;

    if not sim_done then
      report "FAIL: timeout" severity failure;
    end if;

    wait;

  end process watchdog;

end architecture sim;

-- ---------------------------------------------------------------------------
-- tb_argus_rhd2132_model.vhd
-- ---------------------------------------------------------------------------
library ieee;

use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_argus_rhd2132_model is
end entity tb_argus_rhd2132_model;

architecture sim of tb_argus_rhd2132_model is

    constant CH_PER_CHIP : natural := 32;
    constant CHIP_ID     : natural := 2;
    constant PATTERN     : natural := 0; -- IDENT

    constant CLK_PERIOD : time := 10 ns; -- 100 MHz PL clock 
    constant TSCLK      : time := 100 ns; -- 10 MHz SCLK, 10x oversampled
    constant TCS        : time := 200 ns; --CS setup / hold / inter-frame gap

    constant OP_CONVERT : std_logic_vector(1 downto 0) := "00";
    constant OP_READ    : std_logic_vector(1 downto 0) := "11";

    signal clk      : std_logic := '0'; 
    signal rst_n    : std_logic := '0';
    
    signal sclk : std_logic := '0';
    signal cs_n : std_logic := '1';
    signal mosi : std_logic := '0';
    signal miso : std_logic;
    signal miso_oe : std_logic; 

    signal dbg_last_cmd     : std_logic_vector(15 downto 0);
    signal dbg_cmd_valid    : std_logic;
    signal dbg_last_resp    : std_logic_vector(15 downto 0);

    signal sim_done         : boolean := false;

    function hex4 (v : std_logic_vector(15 downto 0)) return string is
        constant DIGITS : string(1 to 16) := "0123456789ABCDEF";
        variable s      : string(1 to 4);
        variable nib    : integer;
    begin 
        for i in 0 to 3 loop
            nib := to_integer(unsigned(v(15 - 4 * i downto 12 - 4 * i)));
            s(i + 1) := DIGITS(nib + 1);
        end loop;
        return s;
    end function hex4;

    function cmd_convert (ch : natural) return std_logic_vector is
    begin
        return OP_CONVERT & std_logic_vector(to_unsigned(ch, 6)) & x"00";
    end function cmd_convert;

    function cmd_read (addr : natural) return std_logic_vector is
    begin 
        return OP_READ & std_logic_vector(to_unsigned(addr, 6)) & x"00";
    end function cmd_read;

    function golden_response (
        cmd : std_logic_vector(15 downto 0);
        idx : unsigned(7 downto 0)
    ) return std_logic_vector is
    begin 
        if cmd(15 downto 14) = OP_CONVERT then 
            return std_logic_vector(to_unsigned(CHIP_ID mod 4, 2))
                & cmd(13 downto 8)
                & std_logic_vector(idx);
        else
            return x"0000";
        end if;
    end function golden_response;
begin
    clk <= not clk after CLK_PERIOD / 2 when not sim_done else '0';
    
    dut : entity work.argus_rhd2132_model
        generic map (
            CH_PER_CHIP => CH_PER_CHIP,
            CHIP_ID     => CHIP_ID,
            PATTERN     => PATTERN
        )
        port map(
            clk           => clk,
            rst_n         => rst_n,
            sclk          => sclk,
            cs_n          => cs_n,
            mosi          => mosi,
            miso          => miso,
            miso_oe       => miso_oe,
            dbg_last_cmd  => dbg_last_cmd,
            dbg_cmd_valid => dbg_cmd_valid,
            dbg_last_resp => dbg_last_resp
        );
    
    stim : process

        variable resp    : std_logic_vector(15 downto 0);
        variable cmd     : std_logic_vector(15 downto 0);
        variable exp_new : std_logic_vector(15 downto 0);

        variable exp_d1 : std_logic_vector(15 downto 0) := (others => '0');
        variable exp_d2 : std_logic_vector(15 downto 0) := (others => '0');
        
        variable primed     : natural := 0;
        variable golden_idx : unsigned(7 downto 0) := (others => '0');
        variable errors     : natural := 0;
        variable ident  : string(1 to 5);

        procedure spi_xfer (
            cmd_in : in std_logic_vector(15 downto 0);
            r      : out std_logic_vector(15 downto 0)
        ) is
            variable acc : std_logic_vector(15 downto 0) := (others => '0');
        begin 
            mosi <= cmd_in(15);
            cs_n <= '0';
            wait for TCS;

            for i in 15 downto 0 loop
                mosi <= cmd_in(i);
                wait for TSCLK / 2;
                sclk <= '1';
                acc := acc(14 downto 0) & miso;
                wait for TSCLK / 2;
                sclk <= '0';
            end loop;

            wait for TCS;
            cs_n <= '1';
            wait for TCS;
            r := acc;
        end procedure spi_xfer;

    begin
        report "--- argus_rhd2132_model: chip " & integer'image(CHIP_ID)
            & ", " & integer'image(CH_PER_CHIP) & " channels---";
        
        rst_n <= '0';
        wait for 10 * CLK_PERIOD;
        rst_n <= '1';
        wait for 10 * CLK_PERIOD;

        for sweep in 0 to 2 loop
            for ch in 0 to CH_PER_CHIP - 1 loop
                cmd := cmd_convert(ch);

                exp_new := golden_response(cmd, golden_idx);
                if ch = CH_PER_CHIP - 1 then
                    golden_idx := golden_idx + 1;
                end if;
                
                spi_xfer(cmd, resp);

                if primed >= 2 then
                    if resp /= exp_d2 then
                        errors := errors + 1;
                        report "FAIL sweep " & integer'image(sweep)
                            & " ch " & integer'image(ch)
                            & ": resp=" & hex4(resp)
                            & " expected=" & hex4(exp_d2)
                            severity error;
                    end if;
                else
                    primed := primed + 1;
                end if;

                exp_d2 := exp_d1;
                exp_d1 := exp_new;
            end loop;
        end loop;
        
        for i in 0 to 4 loop
            spi_xfer(cmd_read(40 + i), resp);
            spi_xfer(cmd_read(63), resp);
            spi_xfer(cmd_read(63), resp);
            ident(i + 1) := character'val(to_integer(unsigned(resp(7 downto 0))));
        end loop;
        
        report "chip identifier: " & ident
            & " (expect INTAN -- register addresses unconfirmed)";
        
        if errors = 0 then
            report "PASS: pipeline depth and channel identity verified";
        else
            report "FAIL: " & integer'image(errors) & "mismatches"
                severity failure;
        end if;

        sim_done <= true;
        wait;
    end process stim;

    watchdog : process
    begin
        wait for 5 ms;
        if not sim_done then
            report "FAIL: timeout" severity failure;
        end if;
        wait;
    end process watchdog;
    
end architecture sim;
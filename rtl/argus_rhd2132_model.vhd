library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity argus_rhd2132 model is
    generic (
        CH_PER_CHIP : natural := 32;
        CHIP_ID : natural := 0;

        PATTERN : natural := 0
        );
        port (
            clk : in std_logic;
            rst_n : in std_logic;

            sclk : in std_logic;
            cs_n : in std_logic;
            mosi : in std_logic;
            miso : out std_logic;

            dbg_last_cmd : out std_logic_vector(15 downto 0);
            dbg_cmd_valid : out std_logic;
            dbg_last_resp : out std_logic_vector(15 downto 0);
        );
    end entity argus_rhd2132_model;

    architecture rtl of argus_rhd2132_model is
        constant PATTERN_IDENT : natural := 0;
        constant PATTERN_RAMP  : natural := 1;

        constant OP_CONVERT : std_logic_vector(1 downto 0) := "00";
        constant OP_AUX     : std_logic_vector(1 downto 0) := "01"; -- CALIBRATE, CLEAR
        constant OP_WRITE   : std_logic_vector(1 downto 0) := "10";
        constant OP_READ    : std_logic_vector(1 downto 0) := "11";

        type regfile_t is array (0 to 63 of std_logic_vector(7 downto 0));

        function init_regfile return regfile_t is
            variable r : regfile_t := (others 
        -- fill out later=> (others => '0'));
        begin
            r(40) := std_logic_vector(to_unsigned(character'pos('I'), 8));
            r(41) := std_logic_vector(to_unsigned(character'pos('N'), 8));
            r(42) := std_logic_vector(to_unsigned(character'pos('T'), 8));
            r(43) := std_logic_vector(to_unsigned(character'pos('A'), 8));
            r(44) := std_logic_vector(to_unsigned(character'pos('N'), 8));
            return r;
        end function init_regfile;

        function sample_value (
            ch : std_logic_vector(5 downto 0);
            sample_idx : std_logic_vector(7 downto 0);
            chip : natural;
            pat : natural
        ) return std_logic_vector is
            variable phase : unsigned(7 downto 0);
            variable ramp : signed(15 downto 0);
        begin
            if pat = PATTERN_RAMP then
                phase := unsigned(sample_idx) + resize(unsigned(ch), 8);
                
                ramp := shift_left(resize(signed(phase), 16), 6);
                return std_logic_vector(unsigned(ramp) + x"8000");
            else 
                return std_logic_vector(to_unsigned(chip mod 4, 2)) & ch & sample_idx;
            end if;
        end function sample_value;

        function rhd_response(
            cmd : std_logic_vector(15 downto 0);
            sample_idx : std_logic_vector(7 downto 0);
            regs : regfile_t;
            chip : natural;
            pat : natural
        ) return std_logic_vector is
            variable op : std_logic_vector(1 downto 0);
            variable arg : std_logic_vector(5 downto 0);
        begin
            op := cmd(15 downto 14);
            arg := cmd(13 downto 8);
            case op is
                when OP_CONVERT =>
                    return sample_value(arg, sample_idx, chip, pat);
                when OP_WRITE =>
                    return x"00" & cmd(7 downto 0);
                when OP_READ =>
                    return x"00" & regs(to_integer(unsigned(arg)));
                when others =>
                    return x"0000";
            end case;
        end function rhd_response;

        function is_sweep_end (
            cmd     : std_logic_vector(15 downto 0);
            n_chan  : natural
        ) return boolean is
        begin
            return (cmd(15 downto 14) = OP_CONVERT)
                and (unsigned(cmd(13 downto 8)) = to_unsigned(n_chan - 1, 6));
        end function is_sweep_end;
        
        signal sclk_q : std_logic := '0';
        signal cs_n_q : std_logic := '1';

        signal sclk_rise : std_logic;
        signal sclk_fall : std_logic;
        signal cs_assert : std_logic;
        signal cs_deassert : std_logic;

        signal shift_in : std_logic_vector(15 downto 0) := (others => '0');
        signal shift_out : std_logic_vector(15 downto 0) := (others => '0');
        signal bit_cnt : unsigned(4 downto 0) := (others => '0');

        signal resp_prev : std_logic_vector(15 downto 0) := (others => '0');
        signal resp_last : std_logic_vector(15 downto 0) := (others => '0');

        signal sample_idx : std_logic_vector(7 downto 0) := (others => '0');
        signal regfile : regfile_t := init_regfile;
        signal last_cmd : std_logic_vector(15 downto 0) := (others => '0');
        signal cmd_valid : std_logic := '0';

    begin
        sclk_rise <= sclk and not sclk_q;
        sclk_fall <= (not sclk) and slk_q;
        cs_assert <= (not cs_n) and cs_n_q;
        cs_deassert <= cs_n and (not cs_n_q);

        process (clk)
        begin
            if rising_edge(clk) then
                sclk_q <= sclk;
                cs_n_q <= cs_n;

                if rst_n = '0' then
                    shift_in <= (others => '0');
                    shift_out <= (others => '0');
                    bit_cnt <= (others => '0');
                    resp_prev <= (others => '0');
                    resp_last <= (others => '0');
                    sample_idx <= (others => '0');
                    last_cmd <= (others => '0');
                    cmd_valid <= '0';
                else
                    cmd_valid <= '0';

                    if cs_assert = '1' then
                        bit_cnt <= (others => '0');
                        shift_out <= resp_prev;
                        shift_in <= (others => '0');
                    end if;

                    if cs_n = '0' then
                        if sclk_rise = '1' then
                            shift_in <= shift_in(14 downto 0) & modi;
                            bit_cnt <= bit_cnt + 1;
                        end if;

                        if (sclk_fall = '1') and (bit_cnt /= 0) then
                            shift_out <= shift_out(14 downto 0) & '0';
                        end if;

                        if (cs_deassert = '1') and (bit_cnt = 16) then
                            last_cmd <= shift_in;
                            cmd_valid <= '1';

                            if shift_in(15 downto 14) OP_WRITE then
                                regfile(to_integer(unsigned(shift_in(13 downto 8))))
                            end if;

                            if is_sweep_end(shift_in, CH_PER_CHIP) then
                                sample_idx <= std_logic_vector(unsigned(sample_idx) + 1);
                            end if;

                            resp_last <= rhd_response(shift_in, sample_idx, regfile, CHIP_ID, PATTERN);
                            resp_prev <= resp_last;
                        end if;
                    end if;
                end if;
        end process;
        dbg_last_cmd <= last_cmd;
        dbg_cmd_valid <= cmd_valid;
        dbg_last_resp <= resp_last;
    end architecture rtl;